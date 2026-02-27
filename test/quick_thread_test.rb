#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# QUICK BLUESKY THREAD TEST
# ============================================================
# Jednoduchý test pro ověření thread detekce na produkčním serveru.
#
# Použití:
#   cd /app/data/zbnw-ng
#   ruby quick_thread_test.rb vladafoltan.bsky.social
#
# Nebo v rails console / irb:
#   load 'quick_thread_test.rb'
#   QuickThreadTest.run('vladafoltan.bsky.social')
# ============================================================

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/adapters/bluesky_adapter'

module QuickThreadTest
  def self.run(handle, limit: 20)
    puts "=" * 60
    puts "🧪 Quick Bluesky Thread Test"
    puts "=" * 60
    puts "Handle: @#{handle}"
    puts

    # Test s filtrem :threads (posts_and_author_threads)
    puts "Fetching with filter :threads..."
    adapter = Adapters::BlueskyAdapter.new(
      handle: handle,
      filter: :threads,
      skip_replies: true  # Default - but should allow self-replies through
    )

    posts = adapter.fetch_posts(since: Time.now - 86400, limit: limit)

    puts "Received #{posts.length} posts"
    puts

    # Analyze posts
    normal = 0
    threads = 0
    external_replies = 0

    posts.each do |p|
      if p.is_reply
        if p.is_thread_post
          threads += 1
          puts "🧵 THREAD: #{p.text[0..60]}..."
          puts "   reply_to_handle: #{p.reply_to_handle}"
          puts "   url: #{p.url}"
          puts
        else
          external_replies += 1
          puts "↩️  REPLY: #{p.text[0..60]}..."
          puts "   (This should have been filtered - BUG if visible)"
          puts
        end
      else
        normal += 1
      end
    end

    puts "-" * 60
    puts "Summary:"
    puts "  Normal posts: #{normal}"
    puts "  Thread posts: #{threads}"
    puts "  External replies: #{external_replies}"
    puts

    if threads > 0
      puts "✅ Thread detection is working!"
    elsif external_replies > 0
      puts "⚠️  External replies found - check skip_replies setting"
    else
      puts "ℹ️  No replies found in recent posts"
    end

    puts "=" * 60
  end
end

# Run if executed directly
if __FILE__ == $0
  handle = ARGV[0] || 'vladafoltan.bsky.social'
  QuickThreadTest.run(handle)
end
