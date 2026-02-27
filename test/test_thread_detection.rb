#!/usr/bin/env ruby
# frozen_string_literal: true

# Thread Detection Test Script for Zpravobot NG
# Location: /app/data/zbnw-ng/bin/test_thread_detection.rb
#
# Usage:
#   ruby bin/test_thread_detection.rb [handle] [nitter_instance]
#
# Examples:
#   ruby bin/test_thread_detection.rb ct24zive
#   ruby bin/test_thread_detection.rb Lord_of_war_95 http://xn.zpravobot.news:8080

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require_relative '../lib/adapters/twitter_adapter'
require_relative '../lib/adapters/twitter_thread_fetcher'
require_relative '../lib/formatters/twitter_formatter'
require_relative '../lib/models/post'
require_relative '../lib/models/author'
require_relative '../lib/models/media'

class ThreadDetectionTest
  def initialize(handle:, nitter_instance: nil)
    @handle = handle
    @nitter_instance = nitter_instance || 'http://xn.zpravobot.news:8080'
    
    @adapter = Adapters::TwitterAdapter.new(
      handle: @handle,
      nitter_instance: @nitter_instance
    )
    
    @thread_fetcher = Adapters::TwitterThreadFetcher.new(
      handle: @handle,
      nitter_instance: @nitter_instance,
      use_cache: false  # Disable cache for testing
    )
    
    @formatter = Formatters::TwitterFormatter.new(
      source_name: @handle,
      thread_handling: {
        show_indicator: true,
        indicator_position: 'end'
      }
    )
  end

  def run
    puts "=" * 70
    puts "Thread Detection Test for @#{@handle}"
    puts "Nitter Instance: #{@nitter_instance}"
    puts "=" * 70
    puts

    # Phase 1: Fetch posts via RSS
    puts "📡 Phase 1: Fetching RSS feed..."
    posts = @adapter.fetch_posts(limit: 20)
    puts "   Found #{posts.length} posts"
    puts

    # Analyze posts
    stats = analyze_posts(posts)
    print_stats(stats)

    # Show thread posts
    thread_posts = posts.select(&:is_thread_post)
    if thread_posts.any?
      puts "\n🧵 Thread Posts Detected (Phase 1 - RSS):"
      puts "-" * 50
      
      thread_posts.each_with_index do |post, idx|
        puts "\n[#{idx + 1}] #{post.url}"
        puts "    Reply to: @#{post.reply_to_handle}"
        puts "    Text: #{truncate(post.text, 100)}"
        
        # Phase 2: Fetch thread context (optional)
        if ENV['FETCH_CONTEXT'] == 'true'
          puts "\n    📥 Fetching thread context (Phase 2)..."
          context = @thread_fetcher.fetch_thread_context(post.url)
          post.thread_context = context
          
          puts "    Position: #{context[:position]}/#{context[:total]}"
          puts "    Before: #{context[:before].length} tweets"
          puts "    After: #{context[:after].length} tweets"
        end
        
        # Format output
        puts "\n    📝 Formatted output:"
        formatted = @formatter.format(post)
        puts "    " + formatted.gsub("\n", "\n    ")
      end
    else
      puts "\n✅ No thread posts detected in recent feed"
    end

    # Show sample of other post types
    puts "\n\n📊 Sample of Other Post Types:"
    puts "-" * 50
    
    show_samples(posts)

    puts "\n" + "=" * 70
    puts "Test complete!"
  end

  private

  def analyze_posts(posts)
    {
      total: posts.length,
      regular: posts.count { |p| !p.is_repost && !p.is_quote && !p.is_reply },
      reposts: posts.count(&:is_repost),
      quotes: posts.count(&:is_quote),
      replies: posts.count(&:is_reply),
      thread_posts: posts.count(&:is_thread_post),
      external_replies: posts.count { |p| p.is_reply && !p.is_thread_post }
    }
  end

  def print_stats(stats)
    puts "📊 Post Statistics:"
    puts "-" * 30
    puts "   Total posts:      #{stats[:total]}"
    puts "   Regular posts:    #{stats[:regular]}"
    puts "   Reposts (RT):     #{stats[:reposts]}"
    puts "   Quote tweets:     #{stats[:quotes]}"
    puts "   All replies:      #{stats[:replies]}"
    puts "   ├─ Self-replies:  #{stats[:thread_posts]} (threads)"
    puts "   └─ External:      #{stats[:external_replies]}"
  end

  def show_samples(posts)
    # Regular post
    regular = posts.find { |p| !p.is_repost && !p.is_quote && !p.is_reply }
    if regular
      puts "\n[Regular Post]"
      puts "   #{truncate(regular.text, 80)}"
    end

    # Repost
    repost = posts.find(&:is_repost)
    if repost
      puts "\n[Repost]"
      puts "   RT @#{repost.author.username}: #{truncate(repost.text, 60)}"
    end

    # Quote
    quote = posts.find(&:is_quote)
    if quote
      puts "\n[Quote Tweet]"
      puts "   #{truncate(quote.text, 80)}"
    end

    # External reply
    ext_reply = posts.find { |p| p.is_reply && !p.is_thread_post }
    if ext_reply
      puts "\n[External Reply]"
      puts "   Reply to @#{ext_reply.reply_to_handle}: #{truncate(ext_reply.text, 60)}"
    end
  end

  def truncate(text, max_length)
    return '' unless text
    text.length > max_length ? text[0...max_length] + '…' : text
  end
end

# ============================================
# Main
# ============================================

if __FILE__ == $0
  handle = ARGV[0] || 'ct24zive'
  nitter = ARGV[1] || 'http://xn.zpravobot.news:8080'
  
  test = ThreadDetectionTest.new(handle: handle, nitter_instance: nitter)
  test.run
end
