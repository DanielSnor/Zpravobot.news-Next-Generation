
# frozen_string_literal: true

# RSS Adapter for Zpravobot Next Generation
# Fetches and parses RSS/Atom feeds
#
# Features:
# - Supports both RSS 2.0 and Atom feeds
# - HTML content cleaning
# - Media/enclosure extraction
# - max_input_chars pre-truncation for long HTML content

require 'rss'
require 'net/http'
require 'uri'
require_relative 'base_adapter'
require_relative '../utils/html_cleaner'
require_relative '../utils/http_client'

module Adapters
  class RssAdapter < BaseAdapter
    USER_AGENT = 'Zpravobot/1.0 (+https://zpravobot.news)'
    MAX_REDIRECTS = 5
    REDIRECT_CODES = %w[301 302 307 308].freeze

    def platform
      'rss'
    end

    def validate_config!
      raise ArgumentError, "RSS feed_url required" unless config[:feed_url]
      
      # Optional: source_name for identifying the feed
      @source_name = config[:source_name]
      
      # Optional: max_input_chars for pre-truncation (before HTML cleaning)
      # This helps when RSS feeds contain very long HTML with lots of boilerplate
      # before the actual content
      @max_input_chars = config[:max_input_chars] || config.dig(:content, :max_input_chars)
    end

    def fetch_posts(since: nil)
      log "Fetching RSS feed: #{config[:feed_url]}"
      
      feed = parse_feed(config[:feed_url])
      
      # Get entries - handle both RSS 2.0 (channel.item) and Atom (entries)
      entries = get_feed_entries(feed)
      log "Found #{entries.count} total entries"
      
      # Filter by date if specified
      if since
        entries = entries.select { |e| entry_time(e) > since }
        log "Filtered to #{entries.count} entries since #{since}"
      end
      
      # Convert to Post objects
      posts = entries.map { |entry| entry_to_post(feed, entry) }
      
      log "Successfully converted #{posts.count} posts", level: :success
      posts
    end

    private
    
    # Get entries from either RSS 2.0 or Atom feed
    def get_feed_entries(feed)
      if feed.respond_to?(:entries)
        # Atom feed
        Array(feed.entries)
      elsif feed.respond_to?(:channel) && feed.channel.respond_to?(:items)
        # RSS 2.0 feed
        Array(feed.channel.items)
      elsif feed.respond_to?(:items)
        # Some RSS formats
        Array(feed.items)
      else
        log "Unknown feed format: #{feed.class}", level: :warn
        []
      end
    end

    # Fetch URL with automatic redirect following and logging
    # @param url [String] URL to fetch
    # @yield [StringIO] Response body as StringIO
    # @return [Object] Result from block
    def fetch_url(url)
      current_url = url
      visited = []

      MAX_REDIRECTS.times do |i|
        if visited.include?(current_url)
          log "Redirect loop detected: #{current_url}", level: :error
          raise "Redirect loop detected for #{current_url}"
        end
        visited << current_url

        response = HttpClient.get(current_url,
          headers: { 'Accept' => 'application/rss+xml, application/xml, text/xml, */*' })

        if REDIRECT_CODES.include?(response.code)
          location = response['location']
          unless location
            raise "Redirect #{response.code} without Location header for #{current_url}"
          end

          # Handle relative redirects
          location = URI.join(current_url, location).to_s unless location.start_with?('http')

          log "Redirect #{response.code}: #{current_url} → #{location}", level: :warn
          current_url = location
          next
        end

        unless response.code.to_i == 200
          raise "HTTP #{response.code}: #{response.message}"
        end

        # Log final URL if we followed redirects
        if visited.size > 1
          log "Followed to final URL: #{current_url}", level: :success
        end

        return yield StringIO.new(response.body.force_encoding('UTF-8'))
      end

      log "Too many redirects (#{MAX_REDIRECTS}) for #{url}", level: :error
      raise "Too many redirects (#{MAX_REDIRECTS}) for #{url}"
    rescue StandardError => e
      log "Fetch error for #{url}: #{e.message}", level: :error
      raise
    end

    def parse_feed(url)
      fetch_url(url) do |response|
        content = response.read
        content = sanitize_xml(content)

        # Parse with RSS library (supports both RSS and Atom)
        RSS::Parser.parse(content, false) # false = don't validate
      end
    rescue RSS::Error => e
      log "RSS parsing error: #{e.message}", level: :error
      raise
    end

    # Strip trailing garbage after the closing root element tag.
    # Some servers inject <script>, tracking pixels, etc. after the
    # XML document ends, which breaks RSS::Parser.
    # Covers RSS 2.0 (</rss>), Atom (</feed>), and RSS 1.0 (</rdf:RDF>).
    def sanitize_xml(xml)
      xml = xml.sub(%r{(</rss>).*}mi, '\1')
      xml = xml.sub(%r{(</feed>).*}mi, '\1')
      xml = xml.sub(%r{(</rdf:RDF>).*}mi, '\1')
      xml
    end

    def entry_to_post(feed, entry)
      Post.new(
        platform: platform,
        id: entry_id(entry),
        url: entry_link(entry),
        title: entry_title(entry),
        text: entry_text(entry),
        published_at: entry_time(entry),
        author: entry_author(feed, entry),
        media: entry_media(entry),
        
        # RSS doesn't have social features
        is_repost: false,
        is_quote: false,
        is_reply: false,
        
        # Store raw entry for debugging
        raw: {
          entry_class: entry.class.name,
          categories: entry_categories(entry),
          feed_title: feed_title(feed)
        }
      )
    end

    # Extract entry ID (prefer GUID, fallback to link)
    def entry_id(entry)
      if entry.respond_to?(:id) && entry.id
        entry.id.content || entry.id
      elsif entry.respond_to?(:guid) && entry.guid
        entry.guid.content || entry.guid
      else
        entry_link(entry)
      end
    end

    # Extract entry link/URL
    def entry_link(entry)
      if entry.respond_to?(:link) && entry.link
        entry.link.respond_to?(:href) ? entry.link.href : entry.link
      else
        nil
      end
    end

    # Extract entry title
    def entry_title(entry)
      return nil unless entry.respond_to?(:title)
      
      title = entry.title
      title.respond_to?(:content) ? title.content : title.to_s
    end

    # Extract and clean entry text/content
    # Applies max_input_chars pre-truncation BEFORE HTML cleaning
    # This is important because some feeds have very long HTML with
    # navigation/sidebar before actual content
    def entry_text(entry)
      # Try different content fields in order of preference
      content = if entry.respond_to?(:content) && entry.content
                  entry.content.respond_to?(:content) ? entry.content.content : entry.content
                elsif entry.respond_to?(:summary) && entry.summary
                  entry.summary.respond_to?(:content) ? entry.summary.content : entry.summary
                elsif entry.respond_to?(:description)
                  entry.description
                else
                  ""
                end

      raw_content = content.to_s
      
      # Pre-truncation: if max_input_chars is set and content is very long,
      # truncate BEFORE HTML cleaning to avoid processing huge amounts of
      # boilerplate HTML and potentially missing the actual content
      if @max_input_chars && @max_input_chars > 0 && raw_content.length > @max_input_chars
        log "Pre-truncating content from #{raw_content.length} to #{@max_input_chars} chars", level: :debug
        raw_content = pre_truncate_html(raw_content, @max_input_chars)
      end

      clean_html(raw_content)
    end

    # Pre-truncate HTML content intelligently
    # Tries to cut at tag boundary to avoid broken HTML
    # @param html [String] Raw HTML content
    # @param max_chars [Integer] Maximum characters
    # @return [String] Truncated HTML
    def pre_truncate_html(html, max_chars)
      return html if html.length <= max_chars
      
      truncated = html[0...max_chars]
      
      # Try to find last CLOSING tag (</tagname>) for clean cut
      # This ensures we don't cut in the middle of content
      last_closing_tag = truncated.rindex(%r{</[a-zA-Z][a-zA-Z0-9]*>})
      
      if last_closing_tag
        # Find the end of this closing tag
        tag_end = truncated.index('>', last_closing_tag)
        if tag_end
          return truncated[0..tag_end]
        end
      end
      
      # Fallback: try to cut before any open tag to avoid partial tags
      last_open_tag = truncated.rindex('<')
      if last_open_tag && last_open_tag > 0
        # Check if we're inside a tag (no > after <)
        last_close = truncated.rindex('>')
        if last_close.nil? || last_close < last_open_tag
          # We're inside a tag, cut before it
          return truncated[0...last_open_tag]
        end
      end
      
      truncated
    end

    # Extract published/updated time
    def entry_time(entry)
      time = if entry.respond_to?(:published) && entry.published
               entry.published
             elsif entry.respond_to?(:updated) && entry.updated
               entry.updated
             elsif entry.respond_to?(:pubDate) && entry.pubDate
               entry.pubDate
             else
               Time.now
             end

      time.is_a?(Time) ? time : Time.parse(time.to_s)
    rescue ArgumentError
      source_id = @source_name || 'unknown'
      log "[#{source_id}] Could not parse time, using current time", level: :warn
      Time.now
    end

    # Extract author information
    def entry_author(feed, entry)
      author_name = if entry.respond_to?(:author) && entry.author
                      entry.author
                    elsif entry.respond_to?(:dc_creator)
                      entry.dc_creator
                    else
                      @source_name || feed_title(feed)
                    end

      # Extract author name if it's an object
      author_name = author_name.name if author_name.respond_to?(:name)
      author_name = author_name.content if author_name.respond_to?(:content)

      Author.new(
        username: @source_name || feed_title(feed),
        full_name: author_name.to_s,
        url: feed_link(feed)
      )
    end

    # Extract media/enclosures
    def entry_media(entry)
      return [] unless entry.respond_to?(:enclosure) && entry.enclosure

      enclosure = entry.enclosure
      
      [Media.new(
        type: guess_media_type(enclosure.type),
        url: enclosure.url,
        alt_text: ''
      )]
    rescue StandardError => e
      source_id = @source_name || 'unknown'
      log "[#{source_id}] Error extracting media: #{e.message} (#{e.class})", level: :warn
      []
    end

    # Extract categories/tags
    def entry_categories(entry)
      return [] unless entry.respond_to?(:categories)
      
      entry.categories.map do |cat|
        cat.respond_to?(:content) ? cat.content : cat.to_s
      end
    end

    # Feed-level helpers
    def feed_title(feed)
      title = feed.channel.title rescue feed.title
      title.respond_to?(:content) ? title.content : title.to_s
    end

    def feed_link(feed)
      link = feed.channel.link rescue feed.link
      link.respond_to?(:href) ? link.href : link.to_s
    end

    # Clean HTML and decode all entities
    def clean_html(text)
      HtmlCleaner.clean(text)
    end

    # Guess media type from MIME type
    def guess_media_type(mime_type)
      return 'unknown' unless mime_type
      
      mime_type = mime_type.to_s.downcase
      
      case mime_type
      when /^image\//
        'image'
      when /^video\//
        'video'
      when /^audio\//
        'audio'
      else
        'unknown'
      end
    end
  end
end

