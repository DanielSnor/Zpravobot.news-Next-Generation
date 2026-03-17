# frozen_string_literal: true

# ============================================================
# Base Profile Syncer - Shared functionality for all profile syncers
# ============================================================
#
# Provides common infrastructure for synchronizing profile info
# from source platforms (Twitter, Bluesky, Facebook) to Mastodon.
#
# Subclasses implement platform-specific fetch logic via template methods:
#   - source_handle         → platform handle string
#   - platform_name         → "Twitter" / "Bluesky" / "Facebook"
#   - field_prefix          → "x:" / "bsky:" / "fb:"
#   - default_mentions_config → default mentions Hash
#   - fetch_platform_profile  → fetch profile from source platform
#
# Optional overrides:
#   - banner_key            → :banner_url (default) or :cover_url (Facebook)
#   - validate_image_content_type? → false (default) or true
#   - build_fields          → override for platform-specific field logic
#   - log_preview_details   → override for platform-specific preview output
#   - log_sync_details      → override to add platform-specific sync info
#
# ============================================================

require_relative '../utils/http_client'
require_relative '../support/loggable'
require_relative 'image_cache_manager'
require_relative 'mastodon_profile_updater'
require_relative 'profile_fields_builder'

module Syncers
  class BaseProfileSyncer
    include Support::Loggable
    include ProfileFieldsBuilder

    USER_AGENT = 'Zpravobot/1.0 (+https://zpravobot.news)'
    DEFAULT_CACHE_DIR = ImageCacheManager::DEFAULT_CACHE_DIR

    attr_reader :mastodon_instance, :mastodon_token,
                :language, :retention_days, :cache_dir, :use_cache, :mentions_config

    def initialize(mastodon_instance:, mastodon_token:,
                   language: 'cs', retention_days: 90, cache_dir: nil, use_cache: true,
                   mentions_config: nil, source_platforms: nil)
      @mastodon_instance = mastodon_instance.chomp('/')
      @mastodon_token = mastodon_token
      @language = FIELD_LABELS.key?(language) ? language : 'cs'
      @retention_days = VALID_RETENTION_DAYS.include?(retention_days) ? retention_days : 90
      @cache_dir = cache_dir || DEFAULT_CACHE_DIR
      @use_cache = use_cache
      @mentions_config = mentions_config || default_mentions_config
      @source_platforms = source_platforms

      @image_cache = ImageCacheManager.new(
        source_handle: source_handle,
        cache_dir: @cache_dir,
        use_cache: @use_cache,
        download_options: image_download_options,
        validate_content_type: validate_image_content_type?
      )

      @profile_updater = MastodonProfileUpdater.new(
        instance_url: @mastodon_instance,
        access_token: @mastodon_token
      )
    end

    # ============================================
    # Template methods — subclass MUST override
    # ============================================

    # @return [String] The platform handle (e.g., twitter_handle, bluesky_handle)
    def source_handle
      raise NotImplementedError, "#{self.class} must implement #source_handle"
    end

    # @return [String] Platform name for log messages
    def platform_name
      raise NotImplementedError, "#{self.class} must implement #platform_name"
    end

    # @return [String] First metadata field name (e.g., 'x:', 'bsky:', 'fb:')
    def field_prefix
      raise NotImplementedError, "#{self.class} must implement #field_prefix"
    end

    # @return [Hash] Default mentions config for this platform
    def default_mentions_config
      raise NotImplementedError, "#{self.class} must implement #default_mentions_config"
    end

    # @return [String] Platform key used to look up PLATFORM_LABELS (e.g. 'twitter', 'bluesky', 'facebook')
    def platform_key
      raise NotImplementedError, "#{self.class} must implement #platform_key"
    end

    # Fetch profile data from the source platform
    # @return [Hash] Must include :handle, :description, :avatar_url, and :banner_url or :cover_url
    def fetch_platform_profile
      raise NotImplementedError, "#{self.class} must implement #fetch_platform_profile"
    end

    # ============================================
    # Template methods — subclass MAY override
    # ============================================

    # Key used for banner URL in profile hash
    # @return [Symbol] :banner_url (default) or :cover_url (Facebook)
    def banner_key
      :banner_url
    end

    # Whether to validate image content-type before accepting download
    # @return [Boolean]
    def validate_image_content_type?
      false
    end

    # ============================================
    # Public API
    # ============================================

    # Fetch source profile and show what would be synced
    # @return [Hash] Profile data
    def preview
      log "Fetching #{platform_name} profile for #{format_source_handle}..."

      profile = fetch_platform_profile
      log_preview_details(profile)

      profile
    end

    # Sync profile from source platform to Mastodon
    # @param sync_avatar [Boolean] Whether to sync avatar
    # @param sync_banner [Boolean] Whether to sync banner
    # @param sync_bio [Boolean] Whether to sync bio/description
    # @param sync_fields [Boolean] Whether to update all 4 metadata fields
    # @param force [Boolean] Force re-download images even if cached
    # @return [Hash] Result with changes made
    def sync!(sync_avatar: true, sync_banner: true, sync_bio: true, sync_fields: true, force: false)
      log "Starting profile sync: #{platform_name} → Mastodon"
      log_sync_details(force)

      profile = with_retry { fetch_platform_profile }

      params = {}
      files = {}
      changes = []

      # Bio/description
      if sync_bio && profile[:description]
        params[:note] = profile[:description]
        changes << 'bio'
        log '  ✔ Will update bio'
      end

      # All 4 metadata fields
      if sync_fields
        log '  Fetching current Mastodon profile fields...'
        current_fields = @profile_updater.fetch_fields

        new_fields = build_fields(profile[:handle], current_fields, profile.merge(source_platforms: @source_platforms))

        new_fields.each_with_index do |field, idx|
          params[:"fields_attributes[#{idx}][name]"] = field[:name]
          params[:"fields_attributes[#{idx}][value]"] = field[:value]
        end

        changes << 'fields'
        log '  ✔ Will update all 4 metadata fields'
        new_fields.each { |f| log "    #{f[:name]} #{f[:value]}" }
      end

      # Avatar
      if sync_avatar && profile[:avatar_url]
        log "  Downloading avatar (#{profile[:avatar_url][0, 80]}...)"
        avatar_data = @image_cache.download_image_cached(profile[:avatar_url], 'avatar', force: force)
        if avatar_data
          log_image_result('Avatar', avatar_data)
          files[:avatar] = avatar_data
          changes << 'avatar'
        else
          log '  ⚠️ Avatar download failed, skipping avatar sync', level: :warn
        end
      end

      # Banner
      b_url = profile[banner_key]
      if sync_banner && b_url
        b_label = banner_key == :cover_url ? 'cover photo' : 'banner'
        log "  Downloading #{b_label}..."
        banner_data = @image_cache.download_image_cached(b_url, 'banner', force: force)
        if banner_data
          log_image_result(b_label.capitalize, banner_data)
          files[:header] = banner_data
          changes << 'banner'
        end
      end

      if changes.empty?
        log '  Nothing to sync'
        return { success: true, changes: [] }
      end

      # Update Mastodon profile
      log '  Updating Mastodon profile...'
      result = @profile_updater.update(params, files)

      if result[:success]
        log '✅ Profile synced successfully!', level: :success
        log "  Changes: #{changes.join(', ')}"
        if changes.include?('avatar') && result[:account]
          masto_avatar = result[:account]['avatar']
          log "  Mastodon avatar: #{masto_avatar}"
        end
      else
        log "❌ Sync failed: #{result[:error]}", level: :error
      end

      result.merge(changes: changes)
    end

    # Sync only bio
    def sync_bio!
      sync!(sync_avatar: false, sync_banner: false, sync_bio: true, sync_fields: false)
    end

    # Sync only avatar
    def sync_avatar!
      sync!(sync_avatar: true, sync_banner: false, sync_bio: false, sync_fields: false)
    end

    # Sync only banner
    def sync_banner!
      sync!(sync_avatar: false, sync_banner: true, sync_bio: false, sync_fields: false)
    end

    # Sync only fields
    def sync_fields!
      sync!(sync_avatar: false, sync_banner: false, sync_bio: false, sync_fields: true)
    end

    # Force full sync (bypass image cache)
    def force_sync!
      sync!(force: true)
    end

    # ============================================
    # Class-level API (delegates to ImageCacheManager)
    # ============================================

    class << self
      # Clear all cached images for a handle
      # @param handle [String] Platform handle
      # @return [Integer] Number of deleted files
      def clear_cache(handle)
        ImageCacheManager.clear_cache(handle)
      end

      # Get cache statistics
      # @return [Hash] Cache statistics
      def cache_stats
        ImageCacheManager.cache_stats
      end
    end

    private

    # ============================================
    # Logging helpers
    # ============================================

    # Format source handle for log messages (subclass can override)
    def format_source_handle
      "@#{source_handle}"
    end

    # Log preview details (subclass can override for different format)
    def log_preview_details(profile)
      log 'Profile data:'
      log "  Display name: #{profile[:display_name]}" if profile.key?(:display_name)
      log "  Description: #{profile[:description]&.slice(0, 60)}..."
      log "  Avatar: #{profile[:avatar_url] ? '✅ present' : '❌ none'}"
      b_url = profile[banner_key]
      b_label = banner_key == :cover_url ? 'Cover' : 'Banner'
      log "  #{b_label}: #{b_url ? '✅ present' : '❌ none'}"
      log "  Website: #{profile[:website] || 'none'}" if profile.key?(:website)
      log "  Profile URL: #{build_profile_url(profile[:handle])}"
    end

    # Log sync details (subclass can override to add platform-specific info)
    def log_sync_details(force)
      log "  Source: #{format_source_handle}"
      log "  Target: #{mastodon_instance}"
      log "  Language: #{language}, Retention: #{retention_days} days"
      log "  Cache: #{use_cache ? 'enabled' : 'disabled'}#{force ? ' (force refresh)' : ''}"
    end

    def log_image_result(label, data)
      if data[:from_cache]
        log "  ✔ #{label} loaded from cache (#{data[:data].bytesize} bytes)"
      else
        log "  ✔ #{label} downloaded (#{data[:data].bytesize} bytes)"
      end
    end

    # ============================================
    # HTTP Helpers — delegate to HttpClient
    # ============================================

    def http_get(uri, open_timeout: 10, read_timeout: 15)
      HttpClient.get(uri, user_agent: USER_AGENT, open_timeout: open_timeout, read_timeout: read_timeout)
    end

    # Retry wrapper for fetch_platform_profile — handles transient network errors.
    # Default: 3 retries with [1, 2, 4] s exponential backoff.
    FETCH_RETRY_DELAYS = HttpClient::DEFAULT_RETRY_DELAYS

    def with_retry(max_retries: HttpClient::DEFAULT_MAX_RETRIES, delays: FETCH_RETRY_DELAYS, &block)
      attempts = 0
      begin
        block.call
      rescue => e
        attempts += 1
        if attempts <= max_retries
          delay = delays[attempts - 1] || delays.last
          log "  ⚠️ Fetch failed (#{e.message.lines.first.strip}), retry #{attempts}/#{max_retries} in #{delay}s...", level: :warn
          sleep delay
          retry
        end
        raise
      end
    end

    # Options passed to HttpClient.download when fetching images.
    # Subclasses can override to add custom headers or user_agent.
    # Called once during initialize to configure @image_cache.
    def image_download_options
      {}
    end
  end
end
