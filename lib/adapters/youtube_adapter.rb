
# frozen_string_literal: true

require 'rss'
require 'net/http'
require 'uri'
require 'rexml/document'
require_relative 'base_adapter'
require_relative '../models/post'
require_relative '../models/author'
require_relative '../models/media'
require_relative '../utils/http_client'

module Adapters
  # Raised when YouTube feed returns a transient HTTP error (maintenance window)
  class YouTubeTransientError < StandardError; end

  # Adapter for fetching posts from YouTube channel RSS feeds
  # Parses media:group namespace for full video metadata
  #
  # Config options:
  #   channel_id:   YouTube channel ID (UC...)
  #   handle:       YouTube handle (@channel) - will be resolved to channel_id
  #   source_name:  Display name for the channel
  #   no_shorts:    If true, use UULF playlist to exclude Shorts (default: false)
  #
  # Example:
  #   adapter = YouTubeAdapter.new(
  #     channel_id: 'UCFb-u3ISt99gxZ9TxIQW7UA',
  #     source_name: 'DVTV'
  #   )
  #   posts = adapter.fetch_posts(since: 1.day.ago)
  #
  class YouTubeAdapter < BaseAdapter
    USER_AGENT = 'Mozilla/5.0 (compatible; Zpravobot/1.0; +https://zpravobot.news)'

    def platform
      'youtube'
    end

    def validate_config!
      unless config[:channel_id] || config[:handle]
        raise ArgumentError, "YouTube channel_id or handle required"
      end

      @source_name = config[:source_name]
      @no_shorts = config[:no_shorts] || false
      
      # Resolve handle to channel_id if needed
      @channel_id = config[:channel_id] || resolve_handle(config[:handle])
      
      raise ArgumentError, "Could not resolve YouTube channel" unless @channel_id
    end

    def fetch_posts(since: nil)
      log "Fetching YouTube feed for channel: #{@channel_id}"
      
      raw_content = fetch_feed_content
      
      # Parse with RSS gem for basic structure
      feed = RSS::Parser.parse(raw_content, false)
      entries = feed.items
      log "Found #{entries.count} entries"
      
      # Parse media:group with REXML for full metadata
      media_data = parse_media_groups(raw_content)
      log "Extracted media:group for #{media_data.size} videos"
      
      # Filter by date if specified
      if since
        entries = entries.select { |e| entry_time(e) > since }
        log "Filtered to #{entries.count} entries since #{since}"
      end
      
      # Convert to Post objects
      posts = entries.map { |entry| entry_to_post(feed, entry, media_data) }
      
      log "Successfully converted #{posts.count} posts", level: :success
      posts
    end

    # Get the feed URL for this channel
    def feed_url
      if @no_shorts
        # UULF playlist = long-form videos only (no Shorts, no livestreams)
        playlist_id = @channel_id.sub(/^UC/, 'UULF')
        "https://www.youtube.com/feeds/videos.xml?playlist_id=#{playlist_id}"
      else
        "https://www.youtube.com/feeds/videos.xml?channel_id=#{@channel_id}"
      end
    end

    private

    # Resolve @handle to channel ID
    def resolve_handle(handle)
      handle = "@#{handle}" unless handle.start_with?('@')

      log "Resolving handle: #{handle}"

      response = HttpClient.get("https://www.youtube.com/#{handle}",
        headers: { 'Accept-Language' => 'en-US,en;q=0.9' },
        read_timeout: 15,
        user_agent: USER_AGENT)

      return nil unless response.code.to_i == 200

      # Try multiple patterns to find channel ID
      patterns = [
        /"channelId":"(UC[a-zA-Z0-9_-]{22})"/,
        /"externalId":"(UC[a-zA-Z0-9_-]{22})"/,
        /channel\/(UC[a-zA-Z0-9_-]{22})/,
        /"browseId":"(UC[a-zA-Z0-9_-]{22})"/
      ]

      patterns.each do |pattern|
        match = response.body.match(pattern)
        if match
          log "Resolved to: #{match[1]}", level: :success
          return match[1]
        end
      end

      log "Could not find channel ID in page", level: :error
      nil
    rescue StandardError => e
      source_id = @source_name || config[:handle] || 'unknown'
      log "[#{source_id}] Error resolving handle: #{e.message} (#{e.class})", level: :error
      nil
    end

    # Fetch raw feed content
    def fetch_feed_content
      response = HttpClient.get(feed_url, read_timeout: 15, user_agent: USER_AGENT)

      unless response.code.to_i == 200
        code = response.code.to_i
        if [404, 500, 502, 503].include?(code)
          raise YouTubeTransientError, "YouTube feed temporarily unavailable: HTTP #{code}"
        end
        raise "Failed to fetch feed: HTTP #{response.code}"
      end

      log "Received #{response.body.bytesize} bytes"
      response.body
    end

    # Parse media:group elements from raw XML
    def parse_media_groups(xml_content)
      media_data = {}
      
      doc = REXML::Document.new(xml_content)
      
      doc.elements.each('//entry') do |entry|
        video_id = extract_video_id_from_xml(entry)
        next unless video_id
        
        media_info = {
          video_id: video_id,
          description: nil,
          thumbnail_url: nil,
          thumbnail_width: nil,
          thumbnail_height: nil,
          views: nil,
          star_rating: nil
        }
        
        # Parse media:group
        entry.elements.each('media:group') do |group|
          # media:description
          group.elements.each('media:description') do |desc|
            media_info[:description] = desc.text
          end
          
          # media:thumbnail - get highest quality
          best_width = 0
          group.elements.each('media:thumbnail') do |thumb|
            width = thumb.attributes['width'].to_i
            if width > best_width
              best_width = width
              media_info[:thumbnail_url] = thumb.attributes['url']
              media_info[:thumbnail_width] = width
              media_info[:thumbnail_height] = thumb.attributes['height'].to_i
            end
          end
          
          # media:community for views/ratings
          group.elements.each('media:community') do |community|
            community.elements.each('media:statistics') do |stats|
              media_info[:views] = stats.attributes['views']&.to_i
            end
            community.elements.each('media:starRating') do |rating|
              media_info[:star_rating] = {
                count: rating.attributes['count']&.to_i,
                average: rating.attributes['average']&.to_f
              }
            end
          end
        end
        
        media_data[video_id] = media_info
      end
      
      media_data
    rescue REXML::ParseException => e
      source_id = @source_name || @channel_id || 'unknown'
      log "[#{source_id}] REXML parsing error: #{e.message} (#{e.class})", level: :warn
      {}
    end

    # Extract video ID from REXML entry element
    def extract_video_id_from_xml(entry)
      # Try yt:videoId element
      entry.elements.each('yt:videoId') do |vid|
        return vid.text if vid.text
      end
      
      # Fallback: extract from id element
      entry.elements.each('id') do |id_elem|
        if id_elem.text =~ /video:([a-zA-Z0-9_-]+)/
          return $1
        end
      end
      
      nil
    end

    # Convert RSS entry to Post object
    def entry_to_post(feed, entry, media_data)
      video_id = extract_video_id(entry)
      yt_media = media_data[video_id] || {}
      
      Post.new(
        platform: platform,
        id: video_id || entry_id(entry),
        url: entry_link(entry),
        title: entry_title(entry),
        text: yt_media[:description] || '',
        published_at: entry_time(entry),
        author: entry_author(feed, entry),
        media: build_media(video_id, yt_media),
        
        # YouTube videos aren't social posts
        is_repost: false,
        is_quote: false,
        is_reply: false,
        
        # Store extra YouTube data
        raw: {
          video_id: video_id,
          views: yt_media[:views],
          star_rating: yt_media[:star_rating],
          is_short: entry_link(entry)&.include?('/shorts/'),
          channel_id: @channel_id
        }
      )
    end

    # Build media array with thumbnail
    def build_media(video_id, yt_media)
      return [] unless video_id
      
      thumbnail_url = yt_media[:thumbnail_url] || 
                      "https://i.ytimg.com/vi/#{video_id}/hqdefault.jpg"
      
      # Build alt_text with dimensions if available
      alt_text = "Video thumbnail"
      if yt_media[:thumbnail_width] && yt_media[:thumbnail_height]
        alt_text = "Video thumbnail (#{yt_media[:thumbnail_width]}x#{yt_media[:thumbnail_height]})"
      end
      
      [
        Media.new(
          type: 'image',
          url: thumbnail_url,
          alt_text: alt_text
        )
      ]
    end

    # === RSS entry extraction helpers ===

    def extract_video_id(entry)
      # Try yt:videoId accessor (if RSS gem exposes it)
      if entry.respond_to?(:yt_videoId) && entry.yt_videoId
        return entry.yt_videoId
      end
      
      # Extract from entry ID (format: yt:video:VIDEO_ID)
      entry_id = entry_id(entry).to_s
      if entry_id =~ /video:([a-zA-Z0-9_-]+)/
        return $1
      end
      
      # Extract from URL
      url = entry_link(entry).to_s
      if url =~ /(?:watch\?v=|shorts\/|youtu\.be\/)([a-zA-Z0-9_-]+)/
        return $1
      end
      
      nil
    end

    def entry_id(entry)
      if entry.respond_to?(:id) && entry.id
        entry.id.respond_to?(:content) ? entry.id.content : entry.id.to_s
      else
        entry_link(entry)
      end
    end

    def entry_link(entry)
      if entry.respond_to?(:link) && entry.link
        entry.link.respond_to?(:href) ? entry.link.href : entry.link.to_s
      end
    end

    def entry_title(entry)
      return nil unless entry.respond_to?(:title)
      title = entry.title
      title.respond_to?(:content) ? title.content : title.to_s
    end

    def entry_time(entry)
      time = if entry.respond_to?(:published) && entry.published
               entry.published
             elsif entry.respond_to?(:updated) && entry.updated
               entry.updated
             else
               Time.now
             end
      
      return time.content if time.respond_to?(:content)
      time.is_a?(Time) ? time : Time.parse(time.to_s)
    rescue ArgumentError
      log "Could not parse time, using current time", level: :warn
      Time.now
    end

    def entry_author(feed, entry)
      author_name = nil
      author_url = nil
      
      if entry.respond_to?(:author) && entry.author
        author = entry.author
        author_name = if author.respond_to?(:name)
                        name = author.name
                        name.respond_to?(:content) ? name.content : name.to_s
                      else
                        author.to_s
                      end
        
        if author.respond_to?(:uri)
          uri = author.uri
          author_url = uri.respond_to?(:content) ? uri.content : uri.to_s
        end
      end
      
      author_name ||= @source_name || feed_title(feed)
      author_url ||= "https://www.youtube.com/channel/#{@channel_id}"
      
      Author.new(
        username: @source_name || sanitize_username(author_name),
        full_name: author_name,
        url: author_url
      )
    end

    def feed_title(feed)
      if feed.respond_to?(:title)
        title = feed.title
        title.respond_to?(:content) ? title.content : title.to_s
      else
        'YouTube Channel'
      end
    end

    def sanitize_username(name)
      name.to_s.downcase.gsub(/[^a-z0-9_]/, '_').gsub(/_+/, '_').gsub(/^_|_$/, '')
    end
  end
end

