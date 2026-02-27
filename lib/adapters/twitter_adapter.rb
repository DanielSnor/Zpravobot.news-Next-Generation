# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'time'
require_relative 'base_adapter'
require_relative '../models/post'
require_relative '../models/author'
require_relative '../models/media'
require_relative '../utils/html_cleaner'
require_relative '../utils/format_helpers'
require_relative '../utils/http_client'
require_relative 'twitter_rss_parser'
require_relative 'twitter_html_parser'
require_relative 'twitter_tweet_classifier'
require_relative '../formatters/universal_formatter'

module Adapters
  # Twitter Adapter for Zpravobot Next Generation
  # Fetches tweets via Nitter RSS feed with thread detection support
  #
  # Nitter provides RSS feeds at: https://nitter.example.com/{username}/rss
  #
  # Architecture (Phase 3 refactor):
  # - TwitterRssParser:        RSS XML parsing, item→Post conversion, text/media extraction from RSS
  # - TwitterHtmlParser:       Nitter HTML page parsing, single-tweet extraction, HTML media extraction
  # - TwitterTweetClassifier:  Type detection (RT, quote, reply, thread), video detection
  # - TwitterAdapter:          Orchestration, HTTP fetching via HttpClient, media URL fixing
  #
  # Thread Detection (Phase 1 - RSS based):
  # - Detects self-replies by checking "R to @same_handle:" pattern
  # - Sets is_thread_post = true for tweets that are part of a thread
  # - No extra HTTP requests needed for detection
  #
  # Thread Context (Phase 2 - Optional):
  # - Use TwitterThreadFetcher to get full thread context
  # - Only when needed, fetches HTML page for before/after tweets
  #
  # Single Post Fetch (for IFTTT Hybrid):
  # - fetch_single_post(post_id) fetches a specific tweet by ID from Nitter HTML
  # - Used when IFTTT triggers but we need full Nitter data (Tier 2)
  #
  class TwitterAdapter < BaseAdapter
    include TwitterRssParser
    include TwitterHtmlParser
    include TwitterTweetClassifier

    USER_AGENT = 'Zpravobot/1.0 (+https://zpravobot.news)'

    attr_reader :handle, :nitter_instance

    # Initialize adapter
    # @param handle [String] Twitter handle (without @)
    # @param nitter_instance [String] Nitter instance URL (e.g., http://xn.zpravobot.news:8080)
    def initialize(handle:, nitter_instance: nil, url_domain: nil)
      @handle = handle.gsub(/^@/, '').downcase  # Remove @ if present, lowercase
      @nitter_instance = nitter_instance || ENV['NITTER_INSTANCE'] || 'http://xn.zpravobot.news:8080'
      @nitter_instance = @nitter_instance.chomp('/')
      @url_domain = (url_domain || "https://#{Formatters::TWITTER_URL_DOMAIN}").chomp('/')
    end

    # Fetch posts from Nitter RSS feed
    # @param since [Time, nil] Only return posts after this time
    # @param limit [Integer] Maximum number of posts to return
    # @return [Array<Post>] Array of Post objects
    def fetch_posts(since: nil, limit: 50)
      log "Fetching Twitter feed for @#{handle} via #{nitter_instance}"

      rss_url = "#{nitter_instance}/#{handle}/rss"
      log "RSS URL: #{rss_url}"

      xml = fetch_rss(rss_url)
      return [] unless xml

      items = parse_rss(xml)
      log "Found #{items.length} items"

      posts = items.map { |item| convert_to_post(item) }.compact

      # Filter by date if specified
      if since
        posts = posts.select { |post| post.published_at && post.published_at > since }
      end

      # Log thread detection stats
      thread_posts = posts.count(&:is_thread_post)
      log "Thread posts detected: #{thread_posts}/#{posts.length}" if thread_posts > 0

      # Limit results
      posts = posts.first(limit)

      log "Returning #{posts.length} posts after filtering", level: :success
      posts
    end

    # ============================================
    # Single Post Fetch (for IFTTT Hybrid Tier 2)
    # ============================================

    # Fetch a single post by ID from Nitter HTML page
    # Used by hybrid IFTTT adapter for Tier 2 processing when we need
    # full tweet data (multiple images, full text, etc.)
    #
    # @param post_id [String] Twitter status ID (numeric string)
    # @param username [String, nil] Override username (for RTs where author differs from handle)
    # @return [Post, nil] Post object or nil if not found/error
    def fetch_single_post(post_id, username: nil)
      target_user = username || handle
      log "Fetching single post #{post_id} for @#{target_user}"

      # Build Nitter URL for the specific tweet
      nitter_url = "#{nitter_instance}/#{target_user}/status/#{post_id}"
      log "Nitter URL: #{nitter_url}"

      # Fetch HTML page
      html = fetch_html_page(nitter_url)
      return nil unless html

      # Parse the main tweet from HTML (delegated to TwitterHtmlParser)
      post = parse_main_tweet_from_html(html, post_id, target_user)

      if post
        if post.text.nil? || post.text.strip.empty?
          log "Nitter returned empty content for post #{post_id} (tweet likely deleted)", level: :warn
        else
          log "Successfully fetched post #{post_id}", level: :success
        end
      else
        log "Failed to parse post #{post_id} from Nitter HTML", level: :error
      end

      post
    rescue StandardError => e
      log "Error fetching single post #{post_id}: #{e.message}", level: :error
      log e.backtrace.first(3).join("\n"), level: :error
      nil
    end

    private

    # ============================================
    # HTTP Fetching (uses HttpClient from Phase 1)
    # ============================================

    def fetch_rss(url)
      response = HttpClient.get(url)

      if response.code.to_i == 200
        response.body.force_encoding('UTF-8').scrub('?')
      else
        log "HTTP #{response.code}: #{response.message}", level: :error
        nil
      end
    rescue StandardError => e
      log "Fetch error: #{e.message}", level: :error
      nil
    end

    # Fetch HTML page from Nitter
    # @param url [String] Full Nitter URL
    # @return [String, nil] HTML content or nil on error
    def fetch_html_page(url)
      response = HttpClient.get(url, headers: { 'Accept' => 'text/html' })

      if response.code.to_i == 200
        response.body.force_encoding('UTF-8').scrub('?')
      else
        log "HTTP #{response.code} fetching HTML: #{response.message}", level: :error
        nil
      end
    rescue StandardError => e
      log "HTML fetch error: #{e.message}", level: :error
      nil
    end

    # ============================================
    # Media URL Fixing (shared by RSS and HTML parsers)
    # ============================================

    # Fix media URL to use correct Nitter instance and full resolution
    # Nitter RSS generates HTTPS URLs even when running on HTTP
    # @param url [String] Original URL from RSS
    # @return [String] Fixed URL matching nitter_instance with full resolution
    def fix_media_url(url)
      return url unless url

      # Extract the path from Nitter URL
      # URLs look like: https://xn.zpravobot.news/pic/media%2F...
      if url =~ %r{https?://[^/]*zpravobot[^/]*(/.+)$}
        path = $1
        # Use /pic/orig/ for full resolution images (but not video thumbnails)
        if path.include?('/pic/media') && !path.include?('video')
          path = path.sub('/pic/', '/pic/orig/')
        end
        "#{nitter_instance}#{path}"
      elsif url.start_with?('/pic/') || url.start_with?('/media/')
        # Relative URL - upgrade to full resolution for regular images
        path = url
        if path.include?('/pic/media') && !path.include?('video')
          path = path.sub('/pic/', '/pic/orig/')
        end
        "#{nitter_instance}#{path}"
      else
        url
      end
    end

  end
end
