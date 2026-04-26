#!/usr/bin/env ruby
# frozen_string_literal: true

# Test Post model attribute defaults and methods (MODEL-1)
# Run: ruby test/test_post_model.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/models/post'
require_relative '../lib/models/author'
require_relative '../lib/models/media'

puts '=' * 60
puts 'Post Model Tests'
puts '=' * 60
puts

$passed = 0
$failed = 0

def test(name, expected, actual)
  if expected == actual
    puts "  \e[32m\u2713\e[0m #{name}"
    $passed += 1
  else
    puts "  \e[31m\u2717\e[0m #{name}"
    puts "    Expected: #{expected.inspect}"
    puts "    Actual:   #{actual.inspect}"
    $failed += 1
  end
end

def section(title)
  puts
  puts "--- #{title} ---"
end

AUTHOR = Author.new(username: 'testuser', display_name: 'Test User')

def minimal_post(**overrides)
  Post.new(
    platform: 'twitter',
    id: '123',
    url: 'https://example.com/post/123',
    text: 'Hello world',
    published_at: Time.now,
    author: AUTHOR,
    **overrides
  )
end

# =============================================================================
# Attribute defaults
# =============================================================================
section('Attribute defaults')

p = minimal_post
test('is_repost defaults false',    false, p.is_repost)
test('is_quote defaults false',     false, p.is_quote)
test('is_reply defaults false',     false, p.is_reply)
test('is_thread_post defaults false', false, p.is_thread_post)
test('has_video defaults false',    false, p.has_video)
test('title defaults nil',          nil,   p.title)
test('reposted_by defaults nil',    nil,   p.reposted_by)
test('quoted_post defaults nil',    nil,   p.quoted_post)
test('reply_to defaults nil',       nil,   p.reply_to)
test('raw defaults nil',            nil,   p.raw)
test('poll_data defaults nil',      nil,   p.poll_data)
test('media defaults []',           [],    p.media)
test('reply_to_handle defaults nil', nil,  p.reply_to_handle)
test('thread_context defaults nil', nil,   p.thread_context)

# =============================================================================
# Methods always available
# =============================================================================
section('Methods always available')

test('has_media? false for empty media', false, p.has_media?)
test('has_video? false when has_video=false', false, p.has_video?)
test('has_poll? false when poll_data nil', false, p.has_poll?)
test('has_title? false when title nil', false, p.has_title?)
test('has_text? true', true, p.has_text?)
test('empty? false (has text)', false, p.empty?)
test('rss? false for twitter', false, p.rss?)
test('twitter? true', true, p.twitter?)
test('social? true', true, p.social?)
test('content? false', false, p.content?)

# =============================================================================
# has_media? with actual media
# =============================================================================
section('has_media? with media')

pm = minimal_post(media: [Media.new(type: 'image', url: 'https://img.example.com/pic.jpg')])
test('has_media? true with 1 media', true, pm.has_media?)
test('media count', 1, pm.media.length)

# =============================================================================
# has_video?
# =============================================================================
section('has_video?')

pv = minimal_post(has_video: true)
test('has_video? true when has_video=true', true, pv.has_video?)
test('has_video attribute', true, pv.has_video)

# =============================================================================
# Mutable attributes
# =============================================================================
section('Mutable attributes')

pm2 = minimal_post
pm2.is_repost = true
test('is_repost mutable', true, pm2.is_repost)
pm2.raw = { force_read_more: true }
test('raw mutable', true, pm2.raw[:force_read_more])
pm2.has_video = true
test('has_video mutable', true, pm2.has_video)

# =============================================================================
# Author
# =============================================================================
section('Author')

test('author.username', 'testuser', p.author.username)
test('author.handle', '@testuser', p.author.handle)
test('author_username helper', 'testuser', p.author_username)

# =============================================================================
# platform
# =============================================================================
section('Platform')

test('platform stored as lowercase', 'twitter', p.platform)
pr = minimal_post(platform: 'RSS')
test('rss? case-insensitive', true, pr.rss?)

# =============================================================================
section('Summary')
# done below

puts
puts '=' * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts '=' * 60

exit($failed == 0 ? 0 : 1)
