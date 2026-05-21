# frozen_string_literal: true

# Threads Profile Syncer - Synchronizes profile info from Threads to Mastodon
#
# Uses Browserless.io API to render Threads pages with JavaScript.
# Threads profiles are PUBLIC — no session cookies required.
#
# Syncs:
# - description/bio
# - avatar image (profile photo, hosted on cdninstagram.com CDN)
# - All 4 metadata fields (threads:, web:, spravuje:, retence:)
#
# Does NOT sync:
# - banner/header (Threads nemá cover foto)
# - website URL (Threads nepodporuje web URL na profilu)
# - display_name, handle (set at creation)
#
# Usage:
#   syncer = Syncers::ThreadsProfileSyncer.new(
#     threads_handle: 'jirikostaf1',
#     mastodon_instance: 'https://zpravobot.news',
#     mastodon_token: 'xxx',
#     browserless_token: 'xxx',
#     language: 'cs',
#     retention_days: 90
#   )
#   syncer.sync!

require_relative 'browserless_profile_syncer'

module Syncers
  class ThreadsProfileSyncer < BrowserlessProfileSyncer
    DEFAULT_MENTIONS_CONFIG = { 'type' => 'domain_suffix', 'value' => 'threads.net' }.freeze

    attr_reader :threads_handle

    def initialize(threads_handle:, **base_opts)
      @threads_handle = threads_handle.gsub(%r{^https?://[^/]+/}, '').gsub(/^@/, '')
      super(**base_opts)
    end

    def source_handle
      threads_handle
    end

    def platform_name
      'Threads'
    end

    def platform_key
      'threads'
    end

    def field_prefix
      'threads:'
    end

    def default_mentions_config
      DEFAULT_MENTIONS_CONFIG
    end

    def banner_key
      :banner_url
    end

    def validate_image_content_type?
      true
    end

    def fetch_platform_profile
      url = "https://www.threads.net/@#{threads_handle}"
      log "  Fetching #{url} via Browserless (no cookies — public profile)..."

      # Threads uses safe_encoding because response may contain non-UTF-8 byte sequences.
      html = fetch_page_via_browserless(url, safe_encoding: true)
      parse_threads_profile(html)
    end

    private

    def format_source_handle
      "@#{threads_handle}"
    end

    def log_preview_details(profile)
      log 'Profile data:'
      log "  Description: #{profile[:description]&.slice(0, 60)}..."
      log "  Avatar: #{profile[:avatar_url] ? '✅ present' : '❌ none'}"
      log "  Profile URL: #{build_profile_url(threads_handle)}"
    end

    def build_profile_url_fallback(handle)
      "https://www.threads.net/@#{handle}"
    end

    def parse_threads_profile(html)
      profile = {
        handle: threads_handle,
        description: nil,
        avatar_url: nil,
        banner_url: nil,  # Threads nemá banner
        website: nil      # Threads nepodporuje web URL na profilu
      }

      # Bio z embedded JSON (stejná Meta Graph struktura jako Instagram)
      # Threads vrací Unicode escape sekvence (\uXXXX) — je nutno dekódovat.
      bio_raw = nil
      if html =~ /"biography"\s*:\s*"((?:[^"\\]|\\.)*)"/
        bio_raw = $1
      end
      if bio_raw
        bio = decode_meta_json_string(bio_raw)
        profile[:description] = bio unless bio.strip.empty?
      end

      # Fallback: meta description
      if profile[:description].nil?
        raw = html[/<meta\b[^>]*property="og:description"[^>]*content="([^"]+)"/i, 1] ||
              html[/<meta\b[^>]*content="([^"]+)"[^>]*property="og:description"/i, 1] ||
              html[/<meta\b[^>]*name="description"[^>]*content="([^"]+)"/i, 1]
        if raw
          decoded = raw.gsub('&quot;', '"').gsub('&amp;', '&').gsub('&#39;', "'")
                       .gsub('&lt;', '<').gsub('&gt;', '>')
          profile[:description] = decoded unless decoded.strip.empty?
        end
      end

      # Avatar — strategie stejné jako InstagramProfileSyncer
      # Strategie 1: <img alt="[handle]'s profile picture">
      img_pattern = /#{Regexp.escape(threads_handle)}'s profile picture/i
      html.scan(/<img\b[^>]*>/i) do |img_tag|
        alt = img_tag[/\balt="([^"]*)"/i, 1]
        if alt&.match?(img_pattern)
          src = img_tag[/\bsrc="([^"]+)"/i, 1]
          if src && !src.empty?
            profile[:avatar_url] = src.gsub('&amp;', '&')
            break
          end
        end
      end

      # Strategie 2: og:image
      if profile[:avatar_url].nil?
        og = html[/<meta\b[^>]*property="og:image"[^>]*content="([^"]+)"/i, 1] ||
             html[/<meta\b[^>]*content="([^"]+)"[^>]*property="og:image"/i, 1]
        profile[:avatar_url] = og.gsub('&amp;', '&') if og
      end

      # Strategie 3: JSON profile_pic_url_hd / profile_pic_url
      if profile[:avatar_url].nil?
        if html =~ /"profile_pic_url_hd"\s*:\s*"([^"]+)"/
          profile[:avatar_url] = $1.gsub('\\/', '/')
        elsif html =~ /"profile_pic_url"\s*:\s*"([^"]+)"/
          profile[:avatar_url] = $1.gsub('\\/', '/')
        end
      end

      profile
    end

    # Dekóduje JSON string z Meta Graph API:
    # - \n → newline
    # - \" → "
    # - \/ → /
    # - \uXXXX → unicode znak (včetně surrogate pairs pro emoji)
    def decode_meta_json_string(str)
      str
        .gsub('\\n', "\n")
        .gsub('\\"', '"')
        .gsub('\\/', '/')
        .gsub('\\\\', '\\')
        .gsub(/\\u([Dd][89AaBb][0-9a-fA-F]{2})\\u([Dd][CcDdEeFf][0-9a-fA-F]{2})|\\u([0-9a-fA-F]{4})/) do
          if $3
            [$3.to_i(16)].pack('U')
          else
            high = $1.to_i(16)
            low  = $2.to_i(16)
            [0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00)].pack('U')
          end
        end
    end
  end
end
