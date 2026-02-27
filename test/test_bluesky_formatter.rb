#!/usr/bin/env ruby
# frozen_string_literal: true

# Bluesky Formatter Test Script
# Tests formatting of Bluesky posts for Mastodon output
#
# Location: /app/data/zbnw-ng-test/bin/test_bluesky_formatter.rb
#
# Usage:
#   ruby bin/test_bluesky_formatter.rb                      # Test with default profile
#   ruby bin/test_bluesky_formatter.rb nesestra.bsky.social # Test specific profile

require_relative '../lib/adapters/bluesky_adapter'
require_relative '../lib/formatters/bluesky_formatter'

# ============================================
# Helpers
# ============================================

def separator(char = '=', length = 70)
  puts char * length
end

def section(title)
  puts
  separator
  puts "  #{title}"
  separator
  puts
end

def post_type_label(post)
  if post.is_repost
    '🔁 REPOST'
  elsif post.is_quote
    '💬 QUOTE'
  else
    '📝 POST'
  end
end

def char_count_status(text, limit = 500)
  len = text.length
  if len <= limit
    "✅ #{len}/#{limit}"
  else
    "❌ #{len}/#{limit} (OVER BY #{len - limit})"
  end
end

# ============================================
# Main Test
# ============================================

def test_formatter(handle)
  section("Bluesky Formatter Test: @#{handle}")
  
  # Create adapter and formatter
  adapter = Adapters::BlueskyAdapter.new(
    handle: handle,
    filter: :no_replies,
    skip_replies: false,
    skip_reposts: false
  )
  
  formatter = Formatters::BlueskyFormatter.new(
    source_name: 'Test',
    show_platform: true
  )
  
  # Fetch posts
  puts "Fetching posts..."
  posts = adapter.fetch_posts(limit: 30)
  puts "✅ Fetched #{posts.count} posts"
  
  # Separate by type for focused testing
  regular_posts = posts.reject { |p| p.is_repost || p.is_quote }
  reposts = posts.select(&:is_repost)
  quotes = posts.select(&:is_quote)
  
  # Test regular posts
  section("Regular Posts (#{regular_posts.count})")
  regular_posts.first(3).each_with_index do |post, idx|
    test_single_post(post, formatter, idx + 1)
  end
  
  # Test reposts
  section("Reposts (#{reposts.count})")
  if reposts.any?
    reposts.first(3).each_with_index do |post, idx|
      test_single_post(post, formatter, idx + 1)
    end
  else
    puts "(žádné reposty v tomto vzorku)"
  end
  
  # Test quotes
  section("Quote Posts (#{quotes.count})")
  if quotes.any?
    quotes.first(3).each_with_index do |post, idx|
      test_single_post(post, formatter, idx + 1)
    end
  else
    puts "(žádné quote posty v tomto vzorku)"
  end
  
  # Summary
  section("Summary")
  
  all_formatted = posts.map { |p| formatter.format(p) }
  
  over_limit = all_formatted.count { |f| f.length > 500 }
  avg_length = all_formatted.sum(&:length) / all_formatted.count.to_f
  max_length = all_formatted.max_by(&:length).length
  min_length = all_formatted.min_by(&:length).length
  
  puts "Total posts formatted: #{posts.count}"
  puts "Over 500 char limit:   #{over_limit} #{over_limit > 0 ? '⚠️' : '✅'}"
  puts "Average length:        #{avg_length.round(1)} chars"
  puts "Max length:            #{max_length} chars"
  puts "Min length:            #{min_length} chars"
  
  # Show any problematic posts
  if over_limit > 0
    puts
    puts "⚠️  Posts over limit:"
    all_formatted.each_with_index do |formatted, idx|
      if formatted.length > 500
        puts "  - Post #{idx + 1}: #{formatted.length} chars"
      end
    end
  end
end

def test_single_post(post, formatter, index)
  puts "#{index}. #{post_type_label(post)}"
  puts "   Original: @#{post.author.username}"
  puts "   Text (#{post.text.length} chars): #{post.text[0..60]}..."
  
  if post.is_repost && post.reposted_by
    puts "   Reposted by: @#{post.reposted_by}"
  end
  
  if post.is_quote && post.quoted_post
    puts "   Quoting: @#{post.quoted_post[:author]}"
  end
  
  puts
  
  # Format
  formatted = formatter.format(post)
  
  puts "   📤 FORMATTED OUTPUT:"
  puts "   " + "-" * 50
  
  # Show formatted output with line prefixes
  formatted.lines.each do |line|
    puts "   │ #{line.chomp}"
  end
  
  puts "   " + "-" * 50
  puts "   Length: #{char_count_status(formatted)}"
  puts
end

# ============================================
# Different formatter configurations test
# ============================================

def test_formatter_configs(handle)
  section("Formatter Configuration Variants")
  
  adapter = Adapters::BlueskyAdapter.new(handle: handle)
  posts = adapter.fetch_posts(limit: 5)
  
  # Pick one post of each type if available
  sample_post = posts.find { |p| !p.is_repost && !p.is_quote } || posts.first
  sample_repost = posts.find(&:is_repost)
  sample_quote = posts.find(&:is_quote)
  
  configs = [
    { name: "Default", source_name: nil, show_platform: true },
    { name: "With source name", source_name: "Zprávy", show_platform: true },
    { name: "No platform emoji", source_name: "News", show_platform: false },
    { name: "Minimal", source_name: nil, show_platform: false }
  ]
  
  [sample_post, sample_repost, sample_quote].compact.each do |post|
    puts "Testing #{post_type_label(post)}:"
    puts "Original text: #{post.text[0..50]}..."
    puts
    
    configs.each do |config|
      formatter = Formatters::BlueskyFormatter.new(
        source_name: config[:source_name],
        show_platform: config[:show_platform]
      )
      
      formatted = formatter.format(post)
      first_line = formatted.lines.first&.chomp || ""
      
      puts "  #{config[:name]}:"
      puts "    Header: #{first_line}"
      puts "    Length: #{formatted.length} chars"
    end
    
    puts
    separator('-', 50)
    puts
  end
end

# ============================================
# Main
# ============================================

if __FILE__ == $PROGRAM_NAME
  puts
  puts "🦋 Bluesky Formatter Test Suite"
  separator
  
  handle = ARGV[0] || 'nesestra.bsky.social'
  
  case ARGV[0]
  when '--configs'
    handle = ARGV[1] || 'nesestra.bsky.social'
    test_formatter_configs(handle)
  when '--help', '-h'
    puts "Usage:"
    puts "  ruby bin/test_bluesky_formatter.rb [handle]           # Test formatting"
    puts "  ruby bin/test_bluesky_formatter.rb --configs [handle] # Test config variants"
  else
    test_formatter(handle)
    
    puts
    puts "💡 Tip: Run with --configs to see different formatter configurations"
  end
end
