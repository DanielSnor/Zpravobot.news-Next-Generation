#!/usr/bin/env ruby
# frozen_string_literal: true

# End-to-end test: RSS → Format → Upload Media → Publish to Mastodon
# This tests the complete flow including media attachments

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require_relative '../lib/adapters/rss_adapter'
require_relative '../lib/formatters/rss_formatter'
require_relative '../lib/publishers/mastodon_publisher'
require 'yaml'

puts "=" * 80
puts "RSS → Mastodon Integration Test (WITH MEDIA)"
puts "=" * 80
puts ""

# 1. Load Mastodon config
config_path = File.expand_path('../config/mastodon.yml', __dir__)

unless File.exist?(config_path)
  puts "❌ Config file not found: #{config_path}"
  puts ""
  puts "Please create config/mastodon.yml from mastodon.yml.example"
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

# 5. Find post with media
post_with_media = posts.find { |p| p.has_media? }

if post_with_media
  puts "📝 Selected post WITH MEDIA:"
  post = post_with_media
else
  puts "📝 Selected post (no media available in test feed):"
  post = posts.first
end

puts "   Title: #{post.title}"
puts "   Author: #{post.author_name}"
puts "   URL: #{post.url}"
puts "   Has media: #{post.has_media?}"

if post.has_media?
  puts "   Media count: #{post.media.count}"
  post.media.each_with_index do |media, i|
    puts "     #{i + 1}. #{media.type}: #{media.url[0..60]}..."
  end
end

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

# 7. Upload media if present
media_ids = []

if post.has_media?
  puts "📤 Uploading media to Mastodon..."
  puts ""
  
  # Limit to first 4 images (Mastodon limit)
  post.media.select(&:image?).first(4).each_with_index do |media, i|
    puts "   #{i + 1}. Uploading: #{File.basename(media.url)}"
    
    begin
      media_id = publisher.upload_media_from_url(
        media.url,
        description: media.alt_text
      )
      
      if media_id
        media_ids << media_id
        puts "      ✅ Uploaded, ID: #{media_id}"
      else
        puts "      ⚠️  Skipped (download failed)"
      end
    rescue StandardError => e
      puts "      ❌ Upload failed: #{e.message}"
    end
    
    puts ""
  end
  
  if media_ids.any?
    puts "✅ Successfully uploaded #{media_ids.count} media file(s)"
  else
    puts "⚠️  No media uploaded (all failed)"
  end
  puts ""
end

# 8. Confirm publication
print "🚀 Publish to Mastodon"
print media_ids.any? ? " (with #{media_ids.count} media)? [y/N]: " : "? [y/N]: "
confirmation = gets.chomp.downcase

unless confirmation == 'y' || confirmation == 'yes'
  puts ""
  puts "❌ Publication cancelled"
  exit 0
end

puts ""

# 9. Publish!
puts "📤 Publishing to Mastodon..."
begin
  result = publisher.publish(
    formatted_text,
    media_ids: media_ids,
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
  
  if media_ids.any?
    puts "   Media attachments: #{media_ids.count}"
  end
  
  puts ""
  puts "🎉 End-to-end test PASSED (with media)!"
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
  puts "  Media IDs: #{media_ids.inspect}"
  puts "  Instance: #{config['instance_url']}"
  puts ""
  exit 1
end
