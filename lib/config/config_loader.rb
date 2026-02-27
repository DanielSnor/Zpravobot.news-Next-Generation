# frozen_string_literal: true
require 'yaml'
require_relative '../utils/hash_helpers'
require_relative 'config_merger'
require_relative 'credentials_resolver'
require_relative 'source_finder'
module Config
  # Loads and merges hierarchical YAML configuration
  #
  # Facade class — delegates to:
  #   - ConfigMerger: hierarchické merging (global → platform → source)
  #   - CredentialsResolver: Mastodon token resolution
  #   - SourceFinder: lookup by handle/platform/account
  #
  # Hierarchy (later overrides earlier):
  #   1. global.yml
  #   2. platforms/{platform}.yml
  #   3. sources/{source_id}.yml
  #
  # Usage:
  #   loader = Config::ConfigLoader.new('config')
  #
  #   # Load single source
  #   config = loader.load_source('ct24_twitter')
  #
  #   # Load all enabled sources
  #   sources = loader.load_all_sources
  #
  #   # Get Mastodon credentials
  #   creds = loader.mastodon_credentials('ct24')
  #
  class ConfigLoader
    attr_reader :config_dir
    def initialize(config_dir = 'config')
      @config_dir = config_dir
      @cache = {}
      @platforms = {}
      @global = nil
      @merger = ConfigMerger.new
      @credentials_resolver = CredentialsResolver.new
      @source_finder = SourceFinder.new
    end
    # Load fully merged config for a source
    # @param source_id [String] Source identifier (e.g., "ct24_twitter")
    # @return [Hash] Merged configuration
    def load_source(source_id)
      return @cache[source_id] if @cache[source_id]
      # Skip example files
      if example_file?(source_id)
        raise "Source '#{source_id}' is an example file and cannot be loaded"
      end
      source_config = load_yaml("sources/#{source_id}.yml")
      raise "Source not found: #{source_id}" unless source_config
      platform = source_config[:platform]
      raise "Platform not specified for: #{source_id}" unless platform
      # Merge hierarchy: global → platform → source
      merged = @merger.merge(load_global, load_platform(platform), source_config)
      # Resolve Mastodon credentials
      credentials_loader = method(:mastodon_credentials)
      @credentials_resolver.resolve(merged, credentials_loader, load_global)
      @cache[source_id] = merged
      merged
    end
    # Load all enabled sources
    # @return [Array<Hash>] Array of merged configurations
    def load_all_sources
      return @all_sources if @all_sources

      sources_dir = File.join(@config_dir, 'sources')
      return [] unless Dir.exist?(sources_dir)
      # Note: Using map + compact instead of filter_map for Ruby 2.6 compatibility
      @all_sources = Dir.glob(File.join(sources_dir, '*.yml')).map do |file|
        source_id = File.basename(file, '.yml')

        # Skip example files
        next nil if example_file?(source_id)

        config = load_source(source_id)
        config[:enabled] ? config : nil
      rescue StandardError => e
        warn "[ConfigLoader] Error loading #{source_id}: #{e.message}"
        nil
      end.compact
    end
    # Load sources by platform
    # @param platform [String] Platform name (twitter, bluesky, rss, youtube)
    # @return [Array<Hash>]
    def load_sources_by_platform(platform)
      @source_finder.by_platform(load_all_sources, platform)
    end
    # Load sources by Mastodon account
    # @param account_id [String] Mastodon account identifier
    # @return [Array<Hash>]
    def load_sources_by_mastodon_account(account_id)
      @source_finder.by_mastodon_account(load_all_sources, account_id)
    end
    # Get Mastodon credentials for an account
    # @param account_id [String] Account identifier
    # @return [Hash] { token: '...', instance: '...' }
    def mastodon_credentials(account_id)
      accounts = load_yaml('mastodon_accounts.yml') || {}
      creds = accounts[account_id.to_sym]
      raise "Mastodon account not found: #{account_id}" unless creds
      creds
    end
    # List all Mastodon accounts
    # @return [Array<String>] Account identifiers
    def mastodon_account_ids
      accounts = load_yaml('mastodon_accounts.yml') || {}
      accounts.keys
    end
    # List all source IDs (excluding examples)
    # @return [Array<String>]
    def source_ids
      sources_dir = File.join(@config_dir, 'sources')
      return [] unless Dir.exist?(sources_dir)
      # Note: Using map + compact instead of filter_map for Ruby 2.6 compatibility
      Dir.glob(File.join(sources_dir, '*.yml')).map do |file|
        source_id = File.basename(file, '.yml')
        example_file?(source_id) ? nil : source_id
      end.compact
    end
    # Clear cache (useful for reloading)
    def clear_cache
      @cache = {}
      @platforms = {}
      @global = nil
      @all_sources = nil
      @twitter_handle_map = nil
    end
    # Public access to global config (for URL processor etc.)
    # @return [Hash] Global configuration
    def load_global_config
      load_global
    end

    # Public access to platform config
    # @param platform [String] Platform name (twitter, bluesky, rss, youtube, facebook)
    # @return [Hash] Platform configuration
    def load_platform_config(platform)
      load_platform(platform)
    end

    # Build map of Twitter handles → Mastodon account IDs (only zpravobot.news instances)
    # Used for local mention transformation (domain_suffix_with_local)
    # @return [Hash] { 'ct24zive' => 'ct24', 'aktualnecz' => 'aktualnecz', ... }
    def twitter_handle_to_mastodon_map
      @twitter_handle_map ||= build_twitter_handle_map
    end

    private
    # Check if file is an example (should be skipped)
    # Matches: !example_*, _example_*, *_example.yml, example_*
    def example_file?(source_id)
      source_id.start_with?('!') ||
        source_id.start_with?('_') ||
        source_id.include?('example')
    end
    def load_global
      @global ||= load_yaml('global.yml') || {}
    end
    def load_platform(platform)
      return @platforms[platform] if @platforms.key?(platform)
      @platforms[platform] = load_yaml("platforms/#{platform}.yml") || {}
    end
    # Build Twitter handle → Mastodon account map for local mention transformation
    # Keys are lowercased Twitter handles; values are Mastodon account IDs
    # Only includes sources targeting zpravobot.news instances
    def build_twitter_handle_map
      twitter_sources = load_sources_by_platform('twitter')
      twitter_sources.each_with_object({}) do |source_hash, map|
        handle = source_hash.dig(:source, :handle)
        mastodon_account = source_hash.dig(:target, :mastodon_account)
        mastodon_instance = source_hash.dig(:target, :mastodon_instance).to_s
        next unless handle && mastodon_account
        next unless mastodon_instance.include?('zpravobot.news')
        map[handle.to_s.downcase] = mastodon_account.to_s
      end
    end

    # Safe YAML loading with alias support
    def load_yaml(relative_path)
      path = File.join(@config_dir, relative_path)
      return nil unless File.exist?(path)
      content = File.read(path, encoding: 'UTF-8')
      raw = YAML.safe_load(
        content,
        permitted_classes: [],
        permitted_symbols: [],
        aliases: true
      )
      HashHelpers.deep_symbolize_keys(raw)
    rescue Psych::SyntaxError => e
      raise "YAML syntax error in #{relative_path}: #{e.message}"
    end
  end
  # Wrapper for a single source configuration
  # Provides convenient accessors
  class SourceConfig
    attr_reader :data
    def initialize(data)
      @data = data || {}
    end
    # Identity
    def id
      @data[:id]
    end
    def enabled?
      @data[:enabled] != false  # Default true if not specified
    end
    def platform
      @data[:platform]
    end
    # Source
    def source_handle
      @data.dig(:source, :handle)
    end
    def source_feed_url
      @data.dig(:source, :feed_url)
    end
    # Bluesky source type: 'handle' (default) or 'feed'
    def bluesky_source_type
      @data[:bluesky_source_type] || 'handle'
    end
    # RSS source type for Facebook/Instagram/Other feeds
    # Values: 'rss' (default), 'facebook', 'instagram', 'other'
    def rss_source_type
      @data[:rss_source_type] || 'rss'
    end

    def source_channel_id
      @data.dig(:source, :channel_id)
    end
    def nitter_instance
      @data.dig(:source, :nitter_instance) || ENV['NITTER_INSTANCE']
    end

    # Target
    def mastodon_account
      @data.dig(:target, :mastodon_account)
    end
    def mastodon_token
      @data.dig(:target, :mastodon_token)
    end
    def mastodon_instance
      @data.dig(:target, :mastodon_instance)
    end
    def visibility
      @data.dig(:target, :visibility) || 'public'
    end
    # Scheduling
    def priority
      @data.dig(:scheduling, :priority) || 'normal'
    end

    # Default intervals by priority (in minutes)
    # high:   5 min  - checked every cron run (hot news, alerts)
    # normal: 20 min - standard sources (~2-3 cron runs)
    # low:    55 min - low-priority content (~1x per hour)
    PRIORITY_INTERVALS = {
      'high'   => 5,
      'normal' => 20,
      'low'    => 55
    }.freeze

    def interval_minutes
      # Explicit value in config always wins
      explicit = @data.dig(:scheduling, :interval_minutes)
      return explicit if explicit

      # Otherwise derive from priority
      PRIORITY_INTERVALS.fetch(priority, 20)
    end
    def max_posts_per_run
      @data.dig(:scheduling, :max_posts_per_run) || 10
    end
    def skip_hours
      @data.dig(:scheduling, :skip_hours) || []
    end
    # Formatting
    def source_name
      @data.dig(:formatting, :source_name)
    end
    def formatting
      @data[:formatting] || {}
    end

    # Mentions configuration (from platform or source level)
    def mentions
      @data[:mentions]
    end

    # Filtering
    def filtering
      @data[:filtering] || {}
    end
    def banned_phrases
      @data.dig(:filtering, :banned_phrases) || []
    end
    def required_keywords
      @data.dig(:filtering, :required_keywords) || []
    end
    def skip_replies?
      @data.dig(:filtering, :skip_replies)
    end
    def skip_retweets?
      @data.dig(:filtering, :skip_retweets)
    end
    # ============================================
    # NEW: Thread handling support
    # ============================================
    # Check if self-replies (thread posts) should be skipped
    # Default: false (allow threads)
    # @return [Boolean]
    def skip_self_replies?
      @data.dig(:filtering, :skip_self_replies) || false
    end
    # Get thread handling configuration
    # @return [Hash] Thread handling settings
    def thread_handling
      @data[:thread_handling] || {}
    end
    # Get thread handling mode
    # Modes: 'skip', 'individual', 'context', 'first_only'
    # Default: 'individual'
    # @return [String]
    def thread_mode
      @data.dig(:thread_handling, :mode) || 'individual'
    end
    # Should thread indicator be shown?
    # @return [Boolean]
    def show_thread_indicator?
      @data.dig(:thread_handling, :show_indicator) != false
    end
    # ============================================
    # Nitter processing configuration (Twitter only)
    # ============================================
    # Check if Nitter processing (Tier 2) is enabled
    # Default: true (Nitter enabled)
    # Set to false for sources where Tier 1 (IFTTT only) is sufficient
    # @return [Boolean]
    def nitter_processing_enabled?
      @data.dig(:nitter_processing, :enabled) != false
    end

    # Get full nitter_processing configuration
    # @return [Hash]
    def nitter_processing
      @data[:nitter_processing] || {}
    end
    # ============================================
    # Processing
    # ============================================
    def processing
      @data[:processing] || {}
    end
    def content_replacements
      @data.dig(:processing, :content_replacements) || []
    end
    def url_domain_fixes
      @data.dig(:processing, :url_domain_fixes) || []
    end
    def max_length
      @data.dig(:processing, :max_length) || @data.dig(:processing, :post_length) || 500
    end
    def post_length
      max_length  # alias pro zpětnou kompatibilitu
    end
    def trim_strategy
      @data.dig(:processing, :trim_strategy) || 'smart'
    end
    # Content (RSS/YouTube)
    def content_config
      @data[:content] || {}
    end
    def combine_title_and_content?
      @data.dig(:content, :combine_title_and_content)
    end
    # URL
    def url_config
      @data[:url] || {}
    end
    # Profile sync
    def profile_sync_enabled?
      @data.dig(:profile_sync, :enabled)
    end
    def profile_sync_config
      @data[:profile_sync] || {}
    end
    # Raw access
    def [](key)
      @data[key]
    end
    def dig(*keys)
      @data.dig(*keys)
    end
    def to_h
      @data
    end
  end
end
