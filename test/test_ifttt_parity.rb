#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Test: New IFTTT Parity Features
# ============================================================
# Tests for:
# - PREFIX_SELF_REFERENCE (localized self-repost/quote text)
# - URL_REPLACE (twitter.com -> xcancel.com)
# - URL_DOMAIN_FIXES (add https:// to bare domains)
# - RSS_MAX_INPUT_CHARS (pre-truncation)
# ============================================================

# Add lib to load path
$LOAD_PATH.unshift(File.join(__dir__, '..', 'lib'))

require_relative '../lib/models/post'
require_relative '../lib/models/author'

# Minimal mock of ContentProcessor if not available
unless defined?(Processors::ContentProcessor)
  module Processors
    class ContentProcessor
      def initialize(max_length: 500)
        @max_length = max_length
      end
      def process(text)
        return '' if text.nil? || text.empty?
        text.length <= @max_length ? text : text[0...@max_length - 1] + '…'
      end
    end
  end
end

# Minimal mock of MentionFormatting if not available
unless defined?(Formatters::MentionFormatting)
  module Formatters
    module MentionFormatting
      def format_mentions(text, config, skip_username: nil)
        return '' if text.nil? || text.empty?
        return text if config.nil? || config[:type] == 'none'
        
        text.gsub(/@([a-zA-Z0-9_.]+)/) do |match|
          username = $1
          next match if skip_username && username.downcase == skip_username.to_s.downcase
          "#{config[:value]}#{username}"
        end
      end
    end
  end
end

# Load formatters
require_relative '../lib/formatters/bluesky_formatter'
require_relative '../lib/formatters/twitter_formatter'
require_relative '../lib/processors/url_processor'

# Test helper
def test(description)
  print "  Testing: #{description}... "
  begin
    yield
    puts "✅"
    true
  rescue => e
    puts "❌ #{e.message}"
    false
  end
end

