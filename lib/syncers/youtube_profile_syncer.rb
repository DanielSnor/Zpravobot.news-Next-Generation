# frozen_string_literal: true

# YouTube Profile Syncer - Synchronizes profile info from YouTube to Mastodon
#
# Fetches channel data via plain HTTP GET (no API key required).
# Extracts profile data from ytInitialData JSON embedded in channel page HTML.
#
# Syncs:
# - description/bio
# - avatar image (channel profile photo)
# - banner image (channel art)
# - All 4 metadata fields (yt:, web:, spravuje:, retence:)
#
# Does NOT sync:
# - display_name (contains :bot: badge), handle (set at creation)
#
# Usage:
#   syncer = Syncers::YoutubeProfileSyncer.new(
#     youtube_handle: 'PetrLudvikPavel',
#     mastodon_instance: 'https://zpravobot.news',
#     mastodon_token: 'xxx',
#     language: 'cs',
#     retention_days: 180
#   )
#   syncer.sync!
#
# Handle formats supported:
#   'PetrLudvikPavel'   → https://www.youtube.com/@PetrLudvikPavel
#   '@PetrLudvikPavel'  → same (@ stripped automatically)
#   'UCxxxxx'           → https://www.youtube.com/channel/UCxxxxx

require_relative 'base_profile_syncer'

module Syncers
  class YoutubeProfileSyncer < BaseProfileSyncer
    DEFAULT_MENTIONS_CONFIG = { 'type' => 'none', 'value' => '' }.freeze

    attr_reader :youtube_handle

    def initialize(youtube_handle:, **base_opts)
      @youtube_handle = youtube_handle.gsub(%r{^https?://[^/]+/}, '').gsub(/^@/, '')
      super(**base_opts)
    end

    # ============================================
    # Template method implementations
    # ============================================

    def source_handle
      youtube_handle
    end

    def platform_name
      'YouTube'
    end

    def platform_key
      'youtube'
    end

    def field_prefix
      'yt:'
    end

    def default_mentions_config
      DEFAULT_MENTIONS_CONFIG
    end

    def fetch_platform_profile
      url = channel_url
      log "  Fetching #{url}..."

      uri = URI(url)
      response = http_get(uri, open_timeout: 15, read_timeout: 30)

      unless response.is_a?(Net::HTTPSuccess)
        raise "YouTube HTTP error: #{response.code} #{response.message}"
      end

      html = response.body.dup.force_encoding('UTF-8')
      parse_youtube_profile(html)
    end

    private

    # ============================================
    # Overrides
    # ============================================

    def format_source_handle
      "@#{youtube_handle}"
    end

    def log_preview_details(profile)
      log 'Profile data:'
      log "  Description: #{profile[:description]&.slice(0, 60)}..."
      log "  Avatar: #{profile[:avatar_url] ? '✅ present' : '❌ none'}"
      log "  Banner: #{profile[:banner_url] ? '✅ present' : '❌ none'}"
      log "  Profile URL: #{build_profile_url(youtube_handle)}"
    end

    def build_profile_url_fallback(handle)
      if handle.start_with?('UC')
        "https://youtube.com/channel/#{handle}"
      else
        "https://youtube.com/@#{handle}"
      end
    end

    # ============================================
    # YouTube Page Parsing
    # ============================================

    def channel_url
      if youtube_handle.start_with?('UC')
        "https://www.youtube.com/channel/#{youtube_handle}"
      else
        "https://www.youtube.com/@#{youtube_handle}"
      end
    end

    def parse_youtube_profile(html)
      profile = {
        handle: youtube_handle,
        description: nil,
        avatar_url: nil,
        banner_url: nil
      }

      # Primary: parse ytInitialData JSON embedded in page
      data = extract_yt_initial_data(html)

      if data
        # Description from channelMetadataRenderer
        desc = data.dig('metadata', 'channelMetadataRenderer', 'description')
        profile[:description] = desc unless desc.nil? || desc.strip.empty?

        # Avatar and banner from c4TabbedHeaderRenderer
        header = data.dig('header', 'c4TabbedHeaderRenderer')
        if header
          avatar_thumbs = header.dig('avatar', 'thumbnails') || []
          best_avatar = avatar_thumbs.max_by { |t| t['width'].to_i }
          profile[:avatar_url] = best_avatar['url'] if best_avatar

          banner_thumbs = header.dig('banner', 'thumbnails') || []
          best_banner = banner_thumbs.max_by { |t| t['width'].to_i }
          profile[:banner_url] = best_banner['url'] if best_banner
        end
      end

      # Fallback: description from meta tags
      if profile[:description].nil?
        raw = html[/<meta\b[^>]*\bname="description"[^>]*\bcontent="([^"]+)"/i, 1]
        raw ||= html[/<meta\b[^>]*\bcontent="([^"]+)"[^>]*\bname="description"/i, 1]
        raw ||= html[/<meta\b[^>]*\bproperty="og:description"[^>]*\bcontent="([^"]+)"/i, 1]
        raw ||= html[/<meta\b[^>]*\bcontent="([^"]+)"[^>]*\bproperty="og:description"/i, 1]
        profile[:description] = HtmlCleaner.decode_html_entities(raw) if raw
      end

      # Fallback: avatar from og:image
      if profile[:avatar_url].nil?
        raw = html[/<meta\b[^>]*\bproperty="og:image"[^>]*\bcontent="([^"]+)"/i, 1]
        raw ||= html[/<meta\b[^>]*\bcontent="([^"]+)"[^>]*\bproperty="og:image"/i, 1]
        profile[:avatar_url] = HtmlCleaner.decode_html_entities(raw) if raw
      end

      profile
    end

    # Extract and parse the ytInitialData JSON blob embedded in YouTube's HTML.
    #
    # Uses a balanced-bracket character scan to reliably find the JSON boundaries —
    # avoids fragile regex that would break on nested objects or description text
    # containing special characters.
    #
    # @param html [String] Full HTML of YouTube channel page
    # @return [Hash, nil] Parsed JSON data, or nil on failure
    def extract_yt_initial_data(html)
      start_match = html.match(/var ytInitialData\s*=\s*(\{)/)
      return nil unless start_match

      start_pos = start_match.begin(1)
      depth     = 0
      in_string = false
      escape    = false

      i = start_pos
      len = html.length

      while i < len
        c = html[i]

        if escape
          escape = false
        elsif in_string
          if c == '\\'
            escape = true
          elsif c == '"'
            in_string = false
          end
        else
          case c
          when '"' then in_string = true
          when '{' then depth += 1
          when '}'
            depth -= 1
            return JSON.parse(html[start_pos..i]) if depth.zero?
          end
        end

        i += 1
      end

      nil
    rescue JSON::ParserError => e
      log "  ⚠️ ytInitialData parse error: #{e.message.slice(0, 80)}", level: :warn
      nil
    end
  end
end
