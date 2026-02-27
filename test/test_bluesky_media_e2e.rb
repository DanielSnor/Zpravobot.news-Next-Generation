#!/usr/bin/env ruby
# frozen_string_literal: true

# Bluesky to Mastodon E2E Test with Media Upload
# Uses existing MastodonPublisher.upload_media_from_url()
#
# Location: /app/data/zbnw-ng-test/bin/test_bluesky_media_e2e.rb
#
# URL Logic:
# - POST: No URL
# - REPOST: No URL
# - QUOTE: URL to quoted post
#
# Usage:
#   ruby bin/test_bluesky_media_e2e.rb              # Interactive mode
#   ruby bin/test_bluesky_media_e2e.rb --dry-run   # No actual publish

require_relative '../lib/adapters/bluesky_adapter'
require_relative '../lib/formatters/bluesky_formatter'
require_relative '../lib/publishers/mastodon_publisher'
require 'yaml'

# ==============================================================================
# Configuration
# ==============================================================================

BLUESKY_HANDLE = 'nesestra.bsky.social'
MASTODON_CONFIG_PATH = 'config/mastodon.yml'

# ==============================================================================
# Helper Methods
# ==============================================================================

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

def load_mastodon_config
  unless File.exist?(MASTODON_CONFIG_PATH)
    puts "❌ Mastodon config not found: #{MASTODON_CONFIG_PATH}"
    exit 1
  end
  
  config = YAML.load_file(MASTODON_CONFIG_PATH)
  
  {
    instance_url: config['instance_url'] || config[:instance_url],
    access_token: config['access_token'] || config[:access_token]
  }
end

def post_type_icon(post)
  if post.is_repost
    '🔁 REPOST'
  elsif post.is_quote
    '💬 QUOTE'
  else
    '📝 POST'
  end
end

def has_images?(post)
  post.media&.any? { |m| m.type == 'image' }
end

def image_count(post)
  return 0 unless post.media
  post.media.count { |m| m.type == 'image' }
end

def get_images(post)
  return [] unless post.media
  post.media.select { |m| m.type == 'image' }
end

# ==============================================================================
# Main Test
# ==============================================================================