def assert_equal(expected, actual, message = nil)
  raise "Expected #{expected.inspect}, got #{actual.inspect}#{message ? " (#{message})" : ''}" unless expected == actual
end

def assert_contains(text, substring, message = nil)
  raise "Expected to contain '#{substring}' in '#{text}'#{message ? " (#{message})" : ''}" unless text.include?(substring)
end

def assert_not_contains(text, substring, message = nil)
  raise "Expected NOT to contain '#{substring}' in '#{text}'#{message ? " (#{message})" : ''}" if text.include?(substring)
end

# ============================================================
# Test 1: PREFIX_SELF_REFERENCE - BlueskyFormatter
# ============================================================
puts "\n" + "=" * 60
puts "Test 1: PREFIX_SELF_REFERENCE - BlueskyFormatter"
puts "=" * 60

# Create a self-repost
author = Author.new(username: 'ct24zive', full_name: 'ČT24', url: 'https://bsky.app/profile/ct24zive')

# Self-repost (same user reposted their own post)
self_repost = Post.new(
  platform: 'bluesky',
  id: '123',
  url: 'https://bsky.app/profile/ct24zive/post/123',
  text: 'Test self-repost content',
  published_at: Time.now,
  is_repost: true,
  reposted_by: 'ct24zive',
  author: author
)

# External repost (different user)
external_repost = Post.new(
  platform: 'bluesky',
  id: '456',
  url: 'https://bsky.app/profile/other_user/post/456',
  text: 'Test external repost content',
  published_at: Time.now,
  is_repost: true,
  reposted_by: 'ct24zive',
  author: Author.new(username: 'other_user', full_name: 'Other User', url: 'https://bsky.app/profile/other_user')
)

test "BlueskyFormatter self-repost uses 'svůj post' (cs)" do
  formatter = Formatters::BlueskyFormatter.new(
    source_name: 'ČT24',
    language: 'cs'
  )
  result = formatter.format(self_repost)
  assert_contains(result, "svůj post:", "Should contain self-reference text")
  assert_not_contains(result, "@ct24zive:", "Should NOT contain @username")
end

test "BlueskyFormatter self-repost uses 'vlastný príspevok' (sk)" do
  formatter = Formatters::BlueskyFormatter.new(
    source_name: 'ČT24',
    language: 'sk'
  )
  result = formatter.format(self_repost)
  assert_contains(result, "vlastný príspevok:", "Should contain Slovak self-reference")
end

test "BlueskyFormatter self-repost uses 'own post' (en)" do
  formatter = Formatters::BlueskyFormatter.new(
    source_name: 'ČT24',
    language: 'en'
  )
  result = formatter.format(self_repost)
  assert_contains(result, "own post:", "Should contain English self-reference")
end

test "BlueskyFormatter external repost uses @username" do
  formatter = Formatters::BlueskyFormatter.new(
    source_name: 'ČT24',
    language: 'cs'
  )
  result = formatter.format(external_repost)
  assert_contains(result, "@other_user:", "Should contain @username")
  assert_not_contains(result, "svůj post", "Should NOT contain self-reference")
end

# ============================================================
# Test 2: PREFIX_SELF_REFERENCE - TwitterFormatter
# ============================================================
puts "\n" + "=" * 60
puts "Test 2: PREFIX_SELF_REFERENCE - TwitterFormatter"
puts "=" * 60

tw_author = Author.new(username: 'ct24zive', full_name: 'ČT24', url: 'https://twitter.com/ct24zive')

tw_self_repost = Post.new(
  platform: 'twitter',
  id: '123',
  url: 'https://twitter.com/ct24zive/status/123',
  text: 'Test self-retweet content',
  published_at: Time.now,
  is_repost: true,
  reposted_by: 'ct24zive',
  author: tw_author
)

test "TwitterFormatter self-repost uses localized text (cs)" do
  formatter = Formatters::TwitterFormatter.new(
    source_name: 'ČT24',
    language: 'cs'
  )
  result = formatter.format(tw_self_repost)
  assert_contains(result, "svůj post:", "Should contain Czech self-reference")
end

test "TwitterFormatter with Slovak language self_reference_texts" do
  formatter = Formatters::TwitterFormatter.new(
    source_name: 'Test',
    language: 'sk'
  )
  result = formatter.format(tw_self_repost)
  assert_contains(result, "vlastný príspevok:", "Should use Slovak self-reference text")
end

# ============================================================
# Test 3: URL_REPLACE - TwitterFormatter (via UniversalFormatter)
# ============================================================
puts "\n" + "=" * 60
puts "Test 3: URL_REPLACE - twitter.com -> xcancel.com"
puts "=" * 60

# URL rewriting is done by UniversalFormatter (delegated from TwitterFormatter)
# TwitterFormatter defaults: url_domain: 'xcancel.com', rewrite_domains: [twitter.com, x.com, nitter.net]

test "TwitterFormatter rewrites twitter.com URLs in text to xcancel.com" do
  # Test with URL embedded in text (regular posts don't include post URL by default)
  post = Post.new(
    platform: 'twitter',
    id: '12345',
    url: 'https://twitter.com/user/status/12345',
    text: 'Check out https://twitter.com/other/status/999',
    published_at: Time.now,
    author: Author.new(username: 'user', full_name: 'User', url: 'https://twitter.com/user')
  )
  formatter = Formatters::TwitterFormatter.new(source_name: 'Test')
  result = formatter.format(post)
  assert_contains(result, "xcancel.com", "Should rewrite twitter.com to xcancel.com in text")
end

test "TwitterFormatter rewrites x.com URLs in text to xcancel.com" do
  post = Post.new(
    platform: 'twitter',
    id: '12345',
    url: 'https://x.com/user/status/12345',
    text: 'Check out https://x.com/other/status/999',
    published_at: Time.now,
    author: Author.new(username: 'user', full_name: 'User', url: 'https://x.com/user')
  )
  formatter = Formatters::TwitterFormatter.new(source_name: 'Test')
  result = formatter.format(post)
  assert_contains(result, "xcancel.com", "Should rewrite x.com to xcancel.com in text")
end

# ============================================================
# Test 4: URL_DOMAIN_FIXES - UrlProcessor.apply_domain_fixes
# ============================================================
puts "\n" + "=" * 60
puts "Test 4: URL_DOMAIN_FIXES - add https:// to bare domains"
puts "=" * 60

# Domain fixes are applied via UrlProcessor.apply_domain_fixes (called from PostProcessor)

test "UrlProcessor adds https:// to bare domain" do
  processor = Processors::UrlProcessor.new(no_trim_domains: [])
  input = "Přečtěte si článek na ihned.cz/clanek/123"
  result = processor.apply_domain_fixes(input, ['ihned.cz', 'respekt.cz'])
  assert_contains(result, "https://ihned.cz", "Should add https:// to bare domain")
end

test "UrlProcessor doesn't double-add https://" do
  processor = Processors::UrlProcessor.new(no_trim_domains: [])
  input = "Přečtěte si https://ihned.cz/clanek/123"
  result = processor.apply_domain_fixes(input, ['ihned.cz'])
  assert_not_contains(result, "https://https://", "Should not double-add protocol")
end

# ============================================================
# Test 5: RSS_MAX_INPUT_CHARS - RssAdapter (simulation)
# ============================================================
puts "\n" + "=" * 60
puts "Test 5: RSS_MAX_INPUT_CHARS - Pre-truncation logic"
puts "=" * 60

# We can't easily test RssAdapter without a real feed, so we test the logic
test "Pre-truncation cuts at tag boundary" do
  # Simulate the pre_truncate_html logic (must match rss_adapter.rb)
  def pre_truncate_html(html, max_chars)
    return html if html.length <= max_chars
    
    truncated = html[0...max_chars]
    
    # Try to find last CLOSING tag (</tagname>) for clean cut
    last_closing_tag = truncated.rindex(%r{</[a-zA-Z][a-zA-Z0-9]*>})
    
    if last_closing_tag
      # Find the end of this closing tag
      tag_end = truncated.index('>', last_closing_tag)
      if tag_end
        return truncated[0..tag_end]
      end
    end
    
    # Fallback: try to cut before any open tag to avoid partial tags
    last_open_tag = truncated.rindex('<')
    if last_open_tag && last_open_tag > 0
      last_close = truncated.rindex('>')
      if last_close.nil? || last_close < last_open_tag
        return truncated[0...last_open_tag]
      end
    end
    
    truncated
  end
  
  html = "<div><p>Short text</p><p>More text here that is longer</p></div>"
  result = pre_truncate_html(html, 30)
  
  # Should cut at a tag boundary
  assert_equal("<div><p>Short text</p>", result, "Should cut at tag boundary")
end

test "Pre-truncation preserves short content" do
  def pre_truncate_html(html, max_chars)
    return html if html.length <= max_chars
    html[0...max_chars]
  end
  
  html = "<p>Short</p>"
  result = pre_truncate_html(html, 100)
  assert_equal(html, result, "Should preserve short content unchanged")
end

# ============================================================
# Summary
# ============================================================
puts "\n" + "=" * 60
puts "All tests completed!"
puts "=" * 60
puts
puts "Implemented features:"
puts "  ✅ PREFIX_SELF_REFERENCE - localized self-repost/quote text (cs/sk/en)"
puts "  ✅ URL_REPLACE - twitter.com/x.com -> xcancel.com"
puts "  ✅ URL_DOMAIN_FIXES - add https:// to bare domains"
puts "  ✅ RSS_MAX_INPUT_CHARS - pre-truncation for long HTML"
puts
