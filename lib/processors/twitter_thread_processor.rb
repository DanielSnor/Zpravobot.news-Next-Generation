# frozen_string_literal: true

# Twitter Thread Processor for ZBNW-NG
#
# Handles thread reconstruction for Twitter sources:
# 1. Detects if tweet is part of a thread (via Nitter HTML)
# 2. Extracts thread chain from before-tweet section
# 3. Reconstructs missing tweets in chain
# 4. Returns correct in_reply_to_id for Mastodon threading
#

require 'net/http'
require 'uri'
require_relative '../utils/http_client'
require_relative '../formatters/universal_formatter'
require_relative '../support/loggable'

module Processors
  class TwitterThreadProcessor
    include Support::Loggable
    MAX_CHAIN_DEPTH = 10
    RETRY_ATTEMPTS = 3
    RETRY_DELAYS = [1, 2, 4].freeze  # seconds
    HTTP_TIMEOUT = 10
    
    attr_reader :state_manager, :twitter_adapter, :publisher, :nitter_instance, :url_domain

    # @param state_manager [State::StateManager] Database state manager
    # @param twitter_adapter [Adapters::TwitterAdapter] For fetching single posts
    # @param publisher [Publishers::MastodonPublisher] For publishing missing tweets
    # @param nitter_instance [String] Nitter base URL
    # @param url_domain [String] Domain for rewriting Twitter URLs (default from config)
    def initialize(state_manager:, twitter_adapter:, publisher:, nitter_instance:, url_domain: nil)
      @state_manager = state_manager
      @twitter_adapter = twitter_adapter
      @publisher = publisher
      @nitter_instance = nitter_instance.chomp('/')
      @url_domain = url_domain || Formatters::TWITTER_URL_DOMAIN
    end
    
    # Process a tweet that might be part of a thread
    #
    # @param source_id [String] Source identifier (e.g., 'andrewofpolesia_twitter')
    # @param post_id [String] Tweet ID from IFTTT
    # @param handle [String] Twitter handle
    # @return [Hash] { in_reply_to_id: String|nil, html: String|nil, is_thread: Boolean }
    def process(source_id, post_id, handle)
      log_info("[#{source_id}] 🧵 ThreadProcessor: checking #{post_id}")
      
      # Fetch Nitter HTML with retry
      html = fetch_with_retry(handle, post_id)
      
      unless html
        log_warn("[#{source_id}] 🧵 Nitter fetch failed, falling back to standalone")
        return { in_reply_to_id: nil, html: nil, is_thread: false }
      end
      
      # Check if this is a thread
      unless has_thread_chain?(html)
        log_debug("[#{source_id}] 🧵 Not a thread, processing as standalone")
        return { in_reply_to_id: nil, html: html, is_thread: false }
      end
      
      # Extract thread chain
      chain = extract_thread_chain(html)
      
      if chain.empty?
        log_warn("[#{source_id}] 🧵 Thread detected but chain extraction failed")
        return { in_reply_to_id: nil, html: html, is_thread: true }
      end
      
      log_info("[#{source_id}] 🧵 Thread chain found: #{chain.length} tweets before current")
      
      # Reconstruct chain (publish missing tweets, get last mastodon_id)
      in_reply_to_id = reconstruct_chain(source_id, handle, chain)
      
      {
        in_reply_to_id: in_reply_to_id,
        html: html,
        is_thread: true,
        chain_length: chain.length
      }
    end
    
    # Check if HTML contains a thread (before-tweet section with content)
    #
    # @param html [String] Nitter HTML page
    # @return [Boolean]
    def has_thread_chain?(html)
      return false unless html
      
      # Look for before-tweet section with timeline-item content
      html.include?('before-tweet') && 
        html.match?(/<div class="before-tweet[^"]*">.*?<div class="timeline-item/m)
    end
    
    # Extract thread chain from Nitter HTML
    #
    # Nitter HTML structure for threads:
    #   <div class="before-tweet thread-line">
    #     <div class="timeline-item " data-username="handle">
    #       <a class="tweet-link" href="/handle/status/ID#m"></a>
    #       ...
    #       <a class="username" href="/handle" title="@handle">@handle</a>
    #       ...
    #       <div class="tweet-content media-body" dir="auto">TEXT</div>
    #       ...
    #     </div>
    #   </div>
    #   <div id="m" class="main-tweet">...</div>
    #
    # @param html [String] Nitter HTML page
    # @return [Array<Hash>] Array of { id:, username:, text_preview: } ordered oldest-first
    def extract_thread_chain(html)
      chain = []

      # Extract before-tweet section (everything between before-tweet and main-tweet)
      # Use greedy match (.*) because the section contains nested divs
      before_match = html.match(/<div class="before-tweet[^"]*">(.*)<\/div>\s*<div[^>]*class="[^"]*main-tweet/m)
      return chain unless before_match

      before_html = before_match[1]

      # Extract each timeline-item using data-username attribute
      # The tweet-link href may contain #m suffix: /handle/status/ID#m
      before_html.scan(/data-username="([^"]+)".*?<a class="tweet-link" href="\/[^\/]+\/status\/(\d+)[^"]*".*?<div class="tweet-content[^"]*"[^>]*>(.*?)<\/div>/m) do |username, tweet_id, content_html|
        # Strip HTML tags from content to get text preview
        text_preview = content_html.gsub(/<[^>]+>/, ' ').gsub(/\s+/, ' ').strip[0..50]
        text_preview = text_preview.encode('UTF-8', 'UTF-8', invalid: :replace, undef: :replace, replace: '?')
        chain << {
          id: tweet_id,
          username: username.downcase,
          text_preview: text_preview
        }
      end

      # Limit to MAX_CHAIN_DEPTH (keep most recent if over limit)
      chain = chain.last(MAX_CHAIN_DEPTH) if chain.length > MAX_CHAIN_DEPTH

      log_debug("Extracted #{chain.length} tweets from thread chain")
      chain
    end
    
    private
    
    # Reconstruct thread chain - publish missing tweets
    #
    # @param source_id [String] Source identifier
    # @param handle [String] Twitter handle
    # @param chain [Array<Hash>] Thread chain from extract_thread_chain
    # @return [String, nil] Mastodon status ID of last tweet in chain (for in_reply_to)
    def reconstruct_chain(source_id, handle, chain)
      last_mastodon_id = nil

      chain.each_with_index do |tweet, index|
        preview = sanitize_encoding(tweet[:text_preview].to_s)
        log_debug("[#{source_id}] 🧵 Chain[#{index + 1}/#{chain.length}]: #{tweet[:id]} - #{preview}...")
        
        # Check if already published
        existing = state_manager.find_by_post_id(source_id, tweet[:id])
        
        if existing && existing[:mastodon_status_id]
          log_debug("[#{source_id}] 🧵 Tweet #{tweet[:id]} already published as #{existing[:mastodon_status_id]}")
          last_mastodon_id = existing[:mastodon_status_id]
          next
        end
        
        # Check if it's a self-reply (same author)
        unless tweet[:username].downcase == handle.downcase
          log_debug("[#{source_id}] 🧵 Tweet #{tweet[:id]} by @#{tweet[:username]} - not self, skipping chain")
          # External reply breaks the chain - this shouldn't happen for self-threads
          # but if it does, we stop here
          break
        end
        
        # Need to publish this missing tweet
        log_info("[#{source_id}] 🧵 Publishing missing chain tweet: #{tweet[:id]}")
        
        begin
          mastodon_id = publish_chain_tweet(source_id, handle, tweet[:id], last_mastodon_id)
          
          if mastodon_id
            last_mastodon_id = mastodon_id
            log_info("[#{source_id}] 🧵 Published chain tweet #{tweet[:id]} → #{mastodon_id}")
          else
            log_warn("[#{source_id}] 🧵 Failed to publish chain tweet #{tweet[:id]}, continuing...")
          end
        rescue StandardError => e
          log_error("[#{source_id}] 🧵 Error publishing chain tweet #{tweet[:id]}: #{sanitize_encoding(e.message)}")
          # Continue with chain even if one tweet fails
        end
        
        # Small delay between chain tweets to avoid rate limiting
        sleep(0.5)
      end
      
      last_mastodon_id
    end
    
    # Publish a single tweet from the chain
    #
    # @param source_id [String] Source identifier
    # @param handle [String] Twitter handle  
    # @param tweet_id [String] Tweet ID to publish
    # @param in_reply_to_id [String, nil] Mastodon status ID to reply to
    # @return [String, nil] New Mastodon status ID or nil on failure
    def publish_chain_tweet(source_id, handle, tweet_id, in_reply_to_id)
      # Fetch full tweet data from Nitter
      post = twitter_adapter.fetch_single_post(tweet_id)
      
      unless post
        log_warn("[#{source_id}] 🧵 Could not fetch tweet #{tweet_id} from Nitter")
        return nil
      end
      
      # Format the post (simplified - caller should provide formatter if needed)
      # For now, we use basic formatting
      text = format_chain_tweet(post)
      
      # Upload media if present
      media_ids = upload_media(post.media) if post.media && !post.media.empty?
      media_ids ||= []
      
      # Publish to Mastodon
      result = publisher.publish(
        text,
        media_ids: media_ids,
        in_reply_to_id: in_reply_to_id
      )
      
      mastodon_id = result['id']
      
      # Record in database
      state_manager.mark_published(
        source_id,
        tweet_id,
        post_url: post.url,
        mastodon_status_id: mastodon_id
      )
      
      mastodon_id
    rescue StandardError => e
      log_error("[#{source_id}] 🧵 publish_chain_tweet failed: #{sanitize_encoding(e.message)}")
      nil
    end
    
    # Sanitize string encoding to UTF-8
    # Nitter HTTP responses arrive as ASCII-8BIT; this prevents encoding crashes
    # when interpolating into UTF-8 strings (log messages, formatting)
    def sanitize_encoding(str)
      return '' unless str
      str.encode('UTF-8', str.encoding, invalid: :replace, undef: :replace, replace: '?')
    end

    # Basic formatting for chain tweets
    # Full formatting is handled by the main adapter
    #
    # @param post [Post] Post object
    # @return [String] Formatted text
    def format_chain_tweet(post)
      text = sanitize_encoding(post.text || '')

      # Add source URL at the end
      url = post.url&.gsub(/twitter\.com|x\.com/, @url_domain)
      
      if url && !text.include?(url)
        text = "#{text}\n\n#{url}"
      end
      
      text.strip
    end
    
    # Upload media attachments
    #
    # @param media [Array<Media>] Media objects
    # @return [Array<String>] Media IDs
    def upload_media(media)
      # Skip non-uploadable types
      uploadable = media.reject { |m| m.type == 'link_card' }
      uploadable = uploadable.reject { |m| m.type == 'video_thumbnail' && media.any? { |o| o.type == 'video' } }
      uploadable = uploadable.select(&:url)

      return [] if uploadable.empty?

      media_items = uploadable.map do |m|
        { url: m.url, description: m.alt_text }
      end

      publisher.upload_media_parallel(media_items)
    end
    
    # Fetch Nitter HTML with retry logic
    #
    # @param handle [String] Twitter handle
    # @param post_id [String] Tweet ID
    # @return [String, nil] HTML content or nil on failure
    def fetch_with_retry(handle, post_id)
      url = "#{nitter_instance}/#{handle}/status/#{post_id}"

      RETRY_ATTEMPTS.times do |attempt|
        delay = RETRY_DELAYS[attempt] || RETRY_DELAYS.last

        begin
          log_debug("Fetching #{url} (attempt #{attempt + 1}/#{RETRY_ATTEMPTS})")

          response = HttpClient.get(url,
            open_timeout: HTTP_TIMEOUT,
            read_timeout: HTTP_TIMEOUT)

          if response.code.to_i == 200
            return response.body.force_encoding('UTF-8').scrub('?')
          elsif response.code.to_i == 404
            log_warn("Tweet #{post_id} not found (404)")
            return nil
          else
            log_warn("Nitter returned #{response.code}, retrying in #{delay}s...")
          end

        rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED => e
          log_warn("Nitter connection error: #{e.message}, retrying in #{delay}s...")
        rescue StandardError => e
          log_error("Nitter fetch error: #{e.class} - #{e.message}")
        end

        sleep(delay) if attempt < RETRY_ATTEMPTS - 1
      end

      nil
    end
    
  end
end
