#!/usr/bin/env ruby
# frozen_string_literal: true

# End-to-end test: YouTube → Format → Publish to Mastodon
# Location: /app/data/zbnw-ng-test/bin/test_youtube_publish.rb
#
# Usage:
#   bundle exec ruby bin/test_youtube_publish.rb @DVTVvideo
#   bundle exec ruby bin/test_youtube_publish.rb @DVTVvideo --dry-run
#
# Required ENV or edit below:
#   MASTODON_INSTANCE - e.g., https://zpravobot.news
#   MASTODON_TOKEN    - access token

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require_relative '../lib/adapters/youtube_adapter'
require_relative '../lib/formatters/youtube_formatter'
require_relative '../lib/publishers/mastodon_publisher'

# Configuration - EDIT THESE or use ENV variables
MASTODON_INSTANCE = ENV['MASTODON_INSTANCE'] || 'https://zpravobot.news'
MASTODON_TOKEN = ENV['MASTODON_TOKEN'] or abort('Set MASTODON_TOKEN env variable')

# Known channel IDs for faster testing
KNOWN_IDS = {
  '@DVTVvideo' => 'UCFb-u3ISt99gxZ9TxIQW7UA',
  '@EisKing' => 'UCY0cBZ3sn2dk8GwMkwSmZ8w',
  '@tomasrajchl' => 'UCr9CKt8VMEhxzqxmJ6F3mxw',
  '@bombyktyci' => 'UCtHorOdGGLs6qdAnzlfx8UA',
  '@publiqsk' => 'UCS8taf0ZZAXyEbsr6zHf2og'
}.freeze

def main
  # Parse arguments
  if ARGV.empty? || ARGV[0] == '--help'
    puts "Usage: ruby bin/test_youtube_publish.rb @handle [--dry-run]"
    puts ""
    puts "Options:"
    puts "  --dry-run    Format and show preview, but don't publish"
    puts ""
    puts "Available test channels:"
    KNOWN_IDS.keys.each { |k| puts "  #{k}" }
    exit 0
  end

  handle = ARGV[0]
  dry_run = ARGV.include?('--dry-run')

  puts <<~HEADER
    ╔══════════════════════════════════════════════════════════════════════╗
    ║         YouTube → Mastodon Publish Test                              ║
    ╚══════════════════════════════════════════════════════════════════════╝
    
    Channel: #{handle}
    Instance: #{MASTODON_INSTANCE}
    Mode: #{dry_run ? 'DRY RUN (no publish)' : 'LIVE PUBLISH'}
    Time: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}
    
  HEADER

  # Step 1: Fetch from YouTube
  puts "=" * 70
  puts "Step 1: Fetching YouTube feed"
  puts "=" * 70

  channel_id = KNOWN_IDS[handle]
  unless channel_id
    puts "Unknown handle, will resolve..."
  end

  adapter = Adapters::YouTubeAdapter.new(
    channel_id: channel_id,
    handle: channel_id ? nil : handle,
    source_name: handle.sub('@', '')
  )
  adapter.validate_config!

  posts = adapter.fetch_posts
  
  if posts.empty?
    puts "❌ No posts found!"
    exit 1
  end

  puts "\n  Fetched #{posts.count} posts"

  # Select a post (prefer non-Short with good description)
  post = posts.find { |p| !p.raw[:is_short] && p.text && p.text.length > 50 }
  post ||= posts.first

  puts "\n  Selected post:"
  puts "    Title: #{truncate(post.title, 50)}"
  puts "    Type: #{post.raw[:is_short] ? 'Short' : 'Video'}"
  puts "    Has description: #{post.text && !post.text.empty? ? 'Yes' : 'No'}"
  puts "    Has thumbnail: #{post.media&.any? ? 'Yes' : 'No'}"

  # Step 2: Format for Mastodon
  puts "\n" + "=" * 70
  puts "Step 2: Formatting for Mastodon"
  puts "=" * 70

  formatter = Formatters::YouTubeFormatter.new(
    include_description: true,
    description_max_lines: 3,
    include_views: true
  )

  formatted_text = formatter.format(post)

  puts "\n  Formatted text (#{formatted_text.length}/500 chars):"
  puts "  " + "-" * 66
  formatted_text.each_line { |line| puts "  │ #{line.chomp}" }
  puts "  " + "-" * 66

  if dry_run
    puts "\n  🔶 DRY RUN - not publishing"
    puts "\n  To publish for real, run without --dry-run"
    exit 0
  end

  # Step 3: Upload thumbnail
  puts "\n" + "=" * 70
  puts "Step 3: Uploading thumbnail"
  puts "=" * 70

  publisher = Publishers::MastodonPublisher.new(
    instance_url: MASTODON_INSTANCE,
    access_token: MASTODON_TOKEN
  )

  # Verify credentials first
  account = publisher.verify_credentials
  puts "  Publishing as: @#{account['username']}"

  media_ids = []
  if post.media&.any?
    thumb = post.media.first
    puts "\n  Thumbnail URL: #{thumb.url}"
    
    media_id = publisher.upload_media_from_url(
      thumb.url,
      description: post.title  # Use title as alt text
    )
    
    if media_id
      media_ids << media_id
      puts "  ✅ Thumbnail uploaded, ID: #{media_id}"
    else
      puts "  ⚠️  Thumbnail upload failed, publishing without media"
    end
  end

  # Step 4: Publish to Mastodon
  puts "\n" + "=" * 70
  puts "Step 4: Publishing to Mastodon"
  puts "=" * 70

  result = publisher.publish(
    formatted_text,
    media_ids: media_ids,
    visibility: 'public'
  )

  puts "\n  🎉 SUCCESS!"
  puts "  Status URL: #{result['url']}"
  puts "  Status ID: #{result['id']}"

rescue StandardError => e
  puts "\n❌ Error: #{e.message}"
  puts e.backtrace.first(5).map { |l| "   #{l}" }.join("\n")
  exit 1
end

def truncate(str, max)
  return '(empty)' if str.nil? || str.to_s.empty?
  s = str.to_s.strip
  s.length > max ? "#{s[0...max]}…" : s
end

main
