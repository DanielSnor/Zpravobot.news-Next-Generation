# frozen_string_literal: true

# Bluesky Adapter for Zpravobot Next Generation
# Fetches posts from Bluesky profiles and custom feeds via public API
#
# Supports:
# - Profile feeds (user's posts)
# - Custom feed generators
# - Reposts, quotes, replies detection
# - Media extraction (images, video, link cards)
# - Facet URL expansion (replaces truncated URLs with full ones)
# - Threading support (self-reply detection for Mastodon threads)

require 'net/http'
require 'uri'
require 'json'
require 'time'
require_relative 'base_adapter'
require_relative '../models/post'
require_relative '../models/author'
require_relative '../models/media'
require_relative '../utils/http_client'
require_relative '../utils/punycode'

module Adapters
  class BlueskyAdapter < BaseAdapter
    # Public Bluesky API - no auth required
    PUBLIC_API = "https://public.api.bsky.app/xrpc"
    
    # Timeouts for HTTP requests (seconds)
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 20
    
    # API filter options for getAuthorFeed
    FEED_FILTERS = {
      all: 'posts_with_replies',           # Everything
      no_replies: 'posts_no_replies',      # Posts and reposts, no replies
      media_only: 'posts_with_media',      # Only posts with media
      threads: 'posts_and_author_threads'  # Posts + author's own threads
    }.freeze
    
    # Feed modes
    MODE_PROFILE = :profile      # Traditional author feed
    MODE_CUSTOM_FEED = :custom_feed  # Custom feed generator
    
    def platform
      'bluesky'
    end
    
    def validate_config!
      # Determine mode based on config
      if config[:feed_url]
        @mode = MODE_CUSTOM_FEED
        parse_feed_url(config[:feed_url])
      elsif config[:feed_creator] && config[:feed_rkey]
        @mode = MODE_CUSTOM_FEED
        @feed_creator = config[:feed_creator]
        @feed_rkey = config[:feed_rkey]
      elsif config[:handle]
        @mode = MODE_PROFILE
        @handle = config[:handle]
      else
        raise ArgumentError, "Bluesky config requires either 'handle' (for profile) or 'feed_url' (for custom feed)"
      end
      
      # Common options
      @skip_replies = config.fetch(:skip_replies, true)
      @skip_reposts = config.fetch(:skip_reposts, false)
      @skip_quotes = config.fetch(:skip_quotes, false)
      
      # Threading support: when enabled, fetches self-threads
      # Only applicable for profile mode
      @include_self_threads = config.fetch(:include_self_threads, false)
      
      # Determine API filter based on threading setting (profile mode only)
      if @mode == MODE_PROFILE
        if @include_self_threads
          @filter = :threads  # posts_and_author_threads - includes self-replies
          log "Threading mode: enabled (posts_and_author_threads)"
        else
          @filter = config[:filter] || :no_replies
          log "Threading mode: disabled (#{FEED_FILTERS[@filter]})"
        end
      else
        # Custom feed mode - use default filter
        @filter = config[:filter] || :threads
      end
    end
    
    def fetch_posts(since: nil, limit: 50)
      validate_config!
      
      case @mode
      when MODE_PROFILE
        fetch_profile_posts(since: since, limit: limit)
      when MODE_CUSTOM_FEED
        fetch_custom_feed_posts(since: since, limit: limit)
      end
    end
    
    # Get info about the feed/profile being fetched
    # Useful for profile sync and debugging
    def feed_info
      validate_config!
      
      case @mode
      when MODE_PROFILE
        { type: :profile, handle: @handle }
      when MODE_CUSTOM_FEED
        resolve_feed_uri_if_needed!
        info = get_feed_generator(@feed_uri)
        {
          type: :custom_feed,
          uri: @feed_uri,
          name: info.dig('view', 'displayName'),
          description: info.dig('view', 'description'),
          creator: info.dig('view', 'creator', 'handle'),
          likes: info.dig('view', 'likeCount'),
          online: info['isOnline'],
          valid: info['isValid']
        }
      end
    end
    
    private
    
    # ============================================
    # Feed URL Parsing
    # ============================================
    
    def parse_feed_url(url)
      # Format: https://bsky.app/profile/{handle}/feed/{rkey}
      if url =~ %r{bsky\.app/profile/([^/]+)/feed/([^/?]+)}
        @feed_creator = $1
        @feed_rkey = $2
      else
        raise ArgumentError, "Invalid Bluesky feed URL format. Expected: https://bsky.app/profile/{handle}/feed/{rkey}"
      end
    end
    
    # ============================================
    # Profile Mode (existing functionality)
    # ============================================
    
    def fetch_profile_posts(since:, limit:)
      log "Fetching Bluesky profile feed for @#{@handle}"
      
      response = get_author_feed(
        actor: @handle,
        limit: [limit, 100].min,  # API max is 100
        filter: FEED_FILTERS[@filter] || FEED_FILTERS[:no_replies]
      )
      
      process_feed_response(response, since)
    end
    
    def get_author_feed(actor:, limit: 50, filter: nil, cursor: nil)
      uri = URI("#{PUBLIC_API}/app.bsky.feed.getAuthorFeed")
      
      params = { actor: actor, limit: limit }
      params[:filter] = filter if filter
      params[:cursor] = cursor if cursor
      
      uri.query = URI.encode_www_form(params)
      log "API call: #{uri}"
      
      api_get(uri)
    end
    
    # ============================================
    # Custom Feed Mode
    # ============================================
    
    def fetch_custom_feed_posts(since:, limit:)
      resolve_feed_uri_if_needed!
      
      log "Fetching Bluesky custom feed: #{@feed_uri}"
      
      response = get_custom_feed(
        feed: @feed_uri,
        limit: [limit, 100].min  # API max is 100
      )
      
      process_feed_response(response, since)
    end
    
    def resolve_feed_uri_if_needed!
      return if @feed_uri
      
      # Resolve handle to DID
      log "Resolving handle @#{@feed_creator} to DID..."
      did = resolve_handle(@feed_creator)
      log "Resolved to: #{did}"
      
      # Build AT URI
      @feed_uri = "at://#{did}/app.bsky.feed.generator/#{@feed_rkey}"
      log "Feed AT-URI: #{@feed_uri}"
    end
    
    def resolve_handle(handle)
      uri = URI("#{PUBLIC_API}/com.atproto.identity.resolveHandle")
      uri.query = URI.encode_www_form(handle: handle)
      
      response = api_get(uri)
      response['did'] or raise "Could not resolve handle: #{handle}"
    end
    
    def get_custom_feed(feed:, limit: 50, cursor: nil)
      uri = URI("#{PUBLIC_API}/app.bsky.feed.getFeed")
      
      params = { feed: feed, limit: limit }
      params[:cursor] = cursor if cursor
      
      uri.query = URI.encode_www_form(params)
      
      api_get(uri)
    end
    
    def get_feed_generator(feed_uri)
      uri = URI("#{PUBLIC_API}/app.bsky.feed.getFeedGenerator")
      uri.query = URI.encode_www_form(feed: feed_uri)
      
      api_get(uri)
    end
    
    # ============================================
    # Common API & Processing
    # ============================================
    
    def api_get(uri)
      log "API call: #{uri}"

      response = HttpClient.get(uri,
        headers: { 'Accept' => 'application/json' },
        open_timeout: OPEN_TIMEOUT,
        read_timeout: READ_TIMEOUT)

      unless response.is_a?(Net::HTTPSuccess)
        error_body = JSON.parse(response.body) rescue { 'error' => response.body }
        log "API error #{response.code}: #{error_body}", level: :error
        raise "Bluesky API error: #{response.code} - #{error_body['message'] || error_body['error']}"
      end

      JSON.parse(response.body)
    end
    
    def process_feed_response(response, since)
      unless response['feed']
        log "No feed data returned", level: :warn
        return []
      end
      
      feed_items = response['feed']
      log "Received #{feed_items.count} items from API"
      
      # Using map + compact instead of filter_map for Ruby 2.6 compatibility
      posts = feed_items.map do |item|
        post = parse_feed_item(item)
        
        # Filter by date
        if since && post.published_at <= since
          log "Post #{post.id.split('/').last}: filtered by date (#{post.published_at.iso8601} <= #{since.iso8601})", level: :debug
          nil
        # Filter by type
        elsif should_skip?(post)
          nil
        else
          post
        end
      end.compact

      log "Returning #{posts.count} posts after filtering", level: :success
      posts
    end
    
    # ============================================
    # Facet URL Expansion
    # ============================================
    # Bluesky stores full URLs in facets, but displays truncated text.
    # This method replaces truncated URLs in text with full ones from facets.
    
    def expand_facet_urls(text, facets)
      return text if text.nil? || text.empty?
      return text if facets.nil? || facets.empty?
      
      # Sort facets by byte start position in reverse order
      # (process from end to avoid offset issues)
      link_facets = facets.select do |f|
        f.dig('features', 0, '$type') == 'app.bsky.richtext.facet#link'
      end.sort_by { |f| -(f.dig('index', 'byteStart') || 0) }
      
      return text if link_facets.empty?
      
      # Work with bytes (Bluesky uses byte offsets, not character offsets)
      text_bytes = text.dup.force_encoding('UTF-8').bytes
      
      link_facets.each do |facet|
        byte_start = facet.dig('index', 'byteStart')
        byte_end = facet.dig('index', 'byteEnd')
        full_url = facet.dig('features', 0, 'uri')
        full_url = PunycodeDecoder.decode_url(full_url) if full_url

        next unless byte_start && byte_end && full_url
        next if byte_start < 0 || byte_end > text_bytes.length
        
        # Extract the truncated URL from text
        truncated_bytes = text_bytes[byte_start...byte_end]
        truncated_url = truncated_bytes.pack('C*').force_encoding('UTF-8')
        
        # Only replace if it looks like a truncated URL (ends with ...)
        # or if the full URL is different
        if truncated_url != full_url
          # Replace in byte array
          url_bytes = full_url.bytes
          text_bytes = text_bytes[0...byte_start] + url_bytes + text_bytes[byte_end..]
        end
      end
      
      text_bytes.pack('C*').force_encoding('UTF-8')
    rescue StandardError => e
      source_id = config[:source_name] || config[:handle] || 'unknown'
      log "[#{source_id}] Error expanding facet URLs: #{e.message} (#{e.class})", level: :warn
      text
    end
    
    # ============================================
    # Post Parsing
    # ============================================
    
    def parse_feed_item(item)
      post_data = item['post']
      record = post_data['record']
      author_data = post_data['author']
      reason = item['reason']
      
      # Determine post type
      is_repost = reason_is_repost?(reason)
      is_quote = embed_is_quote?(record['embed'])
      is_reply = !record['reply'].nil?
      
      # Detect self-reply (thread post)
      is_thread_post = false
      reply_to_handle = nil
      
      if is_reply && record['reply']
        thread_info = detect_self_reply(record['reply'], author_data)
        is_thread_post = thread_info[:is_thread_post]
        reply_to_handle = thread_info[:reply_to_handle]
      end
      
      # Build author
      author = Author.new(
        username: author_data['handle'],
        full_name: author_data['displayName'] || author_data['handle'],
        url: profile_url(author_data['handle'])
      )
      
      # Build reposted_by if this is a repost
      reposted_by = if is_repost
        reason.dig('by', 'handle')
      end
      
      # Build quoted post if this is a quote
      quoted_post = if is_quote
        parse_quoted_post(post_data['embed'])
      end
      
      # Build reply_to if this is a reply
      reply_to = if is_reply
        parse_reply_info(record['reply'])
      end
      
      # Extract media
      media = extract_media(post_data['embed'])
      
      # Extract and expand text - replace truncated URLs with full ones from facets
      post_text = expand_facet_urls(record['text'], record['facets'])
      
      Post.new(
        platform: platform,
        id: post_data['uri'],
        url: build_post_url(author_data['handle'], post_data['uri']),
        text: post_text || '',
        published_at: parse_time(post_data['indexedAt']),
        author: author,
        
        is_repost: is_repost,
        is_quote: is_quote,
        is_reply: is_reply,
        
        reposted_by: reposted_by,
        quoted_post: quoted_post,
        reply_to: reply_to,
        
        # Thread support
        is_thread_post: is_thread_post,
        reply_to_handle: reply_to_handle,
        
        media: media,
        
        raw: {
          uri: post_data['uri'],
          cid: post_data['cid'],
          facets: record['facets'],  # Store facets for debugging
          reason_type: reason&.dig('$type'),
          embed_type: post_data.dig('embed', '$type'),
          embed: post_data['embed'],
          like_count: post_data['likeCount'],
          repost_count: post_data['repostCount'],
          reply_count: post_data['replyCount']
        }
      )
    end
    
    def reason_is_repost?(reason)
      return false unless reason
      reason['$type'] == 'app.bsky.feed.defs#reasonRepost'
    end
    
    def embed_is_quote?(embed)
      return false unless embed
      
      type = embed['$type']
      # Direct quote
      return true if type == 'app.bsky.embed.record'
      # Quote with media
      return true if type == 'app.bsky.embed.recordWithMedia'
      
      false
    end
    
    def parse_quoted_post(embed)
      return nil unless embed
      
      # Handle recordWithMedia (quote + media)
      record_embed = if embed['$type'] == 'app.bsky.embed.recordWithMedia'
        embed.dig('record', 'record')
      else
        embed['record']
      end
      
      return nil unless record_embed
      
      # The actual quoted content is nested inside
      value = record_embed['value'] || record_embed
      author_data = record_embed['author']
      
      return nil unless author_data
      
      {
        text: value['text'],
        author: Author.new(
          username: author_data['handle'],
          full_name: author_data['displayName'] || author_data['handle'],
          url: profile_url(author_data['handle'])
        ),
        url: build_post_url(author_data['handle'], record_embed['uri'])
      }
    end
    
    def parse_reply_info(reply)
      return nil unless reply
      
      parent = reply['parent']
      root = reply['root']
      
      {
        parent_uri: parent&.dig('uri'),
        parent_cid: parent&.dig('cid'),
        root_uri: root&.dig('uri'),
        root_cid: root&.dig('cid')
      }
    end
    
    # Detect if a reply is a self-reply (thread post)
    # Compares DID from parent URI with author's DID
    def detect_self_reply(reply, author_data)
      result = {
        is_thread_post: false,
        reply_to_handle: nil
      }
      
      return result unless reply && author_data
      
      # Get the parent post's DID from its URI
      # URI format: at://did:plc:xxx/app.bsky.feed.post/rkey
      parent_uri = reply.dig('parent', 'uri')
      return result unless parent_uri
      
      parent_did = extract_did_from_uri(parent_uri)
      return result unless parent_did
      
      # Get the current author's DID
      author_did = author_data['did']
      
      # Compare DIDs to detect self-reply
      if parent_did == author_did
        result[:is_thread_post] = true
        result[:reply_to_handle] = author_data['handle']
        log "🧵 Detected thread post (self-reply) for @#{author_data['handle']}"
      end
      
      result
    end
    
    # Extract DID from AT URI
    # @param uri [String] AT URI like "at://did:plc:xxx/app.bsky.feed.post/rkey"
    # @return [String, nil] The DID or nil if not found
    def extract_did_from_uri(uri)
      return nil unless uri
      
      # AT URI format: at://did:plc:xxx/collection/rkey
      if uri =~ %r{^at://(did:[^/]+)/}
        $1
      else
        nil
      end
    end
    
    # ============================================
    # Media Extraction
    # ============================================
    
    def extract_media(embed)
      return [] unless embed
      
      type = embed['$type']
      
      case type
      when 'app.bsky.embed.images#view'
        extract_images(embed)
      when 'app.bsky.embed.video#view'
        extract_video(embed)
      when 'app.bsky.embed.external#view'
        extract_link_card(embed)
      when 'app.bsky.embed.recordWithMedia#view'
        # Quote with media - extract media from the media part
        media_embed = embed['media']
        extract_media(media_embed) if media_embed
      else
        []
      end
    end
    
    def extract_images(embed)
      images = embed['images'] || []
      images.map do |img|
        Media.new(
          type: :image,
          url: img['fullsize'] || img['thumb'],
          thumbnail_url: img['thumb'],
          alt_text: img['alt']
        )
      end
    end
    
    def extract_video(embed)
      [Media.new(
        type: :video,
        url: embed['playlist'],  # HLS playlist URL
        thumbnail_url: embed['thumbnail'],
        alt_text: embed['alt']
      )]
    end
    
    def extract_link_card(embed)
      external = embed['external']
      return [] unless external
      
      [Media.new(
        type: :link_card,
        url: PunycodeDecoder.decode_url(external['uri']),
        thumbnail_url: external['thumb'],
        title: external['title'],
        description: external['description']
      )]
    end
    
    # ============================================
    # Helpers
    # ============================================
    
    def build_post_url(handle, uri)
      # URI format: at://did:plc:xxx/app.bsky.feed.post/rkey
      rkey = uri.split('/').last
      "https://bsky.app/profile/#{handle}/post/#{rkey}"
    end
    
    def profile_url(handle)
      "https://bsky.app/profile/#{handle}"
    end
    
    # Skip logic with threading consideration
    # When threading is enabled, don't skip self-replies
    def should_skip?(post)
      # Handle replies
      if post.is_reply
        # Thread posts (self-replies) should not be skipped if threading is enabled
        if @include_self_threads && post.respond_to?(:is_thread_post) && post.is_thread_post
          # Allow self-reply through for threading
          log "Allowing self-reply for threading"
        elsif @skip_replies
          return true
        end
      end
      
      return true if @skip_reposts && post.is_repost
      return true if @skip_quotes && post.is_quote
      false
    end
    
    def parse_time(time_string)
      Time.parse(time_string)
    rescue ArgumentError
      Time.now
    end
  end
end
