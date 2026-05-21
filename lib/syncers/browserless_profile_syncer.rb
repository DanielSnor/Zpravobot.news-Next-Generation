# frozen_string_literal: true

# ============================================================
# BrowserlessProfileSyncer — intermediate base for Browserless-backed syncers
# ============================================================
#
# Provides shared Browserless.io fetch infrastructure for profile syncers
# that use a headless browser to render JavaScript-heavy pages.
#
# Used by: FacebookProfileSyncer, InstagramProfileSyncer,
#          ThreadsProfileSyncer, YoutubeProfileSyncer
#
# Subclasses MUST still implement all BaseProfileSyncer template methods
# (source_handle, platform_name, platform_key, field_prefix,
#  default_mentions_config, fetch_platform_profile).
#
# Subclasses pass cookies to fetch_page_via_browserless:
#   fetch_page_via_browserless(url, cookies: platform_cookies)
#
# For platforms that receive binary-safe HTML (Threads), pass safe_encoding: true.
# ============================================================

require_relative 'base_profile_syncer'

module Syncers
  class BrowserlessProfileSyncer < BaseProfileSyncer
    BROWSERLESS_API = 'https://chrome.browserless.io/content'

    attr_reader :browserless_token

    def initialize(browserless_token:, browserless_api: nil, **base_opts)
      @browserless_token = browserless_token
      @browserless_api   = (browserless_api || BROWSERLESS_API).chomp('/')
      super(**base_opts)
    end

    private

    # Fetch a URL via Browserless.io headless browser and return decoded HTML.
    #
    # @param url [String] Page URL to render
    # @param cookies [Array<Hash>] Cookies to inject (default: none)
    # @param safe_encoding [Boolean] When true uses encode() with replacement instead of
    #   force_encoding — needed when the response may contain non-UTF-8 byte sequences
    #   (Threads). Default false (force_encoding is faster and correct for UTF-8 sources).
    # @return [String] UTF-8 HTML string
    def fetch_page_via_browserless(url, cookies: [], safe_encoding: false)
      uri  = URI("#{@browserless_api}?token=#{browserless_token}")
      body = { url: url, gotoOptions: { waitUntil: 'networkidle2' } }
      body[:cookies] = cookies unless cookies.empty?

      response = HttpClient.post_json(uri.to_s, body,
                   open_timeout: 30, read_timeout: 60, user_agent: USER_AGENT)

      unless response.is_a?(Net::HTTPSuccess)
        raise "Browserless API error: #{response.code} #{response.message}"
      end

      if safe_encoding
        response.body.b.encode('UTF-8', invalid: :replace, undef: :replace)
      else
        response.body.dup.force_encoding('UTF-8')
      end
    end
  end
end
