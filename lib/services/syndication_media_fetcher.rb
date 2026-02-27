# frozen_string_literal: true

# ============================================================
# Twitter Syndication Media Fetcher
# ============================================================
# Lightweight fetcher pro získání médií z Twitter Syndication API.
# Používá se jako alternativa k Nitter pro zdroje s nitter_processing: false
#
# Syndication API je veřejné API používané pro Twitter embedy.
# Vrací JSON s plným textem, obrázky a video thumbnaily.
#
# Použití:
#   result = Services::SyndicationMediaFetcher.fetch('1234567890')
#   result[:success]         # true/false
#   result[:text]            # Plný text tweetu
#   result[:photos]          # Array of photo URLs
#   result[:video_thumbnail] # Video thumbnail URL nebo nil
#   result[:display_name]    # User display name
# ============================================================

require 'net/http'
require 'uri'
require 'json'
require_relative '../utils/http_client'
require_relative '../support/loggable'

module Services
  class SyndicationMediaFetcher
    include Support::Loggable
    ENDPOINT = 'https://cdn.syndication.twimg.com/tweet-result'
    
    # Retry configuration
    MAX_RETRIES = 3
    RETRY_DELAYS = [1, 2, 4].freeze  # exponential backoff
    
    # Timeouts
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 5
    
    # User agent (Googlebot works reliably)
    USER_AGENT = 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)'
    
    class << self
      # Fetch media and text from Twitter Syndication API
      #
      # @param tweet_id [String] Twitter status ID
      # @return [Hash] Result hash with :success, :text, :photos, :video_thumbnail, :display_name
      def fetch(tweet_id)
        new(tweet_id).fetch
      end
    end
    
    def initialize(tweet_id)
      @tweet_id = tweet_id.to_s
      @logger_prefix = "[SyndicationFetcher]"
    end
    
    # Main fetch method with retry logic
    #
    # @return [Hash] Result hash
    def fetch
      MAX_RETRIES.times do |attempt|
        log "Fetching tweet #{@tweet_id} (attempt #{attempt + 1}/#{MAX_RETRIES})"
        
        result = try_fetch
        
        if result[:success]
          log "Success! Photos: #{result[:photos].count}, Video: #{result[:video_thumbnail] ? 'yes' : 'no'}", level: :success
          return result
        end
        
        # Don't sleep after last attempt
        if attempt < MAX_RETRIES - 1
          delay = RETRY_DELAYS[attempt]
          log "Attempt #{attempt + 1} failed: #{result[:error]}. Retrying in #{delay}s...", level: :warn
          sleep delay
        else
          log "All #{MAX_RETRIES} attempts failed: #{result[:error]}", level: :error
        end
      end
      
      # Return failure result after all retries exhausted
      failure_result("All #{MAX_RETRIES} attempts failed")
    end
    
    private
    
    # Single fetch attempt
    #
    # @return [Hash] Result hash
    def try_fetch
      uri = build_uri
      response = make_request(uri)
      
      unless response.is_a?(Net::HTTPSuccess)
        return failure_result("HTTP #{response.code}")
      end
      
      if response.body.nil? || response.body.empty?
        return failure_result("Empty response body")
      end
      
      parse_response(response.body)
      
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      failure_result("Timeout: #{e.message}")
    rescue JSON::ParserError => e
      failure_result("JSON parse error: #{e.message}")
    rescue StandardError => e
      failure_result("#{e.class}: #{e.message}")
    end
    
    # Build API URL with random token
    #
    # @return [URI]
    def build_uri
      token = generate_token
      URI("#{ENDPOINT}?id=#{@tweet_id}&token=#{token}")
    end
    
    # Generate random token (works according to documentation)
    #
    # @return [String]
    def generate_token
      chars = ('a'..'z').to_a + ('0'..'9').to_a
      10.times.map { chars.sample }.join
    end
    
    # Make HTTP request
    #
    # @param uri [URI]
    # @return [Net::HTTPResponse]
    def make_request(uri)
      HttpClient.get(uri,
        headers: { 'Accept' => 'application/json' },
        open_timeout: OPEN_TIMEOUT,
        read_timeout: READ_TIMEOUT,
        user_agent: USER_AGENT)
    end
    
    # Parse JSON response and extract data
    #
    # @param body [String] JSON response body
    # @return [Hash] Result hash
    def parse_response(body)
      data = JSON.parse(body)
      
      # Check if we got a valid tweet
      unless data['id_str'] || data['text']
        return failure_result("Invalid response: missing id_str or text")
      end
      
      {
        success: true,
        tweet_id: data['id_str'],
        text: data['text'],
        photos: extract_photos(data),
        video_thumbnail: extract_video_thumbnail(data),
        display_name: data.dig('user', 'name'),
        username: data.dig('user', 'screen_name'),
        created_at: data['created_at'],
        error: nil
      }
    end
    
    # Extract photo URLs from response
    #
    # @param data [Hash] Parsed JSON
    # @return [Array<String>] Array of photo URLs
    def extract_photos(data)
      photos = []
      
      # Primary source: mediaDetails array
      media_details = data['mediaDetails'] || []
      media_details.each do |media|
        if media['type'] == 'photo' && media['media_url_https']
          photos << media['media_url_https']
        end
      end
      
      # Fallback: photos array (alternative structure)
      if photos.empty? && data['photos']
        data['photos'].each do |photo|
          photos << photo['url'] if photo['url']
        end
      end
      
      photos.uniq
    end
    
    # Extract video thumbnail URL from response
    #
    # @param data [Hash] Parsed JSON
    # @return [String, nil] Thumbnail URL or nil
    def extract_video_thumbnail(data)
      # Primary: video.poster
      poster = data.dig('video', 'poster')
      return poster if poster
      
      # Fallback: mediaDetails with type video
      media_details = data['mediaDetails'] || []
      video_media = media_details.find { |m| m['type'] == 'video' }
      
      video_media&.dig('media_url_https')
    end
    
    # Build failure result hash
    #
    # @param error [String] Error message
    # @return [Hash]
    def failure_result(error)
      {
        success: false,
        tweet_id: @tweet_id,
        text: nil,
        photos: [],
        video_thumbnail: nil,
        display_name: nil,
        username: nil,
        created_at: nil,
        error: error
      }
    end
    
  end
end
