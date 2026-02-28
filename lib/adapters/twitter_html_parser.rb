# frozen_string_literal: true

require_relative '../models/post'
require_relative '../models/author'
require_relative '../models/media'
require_relative '../utils/html_cleaner'

module Adapters
  # HTML page parsing logic extracted from TwitterAdapter
  #
  # Handles:
  # - Nitter HTML page parsing (single tweet view)
  # - Main tweet section extraction (position-based)
  # - Text extraction from HTML tweet-content divs
  # - Media extraction from HTML (images, videos, thumbnails)
  # - Timestamp extraction from HTML
  # - Quote tweet extraction from HTML
  #
  # Depends on:
  # - TwitterTweetClassifier (for type detection)
  # - TwitterRssParser#decode_html_entities, #clean_text
  # - @handle, @nitter_instance, @url_domain (from TwitterAdapter)
  #
  module TwitterHtmlParser
    # Parse main tweet from Nitter HTML page
    # @param html [String] Full HTML page
    # @param post_id [String] Expected post ID
    # @param target_user [String] Username for the tweet
    # @return [Post, nil] Post object or nil if parsing failed
    def parse_main_tweet_from_html(html, post_id, target_user)
      tweet_html = extract_main_tweet_section(html)
      return nil unless tweet_html

      text = extract_text_from_html(tweet_html)

      if text.empty?
        if tweet_html.include?('tweet-content')
          log "tweet-content div found in main-tweet section but text extraction returned empty for #{post_id} — possible parsing issue", level: :warn
        else
          log "Nitter HTML structure found but tweet content is empty for #{post_id} (tweet likely deleted between IFTTT trigger and Nitter fetch)", level: :warn
        end
      end

      published_at = extract_timestamp_from_html(html)
      media = extract_media_from_html(tweet_html)

      title_match = html.match(/<title>([^<]+)<\/title>/i)
      title = title_match ? title_match[1] : ''

      is_repost = detect_repost(title)
      is_quote = detect_quote_from_html(html)
      reply_info = detect_reply_with_thread(title)

      quoted_post = is_quote ? extract_quoted_post_from_html(html) : nil

      url = "https://twitter.com/#{target_user}/status/#{post_id}"

      author_username = target_user
      reposted_by = nil

      if is_repost
        reposted_by = handle
        author_match = tweet_html.match(/<a[^>]*class="[^"]*username[^"]*"[^>]*>@?(\w+)<\/a>/i)
        author_username = author_match[1] if author_match
      end

      author = Author.new(
        username: author_username,
        full_name: author_username,
        url: "https://twitter.com/#{author_username}"
      )

      text = clean_text(text, is_repost, reply_info[:is_thread_post], is_quote)

      Post.new(
        id: post_id,
        platform: 'twitter',
        text: text,
        url: url,
        author: author,
        published_at: published_at,
        media: media,
        is_repost: is_repost,
        is_quote: is_quote,
        is_reply: reply_info[:is_reply],
        reposted_by: reposted_by,
        quoted_post: quoted_post,
        raw: { source: 'nitter_html', post_id: post_id },
        is_thread_post: reply_info[:is_thread_post],
        reply_to_handle: reply_info[:reply_to_handle],
        has_video: detect_video_from_html(html)
      )
    end

    # Extract the main-tweet section from full HTML using position-based slicing
    # @param html [String] Full Nitter HTML page
    # @return [String, nil] HTML fragment containing the main tweet, or nil
    def extract_main_tweet_section(html)
      start_match = html.match(/<div[^>]*id="m"[^>]*class="[^"]*main-tweet[^"]*"[^>]*>/i)
      start_match ||= html.match(/<div[^>]*class="[^"]*main-tweet[^"]*"[^>]*>/i)

      unless start_match
        start_match = html.match(/<div[^>]*class="[^"]*tweet-body[^"]*"[^>]*>/i)
      end

      return nil unless start_match

      start_pos = start_match.begin(0)

      end_patterns = [
        /<div[^>]*class="[^"]*after-tweet[^"]*"[^>]*>/i,
        /<div[^>]*class="[^"]*replies[^"]*"[^>]*>/i,
        /<div[^>]*class="[^"]*reply-box[^"]*"[^>]*>/i,
        /<\/div>\s*<!--\s*main-thread\s*-->/i
      ]

      end_pos = nil
      remaining = html[start_pos..]

      end_patterns.each do |pattern|
        m = remaining.match(pattern)
        if m
          pos = start_pos + m.begin(0)
          end_pos = pos if end_pos.nil? || pos < end_pos
        end
      end

      end_pos ||= [start_pos + 10_000, html.length].min

      html[start_pos...end_pos]
    end

    # Extract text from tweet HTML
    def extract_text_from_html(html)
      content_match = html.match(/<div[^>]*class="[^"]*tweet-content[^"]*"[^>]*>(.*?)<\/div>/mi)
      return '' unless content_match

      text = content_match[1]

      # Replace video placeholder
      text = text.gsub(/<a[^>]+href="[^"]*\/[\w]+\/status\/\d+[^"]*"[^>]*>\s*<br\s*\/?>\s*Video\s*<br\s*\/?>\s*<img[^>]+>\s*<\/a>/im, '')

      # Remove img tags
      text = text.gsub(/<img[^>]*>/i, '')

      # Extract @mentions from links
      text = text.gsub(/<a[^>]*>(@\w+)<\/a>/i, '\1')

      # Remove media link tags
      text = text.gsub(/<a[^>]+href="[^"]*\/status\/\d+\/(?:photo|video)\/\d+"[^>]*>[^<]*<\/a>/i, '')

      # Remove quote marker link tags
      text = text.gsub(/<a[^>]+href="[^"]*\/status\/\d+#m"[^>]*>[^<]*<\/a>/i, '')

      # Replace truncated URLs with full href
      text = text.gsub(/<a[^>]+href="([^"]+)"[^>]*>[^<]*…<\/a>/i, '\1')

      # Remove remaining a tags, keep text
      text = text.gsub(/<a[^>]*>([^<]*)<\/a>/i, '\1')

      # Convert br/p to newlines
      text = text.gsub(/<br\s*\/?>/, "\n")
      text = text.gsub(/<\/p>\s*<p[^>]*>/, "\n")
      text = text.gsub(/<p[^>]*>/, '')
      text = text.gsub(/<\/p>/, '')

      # Remove remaining HTML
      text = text.gsub(/<[^>]+>/, ' ')

      # Decode entities
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

    # Extract timestamp from tweet HTML
    def extract_timestamp_from_html(html)
      time_match = html.match(/<span[^>]*class="[^"]*tweet-date[^"]*"[^>]*>.*?<a[^>]*title="([^"]+)"/mi)
      time_match ||= html.match(/<span[^>]*class="[^"]*tweet-published[^"]*"[^>]*>([^<]+)/mi)

      return nil unless time_match

      date_str = time_match[1].gsub('·', '').gsub('UTC', '').strip
      Time.parse(date_str + ' UTC')
    rescue ArgumentError, TypeError => e
      log "Failed to parse timestamp: #{e.message}", level: :error
      nil
    end

    # Extract media from tweet HTML (full page)
    def extract_media_from_html(html)
      media = []

      # Images from still-image/gallery-image links
      html.scan(/<a[^>]*class="[^"]*(?:still-image|gallery-image)[^"]*"[^>]*href="([^"]+)"/i) do |match|
        url = fix_media_url(match[0])
        next if url.include?('emoji')

        media << Media.new(
          type: 'image',
          url: url,
          alt_text: ''
        )
      end

      # Fallback: img src
      if media.empty?
        html.scan(/<img[^>]+src="([^"]+)"[^>]*>/i) do |match|
          url = fix_media_url(match[0])
          next if url.include?('emoji') || url.include?('profile') || url.include?('logo')

          is_video_thumb = url.include?('video_thumb') || url.include?('ext_tw_video')
          media << Media.new(
            type: is_video_thumb ? 'video_thumbnail' : 'image',
            url: url,
            alt_text: is_video_thumb ? '🎬 Video' : ''
          )
        end
      end

      # Video sources
      html.scan(/<source[^>]+src="([^"]+)"[^>]*>/i) do |match|
        media << Media.new(
          type: 'video',
          url: fix_media_url(match[0]),
          alt_text: ''
        )
      end

      # Video poster
      html.scan(/<video[^>]+poster="([^"]+)"[^>]*>/i) do |match|
        media << Media.new(
          type: 'video_thumbnail',
          url: fix_media_url(match[0]),
          alt_text: '🎬 Video'
        )
      end

      media.uniq! { |m| m.url }

      # Filter converted GIF artifacts
      images = media.select { |m| m.type == 'image' }
      videos = media.select { |m| m.type == 'video' }
      if images.size >= 4 && videos.any?
        log "Filtering #{videos.size} video(s) alongside #{images.size} images (likely converted GIF artifact)"
        media.reject! { |m| m.type == 'video' }
      end

      media
    end

    # Detect quote tweet from HTML
    def detect_quote_from_html(html)
      html.include?('class="quote') ||
        html.include?("class='quote") ||
        html.include?('quote-link') ||
        html.match?(/class="[^"]*\bquote\b/)
    end

    # Extract quoted post info from HTML
    def extract_quoted_post_from_html(html)
      return nil unless html

      quote_link_match = html.match(/<a[^>]*class="[^"]*quote-link[^"]*"[^>]*href="([^"]+)"[^>]*>/i)
      return nil unless quote_link_match

      quote_path = quote_link_match[1]
      path_match = quote_path.match(%r{/(\w+)/status/(\d+)})
      return nil unless path_match

      username = path_match[1]
      status_id = path_match[2]

      quoted_url = "#{@url_domain}/#{username}/status/#{status_id}"

      quote_text = nil
      quote_div_match = html.match(/<div[^>]*class="[^"]*quote(?:-body)?[^"]*"[^>]*>(.*?)<\/div>/mi)
      if quote_div_match
        quote_text = quote_div_match[1]
        quote_text = quote_text.gsub(/<[^>]+>/, ' ').gsub(/\s+/, ' ').strip
        quote_text = decode_html_entities(quote_text) if quote_text
      end

      {
        username: username,
        author: username,
        url: quoted_url,
        text: quote_text,
        status_id: status_id
      }
    end

    # Detect video from HTML
    def detect_video_from_html(html)
      html.include?('>Video<') || html.include?('video_thumb') || html.include?('<video') || html.include?('video-container')
    end
  end
end
