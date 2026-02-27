# frozen_string_literal: true

# Bluesky Profile Syncer - Synchronizes profile info from Bluesky to Mastodon
#
# Fetches profile data via Bluesky public API and syncs to Mastodon:
# - description/bio
# - avatar image
# - banner/header image
# - All 4 metadata fields (bsky:, web:, spravuje:, retence:)
#
# Does NOT sync: display_name (contains :bot: badge), handle (set at creation)
#
# Usage:
#   syncer = Syncers::BlueskyProfileSyncer.new(
#     bluesky_handle: 'nesestra.bsky.social',
#     mastodon_instance: 'https://zpravobot.news',
#     mastodon_token: 'xxx',
#     language: 'cs',
#     retention_days: 90,
#     mentions_config: { 'type' => 'prefix', 'value' => 'https://bsky.app/profile/' }
#   )
#   syncer.sync!

require_relative 'base_profile_syncer'

module Syncers
  class BlueskyProfileSyncer < BaseProfileSyncer
    BLUESKY_API = 'https://public.api.bsky.app/xrpc'
    DEFAULT_MENTIONS_CONFIG = { 'type' => 'prefix', 'value' => 'https://bsky.app/profile/' }.freeze

    attr_reader :bluesky_handle

    def initialize(bluesky_handle:, bluesky_api: nil, bluesky_profile_prefix: nil, **base_opts)
      @bluesky_handle = bluesky_handle
      @bluesky_api = (bluesky_api || BLUESKY_API).chomp('/')
      @bluesky_profile_prefix = (bluesky_profile_prefix || DEFAULT_MENTIONS_CONFIG['value']).chomp('/')
      super(**base_opts)
    end

    # ============================================
    # Template method implementations
    # ============================================

    def source_handle
      bluesky_handle
    end

    def platform_name
      'Bluesky'
    end

    def platform_key
      'bluesky'
    end

    def field_prefix
      'bsky:'
    end

    def default_mentions_config
      DEFAULT_MENTIONS_CONFIG
    end

    # Bluesky validates image content-type
    def validate_image_content_type?
      true
    end

    def fetch_platform_profile
      uri = URI("#{@bluesky_api}/app.bsky.actor.getProfile")
      uri.query = URI.encode_www_form(actor: bluesky_handle)

      response = http_get(uri)

      unless response.is_a?(Net::HTTPSuccess)
        raise "Bluesky API error: #{response.code} #{response.message}"
      end

      data = JSON.parse(response.body)

      {
        did: data['did'],
        handle: data['handle'],
        display_name: data['displayName'],
        description: data['description'],
        avatar_url: data['avatar'],
        banner_url: data['banner'],
        followers_count: data['followersCount'],
        follows_count: data['followsCount'],
        posts_count: data['postsCount']
      }
    end

    # ============================================
    # Class-level API
    # ============================================

    @class_cache_dir = DEFAULT_CACHE_DIR

    class << self
      attr_accessor :class_cache_dir

      # Fetch display name from Bluesky profile
      # @param handle [String] Bluesky handle (e.g. "nesestra.bsky.social")
      # @return [String, nil] Display name or nil if failed
      def fetch_display_name(handle, bluesky_api: nil)
        api_base = (bluesky_api || BLUESKY_API).chomp('/')
        uri = URI("#{api_base}/app.bsky.actor.getProfile")
        uri.query = URI.encode_www_form(actor: handle)

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 5
        http.read_timeout = 10

        request = Net::HTTP::Get.new(uri)
        request['User-Agent'] = USER_AGENT
        response = http.request(request)

        if response.is_a?(Net::HTTPSuccess)
          data = JSON.parse(response.body)
          display_name = data['displayName']
          return display_name if display_name && !display_name.empty?
        end

        nil
      rescue StandardError
        nil
      end
    end

    private

    def build_profile_url_fallback(handle)
      "#{@bluesky_profile_prefix}/#{handle}"
    end
  end
end
