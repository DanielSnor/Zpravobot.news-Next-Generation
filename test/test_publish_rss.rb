#!/usr/bin/env ruby
# frozen_string_literal: true

# End-to-end test: RSS → Format → Publish to Mastodon
# This is the REAL test - getting content from RSS to Mastodon

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require_relative '../lib/adapters/rss_adapter'
require_relative '../lib/formatters/rss_formatter'
require_relative '../lib/publishers/mastodon_publisher'
require 'yaml'

puts "=" * 80
puts "RSS → Mastodon Integration Test"
puts "=" * 80
puts ""

# 1. Load Mastodon config
config_path = File.expand_path('../config/mastodon.yml', __dir__)

unless File.exist?(config_path)
  puts "❌ Config file not found: #{config_path}"
  puts ""
  puts "Please create config/mastodon.yml from mastodon.yml.example:"
  puts "  cp config/mastodon.yml.example config/mastodon.yml"
  puts "  # Edit and add your access token"
  exit 1
end

config = YAML.load_file(config_path)

# 2. Initialize components
puts "📡 Initializing components..."
puts ""

rss_adapter = Adapters::RssAdapter.new(
  feed_url: "file://#{File.expand_path('../test/fixtures/ct24_test.rss', __dir__)}",
  source_name: 'ct24_test'
)

formatter = RssFormatter.new(
  include_title: true,
  move_url_to_end: true,
  max_length: 500
)

publisher = MastodonPublisher.new(
  instance_url: config['instance_url'],
  access_token: config['access_token']
)

# 3. Verify Mastodon credentials
puts "🔐 Verifying Mastodon credentials..."
begin
  account = publisher.verify_credentials
  puts "   Authenticated as: @#{account['username']}"
  puts "   Instance: #{config['instance_url']}"
  puts ""
rescue StandardError => e
  puts "❌ Authentication failed: #{e.message}"
  puts ""
  puts "Please check your config/mastodon.yml"
  exit 1
end

# 4. Fetch RSS posts
puts "📰 Fetching RSS posts..."
posts = rss_adapter.fetch_posts
puts "   Found #{posts.count} posts"
puts ""

if posts.empty?
  puts "❌ No posts found in RSS feed"
  exit 1
end

# 5. Select post to publish
post = posts.first
puts "📝 Selected post:"
puts "   Title: #{post.title}"
puts "   Author: #{post.author_name}"
puts "   URL: #{post.url}"
puts ""

# 6. Format for Mastodon
puts "✨ Formatting for Mastodon..."
formatted_text = formatter.format(post)
puts ""
puts "-" * 80
puts formatted_text
puts "-" * 80
puts ""
puts "   Length: #{formatted_text.length} chars (max 500)"
puts ""

# 7. Confirm publication
print "🚀 Publish to Mastodon? [y/N]: "
confirmation = gets.chomp.downcase

unless confirmation == 'y' || confirmation == 'yes'
  puts ""
  puts "❌ Publication cancelled"
  exit 0
end

puts ""

# 8. Publish!
puts "📤 Publishing to Mastodon..."
begin
  result = publisher.publish(
    formatted_text,
    visibility: config.dig('publishing', 'visibility') || 'public'
  )
  
  puts ""
  puts "=" * 80
  puts "✅ SUCCESS! Post published to Mastodon"
  puts "=" * 80
  puts ""
  puts "   Post URL: #{result['url']}"
  puts "   Post ID: #{result['id']}"
  puts "   Created: #{result['created_at']}"
  puts ""
  puts "🎉 End-to-end test PASSED!"
  puts ""
  
rescue StandardError => e
  puts ""
  puts "=" * 80
  puts "❌ FAILED to publish"
  puts "=" * 80
  puts ""
  puts "Error: #{e.message}"
  puts ""
  puts "Debug info:"
  puts "  Text length: #{formatted_text.length}"
  puts "  Instance: #{config['instance_url']}"
  puts ""
  exit 1
end
