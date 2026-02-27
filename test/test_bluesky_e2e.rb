#!/usr/bin/env ruby
# frozen_string_literal: true

# End-to-end test: Bluesky → Format → Publish to Mastodon
# Tests the complete pipeline from fetching Bluesky posts to publishing on Mastodon
#
# Location: /app/data/zbnw-ng-test/bin/test_bluesky_e2e.rb
#
# Usage:
#   ruby bin/test_bluesky_e2e.rb                           # Interactive mode
#   ruby bin/test_bluesky_e2e.rb --dry-run                 # Don't actually publish
#   ruby bin/test_bluesky_e2e.rb --handle user.bsky.social # Specific handle

require_relative '../lib/adapters/bluesky_adapter'
require_relative '../lib/formatters/bluesky_formatter'
require_relative '../lib/publishers/mastodon_publisher'

# ============================================
# Configuration
# ============================================

# Mastodon credentials - UPDATE THESE or use config file
MASTODON_CONFIG = {
  instance_url: ENV['MASTODON_INSTANCE'] || 'https://zpravobot.news',
  access_token: ENV['MASTODON_TOKEN'] or abort('Set MASTODON_TOKEN env variable')
}.freeze

# Default Bluesky handle for testing
DEFAULT_HANDLE = 'nesestra.bsky.social'

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

def truncate(text, max = 60)
  return '' if text.nil? || text.empty?
  text.length > max ? "#{text[0...max]}..." : text
end

# ============================================
# Main Test
# ============================================

def run_e2e_test(handle:, dry_run: false)
  section("Bluesky → Mastodon End-to-End Test")
  
  puts "Bluesky handle: @#{handle}"
  puts "Mastodon instance: #{MASTODON_CONFIG[:instance_url]}"
  puts "Mode: #{dry_run ? 'DRY RUN (no actual publish)' : 'LIVE'}"
  puts
  
  # Step 1: Initialize components
  section("Step 1: Initialize Components")
  
  adapter = Adapters::BlueskyAdapter.new(
    handle: handle,
    filter: :no_replies,
    skip_replies: true,
    skip_reposts: false
  )
  puts "✅ BlueskyAdapter initialized"
  
  formatter = Formatters::BlueskyFormatter.new(
    source_name: 'Test',
    show_platform: true
  )
  puts "✅ BlueskyFormatter initialized"
  
  unless dry_run
    publisher = Publishers::MastodonPublisher.new(
      instance_url: MASTODON_CONFIG[:instance_url],
      access_token: MASTODON_CONFIG[:access_token]
    )
    puts "✅ Publishers::MastodonPublisher initialized"
    
    # Verify credentials
    puts
    puts "🔐 Verifying Mastodon credentials..."
    account = publisher.verify_credentials
    puts "✅ Authenticated as: @#{account['username']}@#{URI.parse(MASTODON_CONFIG[:instance_url]).host}"
  end
  
  # Step 2: Fetch posts from Bluesky
  section("Step 2: Fetch Posts from Bluesky")
  
  puts "Fetching posts..."
  posts = adapter.fetch_posts(limit: 30)
  puts "✅ Fetched #{posts.count} posts"
  
  if posts.empty?
    puts "❌ No posts found!"
    return false
  end
  
  # Show available posts
  puts
  puts "Available posts:"
  posts.each_with_index do |post, idx|
    puts "  #{idx + 1}. #{post_type_label(post)} - #{truncate(post.text, 50)}"
  end
  
  # Step 3: Select a post
  section("Step 3: Select Post to Publish")
  
  # Try to find one of each type for testing
  regular_post = posts.find { |p| !p.is_repost && !p.is_quote }
  repost = posts.find(&:is_repost)
  quote = posts.find(&:is_quote)
  
  puts "Found post types:"
  puts "  Regular post: #{regular_post ? '✅' : '❌'}"
  puts "  Repost: #{repost ? '✅' : '❌'}"
  puts "  Quote: #{quote ? '✅' : '❌'}"
  puts
  
  # Let user choose or pick first available
  print "Enter post number to publish (1-#{posts.count}) [default: 1]: "
  
  choice = $stdin.gets&.strip
  post_index = choice.to_i > 0 ? choice.to_i - 1 : 0
  post_index = [post_index, posts.count - 1].min
  
  selected_post = posts[post_index]
  
  puts
  puts "Selected: #{post_type_label(selected_post)}"
  puts "Author: @#{selected_post.author.username}"
  puts "Text: #{selected_post.text[0..100]}..."
  puts "URL: #{selected_post.url}"
  
  if selected_post.is_repost
    puts "Reposted by: @#{selected_post.reposted_by}"
  end
  
  if selected_post.is_quote && selected_post.quoted_post
    puts "Quoting: @#{selected_post.quoted_post[:author]}"
  end
  
  # Step 4: Format for Mastodon
  section("Step 4: Format for Mastodon")
  
  formatted = formatter.format(selected_post)
  
  puts "Formatted output (#{formatted.length}/500 chars):"
  puts "-" * 50
  puts formatted
  puts "-" * 50
  
  if formatted.length > 500
    puts "⚠️  WARNING: Text exceeds 500 character limit!"
  else
    puts "✅ Length OK"
  end
  
  # Step 5: Publish (or dry run)
  section("Step 5: Publish to Mastodon")
  
  if dry_run
    puts "🔸 DRY RUN - Not publishing"
    puts "Would publish to: #{MASTODON_CONFIG[:instance_url]}"
    puts
    puts "To actually publish, run without --dry-run flag"
    return true
  end
  
  # Confirm before publishing
  print "Publish this post? (y/N): "
  confirm = $stdin.gets&.strip&.downcase
  
  unless confirm == 'y' || confirm == 'yes'
    puts "❌ Cancelled by user"
    return false
  end
  
  puts
  puts "📤 Publishing to Mastodon..."
  
  begin
    result = publisher.publish(
      formatted,
      visibility: 'unlisted'  # Use unlisted for testing
    )
    
    puts "✅ Published successfully!"
    puts
    puts "🔗 View your post:"
    puts "   #{result['url']}"
    puts
    puts "Post ID: #{result['id']}"
    
    true
  rescue StandardError => e
    puts "❌ Publish failed: #{e.message}"
    puts e.backtrace.first(3).join("\n") if ENV['DEBUG']
    false
  end
