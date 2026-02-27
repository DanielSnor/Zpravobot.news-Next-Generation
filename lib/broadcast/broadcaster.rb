# frozen_string_literal: true

require 'yaml'
require_relative '../config/config_loader'
require_relative '../publishers/mastodon_publisher'
require_relative '../support/loggable'
require_relative '../support/ui_helpers'
require_relative '../utils/hash_helpers'
require_relative 'broadcast_logger'

module Broadcast
  class Broadcaster
    include Support::Loggable
    include Support::UiHelpers

    VALID_TARGETS = %w[zpravobot all].freeze
    VALID_VISIBILITIES = %w[public unlisted direct].freeze
    ZPRAVOBOT_DOMAIN = 'zpravobot.news'.freeze

    attr_reader :options, :config, :config_loader

    # @param options [Hash] CLI options:
    #   :message [String, nil] - message text (nil = interactive)
    #   :target [String] - 'zpravobot' or 'all'
    #   :visibility [String] - 'public', 'unlisted', or 'direct'
    #   :account [String, nil] - comma-separated account IDs (overrides target)
    #   :media [String, nil] - path to media file
    #   :alt [String, nil] - alt text for media
    #   :dry_run [Boolean] - preview only
    #   :test [Boolean] - use test environment
    def initialize(options = {})
      @options = options
      config_dir = ENV.fetch('ZBNW_CONFIG_DIR', ENV['ZBNW_DIR'] ? "#{ENV['ZBNW_DIR']}/config" : 'config')
      @config_loader = Config::ConfigLoader.new(config_dir)
      @config = load_broadcast_config
      @results = { success: 0, failed: 0, skipped: 0, errors: [] }
    end

    # Main entry point. Returns exit code (0=success, 1=errors, 2=bad args)
    def run
      message = @options[:message] || collect_message_interactive
      if message.nil? || message.strip.empty?
        $stderr.puts "Chyba: Prazdna zprava."
        return 2
      end

      target = @options[:target] || @config[:default_target] || 'zpravobot'
      visibility = @options[:visibility] || @config[:default_visibility] || 'public'
      media_path = @options[:media]
      alt_text = @options[:alt]
      account_filter = parse_account_filter(@options[:account])

      return 2 unless validate_inputs(target, visibility, media_path, account_filter: account_filter)

      # Resolve target accounts
      accounts = resolve_accounts(target, account_filter: account_filter)
      blacklisted = filter_blacklisted(accounts)
      accounts = accounts.reject { |id, _| blacklisted.include?(id) }

      if accounts.empty?
        puts "  Zadne ucty k odeslani."
        return 0
      end

      # Show preview
      show_preview(
        message: message,
        account_count: accounts.size,
        blacklisted: blacklisted,
        target: account_filter ? account_filter.join(', ') : target,
        visibility: visibility,
        media_path: media_path,
        alt_text: alt_text
      )

      if @options[:dry_run]
        puts "\n  [DRY RUN] Zadne zpravy nebyly odeslany."
        return 0
      end

      return 0 unless ask_yes_no('Odeslat broadcast?', default: false)

      broadcast!(
        message: message,
        accounts: accounts,
        visibility: visibility,
        media_path: media_path,
        alt_text: alt_text
      )

      @results[:failed] > 0 ? 1 : 0
    end

    # ============================================================
    # Pure-logic methods (testable without I/O)
    # ============================================================

    # Resolve accounts from mastodon_accounts.yml
    # @param target [String] 'zpravobot' or 'all'
    # @param account_filter [Array<Symbol>, nil] specific accounts to include
    # @return [Hash<Symbol, Hash>] { account_id: { token:, instance: } }
    def resolve_accounts(target, account_filter: nil)
      account_ids = @config_loader.mastodon_account_ids
      global_instance = @config_loader.load_global_config.dig(:mastodon, :instance)

      accounts = {}
      account_ids.each do |account_id|
        # If account_filter specified, only include listed accounts
        next if account_filter && !account_filter.include?(account_id)

        creds = @config_loader.mastodon_credentials(account_id)
        instance = creds[:instance] || global_instance

        # Target filtering (only when no account_filter)
        if !account_filter && target == 'zpravobot'
          next unless instance.to_s.include?(ZPRAVOBOT_DOMAIN)
        end

        accounts[account_id] = { token: creds[:token], instance: instance }
      end
      accounts
    end

    # Filter out blacklisted accounts
    # @param accounts [Hash] account_id => creds
    # @return [Array<Symbol>] blacklisted account IDs that were in accounts
    def filter_blacklisted(accounts)
      blacklist = (@config[:blacklist] || []).map(&:to_sym)
      accounts.keys.select { |id| blacklist.include?(id) }
    end

    # Parse comma-separated account filter string
    # @param filter_str [String, nil]
    # @return [Array<Symbol>, nil]
    def parse_account_filter(filter_str)
      return nil if filter_str.nil? || filter_str.strip.empty?

      filter_str.split(',').map { |s| s.strip.to_sym }.reject { |s| s.empty? }
    end

    # Validate CLI inputs
    # @return [Boolean] true if valid
    def validate_inputs(target, visibility, media_path, account_filter: nil)
      unless VALID_TARGETS.include?(target) || account_filter
        $stderr.puts "Chyba: Neplatny target '#{target}'. Platne: #{VALID_TARGETS.join(', ')}"
        return false
      end
      unless VALID_VISIBILITIES.include?(visibility)
        $stderr.puts "Chyba: Neplatna visibility '#{visibility}'. Platne: #{VALID_VISIBILITIES.join(', ')}"
        return false
      end
      if media_path && !File.exist?(media_path)
        $stderr.puts "Chyba: Soubor nenalezen: #{media_path}"
        return false
      end
      if media_path && File.size(media_path) > Publishers::MastodonPublisher::MAX_MEDIA_SIZE
        $stderr.puts "Chyba: Soubor prilis velky (max 10MB)"
        return false
      end
      if account_filter
        known_ids = @config_loader.mastodon_account_ids
        unknown = account_filter.reject { |id| known_ids.include?(id) }
        unless unknown.empty?
          $stderr.puts "Chyba: Nezname ucty: #{unknown.join(', ')}"
          return false
        end
      end
      true
    end

    # Estimate broadcast time in seconds
    # @param account_count [Integer]
    # @param has_media [Boolean]
    # @return [Float]
    def estimate_time(account_count, has_media)
      delay = @config.dig(:throttle, :delay_seconds) || 0.5
      per_account = has_media ? 1.5 : 0.5
      account_count * (delay + per_account)
    end

    # Format estimated time for display
    # @param seconds [Float]
    # @return [String]
    def format_duration(seconds)
      if seconds < 60
        "~#{seconds.round} sekund"
      elsif seconds < 3600
        minutes = (seconds / 60.0).ceil
        "~#{minutes} #{minutes == 1 ? 'minuta' : minutes < 5 ? 'minuty' : 'minut'}"
      else
        hours = (seconds / 3600.0).round(1)
        "~#{hours} hodin"
      end
    end

    # Format progress bar string
    # @param current [Integer]
    # @param total [Integer]
    # @param failed [Integer]
    # @return [String]
    def format_progress(current, total, failed)
      width = 30
      filled = total > 0 ? (current.to_f / total * width).round : 0
      bar = '=' * filled + '>' + ' ' * [width - filled - 1, 0].max
      fail_str = failed > 0 ? " (#{failed} failed)" : ''
      "\r  Broadcasting... [#{bar}] #{current}/#{total}#{fail_str}"
    end

    private

    def load_broadcast_config
      config_path = File.join(@config_loader.config_dir, 'broadcast.yml')
      if File.exist?(config_path)
        raw = YAML.safe_load(File.read(config_path), permitted_classes: [], permitted_symbols: [], aliases: true)
        HashHelpers.deep_symbolize_keys(raw || {})
      else
        default_config
      end
    end

    def default_config
      {
        blacklist: [],
        throttle: { delay_seconds: 0.5 },
        retry: { max_attempts: 3, backoff_base: 2 },
        default_target: 'zpravobot',
        default_visibility: 'public'
      }
    end

    # Interactive message collection (multiline, end with empty line)
    def collect_message_interactive
      separator('Broadcast')
      puts "  Zadej zpravu (ukonci prazdnym radkem):"
      puts
      lines = []
      loop do
        print '  > '
        line = safe_gets
        break if line.empty? && !lines.empty?
        lines << line unless line.empty? && lines.empty?
      end
      lines.join("\n")
    end

    def show_preview(message:, account_count:, blacklisted:, target:, visibility:, media_path:, alt_text:)
      est = estimate_time(account_count, !media_path.nil?)

      puts
      puts '  ' + '-' * 50
      puts "  #{message}"
      puts
      target_desc = target == 'zpravobot' ? "uctu na #{ZPRAVOBOT_DOMAIN}" : "uctu (#{target})"
      puts "  Cil: #{account_count} #{target_desc}"
      if blacklisted.any?
        puts "  Blacklisted (preskoceno): #{blacklisted.size} (#{blacklisted.join(', ')})"
      end
      puts "  Visibility: #{visibility}"
      if media_path
        puts "  Media: #{File.basename(media_path)}#{alt_text ? " (alt: \"#{alt_text}\")" : ''}"
      end
      puts "  Odhadovany cas: #{format_duration(est)}"
      puts '  ' + '-' * 50
      puts
    end

    def broadcast!(message:, accounts:, visibility:, media_path:, alt_text:)
      logger = BroadcastLogger.new(log_dir: File.join(File.dirname(@config_loader.config_dir), 'logs'))
      logger.start(
        message: message,
        target: @options[:account] || @options[:target] || @config[:default_target],
        account_count: accounts.size,
        visibility: visibility,
        media_path: media_path
      )

      # Pre-read media file once
      media_data = nil
      media_filename = nil
      media_content_type = nil
      if media_path
        media_data = File.binread(media_path)
        media_filename = File.basename(media_path)
        # Detect content type once — reuse for all accounts
        temp_pub = Publishers::MastodonPublisher.new(
          instance_url: accounts.values.first[:instance],
          access_token: accounts.values.first[:token]
        )
        media_content_type = temp_pub.send(:detect_content_type_from_path, media_path, media_data)
      end

      start_time = Time.now
      total = accounts.size
      delay = @config.dig(:throttle, :delay_seconds) || 0.5
      max_attempts = @config.dig(:retry, :max_attempts) || 3
      backoff_base = @config.dig(:retry, :backoff_base) || 2

      accounts.each_with_index do |(account_id, creds), idx|
        break if $shutdown_requested

        print format_progress(idx, total, @results[:failed])

        publisher = Publishers::MastodonPublisher.new(
          instance_url: creds[:instance],
          access_token: creds[:token]
        )

        # Upload media for this account (if any)
        media_ids = []
        if media_data
          media_id = publisher.upload_media(
            media_data,
            filename: media_filename,
            content_type: media_content_type,
            description: alt_text
          )
          media_ids = [media_id] if media_id
        end

        # Publish with retry
        published = false
        last_error = nil
        max_attempts.times do |attempt|
          begin
            result = publisher.publish(message, media_ids: media_ids, visibility: visibility)
            logger.log_account_result(
              account_id: account_id,
              success: true,
              status_id: result['id']
            )
            @results[:success] += 1
            published = true
            break
          rescue StandardError => e
            last_error = e.message
            if attempt < max_attempts - 1
              wait = backoff_base**(attempt + 1)
              sleep(wait)
            end
          end
        end

        unless published
          logger.log_account_result(
            account_id: account_id,
            success: false,
            error: last_error,
            attempt: max_attempts
          )
          @results[:failed] += 1
          @results[:errors] << { account: account_id, error: last_error }
        end

        sleep(delay) if idx < total - 1
      end

      duration = Time.now - start_time
      print format_progress(total, total, @results[:failed])
      puts # newline after progress bar

      logger.finish(
        success_count: @results[:success],
        fail_count: @results[:failed],
        duration_seconds: duration
      )

      puts
      puts "  Broadcast dokoncen za #{format_duration(duration)}."
      puts "  Uspech: #{@results[:success]}, Selhano: #{@results[:failed]}"
      if @results[:errors].any?
        puts
        puts '  Chyby:'
        @results[:errors].each do |err|
          puts "    #{err[:account]}: #{err[:error]}"
        end
      end

      if $shutdown_requested
        remaining = total - (@results[:success] + @results[:failed])
        puts "\n  Preruseno uzivatelem. Zbyvajicich #{remaining} uctu nezpracovano."
      end
    end
  end
end