def run_e2e_test(options = {})
  dry_run = options[:dry_run]
  
  puts
  puts "🦋📷 Bluesky → Mastodon E2E Test WITH MEDIA"
  separator
  
  section("Configuration")
  puts "Bluesky handle: @#{BLUESKY_HANDLE}"
  
  mastodon_config = load_mastodon_config
  puts "Mastodon instance: #{mastodon_config[:instance_url]}"
  puts "Mode: #{dry_run ? 'DRY RUN (no actual publish)' : 'LIVE'}"
  puts
  puts "URL Logic:"
  puts "  POST/REPOST: No URL"
  puts "  QUOTE: URL to quoted post"
  
  # ==========================================================================
  # Step 1: Initialize Components
  # ==========================================================================
  
  section("Step 1: Initialize Components")
  
  adapter = Adapters::BlueskyAdapter.new(
    handle: BLUESKY_HANDLE,
    filter: :no_replies,
    skip_replies: true,
    skip_reposts: false
  )
  puts "✅ BlueskyAdapter initialized"
  
  formatter = Formatters::BlueskyFormatter.new(
    source_name: 'Test',
    show_source_name: true,
    include_quoted_text: true
  )
  puts "✅ BlueskyFormatter initialized"
  
  publisher = nil
  unless dry_run
    publisher = Publishers::MastodonPublisher.new(
      instance_url: mastodon_config[:instance_url],
      access_token: mastodon_config[:access_token]
    )
    puts "✅ MastodonPublisher initialized"
    
    puts
    puts "🔐 Verifying Mastodon credentials..."
    account = publisher.verify_credentials
    puts "✅ Authenticated as: @#{account['username']}@#{URI.parse(mastodon_config[:instance_url]).host}"
  end
  
  # ==========================================================================
  # Step 2: Fetch Posts
  # ==========================================================================
  
  section("Step 2: Fetch Posts from Bluesky")
  
  puts "Fetching posts..."
  posts = adapter.fetch_posts(limit: 30)
  puts "✅ Fetched #{posts.count} posts"
  
  # Show posts with media indicator
  puts
  puts "Available posts:"
  posts.each_with_index do |post, idx|
    media_indicator = has_images?(post) ? " 📷#{image_count(post)}" : ""
    puts "  #{idx + 1}. #{post_type_icon(post)}#{media_indicator} - #{post.text[0..45]}..."
  end
  
  # Statistics
  puts
  puts "📊 Statistics:"
  puts "  Total: #{posts.count}"
  puts "  With images: #{posts.count { |p| has_images?(p) }}"
  puts "  POST: #{posts.count { |p| !p.is_repost && !p.is_quote }}"
  puts "  REPOST: #{posts.count { |p| p.is_repost }}"
  puts "  QUOTE: #{posts.count { |p| p.is_quote }}"
  
  # ==========================================================================
  # Step 3: Select Post
  # ==========================================================================
  
  section("Step 3: Select Post to Publish")
  
  print "Enter post number to publish (1-#{posts.count}) [default: 1]: "
  input = $stdin.gets&.strip
  
  selected_idx = if input.nil? || input.empty?
    0
  else
    input.to_i - 1
  end
  
  unless selected_idx >= 0 && selected_idx < posts.count
    puts "Invalid selection"
    return
  end
  
  selected_post = posts[selected_idx]
  
  puts
  puts "Selected: #{post_type_icon(selected_post)}"
  puts "Author: @#{selected_post.author.username}"
  puts "Text: #{selected_post.text[0..100]}..."
  puts "Images: #{image_count(selected_post)}"
  
  if selected_post.is_repost
    puts "Reposted by: @#{selected_post.reposted_by}"
  elsif selected_post.is_quote
    puts "Quoting: @#{selected_post.quoted_post&.dig(:author)}"
    puts "Quoted URL: #{selected_post.quoted_post&.dig(:url)}"
  end
  
  # ==========================================================================
  # Step 4: Download & Upload Media
  # ==========================================================================
  
  section("Step 4: Download & Upload Media")
  
  media_ids = []
  images = get_images(selected_post)
  
  if dry_run
    puts "🔸 DRY RUN - Skipping media upload"
    if images.any?
      puts "Would download and upload #{images.count} images:"
      images.each_with_index do |img, idx|
        puts "  #{idx + 1}. #{img.url[0..60]}..."
      end
    else
      puts "No images to upload"
    end
  else
    if images.any?
      puts "📥 Downloading and uploading #{images.count} images..."
      puts
      
      images.first(4).each_with_index do |img, idx|
        puts "  #{idx + 1}. #{img.url[0..60]}..."
        
        media_id = publisher.upload_media_from_url(img.url, description: img.alt_text)
        
        if media_id
          puts "     ✅ Uploaded: #{media_id}"
          media_ids << media_id
        else
          puts "     ❌ Upload failed"
        end
      end
      
      puts
      if media_ids.any?
        puts "✅ Uploaded #{media_ids.count}/#{images.count} images"
      else
        puts "⚠️ No images were uploaded successfully"
      end
    else
      puts "ℹ️ Post has no images to upload"
    end
  end
  
  # ==========================================================================
  # Step 5: Format for Mastodon
  # ==========================================================================
  
  section("Step 5: Format for Mastodon")
  
  formatted = formatter.format(selected_post)
  
  puts "Formatted output (#{formatted.length}/500 chars):"
  puts '-' * 50
  puts formatted
  puts '-' * 50
  
  if formatted.length > 500
    puts "❌ Text too long!"
    return
  else
    puts "✅ Length OK"
  end
  
  # Show URL logic explanation
  puts
  puts "📝 URL Logic applied:"
  if selected_post.is_quote
    puts "   QUOTE → URL to quoted post"
  elsif selected_post.is_repost
    puts "   REPOST → No URL"
  else
    puts "   POST → No URL"
  end
  
  # ==========================================================================
  # Step 6: Publish to Mastodon
  # ==========================================================================
  
  section("Step 6: Publish to Mastodon")
  
  if dry_run
    puts "🔸 DRY RUN - Not publishing"
    puts "Would publish to: #{mastodon_config[:instance_url]}"
    puts "With #{images.count} media attachments"
    puts
    puts "To actually publish, run without --dry-run flag"
  else
    media_info = media_ids.any? ? " with #{media_ids.count} images" : ""
    print "Publish this post#{media_info}? (y/N): "
    confirm = $stdin.gets&.strip&.downcase
    
    if confirm == 'y'
      puts
      puts "📤 Publishing to Mastodon..."
      
      result = publisher.publish(formatted, media_ids: media_ids)
      
      puts "✅ Published successfully!"
      puts
      puts "🔗 View your post:"
      puts "   #{result['url']}"
      puts
      puts "Post ID: #{result['id']}"
      puts "Media attachments: #{result['media_attachments']&.count || 0}"
    else
      puts "Cancelled"
      return
    end
  end
  
  # ==========================================================================
  # Result
  # ==========================================================================
  
  section("Result")
  puts "✅ End-to-end test completed successfully!"
end

# ==============================================================================
# Entry Point
# ==============================================================================

options = {
  dry_run: ARGV.include?('--dry-run')
}

run_e2e_test(options)
