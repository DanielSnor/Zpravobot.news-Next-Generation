# frozen_string_literal: true

# ============================================================
# Tlambot Queue Processor
# ============================================================
# Processes broadcast jobs queued by the webhook handler.
# Reads JSON files from queue/broadcast/pending/, parses via
# TlambotWebhookHandler, resolves target accounts via Broadcaster,
# publishes to each account, and favourites the source status.
#
# Designed for cron invocation (every minute):
#   * * * * * ruby bin/process_broadcast_queue.rb
# ============================================================

require 'json'
require 'fileutils'
require 'yaml'
require_relative '../config/config_loader'
require_relative '../publishers/mastodon_publisher'
require_relative '../support/loggable'
require_relative '../utils/hash_helpers'
require_relative 'broadcaster'
require_relative 'broadcast_logger'
require_relative 'tlambot_webhook_handler'

module Broadcast
  class TlambotQueueProcessor
    include Support::Loggable

    # @param queue_dir [String] Base queue directory (with pending/processed/failed subdirs)
    # @param config_dir [String, nil] Config directory (default: auto-detect)
    def initialize(queue_dir:, config_dir: nil)
      @queue_dir = queue_dir
      config_path = config_dir || ENV['ZBNW_CONFIG_DIR'] || (ENV['ZBNW_DIR'] ? "#{ENV['ZBNW_DIR']}/config" : 'config')
      @config_loader = Config::ConfigLoader.new(config_path)
      @broadcast_config = load_broadcast_config
      @tlambot_config = @broadcast_config[:tlambot] || {}
      trigger_account = @tlambot_config[:trigger_account] || TlambotWebhookHandler::TRIGGER_ACCOUNT
      webhook_secret = ENV['TLAMBOT_WEBHOOK_SECRET'] || ''
      @handler = TlambotWebhookHandler.new(
        webhook_secret: webhook_secret,
        trigger_account: trigger_account
      )
    end

    # Process all pending broadcast jobs
    #
    # @return [Hash] Stats { processed:, success:, failed: }
    def process_queue
      pending_dir = File.join(@queue_dir, 'pending')
      ensure_dirs

      files = Dir.glob(File.join(pending_dir, '*.json')).sort
      stats = { processed: 0, success: 0, failed: 0 }
      return stats if files.empty?

      log "Found #{files.count} pending broadcast job(s)"

      files.each do |filepath|
        break if $shutdown_requested

        result = process_job_file(filepath)
        stats[:processed] += 1
        stats[result] += 1
      end

      log "Broadcast queue complete: #{stats[:success]} success, #{stats[:failed]} failed", level: :success
      stats
    end

    private

    def process_job_file(filepath)
      filename = File.basename(filepath)
      log "Processing: #{filename}"

      raw = JSON.parse(File.read(filepath))
      payload = HashHelpers.deep_symbolize_keys(raw)

      # Parse payload into broadcast job
      job = @handler.parse(payload)
      unless job
        log "Skipping #{filename}: not a valid tlambot broadcast", level: :warn
        move_file(filepath, 'processed')
        return :success
      end

      log "Broadcast: '#{job[:text][0..60]}...' routing=#{job[:routing][:target]}"

      # Resolve target accounts based on routing
      accounts = resolve_target_accounts(job[:routing])

      if accounts.empty?
        log "No target accounts found, skipping", level: :warn
        move_file(filepath, 'processed')
        return :success
      end

      # Execute broadcast
      result = execute_broadcast(job, accounts)

      # Favourite source status on any success
      favourite_source_status(job[:status_id]) if result[:success] > 0

      move_file(filepath, 'processed')
      result[:failed] > 0 ? :failed : :success

    rescue JSON::ParserError => e
      log "Invalid JSON in #{filename}: #{e.message}", level: :error
      move_file(filepath, 'failed')
      :failed
    rescue StandardError => e
      log "Error processing #{filename}: #{e.message}", level: :error
      log e.backtrace.first(3).join("\n"), level: :error
      move_file(filepath, 'failed')
      :failed
    end

    # Resolve accounts based on routing directive from extract_targets
    #
    # @param routing [Hash] { target: 'all'|'zpravobot'|'accounts', accounts: [...] }
    # @return [Hash<Symbol, Hash>] { account_id: { token:, instance: } }
    def resolve_target_accounts(routing)
      broadcaster = Broadcaster.new
      target = routing[:target]

      case target
      when 'all'
        accounts = broadcaster.resolve_accounts('all')
      when 'zpravobot'
        accounts = broadcaster.resolve_accounts('zpravobot')
      when 'accounts'
        account_filter = (routing[:accounts] || []).map(&:to_sym)
        accounts = broadcaster.resolve_accounts('all', account_filter: account_filter)
      else
        accounts = broadcaster.resolve_accounts('zpravobot')
      end

      # Remove blacklisted accounts
      blacklisted = broadcaster.filter_blacklisted(accounts)
      accounts = accounts.reject { |id, _| blacklisted.include?(id) }

      # Always exclude tlambot itself
      trigger_sym = (@tlambot_config[:trigger_account] || TlambotWebhookHandler::TRIGGER_ACCOUNT).to_sym
      accounts.delete(trigger_sym)

      accounts
    end

    def resolve_broadcast_visibility(job)
      override = @tlambot_config[:broadcast_visibility]
      if override && !override.to_s.strip.empty?
        log "Visibility override: #{job[:visibility]} → #{override}"
        override.to_s
      else
        job[:visibility]
      end
    end

    def execute_broadcast(job, accounts)
      broadcast_visibility = resolve_broadcast_visibility(job)
      log_dir = resolve_log_dir
      logger = BroadcastLogger.new(log_dir: log_dir)
      logger.start(
        message: job[:text],
        target: job[:routing][:target],
        account_count: accounts.size,
        visibility: broadcast_visibility,
        media_path: job[:media_items].any? ? "(#{job[:media_items].size} from webhook)" : nil
      )

      results = { success: 0, failed: 0 }
      delay = @broadcast_config.dig(:throttle, :delay_seconds) || 0.5
      max_attempts = @broadcast_config.dig(:retry, :max_attempts) || 3
      backoff_base = @broadcast_config.dig(:retry, :backoff_base) || 2
      start_time = Time.now

      accounts.each_with_index do |(account_id, creds), idx|
        break if $shutdown_requested

        publisher = Publishers::MastodonPublisher.new(
          instance_url: creds[:instance],
          access_token: creds[:token]
        )

        # Upload media for this account (from URL)
        media_ids = upload_media_for_account(publisher, job[:media_items])

        # Publish with retry (use broadcast visibility override)
        published = publish_with_retry(publisher, job, media_ids, max_attempts, backoff_base,
                                       visibility: broadcast_visibility)

        if published
          logger.log_account_result(account_id: account_id, success: true, status_id: published['id'])
          results[:success] += 1
          log "  OK: #{account_id}", level: :success
        else
          logger.log_account_result(account_id: account_id, success: false, error: 'All attempts failed')
          results[:failed] += 1
          log "  ERR: #{account_id}", level: :error
        end

        sleep(delay) if idx < accounts.size - 1
      end

      duration = Time.now - start_time
      logger.finish(
        success_count: results[:success],
        fail_count: results[:failed],
        duration_seconds: duration
      )

      log "Broadcast done: #{results[:success]} ok, #{results[:failed]} failed (#{duration.round(1)}s)"
      results
    end

    def upload_media_for_account(publisher, media_items)
      return [] if media_items.empty?

      ids = []
      media_items.first(Publishers::MastodonPublisher::MAX_MEDIA_COUNT).each do |item|
        media_id = publisher.upload_media_from_url(item[:url], description: item[:description])
        ids << media_id if media_id
      rescue StandardError => e
        log "Media upload failed: #{e.message}", level: :warn
      end
      ids
    end

    def publish_with_retry(publisher, job, media_ids, max_attempts, backoff_base, visibility: nil)
      effective_visibility = visibility || job[:visibility]
      max_attempts.times do |attempt|
        result = publisher.publish(
          job[:text],
          media_ids: media_ids,
          visibility: effective_visibility
        )
        return result
      rescue StandardError => e
        log "Publish attempt #{attempt + 1}/#{max_attempts} failed: #{e.message}", level: :warn
        sleep(backoff_base**(attempt + 1)) if attempt < max_attempts - 1
      end
      nil
    end

    def favourite_source_status(status_id)
      return unless status_id

      trigger_account = (@tlambot_config[:trigger_account] || TlambotWebhookHandler::TRIGGER_ACCOUNT).to_sym
      token, instance = resolve_trigger_credentials(trigger_account)

      unless token
        log 'No tlambot token configured, skipping favourite', level: :warn
        return
      end

      publisher = Publishers::MastodonPublisher.new(
        instance_url: instance,
        access_token: token
      )
      publisher.favourite_status(status_id.to_s)
      log "Favourited source status #{status_id}", level: :success
    rescue StandardError => e
      # Non-fatal — broadcast already succeeded
      log "Failed to favourite source status: #{e.message}", level: :warn
    end

    # Resolve tlambot credentials: ENV override → mastodon_accounts.yml → nil
    #
    # @param account_id [Symbol] Account identifier (e.g. :tlambot)
    # @return [Array(String, String)] [token, instance_url] or [nil, nil]
    def resolve_trigger_credentials(account_id)
      global = @config_loader.load_global_config
      default_instance = global.dig(:mastodon, :instance)

      # 1. ENV override (same convention as CredentialsResolver)
      env_token = ENV["ZBNW_MASTODON_TOKEN_#{account_id.upcase}"]
      if env_token && !env_token.empty?
        return [env_token, default_instance]
      end

      # 2. mastodon_accounts.yml
      creds = @config_loader.mastodon_credentials(account_id)
      instance = creds[:instance] || default_instance
      [creds[:token], instance]
    rescue StandardError
      # Account not in mastodon_accounts.yml and no ENV — skip
      [nil, nil]
    end

    def move_file(filepath, subdir)
      dest_dir = File.join(@queue_dir, subdir)
      FileUtils.mkdir_p(dest_dir)
      FileUtils.mv(filepath, File.join(dest_dir, File.basename(filepath)))
    end

    def ensure_dirs
      %w[pending processed failed].each do |subdir|
        FileUtils.mkdir_p(File.join(@queue_dir, subdir))
      end
    end

    def resolve_log_dir
      if ENV['ZBNW_DIR']
        File.join(ENV['ZBNW_DIR'], 'logs')
      else
        base = File.expand_path('../../..', __FILE__)
        File.join(base, 'logs')
      end
    end

    def load_broadcast_config
      config_path = File.join(@config_loader.config_dir, 'broadcast.yml')
      if File.exist?(config_path)
        raw = YAML.safe_load(File.read(config_path), permitted_classes: [], permitted_symbols: [], aliases: true)
        HashHelpers.deep_symbolize_keys(raw || {})
      else
        {
          blacklist: [],
          throttle: { delay_seconds: 0.5 },
          retry: { max_attempts: 3, backoff_base: 2 },
          tlambot: { trigger_account: 'tlambot' }
        }
      end
    end
  end
end
