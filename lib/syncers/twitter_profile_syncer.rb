# frozen_string_literal: true

# Twitter Profile Syncer - Synchronizes profile info from Twitter/X to Mastodon
#
# Fetches profile data via Nitter instance and syncs to Mastodon:
# - description/bio
# - avatar image
# - banner/header image
# - All 4 metadata fields (x:, web:, spravuje:, retence:)
#
# Does NOT sync: display_name (contains :bot: badge), handle (set at creation)
#
# Usage:
#   syncer = Syncers::TwitterProfileSyncer.new(
#     twitter_handle: 'ct24zive',
#     nitter_instance: 'http://xn.zpravobot.news:8080',
#     mastodon_instance: 'https://zpravobot.news',
#     mastodon_token: 'xxx',
#     language: 'cs',
#     retention_days: 90,
#     mentions_config: { 'type' => 'domain_suffix', 'value' => 'x.com' }
#   )
#   syncer.sync!

require_relative 'base_profile_syncer'

module Syncers
  class TwitterProfileSyncer < BaseProfileSyncer
    DEFAULT_NITTER = ENV['NITTER_INSTANCE'] || 'http://xn.zpravobot.news:8080'
    DEFAULT_MENTIONS_CONFIG = { 'type' => 'domain_suffix', 'value' => 'x.com' }.freeze

    attr_reader :twitter_handle, :nitter_instance

    def initialize(twitter_handle:, nitter_instance: nil, **base_opts)
      @twitter_handle = twitter_handle.gsub(/^@/, '')
      @nitter_instance = (nitter_instance || ENV['NITTER_INSTANCE'] || DEFAULT_NITTER).chomp('/')
      super(**base_opts)
    end

    # ============================================
    # Template method implementations
    # ============================================

    def source_handle
      twitter_handle
    end

    def platform_name
      'Twitter'
    end

    def platform_key
      'twitter'
    end

    def field_prefix
      'x:'
    end

    def default_mentions_config
      DEFAULT_MENTIONS_CONFIG
    end

    # Twitter does not validate image content-type (Nitter proxied images)
    def validate_image_content_type?
      false
    end

    def fetch_platform_profile
      uri = URI("#{nitter_instance}/#{twitter_handle}")
      response = http_get(uri)

      unless response.is_a?(Net::HTTPSuccess)
        raise "Nitter error: #{response.code} #{response.message}"
      end

      # Net::HTTP vrací body jako ASCII-8BIT (BINARY). Nitter posílá UTF-8 HTML,
      # takže přeznačíme kódování (bez konverze dat) aby regex a string operace fungovaly.
      html = response.body.dup.force_encoding('UTF-8')
      parse_nitter_profile(html)
    end

    # ============================================
    # Class-level API
    # ============================================

    @class_cache_dir = DEFAULT_CACHE_DIR
    @class_nitter_instance = DEFAULT_NITTER

    class << self
      attr_accessor :class_cache_dir, :class_nitter_instance

      # Fetch display name from Twitter profile via Nitter
      # @param handle [String] Twitter handle (without @)
      # @param nitter_instance [String] Nitter instance URL (optional)
      # @return [String, nil] Display name or nil if failed
      def fetch_display_name(handle, nitter_instance: nil)
        nitter = nitter_instance || @class_nitter_instance || DEFAULT_NITTER
        nitter = nitter.chomp('/')
        handle = handle.gsub(/^@/, '')

        uri = URI("#{nitter}/#{handle}")

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.open_timeout = 5
        http.read_timeout = 10

        request = Net::HTTP::Get.new(uri)
        request['User-Agent'] = USER_AGENT
        response = http.request(request)

        if response.is_a?(Net::HTTPSuccess)
          html = response.body

          if html =~ /<a[^>]*class="profile-card-fullname"[^>]*>([^<]+)<\/a>/
            display_name = $1.strip
            display_name = display_name
              .gsub('&amp;', '&')
              .gsub('&lt;', '<')
              .gsub('&gt;', '>')
              .gsub('&quot;', '"')
              .gsub('&#39;', "'")

            return display_name unless display_name.empty?
          end
        end

        nil
      rescue StandardError
        nil
      end
    end

    private

    # ============================================
    # Overrides
    # ============================================

    def log_sync_details(force)
      super
      log "  Nitter: #{nitter_instance}"
    end

    def build_profile_url_fallback(handle)
      "https://x.com/#{handle}"
    end

    # ============================================
    # Nitter HTML Parsing
    # ============================================

    def parse_nitter_profile(html)
      profile = {
        handle: twitter_handle,
        display_name: nil,
        description: nil,
        avatar_url: nil,
        banner_url: nil
      }

      # Extract display name
      if html =~ /<a[^>]*class="profile-card-fullname"[^>]*>([^<]+)<\/a>/
        profile[:display_name] = HtmlCleaner.decode_html_entities($1.strip)
      end

      # Extract description/bio
      if html =~ /<div[^>]*class="profile-bio"[^>]*>(.*?)<\/div>/m
        bio = $1.strip
        bio = bio.gsub(/<br\s*\/?>/, "\n")
        bio = bio.gsub(/<[^>]+>/, '')
        profile[:description] = HtmlCleaner.decode_html_entities(bio).strip
      end

      # Extract avatar URL
      if html =~ /<a[^>]*class="profile-card-avatar"[^>]*href="([^"]+)"/
        profile[:avatar_url] = resolve_nitter_url($1)
      end

      # Extract banner URL
      if html =~ /<div[^>]*class="profile-banner"[^>]*>\s*<a[^>]*href="([^"]+)"/m
        profile[:banner_url] = resolve_nitter_url($1)
      end

      profile
    end

    def resolve_nitter_url(path)
      return nil if path.nil? || path.empty?

      if path.start_with?('http')
        path
      elsif path.start_with?('/pic/')
        "#{nitter_instance}#{path}"
      else
        "#{nitter_instance}/#{path.sub(/^\//, '')}"
      end
    end

    # Override BaseProfileSyncer#cache_key_for_url to normalize Nitter proxy URLs.
    # Nitter URLs contain the instance hostname (e.g. http://xn.zpravobot.news:8080/pic/enc/...)
    # which is unstable — it changes when the instance restarts or rotates. Using the full
    # URL as cache key would cause a cache miss on every run.
    # Fix: strip the hostname and use only the /pic/... path as the hash input,
    # so the cache key is stable regardless of which Nitter instance served the image.
    def cache_key_for_url(url, prefix)
      normalized = normalize_nitter_cache_url(url)
      hash = Digest::SHA256.hexdigest(normalized)[0, 16]
      handle_key = source_handle.gsub(/[^a-zA-Z0-9]/, '_')
      "#{prefix}_#{handle_key}_#{hash}"
    end

    # Extract only the /pic/... path from a Nitter proxy URL.
    # Non-Nitter URLs (e.g. direct CDN links) are returned unchanged.
    def normalize_nitter_cache_url(url)
      if url =~ %r{https?://[^/]+(/pic/.+)$}
        $1
      else
        url
      end
    end
  end
end
