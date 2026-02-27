# frozen_string_literal: true

require 'time' # Pro Time.parse v source_due?
require_relative 'logging'
require_relative 'config/config_loader'
require_relative 'support/threading_support'
require_relative 'support/loggable'
require_relative 'state/state_manager'
require_relative 'adapters/rss_adapter'
require_relative 'adapters/youtube_adapter'
require_relative 'adapters/bluesky_adapter'
require_relative 'adapters/twitter_adapter'
require_relative 'formatters/rss_formatter'
require_relative 'formatters/youtube_formatter'
require_relative 'formatters/bluesky_formatter'
require_relative 'formatters/twitter_formatter'
require_relative 'publishers/mastodon_publisher'

# PostProcessor - unified processing pipeline
require_relative 'processors/post_processor'
require_relative 'processors/twitter_tweet_processor'

# Optional processors (shared with ifttt_queue_processor)
require_relative 'support/optional_processors'
include Support::OptionalProcessors

module Orchestrator
  # Main orchestrator that coordinates all components
  #
  # REFACTORED: Now uses PostProcessor for post processing pipeline
  # Orchestrator handles: scheduling, threading, verbose logging
  # PostProcessor handles: dedupe, filtering, formatting, publishing
  #
  class Runner
	include Support::ThreadingSupport
	include Support::Loggable

	attr_reader :config_loader, :state_manager, :stats
	VALID_PLATFORMS = %w[twitter bluesky rss youtube].freeze

	def initialize(config_dir: 'config', schema: nil, first_run: false, verbose: false)
	  @config_dir = config_dir
	  @config_loader = Config::ConfigLoader.new(config_dir)
	  @state_manager = State::StateManager.new(schema: schema)
	  @dry_run = false
	  @first_run = first_run
	  @verbose = verbose
	  @stats = { processed: 0, published: 0, skipped: 0, errors: 0 }
	  @publishers_cache = {}
	  @thread_cache = {} # Pro ThreadingSupport modul

	  # Initialize PostProcessor + TwitterTweetProcessor (lazy - created when needed with dry_run flag)
	  @post_processor = nil
	  @tweet_processor = nil
	end

	# Get or create PostProcessor instance
	def post_processor
	  @post_processor ||= Processors::PostProcessor.new(
		state_manager: @state_manager,
		config_loader: @config_loader,
		logger: nil,
		dry_run: @dry_run,
		verbose: verbose_mode?
	  )
	end

	# Get or create TwitterTweetProcessor (singleton shared across all Twitter sources)
	# Shared instance is important — TwitterTweetProcessor maintains per-source
	# @thread_processor_cache for advanced threading consistency.
	def tweet_processor
	  @tweet_processor ||= Processors::TwitterTweetProcessor.new(
		state_manager:   @state_manager,
		config_loader:   @config_loader,
		nitter_instance: ENV['NITTER_INSTANCE'],
		dry_run:         @dry_run,
		post_processor:  post_processor
	  )
	end

	# Run all enabled sources
	def run(dry_run: false, priority: nil, exclude_platform: nil, first_run: false)
	  @dry_run = dry_run
	  @first_run = first_run
	  @post_processor = nil  # Reset to pick up new dry_run setting
	  @tweet_processor = nil # Reset so it inherits new @post_processor + dry_run
	  @stats = { processed: 0, published: 0, skipped: 0, errors: 0 }

	  if exclude_platform && !VALID_PLATFORMS.include?(exclude_platform)
		raise ArgumentError, "Invalid platform: #{exclude_platform}. Valid: #{VALID_PLATFORMS.join(', ')}"
	  end

	  log_info("Starting orchestrator run (dry_run: #{dry_run})")
	  log_info("Excluding platform: #{exclude_platform}") if exclude_platform

	  @state_manager.connect
	  sources = @config_loader.load_all_sources
	  sources = sources.select { |s| s.dig(:scheduling, :priority) == priority } if priority
	  sources = sources.reject { |s| s[:platform] == exclude_platform } if exclude_platform

	  log_info("Found #{sources.length} enabled sources")

	  sources.each do |source_data|
		break if $shutdown_requested
		source = Config::SourceConfig.new(source_data)
		process_source(source)
	  end

	  log_info("Run complete: #{@stats}")
	  @stats
	ensure
	  @state_manager.disconnect
	end

	# Run a specific source by ID
	def run_source(source_id, dry_run: false, first_run: false)
	  @dry_run = dry_run
	  @first_run = first_run
	  @post_processor = nil
	  @tweet_processor = nil
	  @stats = { processed: 0, published: 0, skipped: 0, errors: 0 }

	  log_info("Running source: #{source_id}")

	  @state_manager.connect
	  source_data = @config_loader.load_source(source_id)
	  source = Config::SourceConfig.new(source_data)
	  process_source(source)

	  log_info("Source complete: #{@stats}")
	  @stats
	ensure
	  @state_manager.disconnect
	end

	# Run all sources for a specific platform
	def run_platform(platform, dry_run: false, first_run: false)
	  @dry_run = dry_run
	  @first_run = first_run
	  @post_processor = nil
	  @tweet_processor = nil
	  @stats = { processed: 0, published: 0, skipped: 0, errors: 0 }

	  unless VALID_PLATFORMS.include?(platform)
		raise ArgumentError, "Invalid platform: #{platform}. Valid: #{VALID_PLATFORMS.join(', ')}"
	  end

	  log_info("Running platform: #{platform}")

	  @state_manager.connect
	  sources = @config_loader.load_sources_by_platform(platform)

	  log_info("Found #{sources.length} sources for #{platform}")

	  sources.each do |source_data|
		break if $shutdown_requested
		source = Config::SourceConfig.new(source_data)
		process_source(source)
	  end

	  log_info("Platform complete: #{@stats}")
	  @stats
	ensure
	  @state_manager.disconnect
	end

	private

	# Process a single source
	def process_source(source)
	  log_info("[#{source.id}] Processing...")
	  @stats[:processed] += 1

	  # Reset thread cache for this source at start of processing
	  @thread_cache[source.id] = {}

	  unless source_due?(source)
		log_info("[#{source.id}] Not due yet, skipping")
		return
	  end

	  if skip_maintenance_window?(source)
		log_info("[#{source.id}] Skipping (maintenance window, hour=#{Time.now.hour})")
		@state_manager.mark_check_success(source.id, posts_published: 0)
		return
	  end

	  if @first_run
		return process_first_run(source)
	  end

	  state = @state_manager.get_source_state(source.id)
	  since = extract_since_time(state)

	  adapter = create_adapter(source)
	  posts = adapter.fetch_posts(since: since)

	  log_info("[#{source.id}] Fetched #{posts.length} posts")
	  @state_manager.log_fetch(source.id, posts_found: posts.length)

	  max_posts = source.max_posts_per_run
	  posts = posts.first(max_posts)
	  posts = posts.sort_by { |p| p.published_at || Time.at(0) }

	  published_count = 0
	  posts.each do |post|
		break if $shutdown_requested
		result = if source.platform == 'twitter'
		  process_twitter_post(source, post)
		else
		  process_post(source, post)
		end
		published_count += 1 if result == :published
	  end

	  @state_manager.mark_check_success(source.id, posts_published: published_count)
	rescue Adapters::YouTubeTransientError => e
	  log_warn("[#{source.id}] #{e.message}")
	  @state_manager.log_transient_error(source.id, message: e.message)
	rescue StandardError => e
	  log_error("[#{source.id}] Error: #{e.message}")
	  @state_manager.mark_check_error(source.id, e.message)
	  @state_manager.log_activity(source.id, 'error', { message: e.message, backtrace: e.backtrace.first(3) })
	  @stats[:errors] += 1
	end

	# ============================================
	# REFACTORED: Process a single post
	# Now delegates to PostProcessor
	# ============================================
	def process_post(source, post)
	  post_id = post.id || post.url

	  # VERBOSE: Log raw post data
	  verbose_log_post_input(source.id, post)

	  # Resolve thread parent (Orchestrator-specific)
	  in_reply_to_id = resolve_thread_parent(source, post)

	  # Build source config hash for PostProcessor
	  source_config = build_source_config_hash(source)

	  # Verbose logging callbacks
	  options = {
		in_reply_to_id: in_reply_to_id,
		on_format: ->(text) { verbose_log_step(source.id, 'FORMATTED', text) },
		on_final: ->(text) { verbose_log_final_output(source.id, text) }
	  }

	  # Delegate to PostProcessor
	  result = post_processor.process(post, source_config, options)

	  # Update stats based on result
	  case result.status
	  when :published
		@stats[:published] += 1
		# Update thread cache (Orchestrator-specific)
		update_thread_cache(source.id, post, result.mastodon_id) if result.mastodon_id
	  when :skipped
		@stats[:skipped] += 1
	  when :failed
		@stats[:errors] += 1
	  end

	  result.status
	end

	# Process a single Twitter post via unified TwitterTweetProcessor
	#
	# Replaces the old flow (maybe_fetch_thread_context + resolve_thread_parent + PostProcessor)
	# for Twitter sources. TwitterTweetProcessor handles Nitter fetch, Syndication fallback,
	# threading, and PostProcessor internally.
	#
	# @param source [Config::SourceConfig]
	# @param rss_post [Post]  RSS post from TwitterAdapter (used as Tier 3 fallback)
	# @return [Symbol]  :published, :skipped, or :failed
	def process_twitter_post(source, rss_post)
	  post_id = extract_post_id_from_url(rss_post.url)

	  unless post_id
		log_warn("[#{source.id}] Cannot extract post_id from URL: #{rss_post.url}")
		@stats[:skipped] += 1
		return :skipped
	  end

	  result = tweet_processor.process(
		post_id:       post_id,
		username:      source.source_handle,
		source_config: build_source_config_hash(source),
		fallback_post: rss_post
	  )

	  case result
	  when :published then @stats[:published] += 1
	  when :skipped   then @stats[:skipped] += 1
	  when :failed    then @stats[:errors] += 1
	  end

	  result
	end

	# Extract tweet ID from URL — handles all known formats:
	#   https://twitter.com/user/status/123456
	#   https://x.com/user/status/123456
	#   http://xn.zpravobot.news:8080/user/status/123456  (Nitter RSS)
	#
	# NOTE: The existing regex (?:twitter\.com|x\.com) does NOT match Nitter URLs.
	#       This method uses a generic /status/(\d+) pattern that works universally.
	#
	# @return [String, nil]
	def extract_post_id_from_url(url)
	  return nil unless url
	  url.match(%r{/status/(\d+)})&.[](1)
	end

	# Build source config hash from SourceConfig object
	# PostProcessor expects a Hash, not SourceConfig
	def build_source_config_hash(source)
	  {
		id: source.id,
		platform: source.platform,
		source: {
		  handle: source.source_handle,
		  nitter_instance: source.nitter_instance
		},
		formatting: source.formatting.merge(
		  source_name: source.source_name,
		  max_length: source.post_length
		),
		filtering: source.filtering,
		processing: source.processing.merge(
		  trim_strategy: source.trim_strategy,
		  smart_tolerance_percent: source.processing.fetch(:smart_tolerance_percent, 12),
		  url_domain_fixes: source.url_domain_fixes,
		  content_replacements: source.content_replacements
		),
		target: {
		  mastodon_account: source.mastodon_account,
		  mastodon_instance: source.mastodon_instance,
		  visibility: source.visibility
		},
		content: source.content_config,
		thread_handling: source.thread_handling,
		nitter_processing: source.nitter_processing,
		url: source.url_config,
		rss_source_type: source.respond_to?(:rss_source_type) ? source.rss_source_type : nil,
		mentions: build_mentions_config(source),
		_mastodon_token: source.mastodon_token
	  }
	end

	# Build mentions config — enriches domain_suffix for Twitter sources
	# with local instance handles for zpravobot.news mention transformation
	def build_mentions_config(source)
	  base = source.mentions || {}
	  return base unless base[:type].to_s == 'domain_suffix' && source.platform.to_s == 'twitter'

	  base.merge(
	    type: 'domain_suffix_with_local',
	    local_instance: 'zpravobot.news',
	    local_handles: @config_loader.twitter_handle_to_mastodon_map
	  )
	end

	# ============================================
	# Source timing
	# ============================================

	def extract_since_time(state)
	  return nil unless state

	  ref = state[:last_success] || state[:last_check]
	  return nil unless ref

	  Time.parse(ref.to_s)
	rescue ArgumentError, TypeError
	  nil
	end

	def source_due?(source)
	  state = @state_manager.get_source_state(source.id)
	  return true unless state

	  last_check = state[:last_check]
	  return true unless last_check

	  last_check = Time.parse(last_check) if last_check.is_a?(String)
	  interval = source.interval_minutes * 60
	  Time.now - last_check >= interval
	end

	def skip_maintenance_window?(source)
	  hours = source.skip_hours
	  return false if hours.nil? || hours.empty?

	  hours.include?(Time.now.hour)
	end

	# Resolve thread parent - extends ThreadingSupport with Bluesky-specific logic
	#
	# @param source [SourceConfig] Source configuration
	# @param post [Post] Post to find parent for
	# @return [String, nil] Mastodon status ID of parent
	def resolve_thread_parent(source, post)
	  # Bluesky: explicit reply_to with AT URI (platform-specific)
	  if post.respond_to?(:reply_to) && post.reply_to
		parent_uri = extract_parent_uri_from_reply_to(post.reply_to)
		if parent_uri
		  mastodon_id = find_parent_mastodon_id(source.id, parent_uri)
		  if mastodon_id
			log_info("[#{source.id}] 🧵 Threading: reply to #{mastodon_id} (via reply_to)")
			return mastodon_id
		  end
		end
	  end

	  # Twitter/generic: use shared ThreadingSupport module
	  super(source.id, post)
	end

	def extract_parent_uri_from_reply_to(reply_to)
	  return reply_to unless reply_to.is_a?(Hash)

	  reply_to[:parent_uri] || reply_to['parent_uri'] ||
		reply_to[:uri] || reply_to['uri']
	end

	def find_parent_mastodon_id(source_id, parent_uri)
	  return nil unless parent_uri

	  parent_record = @state_manager.find_by_platform_uri(source_id, parent_uri)
	  parent_record&.dig(:mastodon_status_id)
	end

	# ============================================
	# First run handling
	# ============================================

	def process_first_run(source)
	  log_info("[#{source.id}] FIRST RUN - initializing state")

	  state = @state_manager.get_source_state(source.id)
	  if state
		log_info("[#{source.id}] Already has state, skipping")
		@stats[:skipped] += 1
		return
	  end

	  begin
		adapter = create_adapter(source)
		posts = adapter.fetch_posts(since: nil)
		log_info("[#{source.id}] Fetched #{posts.length} posts")

		if posts.empty?
		  log_info("[#{source.id}] No posts found")
		  @stats[:skipped] += 1
		  @state_manager.mark_check_success(source.id, posts_published: 0)
		  return
		end

		posts = posts.reverse
		valid_post = posts.find do |post|
		  post_id = post.id || post.url
		  next if @state_manager.published?(source.id, post_id)

		  skip_reason = should_skip_for_first_run?(source, post)
		  !skip_reason
		end

		if valid_post.nil?
		  log_info("[#{source.id}] No valid posts found")
		  @stats[:skipped] += 1
		  @state_manager.mark_check_success(source.id, posts_published: 0)
		  return
		end

		post_id = valid_post.id || valid_post.url
		platform_uri = valid_post.respond_to?(:uri) ? valid_post.uri : nil

		@state_manager.mark_published(
		  source.id, post_id,
		  post_url: valid_post.url,
		  platform_uri: platform_uri,
		  mastodon_status_id: nil
		)

		log_info("[#{source.id}] ✅ Initialized with post: #{post_id}")
		@state_manager.mark_check_success(source.id, posts_published: 0)
		@stats[:processed] += 1
	  rescue StandardError => e
		log_error("[#{source.id}] First run error: #{e.message}")
		@state_manager.mark_check_error(source.id, e.message)
		@stats[:errors] += 1
	  end
	end

	# Simplified skip check for first run (no PostProcessor needed)
	def should_skip_for_first_run?(source, post)
	  filtering = source.filtering

	  if post.respond_to?(:is_reply) && post.is_reply
		is_self_reply = post.respond_to?(:is_thread_post) && post.is_thread_post
		return 'is_self_reply_thread' if is_self_reply && filtering[:skip_self_replies]
		return 'is_external_reply' if !is_self_reply && filtering[:skip_replies]
	  end

	  return 'is_retweet' if filtering[:skip_retweets] && post.respond_to?(:is_repost) && post.is_repost

	  return 'is_quote' if filtering[:skip_quotes] && post.respond_to?(:is_quote) && post.is_quote

	  nil
	end

	# ============================================
	# Adapter creation
	# ============================================

	def create_adapter(source)
	  case source.platform
	  when 'rss'
		Adapters::RssAdapter.new(feed_url: source.source_feed_url)
	  when 'youtube'
		Adapters::YouTubeAdapter.new(
		  channel_id: source.source_channel_id,
		  handle: source.source_handle,
		  source_name: source.source_name,
		  no_shorts: source.data.dig(:content, :no_shorts) || false
		)
	  when 'bluesky'
		if source.bluesky_source_type == 'feed'
		  Adapters::BlueskyAdapter.new(feed_url: source.source_feed_url)
		else
		  Adapters::BlueskyAdapter.new(
			handle: source.source_handle,
			include_self_threads: true
		  )
		end
	  when 'twitter'
		Adapters::TwitterAdapter.new(
		  handle: source.source_handle,
		  nitter_instance: source.nitter_instance,
		  url_domain: source.url_config[:replace_to]
		)
	  else
		raise "Unknown platform: #{source.platform}"
	  end
	end


	def verbose_mode?
	  @verbose
	end

	def verbose_log_post_input(source_id, post)
	  return unless verbose_mode?

	  Logging.info("🔍 [#{source_id}] ════════════════════════════════════════════════════════════")
	  Logging.info("🔍 [#{source_id}] POST INPUT")
	  Logging.info("🔍 [#{source_id}]   ID: #{post.id || 'N/A'}")
	  Logging.info("🔍 [#{source_id}]   Platform: #{post.platform}")
	  Logging.info("🔍 [#{source_id}]   URL: #{post.url}")

	  post_type = detect_post_type(post)
	  Logging.info("🔍 [#{source_id}]   Type: #{post_type}")

	  text_preview = truncate_for_log(post.text, 200)
	  Logging.info("🔍 [#{source_id}]   Text (#{post.text.to_s.length} chars): #{text_preview}")
	  Logging.info("🔍 [#{source_id}]   Author: #{post.author&.username || 'N/A'}")

	  if post.is_repost
		Logging.info("🔍 [#{source_id}]   Reposted by: #{post.reposted_by || 'unknown'}")
	  end

	  if post.is_quote && post.quoted_post
		qp = post.quoted_post
		Logging.info("🔍 [#{source_id}]   Quoted URL: #{qp[:url] || 'N/A'}")
	  end

	  Logging.info("🔍 [#{source_id}]   Has media: #{post.respond_to?(:has_media?) ? post.has_media? : 'N/A'}")
	  Logging.info("🔍 [#{source_id}]   Media count: #{post.media&.length || 0}")
	  Logging.info("🔍 [#{source_id}]   Has video: #{post.respond_to?(:has_video?) ? post.has_video? : 'N/A'}")

	  if post.respond_to?(:title) && post.title
		Logging.info("🔍 [#{source_id}]   Title: #{truncate_for_log(post.title, 100)}")
	  end

	  if post.respond_to?(:raw) && post.raw.is_a?(Hash)
		embed = post.raw[:embed] || post.raw['embed']
		if embed
		  embed_type = embed[:$type] || embed['$type'] || 'unknown'
		  Logging.info("🔍 [#{source_id}]   Embed type: #{embed_type}")
		  external = embed[:external] || embed['external']
		  Logging.info("🔍 [#{source_id}]   Embed URI: #{external[:uri] || external['uri']}") if external
		else
		  Logging.info("🔍 [#{source_id}]   Embed: none")
		end
	  end

	  Logging.info("🔍 [#{source_id}] ────────────────────────────────────────────────────────────")
	end

	def verbose_log_step(source_id, step_name, text)
	  return unless verbose_mode?

	  Logging.info("🔍 [#{source_id}] #{step_name}:")
	  text.to_s.split("\n").each_with_index do |line, i|
		Logging.info("🔍 [#{source_id}]   L#{i + 1}: #{line}")
	  end
	end

	def verbose_log_final_output(source_id, text)
	  return unless verbose_mode?

	  Logging.info("🔍 [#{source_id}] ────────────────────────────────────────────────────────────")
	  Logging.info("🔍 [#{source_id}] FINAL OUTPUT (#{text.length} chars):")
	  text.split("\n").each_with_index do |line, i|
		Logging.info("🔍 [#{source_id}]   L#{i + 1}: #{line}")
	  end

	  urls = text.scan(%r{https?://[^\s]+})
	  Logging.info("🔍 [#{source_id}] URLs (#{urls.length}):")
	  urls.each_with_index do |url, i|
		Logging.info("🔍 [#{source_id}]   #{i + 1}. #{url}")
	  end

	  Logging.info("🔍 [#{source_id}] ════════════════════════════════════════════════════════════")
	end

	def detect_post_type(post)
	  types = []
	  types << 'REPOST' if post.is_repost
	  types << 'QUOTE' if post.is_quote
	  types << 'THREAD' if post.respond_to?(:is_thread_post) && post.is_thread_post
	  types << 'VIDEO' if post.respond_to?(:has_video?) && post.has_video?
	  types << 'POST' if types.empty?
	  types.join('+')
	end

	def truncate_for_log(text, max = 150)
	  return 'nil' if text.nil?

	  str = text.to_s.gsub(/\n/, ' ')
	  str.length > max ? "#{str[0...max]}..." : str
	end

  end
end
