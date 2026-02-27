# frozen_string_literal: true

# IFTTT Queue Processor for Zpravobot Next Generation
#
# Facade class — delegates webhook processing to:
#   - WebhookPayloadParser: payload parsing + config resolution
#   - WebhookEditHandler: edit detection + update/delete+republish
#   - WebhookThreadHandler: thread detection + resolution
#   - WebhookPublisher: format, publish, update state
#
# Zpracovává webhook payloady z queue directory.
# Může být spuštěn:
# 1. Jako samostatný daemon (continuous processing)
# 2. Jako cron job (batch processing)
# 3. Integrován do hlavního orchestrátoru
#
# Priority zpracování:
# - HIGH: Okamžité zpracování, bez batch logiky, bez thread detection
# - NORMAL/LOW: Batch s delay, thread-aware, normal před low

require 'json'
require 'fileutils'
require 'set'
require_relative '../adapters/twitter_nitter_adapter'
require_relative '../config/config_loader'
require_relative '../state/state_manager'
require_relative '../publishers/mastodon_publisher'
require_relative '../formatters/twitter_formatter'
require_relative '../processors/post_processor'
require_relative '../processors/edit_detector'
require_relative '../processors/twitter_tweet_processor'
require_relative 'webhook_payload_parser'
require_relative 'webhook_edit_handler'
require_relative 'webhook_thread_handler'

# Optional processors (shared with orchestrator)
require_relative '../support/optional_processors'
require_relative '../support/loggable'
include Support::OptionalProcessors

