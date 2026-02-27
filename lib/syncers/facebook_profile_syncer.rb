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

require_relative 'base_profile_syncer'
require 'cgi'

module Syncers
  class FacebookProfileSyncer < BaseProfileSyncer
    BROWSERLESS_API = 'https://chrome.browserless.io/content'
    DEFAULT_MENTIONS_CONFIG = { 'type' => 'domain_suffix', 'value' => 'facebook.com' }.freeze
    DEFAULT_FACEBOOK_COOKIES = [].freeze

    attr_reader :facebook_handle, :browserless_token, :facebook_cookies

    # NOTE: Image cache is intentionally NOT used for Facebook.
    # Facebook CDN URLs contain time-limited tokens in query parameters
    # (e.g. ?_nc_ohc=...&ccb=...&_nc_sid=...) that change on every fetch.
    # Because cache_key_for_url hashes the full URL, each fetch produces a
    # different key and the cache would never hit. Facebook sync also runs
    # only once every 3 days, so re-downloading images is acceptable.
    def initialize(facebook_handle:, browserless_token:, facebook_cookies:, browserless_api: nil, **base_opts)
      @facebook_handle = facebook_handle.gsub(%r{^https?://[^/]+/}, '').gsub(/^@/, '')
      @browserless_token = browserless_token
      @facebook_cookies = facebook_cookies || DEFAULT_FACEBOOK_COOKIES
      @browserless_api = (browserless_api || BROWSERLESS_API).chomp('/')
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

    # Facebook prefers website from profile over current web: value
    def build_fields(handle, current_fields, extra_data = {})
      labels = FIELD_LABELS[language]
      facebook_website = extra_data[:website]
      source_platforms = extra_data[:source_platforms]

      web_value = if facebook_website && !facebook_website.empty?
                    facebook_website
                  else
                    extract_web_value(current_fields)
                  end

      profile_url = build_profile_url(handle)

      [
        { name: field_prefix, value: profile_url },
        { name: 'web:', value: web_value },
        { name: labels[:managed], value: build_managed_by_value(source_platforms: source_platforms) },
        { name: labels[:retention], value: "#{retention_days} #{labels[:days]}" }
      ]
    end

    def fetch_platform_profile
      url = "https://www.facebook.com/#{facebook_handle}"
      log "  Fetching #{url} via Browserless..."

      html = fetch_page_via_browserless(url)
      parse_facebook_profile(html)
    end

    # ============================================
    # Class-level API
    # ============================================

    @class_cache_dir = DEFAULT_CACHE_DIR

    class << self
      attr_accessor :class_cache_dir
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

    # ============================================
    # Facebook Scraping via Browserless
    # ============================================

    def fetch_page_via_browserless(url)
      uri = URI("#{@browserless_api}?token=#{browserless_token}")

      body = {
        url: url,
        cookies: facebook_cookies,
        gotoOptions: { waitUntil: 'networkidle2' }
      }

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 60
      http.open_timeout = 30

      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request['User-Agent'] = USER_AGENT
      request.body = body.to_json

      response = http.request(request)

      unless response.is_a?(Net::HTTPSuccess)
        raise "Browserless API error: #{response.code} #{response.message}"
      end

      # Net::HTTP vrací body jako ASCII-8BIT (BINARY). Browserless posílá UTF-8 HTML,
      # takže přeznačíme kódování (bez konverze dat) aby regex a string operace fungovaly.
      response.body.dup.force_encoding('UTF-8')
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

      # Extract description from og:description
      if html =~ /<meta property="og:description" content="([^"]+)"/
        desc = HtmlCleaner.decode_html_entities($1)
        desc = desc.sub(/^[^.]+\.\s*[\d\s]+[^.]+\.\s*/, '')
        profile[:description] = desc unless desc.empty?
      end

      # Extract website from Facebook redirect link
      if html =~ /l\.facebook\.com\/l\.php\?u=([^&"\\]+)/
        website = CGI.unescape($1)
        website = website.sub(/[?&]fbclid=.*$/, '')
        profile[:website] = website unless website.include?('facebook.com')
      end

      profile
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
