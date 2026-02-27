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

require 'json'
require 'uri'
require 'digest'
require 'fileutils'
require_relative '../utils/http_client'
require_relative '../utils/format_helpers'
require_relative '../utils/html_cleaner'
require_relative '../support/loggable'

module Syncers
  class BaseProfileSyncer
    include Support::Loggable

    USER_AGENT = 'Zpravobot/1.0 (+https://zpravobot.news)'
    DEFAULT_CACHE_DIR = ENV['ZBNW_DIR'] ? "#{ENV['ZBNW_DIR']}/cache/profiles" : 'cache/profiles'
    IMAGE_CACHE_TTL = 86400 * 7 # 7 days in seconds

    FIELD_LABELS = {
      'cs' => { managed: 'spravuje:', retention: 'retence:', days: 'dní', from: 'z' },
      'sk' => { managed: 'spravované:', retention: 'retencia:', days: 'dní', from: 'z' },
      'en' => { managed: 'managed by:', retention: 'retention:', days: 'days', from: 'from' }
    }.freeze

    VALID_RETENTION_DAYS = [7, 30, 90, 180].freeze
    MANAGED_BY = '@zpravobot@zpravobot.news'

    # Short display labels for each source platform, used in the SPRAVUJE field.
    # e.g. 'twitter' => 'X', 'bluesky' => 'Bluesky'
    PLATFORM_LABELS = {
      'twitter'   => 'X',
      'bluesky'   => 'Bluesky',
      'facebook'  => 'FB',
      'instagram' => 'IG',
      'youtube'   => 'YT',
      'rss'       => 'RSS'
    }.freeze

    attr_reader :mastodon_instance, :mastodon_token,
                :language, :retention_days, :cache_dir, :use_cache, :mentions_config

    def initialize(mastodon_instance:, mastodon_token:,
                   language: 'cs', retention_days: 90, cache_dir: nil, use_cache: true,
                   mentions_config: nil)
      @mastodon_instance = mastodon_instance.chomp('/')
      @mastodon_token = mastodon_token
      @language = FIELD_LABELS.key?(language) ? language : 'cs'
      @retention_days = VALID_RETENTION_DAYS.include?(retention_days) ? retention_days : 90
      @cache_dir = cache_dir || DEFAULT_CACHE_DIR
      @use_cache = use_cache
      @mentions_config = mentions_config || default_mentions_config

      ensure_cache_dir if use_cache
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

      profile = fetch_platform_profile

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
        current_fields = fetch_mastodon_fields

        new_fields = build_fields(profile[:handle], current_fields, profile)

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
        log '  Downloading avatar...'
        avatar_data = download_image_cached(profile[:avatar_url], 'avatar', force: force)
        if avatar_data
          log_image_result('Avatar', avatar_data)
          files[:avatar] = avatar_data
          changes << 'avatar'
        end
      end

      # Banner
      b_url = profile[banner_key]
      if sync_banner && b_url
        b_label = banner_key == :cover_url ? 'cover photo' : 'banner'
        log "  Downloading #{b_label}..."
        banner_data = download_image_cached(b_url, 'banner', force: force)
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
      result = update_mastodon_profile(params, files)

      if result[:success]
        log '✅ Profile synced successfully!', level: :success
        log "  Changes: #{changes.join(', ')}"
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
    # Class-level API (for cross-component usage)
    # ============================================

    @class_cache_dir = DEFAULT_CACHE_DIR

    class << self
      attr_accessor :class_cache_dir

      # Clear all cached images for a handle
      # @param handle [String] Platform handle
      # @return [Integer] Number of deleted files
      def clear_cache(handle)
        ensure_class_cache_dir

        handle_key = handle.gsub(/[^a-zA-Z0-9]/, '_')
        patterns = [
          "avatar_#{handle_key}_*",
          "banner_#{handle_key}_*"
        ]

        deleted = 0
        patterns.each do |pattern|
          Dir.glob(File.join(@class_cache_dir, pattern)).each do |f|
            File.delete(f) rescue nil
            deleted += 1
          end
          # Also delete .meta files
          Dir.glob(File.join(@class_cache_dir, "#{pattern}.meta")).each do |f|
            File.delete(f) rescue nil
          end
        end

        deleted
      end

      # Get cache statistics
      # @return [Hash] Cache statistics
      def cache_stats
        ensure_class_cache_dir

        files = Dir.glob(File.join(@class_cache_dir, '*')).reject { |f| f.end_with?('.meta') }
        total_size = files.sum { |f| File.size(f) rescue 0 }

        {
          total_files: files.count,
          total_size_bytes: total_size,
          total_size_human: FormatHelpers.format_bytes(total_size),
          cache_dir: @class_cache_dir
        }
      end

      private

      def ensure_class_cache_dir
        FileUtils.mkdir_p(@class_cache_dir) unless Dir.exist?(@class_cache_dir)
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
    # Profile URL & Fields
    # ============================================

    # Build profile URL based on mentions_config from platform YAML
    # @param handle [String] Platform handle
    # @return [String] Profile URL
    def build_profile_url(handle)
      config_type = mentions_config['type'] || mentions_config[:type]
      config_value = mentions_config['value'] || mentions_config[:value]

      case config_type
      when 'prefix'
        "#{config_value}#{handle}"
      when 'domain_suffix'
        "https://#{config_value}/#{handle}"
      else
        build_profile_url_fallback(handle)
      end
    end

    # Fallback URL when mentions_config type is unknown (subclass can override)
    def build_profile_url_fallback(handle)
      "https://#{platform_name.downcase}.com/#{handle}"
    end

    # Build all 4 metadata fields
    # @param handle [String] Platform handle
    # @param current_fields [Array<Hash>] Current Mastodon fields
    # @param extra_data [Hash] Additional profile data (e.g., Facebook website,
    #   or source_platforms: ['youtube', 'instagram'] for multi-platform aggregators)
    # @return [Array<Hash>] New fields array
    def build_fields(handle, current_fields, extra_data = {})
      labels = FIELD_LABELS[language]
      source_platforms = extra_data[:source_platforms]

      web_value = extract_web_value(current_fields)
      profile_url = build_profile_url(handle)

      [
        { name: field_prefix, value: profile_url },
        { name: 'web:', value: web_value },
        { name: labels[:managed], value: build_managed_by_value(source_platforms: source_platforms) },
        { name: labels[:retention], value: "#{retention_days} #{labels[:days]}" }
      ]
    end

    # Extract web: field value from current fields
    # @param fields [Array<Hash>] Current fields
    # @return [String] Web value or '""'
    def extract_web_value(fields)
      web_field = fields.find { |f| f[:name].downcase.start_with?('web') }
      value = web_field&.dig(:value)&.strip

      (value.nil? || value.empty?) ? '""' : value
    end

    # Build the value for the SPRAVUJE field, e.g. "@zpravobot@zpravobot.news z X"
    # @param source_platforms [Array<String>, nil] Override platform list (for multi-platform
    #   aggregators in TASK-3). When nil, defaults to [platform_key] from the syncer subclass.
    # @return [String] Full managed-by string with platform suffix
    def build_managed_by_value(source_platforms: nil)
      labels = FIELD_LABELS[language]
      platforms = source_platforms || [platform_key]
      platform_str = platforms.map { |p| PLATFORM_LABELS[p] || p }.join(', ')
      "#{MANAGED_BY} #{labels[:from]} #{platform_str}"
    end

    # ============================================
    # Cache Management
    # ============================================

    def ensure_cache_dir
      FileUtils.mkdir_p(cache_dir) unless Dir.exist?(cache_dir)
    end

    def cache_key_for_url(url, prefix)
      hash = Digest::SHA256.hexdigest(url)[0, 16]
      handle_key = source_handle.gsub(/[^a-zA-Z0-9]/, '_')
      "#{prefix}_#{handle_key}_#{hash}"
    end

    def cache_path(key)
      File.join(cache_dir, key)
    end

    def read_image_cache(key)
      return nil unless use_cache

      path = cache_path(key)
      meta_path = "#{path}.meta"

      return nil unless File.exist?(path) && File.exist?(meta_path)

      # Check TTL
      if (Time.now - File.mtime(path)) > IMAGE_CACHE_TTL
        File.delete(path) rescue nil
        File.delete(meta_path) rescue nil
        return nil
      end

      meta = JSON.parse(File.read(meta_path), symbolize_names: true)
      data = File.binread(path)

      {
        data: data,
        content_type: meta[:content_type],
        filename: meta[:filename],
        from_cache: true,
        cached_at: File.mtime(path)
      }
    rescue StandardError => e
      log "  ⚠️ Cache read error: #{e.message}", level: :warn
      nil
    end

    def write_image_cache(key, data, content_type, filename)
      return unless use_cache

      path = cache_path(key)
      meta_path = "#{path}.meta"

      File.binwrite(path, data)
      File.write(meta_path, { content_type: content_type, filename: filename }.to_json)
    rescue StandardError => e
      log "  ⚠️ Cache write error: #{e.message}", level: :warn
    end

    # ============================================
    # Image Download with Cache
    # ============================================

    def download_image_cached(url, type, force: false)
      cache_key = cache_key_for_url(url, type)

      # Try cache first (unless forcing)
      unless force
        cached = read_image_cache(cache_key)
        return cached if cached
      end

      # Download fresh
      image_data = download_image(url)
      return nil unless image_data

      # Cache the result
      write_image_cache(cache_key, image_data[:data], image_data[:content_type], image_data[:filename])

      image_data.merge(from_cache: false)
    end

    # ============================================
    # Mastodon API
    # ============================================

    def fetch_mastodon_fields
      url = "#{mastodon_instance}/api/v1/accounts/verify_credentials"
      response = HttpClient.get(url, headers: mastodon_auth_headers)

      unless response.is_a?(Net::HTTPSuccess)
        raise "Failed to fetch Mastodon profile: #{response.code}"
      end

      data = JSON.parse(response.body)
      fields = data['fields'] || []

      fields.map { |f| { name: f['name'], value: sanitize_html(f['value']) } }
    end

    def sanitize_html(html)
      HtmlCleaner.sanitize_html(html)
    end

    def update_mastodon_profile(params, files)
      uri = URI("#{mastodon_instance}/api/v1/accounts/update_credentials")

      if files.any?
        boundary = "----ZpravobotBoundary#{rand(1_000_000_000)}"
        body = build_multipart_body(params, files, boundary)

        request = Net::HTTP::Patch.new(uri)
        request['Content-Type'] = "multipart/form-data; boundary=#{boundary}"
        request.body = body
      else
        request = Net::HTTP::Patch.new(uri)
        request['Content-Type'] = 'application/x-www-form-urlencoded'
        request.body = URI.encode_www_form(params)
      end

      request['Authorization'] = "Bearer #{mastodon_token}"
      request['User-Agent'] = HttpClient::DEFAULT_UA

      response = HttpClient.patch_raw(uri, request)

      if response.is_a?(Net::HTTPSuccess)
        data = JSON.parse(response.body)
        { success: true, account: data }
      else
        error = begin
          JSON.parse(response.body)['error']
        rescue StandardError
          response.body
        end
        { success: false, error: error }
      end
    end

    def build_multipart_body(params, files, boundary)
      body = ''.b

      params.each do |key, value|
        body << "--#{boundary}\r\n".b
        body << "Content-Disposition: form-data; name=\"#{key}\"\r\n\r\n".b
        body << value.to_s.dup.force_encoding('UTF-8').b
        body << "\r\n".b
      end

      files.each do |key, file_data|
        body << "--#{boundary}\r\n".b
        body << "Content-Disposition: form-data; name=\"#{key}\"; filename=\"#{file_data[:filename]}\"\r\n".b
        body << "Content-Type: #{file_data[:content_type]}\r\n\r\n".b
        body << file_data[:data].b
        body << "\r\n".b
      end

      body << "--#{boundary}--\r\n".b
      body
    end

    # ============================================
    # HTTP Helpers — delegate to HttpClient
    # ============================================

    def http_get(uri, open_timeout: 10, read_timeout: 15)
      HttpClient.get(uri, user_agent: USER_AGENT, open_timeout: open_timeout, read_timeout: read_timeout)
    end

    def mastodon_auth_headers
      { 'Authorization' => "Bearer #{mastodon_token}" }
    end

    def download_image(url)
      response = HttpClient.get(url)

      return nil unless response.is_a?(Net::HTTPSuccess)

      content_type = response['content-type']&.split(';')&.first || 'image/jpeg'

      if validate_image_content_type?
        unless content_type.start_with?('image/')
          log "  Invalid content type: #{content_type}", level: :warn
          return nil
        end
      end

      ext = case content_type
            when 'image/jpeg' then 'jpg'
            when 'image/png' then 'png'
            when 'image/gif' then 'gif'
            when 'image/webp' then 'webp'
            else 'jpg'
            end

      {
        data: response.body,
        content_type: content_type,
        filename: "profile.#{ext}"
      }
    rescue StandardError => e
      log "  Failed to download image: #{e.message}", level: :warn
      nil
    end
  end
end
