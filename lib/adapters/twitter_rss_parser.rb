# frozen_string_literal: true

require_relative '../models/post'
require_relative '../models/author'
require_relative '../models/media'
require_relative '../utils/html_cleaner'

module Adapters
  # RSS feed parsing logic extracted from TwitterAdapter
  #
  # Handles:
  # - RSS XML parsing (REXML)
  # - RSS item → Post conversion
  # - Text extraction from RSS HTML descriptions
  # - Media extraction from RSS HTML
  # - Author extraction from RSS items
  # - Quote tweet extraction from RSS inline format
  #
  # Depends on:
  # - TwitterTweetClassifier (for type detection)
  # - @handle, @nitter_instance, @url_domain (from TwitterAdapter)
  #
  module TwitterRssParser
    # Regex to match inline quote tweet marker: "— URL#m" at end of text
    QUOTE_MARKER_REGEX = /\n\n?— (https?:\/\/[^\s]+\/\w+\/status\/\d+)#m\s*$/i.freeze

    # Regex to match the full inline quote block
    INLINE_QUOTE_REGEX = /\n\n(.+?) \((https?:\/\/[^\s\)]+\/(\w+))\)\n\n([\s\S]+?)\n\n?— (https?:\/\/[^\s]+\/status\/\d+)#m\s*$/i.freeze

    # ============================================
    # RSS Parsing
    # ============================================

    def parse_rss(xml)
      require 'rexml/document'

      doc = REXML::Document.new(xml)
      items = []

      doc.elements.each('//item') do |item|
        items << {
          title: item.elements['title']&.text,
          description: item.elements['description']&.text,
          link: item.elements['link']&.text,
          pub_date: item.elements['pubDate']&.text,
          guid: item.elements['guid']&.text,
          dc_creator: item.elements['dc:creator']&.text
        }
      end

      items
    rescue StandardError => e
      log "Parse error: #{e.message}", level: :error
      []
    end

    def convert_to_post(item)
      text = extract_text(item[:description])
      title = item[:title] || ''

      is_repost = detect_repost(title)
      is_quote = detect_quote(item)

      reply_info = detect_reply_with_thread(title)
      is_reply = reply_info[:is_reply]
      is_thread_post = reply_info[:is_thread_post]
      reply_to_handle = reply_info[:reply_to_handle]

      author = extract_author(item, text, is_repost)
      media = extract_media(item[:description])

      reposted_by = extract_reposted_by(text) if is_repost
      quoted_post = extract_quoted_post(item) if is_quote

      text = clean_text(text, is_repost, is_thread_post, is_quote)
      url = item[:link]
      published_at = parse_date(item[:pub_date])

      Post.new(
        id: item[:guid] || item[:link],
        platform: 'twitter',
        text: text,
        url: url,
        author: author,
        published_at: published_at,
        media: media,
        is_repost: is_repost,
        is_quote: is_quote,
        is_reply: is_reply,
        reposted_by: reposted_by,
        quoted_post: quoted_post,
        raw: item,
        is_thread_post: is_thread_post,
        reply_to_handle: reply_to_handle,
        has_video: detect_video(item[:description])
      )
    rescue StandardError => e
      log "Convert error: #{e.message}", level: :error
      nil
    end

    # ============================================
    # Text Extraction & Cleaning (for RSS)
    # ============================================

    def extract_text(html)
      return '' unless html

      text = html.dup

      # Remove video placeholder entirely
      text = text.gsub(/<a[^>]+href="[^"]*\/[\w]+\/status\/\d+[^"]*"[^>]*>\s*<br\s*\/?>\s*Video\s*<br\s*\/?>\s*<img[^>]+>\s*<\/a>/im, '')

      # Remove <img> tags entirely
      text = text.gsub(/<img[^>]*>/i, '')

      # Extract @mentions from links
      text = text.gsub(/<a[^>]*>(@\w+)<\/a>/i, '\1')

      # Remove media link tags entirely (photo/video URLs)
      text = text.gsub(/<a[^>]+href="[^"]*\/status\/\d+\/(?:photo|video)\/\d+"[^>]*>[^<]*<\/a>/i, '')

      # Remove quote marker link tags (#m suffix)
      text = text.gsub(/<a[^>]+href="[^"]*\/status\/\d+#m"[^>]*>[^<]*<\/a>/i, '')

      # Replace truncated URLs with full href
      text = text.gsub(/<a[^>]+href="([^"]+)"[^>]*>[^<]*…<\/a>/i, '\1')

      # Remove remaining <a> tags but keep text
      text = text.gsub(/<a[^>]*>([^<]*)<\/a>/i, '\1')

      # Convert br/p to newlines
      text = text.gsub(/<br\s*\/?>/, "\n")
      text = text.gsub(/<\/p>\s*<p[^>]*>/, "\n")
      text = text.gsub(/<p[^>]*>/, '')
      text = text.gsub(/<\/p>/, "")

      # Remove remaining HTML tags
      text = text.gsub(/<[^>]+>/, ' ')

      # Decode HTML entities
      text = decode_html_entities(text)

      # Remove media URLs
      text = text.gsub(%r{\s*https?://[^\s]+/status/\d+/(?:photo|video)/\d+\s*}, ' ')

      # Remove quote marker URLs
      text = text.gsub(%r{\s*https?://[^\s]+/status/\d+#m\s*}, ' ')

      # Normalize whitespace
      text = text.gsub(/[ \t]+/, ' ')
      text = text.gsub(/\n[ \t]+/, "\n")
      text = text.gsub(/[ \t]+\n/, "\n")
      text = text.gsub(/\n{3,}/, "\n\n")

      text.strip
    end

    def decode_html_entities(text)
      HtmlCleaner.decode_html_entities(text)
    end

    def clean_text(text, is_repost, is_thread_post = false, is_quote = false)
      if is_repost
        text = text.sub(/^RT @\w+:\s*/i, '')
        text = text.sub(/^RT by @\w+:\s*/i, '')
      end

      text = text.sub(/^R to @\w+:\s*/i, '')

      text.strip
    end

    # ============================================
    # Author Extraction
    # ============================================

    def extract_author(item, text, is_repost)
      if is_repost
        title = item[:title] || ''
        match = title.match(/^RT by @(\w+):/i)
        if match
          creator = item[:dc_creator] || item[:creator]
          username = creator ? creator.gsub(/^@/, '') : handle
        else
          username = handle
        end
      else
        username = handle
      end

      Author.new(
        username: username,
        full_name: username,
        url: "https://twitter.com/#{username}"
      )
    end

    def extract_reposted_by(text)
      handle
    end

    # ============================================
    # Media Extraction (RSS)
    # ============================================

    def extract_media(html)
      return [] unless html

      media = []

      # Extract images from img tags
      html.scan(/<img[^>]+src="([^"]+)"[^>]*>/) do |match|
        url = fix_media_url(match[0])
        next if url.include?('emoji')

        is_video_thumb = url.include?('video_thumb') || url.include?('ext_tw_video')

        media << Media.new(
          type: is_video_thumb ? 'video_thumbnail' : 'image',
          url: url,
          alt_text: is_video_thumb ? '🎬 Video' : ''
        )
      end

      # Extract videos
      html.scan(/<video[^>]+src="([^"]+)"[^>]*>/) do |match|
        media << Media.new(
          type: 'video',
          url: fix_media_url(match[0]),
          alt_text: ''
        )
      end

      # Extract video poster
      html.scan(/<video[^>]+poster="([^"]+)"[^>]*>/) do |match|
        media << Media.new(
          type: 'video_thumbnail',
          url: fix_media_url(match[0]),
          alt_text: '🎬 Video'
        )
      end

      # Extract video source
      html.scan(/<source[^>]+src="([^"]+)"[^>]*>/) do |match|
        media << Media.new(
          type: 'video',
          url: fix_media_url(match[0]),
          alt_text: ''
        )
      end

      # Extract external links as link_cards
      html.scan(/<a[^>]+href="(https?:\/\/[^"]+)"[^>]*>([^<]*)<\/a>/) do |match|
        url = match[0]
        link_text = match[1]

        next if url.include?('twitter.com') || url.include?('nitter') || url.include?('xn.zpravobot')
        next if link_text&.include?('…')
        next if link_text&.start_with?('@')

        media << Media.new(
          type: 'link_card',
          url: url,
          alt_text: ''
        )
      end

      media.uniq { |m| m.url }
    end

    # ============================================
    # Quote Extraction
    # ============================================

    def extract_quoted_post(item)
      description = item[:description] || ''
      text = extract_text(description)

      match = text.match(INLINE_QUOTE_REGEX)
      return nil unless match

      author_name = match[1].strip
      profile_url = match[2]
      username = match[3]
      quoted_text = match[4].strip
      status_url = match[5]

      {
        author: author_name,
        username: username,
        text: quoted_text,
        url: status_url,
        profile_url: profile_url
      }
    end

    def strip_inline_quote(text)
      return text unless text
      text.sub(INLINE_QUOTE_REGEX, '').strip
    end

    # ============================================
    # Date Parsing
    # ============================================

    def parse_date(date_str)
      return nil unless date_str
      Time.parse(date_str)
    rescue ArgumentError
      nil
    end
  end
end
