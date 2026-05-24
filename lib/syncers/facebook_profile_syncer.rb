# frozen_string_literal: true

# Facebook Profile Syncer - Synchronizes profile info from Facebook to Mastodon
#
# Uses Browserless.io API to render Facebook pages with JavaScript.
#
# Syncs:
# - description/bio
# - avatar image (profile photo)
# - banner/header image (cover photo)
# - All 4 metadata fields (fb:, web:, spravuje:, retence:)
#
# Does NOT sync: display_name (contains :bot: badge), handle (set at creation)
#
# Usage:
#   syncer = Syncers::FacebookProfileSyncer.new(
#     facebook_handle: 'headliner.cz',
#     mastodon_instance: 'https://zpravobot.news',
#     mastodon_token: 'xxx',
#     browserless_token: 'xxx',
#     facebook_cookies: [
#       { name: 'c_user', value: 'xxx', domain: '.facebook.com' },
#       { name: 'xs', value: 'xxx', domain: '.facebook.com' }
#     ],
#     language: 'cs',
#     retention_days: 90,
#     mentions_config: { 'type' => 'domain_suffix', 'value' => 'facebook.com' }
#   )
#   syncer.sync!

require_relative 'browserless_profile_syncer'
require 'cgi'

module Syncers
  class FacebookProfileSyncer < BrowserlessProfileSyncer
    DEFAULT_MENTIONS_CONFIG = { 'type' => 'domain_suffix', 'value' => 'facebook.com' }.freeze
    DEFAULT_FACEBOOK_COOKIES = [].freeze
    # Domains that appear in the global FB footer — never a profile's own website
    FOOTER_DOMAINS = %w[
      facebook.com messenger.com meta.com instagram.com threads.com
      whatsapp.com oculus.com
    ].freeze

    attr_reader :facebook_handle, :facebook_cookies

    # NOTE: Image cache is intentionally NOT used for Facebook.
    # Facebook CDN URLs contain time-limited tokens in query parameters
    # (e.g. ?_nc_ohc=...&ccb=...&_nc_sid=...) that change on every fetch.
    # Because cache_key_for_url hashes the full URL, each fetch produces a
    # different key and the cache would never hit. Facebook sync also runs
    # only once every 3 days, so re-downloading images is acceptable.
    def initialize(facebook_handle:, facebook_cookies:, **base_opts)
      @facebook_handle  = facebook_handle.gsub(%r{^https?://[^/]+/}, '').gsub(/^@/, '')
      @facebook_cookies = facebook_cookies || DEFAULT_FACEBOOK_COOKIES
      super(**base_opts)
    end

    # ============================================
    # Template method implementations
    # ============================================

    def source_handle
      facebook_handle
    end

    def platform_name
      'Facebook'
    end

    def platform_key
      'facebook'
    end

    def field_prefix
      'fb:'
    end

    def default_mentions_config
      DEFAULT_MENTIONS_CONFIG
    end

    # Facebook uses :cover_url instead of :banner_url
    def banner_key
      :cover_url
    end

    # Facebook validates image content-type
    def validate_image_content_type?
      true
    end

    def fetch_platform_profile
      # Fetch /about page — the profile website link only appears there,
      # not on the main profile page (which only has global FB footer links).
      url = "https://www.facebook.com/#{facebook_handle}/about"
      log "  Fetching #{url} via Browserless..."

      html = fetch_page_via_browserless(url, cookies: facebook_cookies)
      profile = parse_facebook_profile(html)

      # Detekce expirovaných cookies: při login wall FB vrátí stránku bez
      # profilových dat — bio i avatar budou nil zároveň.
      if profile[:avatar_url].nil? && profile[:description].nil?
        log '  ⚠️ No avatar or bio extracted — Facebook cookies may have expired', level: :warn
      end

      profile
    end

    private

    # ============================================
    # Overrides
    # ============================================

    # Facebook doesn't use @ prefix for handles
    def format_source_handle
      facebook_handle
    end

    # Facebook shows different preview fields
    def log_preview_details(profile)
      log 'Profile data:'
      log "  Description: #{profile[:description]&.slice(0, 60)}..."
      log "  Avatar: #{profile[:avatar_url] ? '✅ present' : '❌ none'}"
      log "  Cover: #{profile[:cover_url] ? '✅ present' : '❌ none'}"
      log "  Website: #{profile[:website] || 'none'}"
      log "  Profile URL: #{build_profile_url(facebook_handle)}"
    end

    def build_profile_url_fallback(handle)
      "https://facebook.com/#{handle}"
    end

    def parse_facebook_profile(html)
      profile = {
        handle: facebook_handle,
        description: nil,
        avatar_url: nil,
        cover_url: nil,
        website: nil
      }

      # Extract profile image from JSON data
      if html =~ /"profilePhoto".*?"uri":"([^"]+)"/
        profile[:avatar_url] = decode_facebook_url($1)
      elsif html =~ /profilePic.*?src="([^"]+)"/
        profile[:avatar_url] = HtmlCleaner.decode_html_entities($1)
      end

      # Extract cover photo
      if html =~ /CoverPhoto.*?src="([^"]+)"/i
        profile[:cover_url] = HtmlCleaner.decode_html_entities($1)
      elsif html =~ /cover_photo.*?uri["\s:]+\\?"([^"\\]+)/
        profile[:cover_url] = decode_facebook_url($1)
      end

      # Extract description — try embedded JSON first (full text, not truncated),
      # fall back to og:description (FB truncates it at ~300 chars).
      json_desc = extract_description_from_json(html)
      if json_desc && !json_desc.empty?
        log "  Description source: embedded JSON (#{json_desc.length} chars)"
        profile[:description] = json_desc
      elsif html =~ /<meta property="og:description" content="([^"]+)"/
        desc = HtmlCleaner.decode_html_entities($1)
        # Strip FB metrics prefix: "Page Name. 232,088 likes · 19,789 talking about this. "
        # Previous regex failed for page names containing dots (e.g. "noviny.sk").
        desc = desc.sub(/\A.*?\d[\d,]*\s+likes[^.]*\.\s*/m, '')
        log "  Description source: og:description (#{desc.length} chars)"
        profile[:description] = desc unless desc.empty?
      end

      # Extract website from Facebook redirect link.
      # We fetch /about so the profile's own website link appears first.
      # Also filter out known FB/Meta footer domains that appear even on profiles without a website.
      html.scan(/l\.facebook\.com\/l\.php\?u=([^&"\\]+)/).each do |m|
        website = CGI.unescape(m.first)
        website = website.sub(/[?&]fbclid=.*$/, '').chomp('/')
        next if FOOTER_DOMAINS.any? { |d| website.include?(d) }

        profile[:website] = website
        break
      end

      profile
    end

    # Try to extract the full (untruncated) page description from FB's embedded JSON.
    # FB embeds page data in script tags; the "about" field is not truncated unlike og:description.
    def extract_description_from_json(html)
      # Pattern 1: "about":{"text":"..."} — common in newer FB JSON bundles
      if html =~ /"about":\{"text":"((?:[^"\\]|\\.)*)"/
        text = unescape_json_string($1)
        return text if text && !text.empty?
      end

      # Pattern 2: pageAboutInfo / page_about_fields with description key
      if html =~ /"pageAboutInfo"[^{]*\{[^}]*"description":"((?:[^"\\]|\\.)*)"/ ||
         html =~ /"page_about_fields"[^{]*\{[^}]*"description":"((?:[^"\\]|\\.)*)"/
        text = unescape_json_string($1)
        return text if text && !text.empty?
      end

      nil
    end

    def unescape_json_string(s)
      return nil if s.nil?

      s.gsub('\\"', '"')
       .gsub('\\n', "\n")
       .gsub('\\r', '')
       .gsub('\\t', ' ')
       .gsub('\\/', '/')
       .gsub('\\u0026', '&')
       .gsub('\\u003C', '<')
       .gsub('\\u003E', '>')
       .strip
    end

    def decode_facebook_url(url)
      return nil if url.nil? || url.empty?

      url
        .gsub('\\/', '/')
        .gsub('\\u0025', '%')
        .gsub('&amp;', '&')
    end
  end
end