module Webhook
  class IftttQueueProcessor
    include Support::Loggable

    QUEUE_DIR = ENV['IFTTT_QUEUE_DIR'] || (ENV['ZBNW_DIR'] ? "#{ENV['ZBNW_DIR']}/queue/ifttt" : '/app/data/zbnw-ng/queue/ifttt')

    # Timing constants
    BATCH_DELAY = 120      # 2 min - čas na nahromadění batche
    MAX_AGE = 1800         # 30 min - force publish (anti-hromadění)

    # Priority constants
    PRIORITY_HIGH = 'high'
    PRIORITY_NORMAL = 'normal'
    PRIORITY_LOW = 'low'
    DEFAULT_PRIORITY = PRIORITY_NORMAL

    # Edit detection constants
    EDIT_BUFFER_CLEANUP_HOURS = 2

    attr_reader :config_loader, :state_manager, :adapter, :edit_detector

    def initialize(config_dir: nil, nitter_instance: nil)
      config_path = config_dir || ENV['ZBNW_CONFIG_DIR'] || (ENV['ZBNW_DIR'] ? "#{ENV['ZBNW_DIR']}/config" : '/app/data/zbnw-ng/config')
      @config_loader = Config::ConfigLoader.new(config_path)
      @state_manager = State::StateManager.new
      nitter = nitter_instance || ENV['NITTER_INSTANCE']
      @adapter = Adapters::TwitterNitterAdapter.new(nitter_instance: nitter)

      # Thread cache pro ThreadingSupport modul
      @thread_cache = {}

      # Priority cache - username → priority
      @priority_cache = {}

      # Publisher cache - mastodon_account → publisher
      @publisher_cache = {}

      # Track published counts per source_id (for mark_check_success)
      @published_sources = Hash.new(0)

      # Edit detector for Twitter edit deduplication
      @edit_detector = Processors::EditDetector.new(@state_manager, logger: @logger)

      # PostProcessor for unified processing
      @post_processor = Processors::PostProcessor.new(
        state_manager: @state_manager,
        config_loader: @config_loader,
        logger: nil,
        dry_run: false,
        verbose: false
      )

      # Unified tweet processor (TASK-10: single pipeline for IFTTT + RSS)
      @tweet_processor = Processors::TwitterTweetProcessor.new(
        state_manager: @state_manager,
        config_loader: @config_loader,
        nitter_instance: nitter,
        post_processor: @post_processor
      )

      # Pipeline components
      @payload_parser = WebhookPayloadParser.new
      @edit_handler = WebhookEditHandler.new(@edit_detector, @thread_cache)
      @thread_handler = WebhookThreadHandler.new(
        @adapter,
        tweet_processor: @tweet_processor
      )
      log "Initialized with config_dir: #{config_path}"
      log "Using PostProcessor for unified processing pipeline"
      log "Edit detection enabled (buffer cleanup: #{EDIT_BUFFER_CLEANUP_HOURS}h)"
      log "Batch delay: #{BATCH_DELAY}s, Max age: #{MAX_AGE}s"
    end

    # ===========================================
    # Main Processing Loop
    # ===========================================

    # Process all pending webhooks in queue
    # @return [Hash] Processing statistics
    def process_queue
      # Cleanup edit buffer at start of each run
      cleanup_count = @edit_detector.cleanup(retention_hours: EDIT_BUFFER_CLEANUP_HOURS)
      log "Edit buffer cleanup: #{cleanup_count} old entries removed" if cleanup_count > 0

      pending_dir = File.join(QUEUE_DIR, 'pending')
      files = Dir.glob(File.join(pending_dir, '*.json')).sort

      stats = { processed: 0, published: 0, skipped: 0, failed: 0, updated: 0 }

      return stats if files.empty?

      log "Found #{files.count} pending webhooks"

      # Partition by priority
      high, normal, low = partition_by_priority(files)

      log "Priority breakdown: high=#{high.count}, normal=#{normal.count}, low=#{low.count}"

      # 1. HIGH = okamžitě, bez batch logiky
      high.each do |filepath|
        result = process_webhook_file(filepath, force_tier2: false)
        stats[result] = (stats[result] || 0) + 1
        stats[:processed] += 1
      end

      # 2. NORMAL + LOW = batch s delay, thread-aware
      batch_candidates = normal + low  # Normal first, then low
      ready = batch_candidates.select { |f| ready_for_processing?(f) }

      if ready.any?
        log "Processing batch of #{ready.count} webhooks (#{batch_candidates.count - ready.count} still waiting)"
        batch_results = process_batch(ready)
        batch_results.each do |result|
          stats[result] = (stats[result] || 0) + 1
          stats[:processed] += 1
        end
      else
        waiting = batch_candidates.count
        log "No webhooks ready for batch processing (#{waiting} waiting for delay)" if waiting > 0
      end

      # Update source_state for all sources that had successful publishes
      @published_sources.each do |source_id, count|
        @state_manager.mark_check_success(source_id, posts_published: count)
        log "Marked source '#{source_id}' success (#{count} posts)"
      end
      @published_sources.clear

      log "Queue processing complete: #{stats.inspect}", level: :success
      stats
    end

    private

    # ===========================================
    # Priority Partitioning
    # ===========================================

    # Partition files by priority
    # @param files [Array<String>] File paths
    # @return [Array<Array<String>>] [high, normal, low]
    def partition_by_priority(files)
      high = []
      normal = []
      low = []

      files.each do |filepath|
        priority = get_file_priority(filepath)
        case priority
        when PRIORITY_HIGH
          high << filepath
        when PRIORITY_LOW
          low << filepath
        else
          normal << filepath
        end
      end

      [high, normal, low]
    end

    # Get priority for a file (with caching)
    # @param filepath [String] Path to webhook file
    # @return [String] Priority level
    def get_file_priority(filepath)
      username = extract_username_from_filename(filepath)
      return DEFAULT_PRIORITY unless username

      # Check cache first
      return @priority_cache[username] if @priority_cache.key?(username)

      # Lookup and cache
      priority = lookup_priority(username)
      @priority_cache[username] = priority
      priority
    end

    # Lookup priority from config
    # @param username [String] Twitter username
    # @return [String] Priority level
    def lookup_priority(username)
      config = safe_find_config_for_username(username)
      config&.dig(:scheduling, :priority) || DEFAULT_PRIORITY
    end

    # Find config for username (without full bot_config fallback)
    # @param username [String] Twitter username
    # @return [Hash, nil] Config hash or nil
    def safe_find_config_for_username(username)
      normalized = username.to_s.gsub(/^@/, '').downcase

      # Try username as source id
      config = safe_load_source(normalized)
      return config if config

      # Try to find by handle
      find_source_by_handle('twitter', normalized)
    rescue StandardError => e
      log "safe_find_config_for_username(#{username}): #{e.message}", level: :warn
      nil
    end

    # Extract username from filename
    # Format: 20260128061014529_andrewofpolesia_2016392716460937235.json
    # @param filepath [String] File path
    # @return [String, nil] Username or nil
    def extract_username_from_filename(filepath)
      filename = File.basename(filepath, '.json')
      parts = filename.split('_')
      return nil if parts.length < 3

      parts[1]&.downcase
    end

    # Check if file is ready for batch processing
    # @param filepath [String] File path
    # @return [Boolean] true if ready
    def ready_for_processing?(filepath)
      age = Time.now - File.mtime(filepath)
      age >= BATCH_DELAY || age >= MAX_AGE
    end

    # ===========================================
    # Batch Processing with Thread Detection
    # ===========================================

    # Process batch of files with thread detection
    # @param files [Array<String>] File paths (already sorted: normal first, then low)
    # @return [Array<Symbol>] Results for each file
    def process_batch(files)
      results = []

      # Pre-scan: identify authors with multiple tweets in batch
      multi_tweet_authors = detect_multi_tweet_authors(files)

      if multi_tweet_authors.any?
        log "Multi-tweet authors detected: #{multi_tweet_authors.to_a.join(', ')}"
      end

      # Track which authors we've already seen in this batch
      authors_seen = Set.new

      files.each do |filepath|
        username = extract_username_from_filename(filepath)

        # Force Tier 2 if:
        # - Author has multiple tweets in batch AND
        # - This is NOT their first tweet in this batch
        force_tier2 = username &&
                      multi_tweet_authors.include?(username) &&
                      authors_seen.include?(username)

        if force_tier2
          log "Forcing Tier 2 for #{username} (potential thread continuation)"
        end

        result = process_webhook_file(filepath, force_tier2: force_tier2)
        results << result

        # Mark author as seen AFTER processing (first tweet goes through normal tier detection)
        authors_seen.add(username) if username
      end

      results
    end

    # Detect authors with multiple tweets in batch
    # @param files [Array<String>] File paths
    # @return [Set<String>] Set of usernames with multiple tweets
    def detect_multi_tweet_authors(files)
      author_counts = Hash.new(0)

      files.each do |filepath|
        username = extract_username_from_filename(filepath)
        author_counts[username] += 1 if username
      end

      Set.new(author_counts.select { |_, count| count > 1 }.keys)
    end

    # ===========================================
    # Single File Processing
    # ===========================================

    # Process single webhook file
    # @param filepath [String] Path to webhook JSON file
    # @param force_tier2 [Boolean] Force Tier 2 processing for thread detection
    # @return [Symbol] Result (:published, :skipped, :failed, :updated)
    def process_webhook_file(filepath, force_tier2: false)
      filename = File.basename(filepath)

      begin
        payload = JSON.parse(File.read(filepath))
        result = process_webhook(payload, force_tier2: force_tier2)

        case result
        when :published, :skipped, :updated
          move_to_processed(filepath)
          result
        when :failed
          move_to_failed(filepath, 'Processing failed')
          :failed
        else
          move_to_processed(filepath)
          :processed
        end
      rescue JSON::ParserError => e
        log "Invalid JSON in #{filename}: #{e.message}", level: :error
        move_to_failed(filepath, "Invalid JSON: #{e.message}")
        :failed
      rescue StandardError => e
        log "Error processing #{filename}: #{e.message}", level: :error
        log e.backtrace.first(5).join("\n"), level: :error
        move_to_failed(filepath, "Error: #{e.message}")
        :failed
      end
    end

    # ===========================================
    # Webhook Processing Pipeline
    # ===========================================

    # Process single webhook payload
    # Delegates to: PayloadParser → EditHandler → ThreadHandler → Publisher
    # @param payload [Hash] Webhook data
    # @param force_tier2 [Boolean] Force Tier 2 processing
    # @return [Symbol] Result (:published, :skipped, :failed, :updated)
    def process_webhook(payload, force_tier2: false)
      # Step 1: Parse payload and resolve config
      parsed = @payload_parser.parse(payload, method(:find_bot_config))
      unless parsed
        log "No config found for payload (bot_id=#{payload['bot_id']}, username=#{payload['username']}), skipping", level: :warn
        return :skipped
      end
      log "Processing: @#{parsed.username}/#{parsed.post_id} for bot '#{parsed.bot_id}'#{force_tier2 ? ' [force_tier2]' : ''}"

      # Step 2: Edit detection
      edit_result = @edit_handler.handle(
        parsed,
        adapter: adapter, payload: payload, force_tier2: force_tier2,
        publisher_getter: method(:get_publisher),
        formatter: method(:format_post_text),
        updater: method(:try_update_mastodon_status),
        state_manager: @state_manager,
        published_sources: @published_sources
      )
      return edit_result if edit_result

      # Step 3: Process via TwitterTweetProcessor
      # Handles: Nitter fetch (+ retry), Syndication fallback, threading, PostProcessor
      result = @thread_handler.handle(parsed, payload: payload, force_tier2: force_tier2)

      # Step 4: Track published sources on success
      @published_sources[parsed.source_id] += 1 if result == :published

      result
    end

    # ===========================================
    # Edit Detection Helpers
    # ===========================================

    # Format post text using formatter (for Mastodon update)
    # @param post [Post] Post object
    # @param bot_config [Hash] Bot configuration
    # @return [String] Formatted text
    def format_post_text(post, bot_config)
      formatter = Formatters::TwitterFormatter.new(bot_config[:formatting] || {})
      text = formatter.format(post)

      # Apply content replacements if configured
      replacements = bot_config.dig(:processing, :content_replacements) || []
      replacements.each do |repl|
        pattern = repl[:literal] ? Regexp.escape(repl[:pattern]) : repl[:pattern]
        flags = repl[:flags] || ''
        regex_flags = 0
        regex_flags |= Regexp::IGNORECASE if flags.include?('i')
        regex_flags |= Regexp::MULTILINE if flags.include?('m')

        begin
          regex = Regexp.new(pattern, regex_flags)
          text = if flags.include?('g')
                   text.gsub(regex, repl[:replacement] || '')
                 else
                   text.sub(regex, repl[:replacement] || '')
                 end
        rescue RegexpError => e
          log "Invalid regex in content_replacements: #{e.message}", level: :warn
        end
      end

      text
    end

    # Try to update existing Mastodon status
    # @param mastodon_id [String] Mastodon status ID
    # @param new_text [String] New status text
    # @param bot_config [Hash] Bot configuration
    # @return [Hash] { success:, data: or error: }
    def try_update_mastodon_status(mastodon_id, new_text, bot_config)
      publisher = get_publisher(bot_config)

      updated = publisher.update_status(mastodon_id, new_text)
      { success: true, data: updated }

    rescue Publishers::MastodonPublisher::StatusNotFoundError => e
      { success: false, error: "Status not found: #{e.message}" }

    rescue Publishers::MastodonPublisher::EditNotAllowedError => e
      { success: false, error: "Edit not allowed: #{e.message}" }

    rescue StandardError => e
      { success: false, error: "Update failed: #{e.message}" }
    end

    # Get or create publisher for bot config
    # @param bot_config [Hash] Bot configuration
    # @return [Publishers::MastodonPublisher]
    def get_publisher(bot_config)
      account_id = bot_config.dig(:target, :mastodon_account)
      global = @config_loader.load_global_config
      instance_url = bot_config.dig(:target, :mastodon_instance) || global.dig(:mastodon, :instance)

      cache_key = "#{instance_url}:#{account_id}"
      return @publisher_cache[cache_key] if @publisher_cache[cache_key]

      # Load account credentials using correct ConfigLoader method
      account_creds = @config_loader.mastodon_credentials(account_id)
      token = account_creds[:token]

      unless token
        raise "Mastodon account '#{account_id}' not found or has no token"
      end

      publisher = Publishers::MastodonPublisher.new(
        instance_url: instance_url,
        access_token: token
      )

      @publisher_cache[cache_key] = publisher
      publisher
    end

    # ===========================================
    # Bot Configuration
    # ===========================================

    DEFAULT_AGGREGATOR = 'betabot'

    # Find bot configuration by bot_id (primary) or username
    def find_bot_config(bot_id, username)
      normalized_username = username.to_s.gsub(/^@/, '').downcase
      log "Looking for config: bot_id=#{bot_id}, username=#{normalized_username}"

      # Primary: Try explicit bot_id (authoritative identifier from IFTTT payload)
      if bot_id && !bot_id.empty?
        config = safe_load_source(bot_id.downcase)
        if config
          log "Found by bot_id: #{config[:id]}"
          return enrich_mentions(config)
        end
      end

      # Secondary: Try username as source id
      config = safe_load_source(normalized_username)
      if config
        log "Found by username as source_id: #{config[:id]}"
        return enrich_mentions(config)
      end

      # Tertiary: Search Twitter sources by handle
      log 'Trying fallback: search by handle in twitter sources'
      config = find_source_by_handle('twitter', normalized_username)
      if config
        log "Found by handle fallback: #{config[:id]}"
        return enrich_mentions(config)
      end

      # Final fallback: Use default aggregator
      log "No specific config found, using default aggregator: #{DEFAULT_AGGREGATOR}", level: :warn
      enrich_mentions(build_aggregator_config(normalized_username))
    end

    # Build a minimal config for aggregator fallback
    def build_aggregator_config(username)
      platform_sources = config_loader.load_sources_by_platform('twitter')
      platform_defaults = platform_sources.first || {}

      formatting = (platform_defaults[:formatting] || {}).merge(
        source_name: "@#{username}"
      )

      {
        id: "ifttt_#{username}",
        platform: 'twitter',
        source: { handle: username },
        target: {
          mastodon_account: DEFAULT_AGGREGATOR,
          mastodon_instance: @config_loader.load_global_config.dig(:mastodon, :instance),
          visibility: 'public'
        },
        filtering: platform_defaults[:filtering] || {
          skip_replies: true,
          skip_retweets: false,
          banned_phrases: [],
          required_keywords: []
        },
        formatting: formatting,
        processing: platform_defaults[:processing] || {},
        url: platform_defaults[:url] || {},
        mentions: platform_defaults[:mentions] || {}
      }
    end

    # Enrich mentions config for Twitter sources with local instance handle map
    # Transforms domain_suffix → domain_suffix_with_local so that known zpravobot.news
    # handles (@CT24zive) are rendered as local mentions (@ct24@zpravobot.news)
    def enrich_mentions(config)
      mentions = config[:mentions] || {}
      return config unless mentions[:type].to_s == 'domain_suffix' && config[:platform].to_s == 'twitter'

      config.merge(
        mentions: mentions.merge(
          type: 'domain_suffix_with_local',
          local_instance: 'zpravobot.news',
          local_handles: config_loader.twitter_handle_to_mastodon_map
        )
      )
    end

    def safe_load_source(source_id)
      config_loader.load_source(source_id)
    rescue StandardError => e
      log "safe_load_source(#{source_id}): #{e.message}", level: :warn
      nil
    end

    def find_source_by_handle(platform, handle)
      sources = config_loader.load_sources_by_platform(platform)
      log "Searching #{sources.count} #{platform} sources for handle '#{handle}'"

      source_hash = sources.find do |s|
        s_handle = s[:source] && s[:source][:handle]
        s_handle&.downcase == handle.downcase
      end

      unless source_hash
        log "Handle '#{handle}' not found in #{platform} sources"
        return nil
      end

      log "Found source: #{source_hash[:id]}"
      source_hash
    rescue StandardError => e
      log "find_source_by_handle(#{platform}, #{handle}): #{e.message}", level: :warn
      nil
    end

    # ===========================================
    # Queue File Management
    # ===========================================

    def move_to_processed(filepath)
      dest = File.join(QUEUE_DIR, 'processed', File.basename(filepath))
      FileUtils.mv(filepath, dest)
    end

    def move_to_failed(filepath, reason)
      data = JSON.parse(File.read(filepath))
      data['_failure'] = {
        reason: reason,
        failed_at: Time.now.iso8601,
        retry_count: 0
      }
      File.write(filepath, JSON.pretty_generate(data))

      dest = File.join(QUEUE_DIR, 'failed', File.basename(filepath))
      FileUtils.mv(filepath, dest)
    end

  end
end

# CLI runner
if __FILE__ == $PROGRAM_NAME
  require 'optparse'

  options = { mode: :once }

  OptionParser.new do |opts|
    opts.banner = "Usage: #{$PROGRAM_NAME} [options]"

    opts.on('-d', '--daemon', 'Run as daemon (continuous processing)') do
      options[:mode] = :daemon
    end

    opts.on('-i', '--interval SECONDS', Integer, 'Polling interval for daemon mode (default: 30)') do |i|
      options[:interval] = i
    end
  end.parse!

  processor = Webhook::IftttQueueProcessor.new

  case options[:mode]
  when :daemon
    interval = options[:interval] || 30
    puts "Running as daemon, polling every #{interval}s..."
    loop do
      processor.process_queue
      sleep interval
    end
  else
    processor.process_queue
  end
end
