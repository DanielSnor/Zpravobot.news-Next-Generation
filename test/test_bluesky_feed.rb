#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Bluesky Custom Feed API Test
# ============================================================
# Testuje možnost získávat příspěvky z custom feedů na Bluesky
# 
# Použití:
#   ruby test_bluesky_feed.rb https://bsky.app/profile/richardgolias.cz/feed/aaalpdtfsootk
#   ruby test_bluesky_feed.rb richardgolias.cz aaalpdtfsootk
#
# ============================================================

require 'net/http'
require 'json'
require 'uri'
require 'time'

class BlueskyFeedTest
  PUBLIC_API = "https://public.api.bsky.app/xrpc"
  
  OPEN_TIMEOUT = 10
  READ_TIMEOUT = 20
  
  def initialize(feed_url_or_handle, rkey = nil)
    if rkey
      # Direct: handle + rkey
      @handle = feed_url_or_handle
      @rkey = rkey
    else
      # Parse URL
      parse_feed_url(feed_url_or_handle)
    end
  end
  
  def run
    puts
    puts "=" * 70
    puts "🦋 Bluesky Custom Feed API Test"
    puts "=" * 70
    puts
    
    # Step 1: Parse/validate input
    puts "📋 Feed info:"
    puts "   Handle: #{@handle}"
    puts "   Rkey:   #{@rkey}"
    puts
    
    # Step 2: Resolve handle to DID
    puts "🔍 Resolving handle to DID..."
    did = resolve_handle(@handle)
    puts "   DID: #{did}"
    puts
    
    # Step 3: Get feed generator info
    feed_uri = "at://#{did}/app.bsky.feed.generator/#{@rkey}"
    puts "📡 Feed AT-URI: #{feed_uri}"
    puts
    
    puts "ℹ️  Getting feed generator info..."
    feed_info = get_feed_generator(feed_uri)
    if feed_info['view']
      view = feed_info['view']
      puts "   Name:        #{view['displayName']}"
      puts "   Description: #{view['description']&.lines&.first&.strip}"
      puts "   Creator:     @#{view['creator']['handle']}"
      puts "   Likes:       #{view['likeCount'] || 0}"
      puts "   Online:      #{feed_info['isOnline']}"
      puts "   Valid:       #{feed_info['isValid']}"
    end
    puts
    
    # Step 4: Fetch feed posts
    puts "📥 Fetching feed posts (limit: 10)..."
    feed_data = get_feed(feed_uri, limit: 10)
    
    unless feed_data['feed']
      puts "❌ No feed data returned!"
      puts "   Response: #{feed_data}"
      return false
    end
    
    posts = feed_data['feed']
    puts "✅ Received #{posts.count} posts"
    puts
    
    # Step 5: Display posts
    puts "-" * 70
    puts "📝 Posts:"
    puts "-" * 70
    
    posts.each_with_index do |item, idx|
      display_post(item, idx + 1)
    end
    
    # Step 6: Summary
    puts "=" * 70
    puts "📊 Summary:"
    puts "   Total posts:  #{posts.count}"
    puts "   Cursor:       #{feed_data['cursor'] ? '✓ present' : '✗ none'}"
    puts
    puts "✅ Test PASSED - Custom feed API works!"
    puts "=" * 70
    
    true
    
  rescue StandardError => e
    puts
    puts "❌ Error: #{e.message}"
    puts e.backtrace.first(5).join("\n") if ENV['DEBUG']
    false
  end
  
  private
  
  def parse_feed_url(url)
    # Format: https://bsky.app/profile/{handle}/feed/{rkey}
    if url =~ %r{bsky\.app/profile/([^/]+)/feed/([^/?]+)}
      @handle = $1
      @rkey = $2
    else
      raise ArgumentError, "Invalid feed URL format. Expected: https://bsky.app/profile/{handle}/feed/{rkey}"
    end
  end
  
  def resolve_handle(handle)
    uri = URI("#{PUBLIC_API}/com.atproto.identity.resolveHandle")
    uri.query = URI.encode_www_form(handle: handle)
    
    response = api_get(uri)
    response['did'] or raise "Could not resolve handle: #{handle}"
  end
  
  def get_feed_generator(feed_uri)
    uri = URI("#{PUBLIC_API}/app.bsky.feed.getFeedGenerator")
    uri.query = URI.encode_www_form(feed: feed_uri)
    
    api_get(uri)
  end
  
  def get_feed(feed_uri, limit: 30, cursor: nil)
    uri = URI("#{PUBLIC_API}/app.bsky.feed.getFeed")
    
    params = { feed: feed_uri, limit: limit }
    params[:cursor] = cursor if cursor
    
    uri.query = URI.encode_www_form(params)
    
    api_get(uri)
  end
  
  def api_get(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT
    
    request = Net::HTTP::Get.new(uri)
    request['User-Agent'] = 'Zpravobot/1.0 (+https://zpravobot.news)'
    request['Accept'] = 'application/json'
    
    puts "   → GET #{uri}" if ENV['DEBUG']
    
    response = http.request(request)
    
    unless response.is_a?(Net::HTTPSuccess)
      error = JSON.parse(response.body) rescue { 'error' => response.body }
      raise "API error #{response.code}: #{error['message'] || error['error'] || response.body}"
    end
    
    JSON.parse(response.body)
  end
  
  def display_post(item, num)
    post = item['post']
    record = post['record']
    author = post['author']
    reason = item['reason']
    
    # Post type
    type_badge = if reason&.dig('$type') == 'app.bsky.feed.defs#reasonRepost'
      "🔁 RT by @#{reason.dig('by', 'handle')}"
    elsif record['embed']&.dig('$type')&.include?('record')
      "💬 Quote"
    elsif record['reply']
      "↩️ Reply"
    else
      "📝 Post"
    end
    
    # Time
    time = Time.parse(post['indexedAt']).strftime('%Y-%m-%d %H:%M')
    
    # Text preview
    text = record['text'].to_s
    text_preview = text.length > 100 ? text[0..100] + "..." : text
    
    puts
    puts "#{num}. #{type_badge}"
    puts "   Author: @#{author['handle']} (#{author['displayName']})"
    puts "   Time:   #{time}"
    puts "   Text:   #{text_preview.gsub("\n", " ")}"
    
    # Media
    embed = post['embed']
    if embed
      case embed['$type']
      when 'app.bsky.embed.images#view'
        puts "   Media:  #{embed['images']&.count || 0} image(s)"
      when 'app.bsky.embed.video#view'
        puts "   Media:  1 video"
      when 'app.bsky.embed.external#view'
        puts "   Link:   #{embed.dig('external', 'uri')}"
      when 'app.bsky.embed.record#view', 'app.bsky.embed.recordWithMedia#view'
        quoted = embed.dig('record', 'author', 'handle') || embed.dig('record', 'record', 'author', 'handle')
        puts "   Quoted: @#{quoted}" if quoted
      end
    end
    
    # Stats
    likes = post['likeCount'] || 0
    reposts = post['repostCount'] || 0
    replies = post['replyCount'] || 0
    puts "   Stats:  ❤️ #{likes} 🔁 #{reposts} 💬 #{replies}"
  end
end

# ============================================
# Main
# ============================================

if __FILE__ == $PROGRAM_NAME
  if ARGV.empty? || ARGV.include?('--help') || ARGV.include?('-h')
    puts <<~HELP
      Bluesky Custom Feed API Test
      
      Usage:
        ruby #{$PROGRAM_NAME} <feed_url>
        ruby #{$PROGRAM_NAME} <handle> <rkey>
        
      Examples:
        ruby #{$PROGRAM_NAME} https://bsky.app/profile/richardgolias.cz/feed/aaalpdtfsootk
        ruby #{$PROGRAM_NAME} richardgolias.cz aaalpdtfsootk
        
      Environment:
        DEBUG=1  Show API calls and stack traces
    HELP
    exit 0
  end
  
  test = if ARGV.length >= 2
    BlueskyFeedTest.new(ARGV[0], ARGV[1])
  else
    BlueskyFeedTest.new(ARGV[0])
  end
  
  success = test.run
  exit(success ? 0 : 1)
end
