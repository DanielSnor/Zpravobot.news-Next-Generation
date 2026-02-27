#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Test pro aktualizovaný BlueskyAdapter
# ============================================================
# Testuje oba módy: profile a custom feed
#
# Použití:
#   ruby test_bluesky_adapter_v2.rb
#
# ============================================================

# Přidej cestu k lib
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require_relative '../lib/adapters/bluesky_adapter'

def separator(title = nil)
  puts
  puts "=" * 70
  puts "  #{title}" if title
  puts "=" * 70
  puts
end

def display_post(post, num)
  type = if post.is_repost
    "🔁 Repost"
  elsif post.is_quote
    "💬 Quote"
  elsif post.is_reply
    "↩️ Reply"
  else
    "📝 Post"
  end
  
  puts "#{num}. #{type}"
  puts "   Author:  @#{post.author.username}"
  puts "   Time:    #{post.published_at.strftime('%Y-%m-%d %H:%M')}"
  puts "   Text:    #{post.text[0..80]}#{'...' if post.text.length > 80}"
  puts "   URL:     #{post.url}"
  
  if post.is_repost && post.reposted_by
    puts "   RT by:   @#{post.reposted_by}"
  end
  
  if post.is_quote && post.quoted_post
    puts "   Quoted:  @#{post.quoted_post[:author]}"
  end
  
  if post.media.any?
    puts "   Media:   #{post.media.count} item(s) - #{post.media.map(&:type).join(', ')}"
  end
  
  puts
end

def test_profile_mode
  separator("TEST 1: Profile Mode (existing functionality)")
  
  puts "Testing with handle: ct24.bsky.social"
  puts
  
  adapter = Adapters::BlueskyAdapter.new(handle: 'ct24.bsky.social')
  
  # Get info
  info = adapter.feed_info
  puts "Feed info:"
  puts "  Type:   #{info[:type]}"
  puts "  Handle: #{info[:handle]}"
  puts
  
  # Fetch posts
  puts "Fetching posts (limit: 5)..."
  posts = adapter.fetch_posts(limit: 5)
  
  puts "✅ Received #{posts.count} posts"
  puts
  
  posts.first(3).each_with_index do |post, idx|
    display_post(post, idx + 1)
  end
  
  true
rescue StandardError => e
  puts "❌ Error: #{e.message}"
  puts e.backtrace.first(3).join("\n")
  false
end

def test_custom_feed_mode_url
  separator("TEST 2: Custom Feed Mode (via URL)")
  
  feed_url = 'https://bsky.app/profile/richardgolias.cz/feed/aaalpdtfsootk'
  puts "Testing with feed_url: #{feed_url}"
  puts
  
  adapter = Adapters::BlueskyAdapter.new(feed_url: feed_url)
  
  # Get info
  info = adapter.feed_info
  puts "Feed info:"
  puts "  Type:        #{info[:type]}"
  puts "  Name:        #{info[:name]}"
  puts "  Description: #{info[:description]&.lines&.first&.strip}"
  puts "  Creator:     @#{info[:creator]}"
  puts "  Likes:       #{info[:likes]}"
  puts "  Online:      #{info[:online]}"
  puts
  
  # Fetch posts
  puts "Fetching posts (limit: 5)..."
  posts = adapter.fetch_posts(limit: 5)
  
  puts "✅ Received #{posts.count} posts"
  puts
  
  posts.first(3).each_with_index do |post, idx|
    display_post(post, idx + 1)
  end
  
  true
rescue StandardError => e
  puts "❌ Error: #{e.message}"
  puts e.backtrace.first(3).join("\n")
  false
end

def test_custom_feed_mode_explicit
  separator("TEST 3: Custom Feed Mode (explicit creator + rkey)")
  
  puts "Testing with feed_creator: richardgolias.cz, feed_rkey: aaalpdtfsootk"
  puts
  
  adapter = Adapters::BlueskyAdapter.new(
    feed_creator: 'richardgolias.cz',
    feed_rkey: 'aaalpdtfsootk'
  )
  
  # Fetch posts
  puts "Fetching posts (limit: 3)..."
  posts = adapter.fetch_posts(limit: 3)
  
  puts "✅ Received #{posts.count} posts"
  puts
  
  posts.first(2).each_with_index do |post, idx|
    display_post(post, idx + 1)
  end
  
  true
rescue StandardError => e
  puts "❌ Error: #{e.message}"
  puts e.backtrace.first(3).join("\n")
  false
end

def test_filtering
  separator("TEST 4: Filtering options")
  
  feed_url = 'https://bsky.app/profile/richardgolias.cz/feed/aaalpdtfsootk'
  
  # Test with skip_replies: false (default is true)
  puts "Testing with skip_replies: false..."
  adapter = Adapters::BlueskyAdapter.new(
    feed_url: feed_url,
    skip_replies: false,
    skip_quotes: false
  )
  
  posts = adapter.fetch_posts(limit: 20)
  
  replies = posts.count(&:is_reply)
  quotes = posts.count(&:is_quote)
  reposts = posts.count(&:is_repost)
  regular = posts.count { |p| !p.is_reply && !p.is_quote && !p.is_repost }
  
  puts "✅ Results with filtering disabled:"
  puts "   Total:    #{posts.count}"
  puts "   Regular:  #{regular}"
  puts "   Replies:  #{replies}"
  puts "   Quotes:   #{quotes}"
  puts "   Reposts:  #{reposts}"
  puts
  
  # Test with filtering enabled
  puts "Testing with skip_replies: true (default)..."
  adapter2 = Adapters::BlueskyAdapter.new(feed_url: feed_url)
  posts2 = adapter2.fetch_posts(limit: 20)
  
  replies2 = posts2.count(&:is_reply)
  
  puts "✅ Results with skip_replies: true:"
  puts "   Total:    #{posts2.count}"
  puts "   Replies:  #{replies2} (should be 0)"
  
  true
rescue StandardError => e
  puts "❌ Error: #{e.message}"
  puts e.backtrace.first(3).join("\n")
  false
end

def test_error_handling
  separator("TEST 5: Error handling")
  
  # Test invalid config
  puts "Testing missing config..."
  begin
    Adapters::BlueskyAdapter.new({})
    puts "❌ Should have raised error"
    return false
  rescue ArgumentError => e
    puts "✅ Correctly raised: #{e.message}"
  end
  
  # Test invalid feed URL
  puts
  puts "Testing invalid feed URL format..."
  begin
    Adapters::BlueskyAdapter.new(feed_url: 'https://example.com/invalid')
    puts "❌ Should have raised error"
    return false
  rescue ArgumentError => e
    puts "✅ Correctly raised: #{e.message}"
  end
  
  true
end

# ============================================
# Main
# ============================================

if __FILE__ == $PROGRAM_NAME
  puts
  puts "🦋 BlueskyAdapter v2 Test Suite"
  puts "   (Profile + Custom Feed support)"
  
  results = {}
  
  results[:profile] = test_profile_mode
  results[:custom_url] = test_custom_feed_mode_url
  results[:custom_explicit] = test_custom_feed_mode_explicit
  results[:filtering] = test_filtering
  results[:errors] = test_error_handling
  
  separator("SUMMARY")
  
  results.each do |name, passed|
    status = passed ? "✅ PASS" : "❌ FAIL"
    puts "  #{name}: #{status}"
  end
  
  puts
  
  if results.values.all?
    puts "🎉 All tests passed!"
    exit 0
  else
    puts "⚠️  Some tests failed"
    exit 1
  end
end
