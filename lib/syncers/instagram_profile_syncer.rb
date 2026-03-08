# frozen_string_literal: true

# Instagram Profile Syncer - Synchronizes profile info from Instagram to Mastodon
#
# Uses Browserless.io API to render Instagram pages with JavaScript.
#
# Syncs:
# - description/bio
# - avatar image (profile photo)
# - website URL (pokud je nastavena na IG profilu)
# - All 4 metadata fields (ig:, web:, spravuje:, retence:)
#
# Does NOT sync:
# - banner/header (Instagram nemá cover foto)
# - display_name (contains :bot: badge), handle (set at creation)
#
# Usage:
#   syncer = Syncers::InstagramProfileSyncer.new(
#     instagram_handle: 'formulovy_svet',
#     mastodon_instance: 'https://zpravobot.news',
#     mastodon_token: 'xxx',
#     browserless_token: 'xxx',
#     instagram_cookies: [
#       { name: 'sessionid', value: 'xxx', domain: '.instagram.com' },
#       { name: 'csrftoken', value: 'xxx', domain: '.instagram.com' }
#     ],
#     language: 'cs',
#     retention_days: 90,
#     mentions_config: { 'type' => 'domain_suffix', 'value' => 'instagram.com' }
#   )
#   syncer.sync!

require_relative 'base_profile_syncer'

