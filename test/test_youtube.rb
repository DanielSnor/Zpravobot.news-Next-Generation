#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script for YouTubeAdapter
# Location: /app/data/zbnw-ng-test/bin/test_youtube.rb
#
# Usage:
#   bundle exec ruby bin/test_youtube.rb                  # Test all channels
#   bundle exec ruby bin/test_youtube.rb @DVTVvideo       # Test specific handle
#   bundle exec ruby bin/test_youtube.rb UCFb-u3ISt99gxZ9TxIQW7UA  # Test by ID

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require_relative '../lib/adapters/youtube_adapter'

# Test channels
TEST_CHANNELS = [
  { handle: '@DVTVvideo', name: 'DVTV' },
  { handle: '@EisKing', name: 'EisKing TV' },
  { handle: '@tomasrajchl', name: 'Tomáš Rajchl' },
  { handle: '@bombyktyci', name: 'Bombyk tyci' },
  { handle: '@publiqsk', name: 'Publiq SK' }
].freeze

# Known channel IDs (for faster testing)
KNOWN_IDS = {
  '@DVTVvideo' => 'UCFb-u3ISt99gxZ9TxIQW7UA',
  '@EisKing' => 'UCY0cBZ3sn2dk8GwMkwSmZ8w',
  '@tomasrajchl' => 'UCr9CKt8VMEhxzqxmJ6F3mxw',
  '@bombyktyci' => 'UCtHorOdGGLs6qdAnzlfx8UA',
  '@publiqsk' => 'UCS8taf0ZZAXyEbsr6zHf2og'
}.freeze

def test_channel(config)
  puts "\n#{'=' * 70}"
  puts "Testing: #{config[:name] || config[:handle] || config[:channel_id]}"
  puts '=' * 70
  
  # Use known ID if available for speed
  if config[:handle] && KNOWN_IDS[config[:handle]]
    config = config.merge(channel_id: KNOWN_IDS[config[:handle]])
    config.delete(:handle)
  end
  
  adapter = Adapters::YouTubeAdapter.new(config)
  adapter.validate_config!
  
  puts "  Feed URL: #{adapter.feed_url}"
  
  posts = adapter.fetch_posts
  
  puts "\n  📊 Results:"
  puts "     Posts fetched: #{posts.count}"
  
  # Stats
  with_desc = posts.count { |p| p.text && !p.text.empty? }
  with_media = posts.count { |p| p.media && !p.media.empty? }
  shorts = posts.count { |p| p.raw[:is_short] }
  
  puts "     With description: #{with_desc}/#{posts.count}"
  puts "     With thumbnail: #{with_media}/#{posts.count}"
  puts "     Shorts: #{shorts}/#{posts.count}"
  
  # Sample post
  if posts.any?
    post = posts.first
    puts "\n  📝 Sample Post (most recent):"
    puts "     Title: #{truncate(post.title, 55)}"
    puts "     URL: #{post.url}"
    puts "     Video ID: #{post.id}"
    puts "     Published: #{post.published_at}"
    puts "     Author: #{post.author.full_name}"
    puts "     Description: #{truncate(post.text, 70)}"
    
    if post.media&.first
      thumb = post.media.first
      puts "     Thumbnail: #{thumb.url}"
      puts "     Thumb info: #{thumb.alt_text}" if thumb.alt_text
    end
    
    if post.raw[:views]
      puts "     Views: #{format_number(post.raw[:views])}"
    end
    
    # Mastodon preview
    show_mastodon_preview(post)
  end
  
  true
rescue StandardError => e
  puts "  ❌ Error: #{e.message}"
  puts e.backtrace.first(3).map { |l| "     #{l}" }.join("\n")
  false
end

def show_mastodon_preview(post)
  puts "\n  📱 Mastodon Preview:"
  puts "  ┌────────────────────────────────────────────────────────────"
  puts "  │ #{post.author.full_name} 📺:"
  puts "  │ #{truncate(post.title, 54)}"
  
  if post.text && !post.text.empty?
    puts "  │"
    post.text.split(/\n/).first(2).each do |line|
      puts "  │ #{truncate(line.strip, 54)}"
    end
    puts "  │ ..." if post.text.split(/\n/).size > 2
  end
  
  puts "  │"
  puts "  │ 🔗 #{post.url}"
  
  if post.media&.first
    puts "  │"
    puts "  │ [📷 Thumbnail attached]"
  end
  
  if post.raw[:views]
    puts "  │ 👁 #{format_number(post.raw[:views])} views"
  end
  
  puts "  └────────────────────────────────────────────────────────────"
end

def truncate(str, max)
  return '(empty)' if str.nil? || str.to_s.empty?
  s = str.to_s.gsub(/\s+/, ' ').strip
  s.length > max ? "#{s[0...max]}…" : s
end

def format_number(num)
  return 'N/A' unless num
  num.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
end

# Main
puts <<~HEADER
  ╔══════════════════════════════════════════════════════════════════════╗
  ║              YouTube Adapter Test - Varianta B                       ║
  ║         Full media:group extraction (description, thumbnail)         ║
  ╚══════════════════════════════════════════════════════════════════════╝
  
  Time: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}
  
HEADER

if ARGV.empty?
  # Test all channels
  results = TEST_CHANNELS.map do |ch|
    [ch[:name], test_channel(ch)]
  end
  
  puts "\n#{'=' * 70}"
  puts "SUMMARY"
  puts '=' * 70
  
  passed = results.count { |_, ok| ok }
  results.each { |name, ok| puts "  #{ok ? '✓' : '✗'} #{name}" }
  
  puts "\n  Total: #{passed}/#{results.count} passed"
else
  # Test specific channel
  arg = ARGV[0]
  
  config = if arg.start_with?('@')
             { handle: arg, name: arg }
           elsif arg.start_with?('UC') && arg.length == 24
             { channel_id: arg, name: arg }
           else
             puts "Invalid argument: #{arg}"
             puts "Use @handle or channel ID (UC...)"
             exit 1
           end
  
  test_channel(config)
end

puts "\n#{'=' * 70}"
puts "Test complete!"
puts '=' * 70
