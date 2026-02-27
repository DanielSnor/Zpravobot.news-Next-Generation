#!/usr/bin/env ruby
# frozen_string_literal: true

# Bluesky Adapter Test Script
# Tests the Bluesky adapter against real profiles
#
# Location: /app/data/zbnw-ng-test/bin/test_bluesky.rb
#
# Usage:
#   ruby bin/test_bluesky.rb                      # Test default profile
#   ruby bin/test_bluesky.rb nesestra.bsky.social # Test specific profile
#   ruby bin/test_bluesky.rb --all                # Test all configured profiles

require_relative '../lib/adapters/bluesky_adapter'

# ============================================
# Test Configuration
# ============================================

TEST_PROFILES = {
  nesestra: {
    handle: 'nesestra.bsky.social',
    description: 'Czech filmmaker - mix of posts, reposts, quotes'
  },
  bsky: {
    handle: 'bsky.app',
    description: 'Official Bluesky account'
  },
  jay: {
    handle: 'jay.bsky.team',
    description: 'Bluesky CEO'
  }
}.freeze

# ============================================
# Test Helpers
# ============================================

def separator(char = '=', length = 60)
  puts char * length
end

def section(title)
  puts
  separator
  puts "  #{title}"
  separator
  puts
end

def format_time(time)
  time.strftime('%Y-%m-%d %H:%M:%S')
end

def truncate(text, max = 80)
  return '' if text.nil? || text.empty?
  text.length > max ? "#{text[0...max]}..." : text
end

def post_type_emoji(post)
  if post.is_repost
    '🔁'
  elsif post.is_quote
    '💬'
  elsif post.is_reply
    '↩️'
  else
    '📝'
  end
end

def post_type_label(post)
  types = []
  types << 'REPOST' if post.is_repost
  types << 'QUOTE' if post.is_quote
  types << 'REPLY' if post.is_reply
  types.empty? ? 'POST' : types.join('+')
end

# ============================================
# Display Functions
# ============================================

def display_post(post, index)
  puts "#{index}. #{post_type_emoji(post)} [#{post_type_label(post)}] #{format_time(post.published_at)}"
  puts "   Author: @#{post.author.username} (#{post.author.full_name})"
  puts "   Text: #{truncate(post.text, 100)}"
  puts "   URL: #{post.url}"
  
  if post.is_repost && post.reposted_by
    puts "   ↳ Reposted by: @#{post.reposted_by}"
  end
  
  if post.is_quote && post.quoted_post
    puts "   ↳ Quoting @#{post.quoted_post[:author]}: #{truncate(post.quoted_post[:text], 60)}"
  end
  
  if post.has_media?
    media_summary = post.media.map { |m| m.type }.tally
    puts "   📎 Media: #{media_summary.map { |k, v| "#{v}x #{k}" }.join(', ')}"
  end
  
  puts
end

def display_statistics(posts)
  section("Statistics")
  
  total = posts.count
  reposts = posts.count(&:is_repost)
  quotes = posts.count(&:is_quote)
  replies = posts.count(&:is_reply)
  originals = total - reposts - quotes - replies
  with_media = posts.count(&:has_media?)
  
  puts "Total posts:     #{total}"
  puts "├─ Original:     #{originals} (#{percentage(originals, total)})"
  puts "├─ Reposts:      #{reposts} (#{percentage(reposts, total)})"
  puts "├─ Quotes:       #{quotes} (#{percentage(quotes, total)})"
  puts "├─ Replies:      #{replies} (#{percentage(replies, total)})"
  puts "└─ With media:   #{with_media} (#{percentage(with_media, total)})"
  
  puts
  
  # Time range
  if posts.any?
    oldest = posts.min_by(&:published_at)
    newest = posts.max_by(&:published_at)
    puts "Time range: #{format_time(oldest.published_at)} → #{format_time(newest.published_at)}"
  end
end

def percentage(part, total)
  return '0%' if total.zero?
  "#{(part.to_f / total * 100).round(1)}%"
end

# ============================================
# Test Functions
# ============================================

