#!/usr/bin/env ruby
# frozen_string_literal: true

# Add lib to load path
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require_relative '../lib/adapters/rss_adapter'

# Test RSS feeds
TEST_FEEDS = {
  local: {
    name: "Local Test Feed (ČT24 Mock)",
    url: "file://#{File.expand_path('../../test/fixtures/ct24_test.rss', __FILE__)}"
  },
  ct24: {
    name: "ČT24 - Hlavní zprávy",
    url: "https://ct24.ceskatelevize.cz/rss/hlavni-zpravy"
  },
  bigas: {
    name: "Jiří Bigas - Substack",
    url: "https://jiribigas.substack.com/feed"
  },
  irozhlas: {
    name: "iRozhlas.cz",
    url: "https://www.irozhlas.cz/rss/irozhlas/section/zpravy-domov"
  },
  idnes: {
    name: "iDNES.cz",
    url: "https://servis.idnes.cz/rss.aspx?c=zpravodaj"
  },
  github: {
    name: "GitHub Blog",
    url: "https://github.blog/feed/"
  },
  reddit_programming: {
    name: "Reddit /r/programming",
    url: "https://www.reddit.com/r/programming/.rss"
  }
}

def print_separator
  puts "\n" + ("=" * 80) + "\n"
end

def print_post(post)
  puts "📰 Post Details:"
  puts "  Platform: #{post.platform}"
  puts "  ID: #{post.id}"
  puts "  URL: #{post.url}"
  puts "  Author: #{post.author_name} (@#{post.author_username})"
  puts "  Published: #{post.published_at}"
  
  if post.has_title?
    puts "  Title: #{post.title}"
  end
  
  if post.has_text?
    text_preview = post.text[0..200]
    text_preview += "..." if post.text.length > 200
    puts "  Text: #{text_preview}"
  end
  
  if post.has_media?
    puts "  Media: #{post.media.count} item(s)"
    post.media.each_with_index do |media, i|
      puts "    #{i + 1}. #{media.type}: #{media.url}"
    end
  end
  
  puts "  Empty: #{post.empty?}"
  puts "  Has title: #{post.has_title?}"
  puts "  Has text: #{post.has_text?}"
  puts "  Has media: #{post.has_media?}"
end

def test_feed(feed_key, feed_info)
  print_separator
  puts "🔍 Testing: #{feed_info[:name]}"
  puts "   URL: #{feed_info[:url]}"
  print_separator
  
  begin
    # Create adapter
    adapter = Adapters::RssAdapter.new(
      feed_url: feed_info[:url],
      source_name: feed_key.to_s
    )
    
    puts "\n📡 Fetching posts..."
    posts = adapter.fetch_posts
    
    puts "\n✅ Successfully fetched #{posts.count} posts"
    
    if posts.empty?
      puts "⚠️  No posts found in feed"
      return
    end
    
    # Show first 3 posts in detail
    posts.first(3).each_with_index do |post, i|
      puts "\n" + ("-" * 80)
      puts "Post ##{i + 1}"
      puts "-" * 80
      print_post(post)
    end
    
    # Summary statistics
    puts "\n" + ("=" * 80)
    puts "📊 Feed Statistics:"
    puts "  Total posts: #{posts.count}"
    puts "  Posts with titles: #{posts.count(&:has_title?)}"
    puts "  Posts with text: #{posts.count(&:has_text?)}"
    puts "  Posts with media: #{posts.count(&:has_media?)}"
    puts "  Empty posts: #{posts.count(&:empty?)}"
    
    # Show oldest and newest
    oldest = posts.min_by(&:published_at)
    newest = posts.max_by(&:published_at)
    puts "\n  Oldest post: #{oldest.published_at}"
    puts "  Newest post: #{newest.published_at}"
    
  rescue StandardError => e
    puts "\n❌ Error: #{e.message}"
    puts e.backtrace.first(5).join("\n")
  end
end

# Main execution
puts "=" * 80
puts "RSS Adapter Test Suite"
puts "=" * 80

# Test which feed?
if ARGV[0]
  feed_key = ARGV[0].to_sym
  if TEST_FEEDS[feed_key]
    test_feed(feed_key, TEST_FEEDS[feed_key])
  else
    puts "❌ Unknown feed: #{ARGV[0]}"
    puts "Available feeds: #{TEST_FEEDS.keys.join(', ')}"
    exit 1
  end
else
  # Test all feeds
  TEST_FEEDS.each do |feed_key, feed_info|
    test_feed(feed_key, feed_info)
  end
end

puts "\n" + ("=" * 80)
puts "✅ Test suite complete!"
puts "=" * 80