end

# ============================================
# Command Line Interface
# ============================================

if __FILE__ == $PROGRAM_NAME
  puts
  puts "🦋 Bluesky → Mastodon End-to-End Test"
  separator
  
  # Parse arguments
  dry_run = ARGV.include?('--dry-run')
  handle = DEFAULT_HANDLE
  
  ARGV.each_with_index do |arg, idx|
    if arg == '--handle' && ARGV[idx + 1]
      handle = ARGV[idx + 1]
    elsif arg.include?('.') && !arg.start_with?('--')
      handle = arg
    end
  end
  
  if ARGV.include?('--help') || ARGV.include?('-h')
    puts "Usage:"
    puts "  ruby bin/test_bluesky_e2e.rb [options] [handle]"
    puts
    puts "Options:"
    puts "  --dry-run       Don't actually publish, just show what would happen"
    puts "  --handle USER   Bluesky handle to fetch from"
    puts "  --help, -h      Show this help"
    puts
    puts "Examples:"
    puts "  ruby bin/test_bluesky_e2e.rb                      # Interactive, default handle"
    puts "  ruby bin/test_bluesky_e2e.rb --dry-run            # Test without publishing"
    puts "  ruby bin/test_bluesky_e2e.rb nesestra.bsky.social # Specific handle"
    puts
    puts "Environment variables:"
    puts "  MASTODON_INSTANCE  - Mastodon instance URL"
    puts "  MASTODON_TOKEN     - Mastodon access token"
    exit 0
  end
  
  success = run_e2e_test(handle: handle, dry_run: dry_run)
  
  section("Result")
  if success
    puts "✅ End-to-end test completed successfully!"
  else
    puts "❌ Test failed or was cancelled"
  end
  
  exit(success ? 0 : 1)
end