module Syncers
  class InstagramProfileSyncer < BaseProfileSyncer
    BROWSERLESS_API = 'https://chrome.browserless.io/content'
    DEFAULT_MENTIONS_CONFIG = { 'type' => 'domain_suffix', 'value' => 'instagram.com' }.freeze
    DEFAULT_INSTAGRAM_COOKIES = [].freeze

    attr_reader :instagram_handle, :browserless_token, :instagram_cookies

    def initialize(instagram_handle:, browserless_token:, instagram_cookies:, browserless_api: nil, **base_opts)
      @instagram_handle = instagram_handle.gsub(%r{^https?://[^/]+/}, '').gsub(/^@/, '')
      @browserless_token = browserless_token
      @instagram_cookies = instagram_cookies || DEFAULT_INSTAGRAM_COOKIES
      @browserless_api = (browserless_api || BROWSERLESS_API).chomp('/')
      super(**base_opts)
    end

    # ============================================
    # Template method implementations
    # ============================================

    def source_handle
      instagram_handle
    end

    def platform_name
      'Instagram'
    end

    def platform_key
      'instagram'
    end

    def field_prefix
      'ig:'
    end

    def default_mentions_config
      DEFAULT_MENTIONS_CONFIG
    end

    # Instagram nemá banner — přeskočí se automaticky (fetch vrací nil)
    def banner_key
      :banner_url
    end

    # Instagram validuje content-type obrázků
    def validate_image_content_type?
      true
    end

    # Instagram přebírá website z profilu pokud je k dispozici
    def build_fields(handle, current_fields, extra_data = {})
      labels = FIELD_LABELS[language]
      instagram_website = extra_data[:website]
      source_platforms = extra_data[:source_platforms]

      web_value = if instagram_website && !instagram_website.empty?
                    instagram_website.chomp('/')
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
      url = "https://www.instagram.com/#{instagram_handle}/"
      log "  Fetching #{url} via Browserless..."

      html = fetch_page_via_browserless(url)
      parse_instagram_profile(html)
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

    # Instagram CDN (fbcdn.net) vyžaduje session cookies + browser-like headers
    # aby vrátil skutečnou profilovku místo default placeholderu.
    # Server-side request může posílat cookies na libovolnou doménu.
    def image_download_options
      cookie_header = instagram_cookies.map { |c| "#{c[:name]}=#{c[:value]}" }.join('; ')
      {
        headers: {
          'Referer'  => 'https://www.instagram.com/',
          'Accept'   => 'image/jpeg,image/png,image/webp,image/*;q=0.8,*/*;q=0.5',
          'Cookie'   => cookie_header
        },
        user_agent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36'
      }
    end

    # Instagram nepoužívá @ prefix pro handle
    def format_source_handle
      instagram_handle
    end

    def log_preview_details(profile)
      log 'Profile data:'
      log "  Description: #{profile[:description]&.slice(0, 60)}..."
      log "  Avatar: #{profile[:avatar_url] ? '✅ present' : '❌ none'}"
      log "  Website: #{profile[:website] || 'none'}"
      log "  Profile URL: #{build_profile_url(instagram_handle)}"
    end

    def build_profile_url_fallback(handle)
      "https://instagram.com/#{handle}"
    end

    # ============================================
    # Instagram Scraping via Browserless
    # ============================================

    def fetch_page_via_browserless(url)
      uri = URI("#{@browserless_api}?token=#{browserless_token}")

      body = {
        url: url,
        cookies: instagram_cookies,
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

      response.body.dup.force_encoding('UTF-8')
    end

    def parse_instagram_profile(html)
      profile = {
        handle: instagram_handle,
        description: nil,
        avatar_url: nil,
        banner_url: nil,  # Instagram nemá banner
        website: nil
      }

      # Bio z embedded JSON dat (přihlášený pohled)
      # Toleruje mezery kolem dvojtečky: "biography":"..." i "biography": "..."
      # Zkouší i escaped variantu (\u0022biography\u0022)
      bio_raw = nil
      if html =~ /"biography"\s*:\s*"((?:[^"\\]|\\.)*)"/
        bio_raw = $1
      elsif html =~ /\\u0022biography\\u0022\s*:\s*\\u0022((?:[^\\]|\\.)*)\\u0022/
        bio_raw = $1.gsub('\\u000a', "\n")
      end
      if bio_raw
        bio = bio_raw.gsub('\\n', "\n").gsub('\\"', '"').gsub('\\/', '/').gsub('\\\\', '\\')
        profile[:description] = bio unless bio.strip.empty?
      end

      # Profilová fotka — strategie extrakce (pořadí od nejspolehlivější):
      #
      # 1. <img> tag s alt="[handle]'s profile picture" — renderovaný Browserless+cookies,
      #    vždy ukazuje na skutečnou profilovku (nikdy na Stories ani placeholder).
      #
      # 2. og:image — obvykle správná profilovka, ale Instagram někdy vrátí šedý placeholder
      #    (has_profile_pic:false) nebo redirect na CDN s placeholderem.
      #
      # 3. JSON profile_pic_url_hd / profile_pic_url — t51.2885-19 formát,
      #    může být placeholder (573323465) pokud has_profile_pic:false.
      #
      # 4. t51.82787-15 z header sekce (poslední záchrana — může zachytit Stories)

      # Strategie 1: <img alt="[handle]'s profile picture"> — nejspolehlivější
      # Hledáme img tag kde alt atribut přesně matchuje vzor "[handle]'s profile picture"
      img_profile_pattern = /#{Regexp.escape(instagram_handle)}'s profile picture/i
      html.scan(/<img\b[^>]*>/i) do |img_tag|
        alt = img_tag[/\balt="([^"]*)"/i, 1]
        if alt && alt.match?(img_profile_pattern)
          src = img_tag[/\bsrc="([^"]+)"/i, 1]
          if src && !src.empty?
            profile[:avatar_url] = HtmlCleaner.decode_html_entities(src)
            break
          end
        end
      end

      # Strategie 2: og:image
      if profile[:avatar_url].nil?
        og_url = html[/<meta\b[^>]*\bproperty="og:image"\b[^>]*\bcontent="([^"]+)"/i, 1] ||
                 html[/<meta\b[^>]*\bcontent="([^"]+)"[^>]*\bproperty="og:image"/i, 1]
        profile[:avatar_url] = HtmlCleaner.decode_html_entities(og_url) if og_url
      end

      # Strategie 3: JSON profile_pic_url_hd / profile_pic_url
      if profile[:avatar_url].nil?
        if html =~ /"profile_pic_url_hd":"([^"]+)"/
          profile[:avatar_url] = decode_instagram_url($1)
        elsif html =~ /"profile_pic_url":"([^"]+)"/
          profile[:avatar_url] = decode_instagram_url($1)
        end
      end

      # Strategie 4: t51.82787-15 z header sekce (poslední záchrana — může zachytit Stories)
      if profile[:avatar_url].nil?
        header_html = html[/<header\b[^>]*>.*?<\/header>/im] || ''
        if header_html =~ %r{(https?:(?:\\?/){2}[^"'\s<>]+/v/t51\.82787-15/[^"'\s<>]+)}i
          profile[:avatar_url] = HtmlCleaner.decode_html_entities($1.gsub('\\/', '/'))
        end
      end

      # Website z external_url v JSON
      if html =~ /"external_url":"([^"]+)"/
        website = decode_instagram_url($1)
        profile[:website] = website unless website.empty?
      end

      # Fallback bio z meta description tagů
      # Instagram používá <meta name="description"> (bez property=og:) kde je bio
      # Formát: "... (@handle) on Instagram: "Bio text"" (ASCII uvozovky přes &quot;)
      # Instagram renderuje jako <meta content="..." name="description" /> (content před name)
      # Fallback: <meta property="og:description"> — jen statistiky, bio obvykle není
      if profile[:description].nil?
        raw = nil
        raw ||= html[/<meta\b[^>]*\bname="description"[^>]*\bcontent="([^"]+)"/i, 1]
        raw ||= html[/<meta\b[^>]*\bcontent="([^"]+)"[^>]*\bname="description"/i, 1]
        raw ||= html[/<meta\b[^>]*\bproperty="og:description"[^>]*\bcontent="([^"]+)"/i, 1]
        raw ||= html[/<meta\b[^>]*\bcontent="([^"]+)"[^>]*\bproperty="og:description"/i, 1]
        meta_desc = raw ? HtmlCleaner.decode_html_entities(raw) : nil

        if meta_desc
          # Bio je za (@handle)[lokalizovaný text]: "bio" nebo „bio"
          # &quot; se dekóduje na ASCII " (U+0022), typografické uvozovky jako fallback
          if meta_desc =~ /\(@[^)]+\)[^:]*:\s*[\u201e\u201c"](.*?)[\u201c\u201d"]?\s*\z/im
            bio = $1.strip
            profile[:description] = bio unless bio.empty?
          end
        end
      end

      profile
    end

    def decode_instagram_url(url)
      return nil if url.nil? || url.empty?

      url
        .gsub('\\/', '/')
        .gsub(/\\u([0-9a-fA-F]{4})/) { [$1.to_i(16)].pack('U') }
        .gsub('&amp;', '&')
    end
  end
end