def test_profile(handle, description = nil)
  section("Testing: @#{handle}")
  puts "Description: #{description}" if description
  puts
  
  # Create adapter
  adapter = Adapters::BlueskyAdapter.new(
    handle: handle,
    filter: :no_replies,
    skip_replies: false,  # Let's see all types for testing
    skip_reposts: false
  )
  
  # Fetch posts
  puts "Fetching posts..."
  start_time = Time.now
  posts = adapter.fetch_posts(limit: 30)
  elapsed = Time.now - start_time
  
  puts "✅ Fetched #{posts.count} posts in #{elapsed.round(2)}s"
  puts
  
  # Display posts
  section("Posts")
  posts.each_with_index do |post, idx|
    display_post(post, idx + 1)
  end
  
  # Statistics
  display_statistics(posts)
  
  # Return success
  true
  
rescue StandardError => e
  puts "❌ Error: #{e.message}"
  puts e.backtrace.first(5).join("\n") if ENV['DEBUG']
  false
end

def test_api_directly(handle)
  section("Direct API Test: @#{handle}")
  
  require 'net/http'
  require 'json'
  
  uri = URI("https://public.api.bsky.app/xrpc/app.bsky.feed.getAuthorFeed")
  uri.query = URI.encode_www_form(actor: handle, limit: 3)
  
  puts "Request: #{uri}"
  puts
  
  response = Net::HTTP.get_response(uri)
  
  puts "Status: #{response.code} #{response.message}"
  puts
  
  if response.is_a?(Net::HTTPSuccess)
    data = JSON.parse(response.body)
    puts "Feed items: #{data['feed']&.count || 0}"
    puts "Cursor: #{data['cursor'] ? 'present' : 'none'}"
    
    if data['feed']&.any?
      puts
      puts "First item structure:"
      item = data['feed'].first
      puts JSON.pretty_generate({
        'post.uri' => item.dig('post', 'uri'),
        'post.author.handle' => item.dig('post', 'author', 'handle'),
        'post.record.text' => truncate(item.dig('post', 'record', 'text'), 50),
        'reason.$type' => item.dig('reason', '$type'),
        'post.embed.$type' => item.dig('post', 'embed', '$type')
      })
    end
    
    true
  else
    puts "Error body: #{response.body}"
    false
  end
end

# ============================================
# Main
# ============================================

if __FILE__ == $PROGRAM_NAME
  puts
  puts "🦋 Bluesky Adapter Test Suite"
  puts "=" * 60
  puts
  
  arg = ARGV[0]
  
  case arg
  when '--all'
    # Test all profiles
    results = TEST_PROFILES.map do |key, config|
      [key, test_profile(config[:handle], config[:description])]
    end
    
    section("Summary")
    results.each do |key, success|
      status = success ? '✅' : '❌'
      puts "#{status} #{key}: #{TEST_PROFILES[key][:handle]}"
    end
    
  when '--api'
    # Direct API test
    handle = ARGV[1] || 'nesestra.bsky.social'
    test_api_directly(handle)
    
  when '--help', '-h'
    puts "Usage:"
    puts "  ruby bin/test_bluesky.rb                      # Test default profile"
    puts "  ruby bin/test_bluesky.rb handle.bsky.social   # Test specific profile"
    puts "  ruby bin/test_bluesky.rb --all                # Test all profiles"
    puts "  ruby bin/test_bluesky.rb --api [handle]       # Direct API test"
    puts
    puts "Available test profiles:"
    TEST_PROFILES.each do |key, config|
      puts "  #{key}: #{config[:handle]} - #{config[:description]}"
    end
    
  when nil
    # Default: test nesestra
    test_profile('nesestra.bsky.social', 'Default test profile')
    
  else
    # Treat as handle
    if arg.include?('.')
      test_profile(arg)
    else
      # Try as key
      if TEST_PROFILES.key?(arg.to_sym)
        config = TEST_PROFILES[arg.to_sym]
        test_profile(config[:handle], config[:description])
      else
        puts "Unknown profile: #{arg}"
        puts "Use --help for usage information"
        exit 1
      end
    end
  end
end
