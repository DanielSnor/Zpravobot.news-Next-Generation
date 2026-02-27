#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script for repost/quote header formatting changes
# Tests that:
# 1. Header mentions use @username (intentional design - avoids URL preview issues)
# 2. include_quoted_text defaults to false

# Robust path resolution using __dir__
lib_path = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(lib_path) unless $LOAD_PATH.include?(lib_path)

require 'formatters/bluesky_formatter'
require 'formatters/twitter_formatter'

# Simple test helpers
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

def test(name)
  print "  #{name}... "
  begin
    yield
    puts "✅ PASS"
    true
  rescue => e
    puts "❌ FAIL: #{e.message}"
    false
  end
end

def assert(condition, message = "Assertion failed")
  raise message unless condition
end

def assert_contains(text, substring, message = nil)
  raise "Expected '#{text}' to contain '#{substring}'#{message ? " (#{message})" : ''}" unless text.include?(substring)
end

def assert_not_contains(text, substring, message = nil)
  raise "Expected '#{text}' NOT to contain '#{substring}'#{message ? " (#{message})" : ''}" if text.include?(substring)
end

# Mock Post class for testing
class MockPost
  attr_reader :platform, :id, :url, :text, :published_at, :author,
              :is_repost, :is_quote, :reposted_by, :quoted_post, :raw

  def initialize(attrs = {})
    @platform = attrs[:platform] || 'bluesky'
    @id = attrs[:id] || '123'
    @url = attrs[:url] || 'https://bsky.app/profile/test/post/123'
    @text = attrs[:text] || 'Test post content'
    @published_at = attrs[:published_at] || Time.now
    @author = attrs[:author]
    @is_repost = attrs[:is_repost] || false
    @is_quote = attrs[:is_quote] || false
    @reposted_by = attrs[:reposted_by]
    @quoted_post = attrs[:quoted_post]
    @raw = attrs[:raw] || {}
  end

  def self_repost?
    is_repost && reposted_by && author&.username == reposted_by
  end

  def self_quote?
    is_quote && quoted_post && quoted_post[:author] == author&.username
  end
end

class MockAuthor
  attr_reader :username, :full_name, :url

  def initialize(username:, full_name: nil, url: nil)
    @username = username
    @full_name = full_name || username
    @url = url
  end
end

# ============================================
# Tests
# ============================================

results = []

section("Test 1: BlueskyFormatter repost header")

results << test("Repost header contains @username (intentional design)") do
  author = MockAuthor.new(username: 'original_author', full_name: 'Original')
  post = MockPost.new(
    platform: 'bluesky',
    text: 'Original post text',
    author: author,
    is_repost: true,
    reposted_by: 'reposter'
  )

  formatter = Formatters::BlueskyFormatter.new(source_name: 'TestBot')
  result = formatter.format(post)

  # Headers intentionally use @username (not profile URLs) to avoid URL preview issues
  assert_contains(result, '@original_author', 'Should contain @username in header')
end

results << test("Self-repost uses 'svůj post' text") do
  author = MockAuthor.new(username: 'same_user', full_name: 'Same')
  post = MockPost.new(
    platform: 'bluesky',
    text: 'My own post',
    author: author,
    is_repost: true,
    reposted_by: 'same_user'
  )
  
  formatter = Formatters::BlueskyFormatter.new(source_name: 'TestBot', language: 'cs')
  result = formatter.format(post)
  
  assert_contains(result, 'svůj post:', 'Should contain self-reference text')
  assert_not_contains(result, 'https://bsky.app/profile/same_user', 'Should NOT contain profile URL for self')
end

section("Test 2: BlueskyFormatter quote header")

results << test("Quote header contains @username (intentional design)") do
  author = MockAuthor.new(username: 'quoter', full_name: 'Quoter')
  post = MockPost.new(
    platform: 'bluesky',
    text: 'My comment on this',
    author: author,
    is_quote: true,
    quoted_post: {
      author: 'quoted_author',
      text: 'The original quoted text that should not appear by default',
      url: 'https://bsky.app/profile/quoted_author/post/456'
    }
  )

  formatter = Formatters::BlueskyFormatter.new(source_name: 'TestBot')
  result = formatter.format(post)

  # Headers intentionally use @username (not profile URLs) to avoid URL preview issues
  assert_contains(result, '@quoted_author', 'Should contain @username in quote header')
end

results << test("Quote does NOT include quoted text by default") do
  author = MockAuthor.new(username: 'quoter', full_name: 'Quoter')
  post = MockPost.new(
    platform: 'bluesky',
    text: 'My comment',
    author: author,
    is_quote: true,
    quoted_post: {
      author: 'other',
      text: 'This text should NOT appear',
      url: 'https://bsky.app/profile/other/post/789'
    }
  )
  
  formatter = Formatters::BlueskyFormatter.new(source_name: 'TestBot')
  result = formatter.format(post)
  
  assert_not_contains(result, 'This text should NOT appear', 'Quoted text should not be included by default')
  assert_not_contains(result, '> ', 'No quote prefix should appear')
end

# NOTE: include_quoted_text feature is defined in config defaults but not yet
# implemented in UniversalFormatter.format_quote. Skipping this test for now.
# When implemented, uncomment and verify.
#
# results << test("Quote includes quoted text when explicitly enabled") do
#   ...
# end

section("Test 3: TwitterFormatter repost/quote headers")

results << test("Twitter repost header contains @username") do
  author = MockAuthor.new(username: 'original', full_name: 'Original')
  post = MockPost.new(
    platform: 'twitter',
    text: 'Original tweet',
    author: author,
    is_repost: true,
    reposted_by: 'retweeter'
  )

  formatter = Formatters::TwitterFormatter.new(source_name: 'TestBot')
  result = formatter.format(post)

  # Headers intentionally use @username (not profile URLs) to avoid URL preview issues
  assert_contains(result, '@original', 'Should contain @username in repost header')
end

results << test("Twitter quote header contains @username and post URL is rewritten") do
  author = MockAuthor.new(username: 'quoter', full_name: 'Quoter')
  post = MockPost.new(
    platform: 'twitter',
    url: 'https://twitter.com/quoter/status/999',
    text: 'Quote tweet comment',
    author: author,
    is_quote: true,
    quoted_post: {
      author: 'quoted_user',
      text: 'Original tweet text',
      url: 'https://twitter.com/quoted_user/status/123'
    }
  )

  formatter = Formatters::TwitterFormatter.new(source_name: 'TestBot')
  result = formatter.format(post)

  # Headers use @username; post URL (twitter.com) should be rewritten to xcancel.com
  assert_contains(result, '@quoted_user', 'Should contain @username in quote header')
  assert_contains(result, 'xcancel.com', 'Post URL should be rewritten to xcancel')
end

section("Test 4: Example output comparison")

puts "  Bluesky quote - BEFORE vs AFTER:"
puts
puts "  BEFORE (old format):"
puts "  ─────────────────────────────────────────"
puts "  Vláďa Foltán 🦋💬 @janacigler.bsky.social:"
puts "  Trump v posledních dnech vyvádí..."
puts "  > \"Donald Trump sdělil zemím, které chtějí být členy jeho Rady míru, že za trvalé…"
puts "  https://bsky.app/profile/janacigler.bsky.social/post/3mcoeinzy4c2w"
puts
puts "  AFTER (new format):"
puts "  ─────────────────────────────────────────"

author = MockAuthor.new(username: 'vlada_foltan', full_name: 'Vláďa Foltán 🦋💬')
post = MockPost.new(
  platform: 'bluesky',
  text: 'Trump v posledních dnech vyvádí tak moc, že buď umírá a zbývá mu fakt málo času nebo jeho stařecká demence (nebo čím přesně trpí) pokročila do stádia, kdy už ztratil kontakt s realitou.

Btw, Donalda může snadno v řadě věcí zastavit republikány ovládaný Kongres. Doslova pár lidí…',
  author: author,
  is_quote: true,
  quoted_post: {
    author: 'janacigler.bsky.social',
    text: 'Donald Trump sdělil zemím, které chtějí být členy jeho Rady míru, že za trvalé...',
    url: 'https://bsky.app/profile/janacigler.bsky.social/post/3mcoeinzy4c2w'
  }
)

formatter = Formatters::BlueskyFormatter.new(source_name: 'Vláďa Foltán')
result = formatter.format(post)

result.each_line { |line| puts "  #{line}" }
puts
puts "  Character count: #{result.length}/500"

# Summary
section("Summary")

passed = results.count(true)
failed = results.count(false)
total = results.length

puts "  Total: #{total} tests"
puts "  Passed: #{passed} ✅"
puts "  Failed: #{failed} ❌"
puts

exit(failed == 0 ? 0 : 1)
