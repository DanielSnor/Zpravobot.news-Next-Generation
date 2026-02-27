#!/usr/bin/env ruby
# frozen_string_literal: true

# Test Post, Author, Media models
# Validates constructors, type checks, helpers, serialization
# Run: ruby test/test_models.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/models/post'
require_relative '../lib/models/author'
require_relative '../lib/models/media'

puts "=" * 60
puts "Model Tests (Post, Author, Media)"
puts "=" * 60
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

def test_raises(name, exception_class, &block)
  begin
    block.call
    puts "  \e[31m\u2717\e[0m #{name} (no exception raised)"
    $failed += 1
  rescue exception_class
    puts "  \e[32m\u2713\e[0m #{name}"
    $passed += 1
  rescue => e
    puts "  \e[31m\u2717\e[0m #{name}"
    puts "    Expected: #{exception_class}"
    puts "    Got:      #{e.class}: #{e.message}"
    $failed += 1
  end
end

def section(title)
  puts
  puts "--- #{title} ---"
end

# =============================================================================
# Helper: build a minimal Post
# =============================================================================
def make_author(username: 'testuser', full_name: 'Test User')
  Author.new(username: username, full_name: full_name, url: "https://example.com/#{username}")
end

def make_post(overrides = {})
  defaults = {
    platform: 'twitter',
    id: '12345',
    url: 'https://example.com/post/12345',
    text: 'Hello world',
    published_at: Time.now,
    author: make_author
  }
  Post.new(**defaults.merge(overrides))
end

# =============================================================================
# AUTHOR TESTS
# =============================================================================
section("Author: Constructor")

author = Author.new(username: 'testuser', full_name: 'Test User', url: 'https://example.com')
test("username stored", 'testuser', author.username)
test("full_name stored", 'Test User', author.full_name)
test("url stored", 'https://example.com', author.url)

author_at = Author.new(username: '@withatsign')
test("@ is stripped from username", 'withatsign', author_at.username)

author_minimal = Author.new(username: 'minimal')
test("display_name defaults to username", 'minimal', author_minimal.display_name)
test("full_name defaults to username", 'minimal', author_minimal.full_name)

section("Author: Methods")

test("handle adds @", '@testuser', author.handle)
test("name returns display_name", 'Test User', author.name)

section("Author: Equality")

a1 = Author.new(username: 'Same')
a2 = Author.new(username: 'same')
a3 = Author.new(username: 'different')
test("Same username (case-insensitive) are equal", true, a1 == a2)
test("Different usernames are not equal", false, a1 == a3)
test("eql? matches ==", true, a1.eql?(a2))
test("hash matches for equal authors", a1.hash, a2.hash)
test("Not equal to non-Author", false, a1 == 'same')

section("Author: Serialization")

h = author.to_h
test("to_h includes username", 'testuser', h[:username])
test("to_h includes full_name", 'Test User', h[:full_name])
test("inspect includes @", true, author.inspect.include?('@testuser'))

# =============================================================================
# MEDIA TESTS
# =============================================================================
section("Media: Constructor")

img = Media.new(type: :image, url: 'https://example.com/img.jpg', alt_text: 'Photo')
test("type stored as string", 'image', img.type)
test("url stored", 'https://example.com/img.jpg', img.url)
test("alt_text stored", 'Photo', img.alt_text)

media_no_alt = Media.new(type: 'video', url: 'https://example.com/vid.mp4')
test("alt_text defaults to empty string", '', media_no_alt.alt_text)

section("Media: Type Validation")

test_raises("Invalid type raises ArgumentError", ArgumentError) do
  Media.new(type: 'invalid_type', url: 'https://example.com')
end

test_raises("Empty type raises ArgumentError", ArgumentError) do
  Media.new(type: '', url: 'https://example.com')
end

# Valid types
%w[image video gif audio link_card video_thumbnail].each do |valid_type|
  m = Media.new(type: valid_type, url: 'https://example.com')
  test("Type '#{valid_type}' is valid", valid_type, m.type)
end

section("Media: Type Checks")

test("image? true for image", true, Media.new(type: 'image', url: 'x').image?)
test("image? false for video", false, Media.new(type: 'video', url: 'x').image?)
test("video? true for video", true, Media.new(type: 'video', url: 'x').video?)
test("video? true for video_thumbnail", true, Media.new(type: 'video_thumbnail', url: 'x').video?)
test("gif? true for gif", true, Media.new(type: 'gif', url: 'x').gif?)
test("audio? true for audio", true, Media.new(type: 'audio', url: 'x').audio?)
test("link_card? true for link_card", true, Media.new(type: 'link_card', url: 'x').link_card?)
test("visual? true for image", true, Media.new(type: 'image', url: 'x').visual?)
test("visual? true for video", true, Media.new(type: 'video', url: 'x').visual?)
test("visual? false for audio", false, Media.new(type: 'audio', url: 'x').visual?)
test("visual? false for link_card", false, Media.new(type: 'link_card', url: 'x').visual?)

section("Media: Equality")

m1 = Media.new(type: 'image', url: 'https://example.com/a.jpg')
m2 = Media.new(type: 'video', url: 'https://example.com/a.jpg')
m3 = Media.new(type: 'image', url: 'https://example.com/b.jpg')
test("Same URL are equal (regardless of type)", true, m1 == m2)
test("Different URL are not equal", false, m1 == m3)
test("Not equal to non-Media", false, m1 == 'string')

section("Media: Serialization")

mh = img.to_h
test("to_h includes type", 'image', mh[:type])
test("to_h includes url", 'https://example.com/img.jpg', mh[:url])
test("inspect includes type", true, img.inspect.include?('image'))

# =============================================================================
# POST TESTS
# =============================================================================
section("Post: Constructor")

post = make_post
test("platform stored (lowercased)", 'twitter', post.platform)
test("id stored", '12345', post.id)
test("url stored", 'https://example.com/post/12345', post.url)
test("text stored", 'Hello world', post.text)
test("author stored", 'testuser', post.author.username)
test("is_repost defaults false", false, post.is_repost)
test("is_quote defaults false", false, post.is_quote)
test("is_reply defaults false", false, post.is_reply)
test("media defaults to empty array", [], post.media)
test("is_thread_post defaults false", false, post.is_thread_post)
test("has_video defaults false", false, post.has_video)

post_upper = make_post(platform: 'TWITTER')
test("platform is lowercased", 'twitter', post_upper.platform)

section("Post: Platform Checks")

test("twitter? true", true, make_post(platform: 'twitter').twitter?)
test("twitter? false for rss", false, make_post(platform: 'rss').twitter?)
test("bluesky? true", true, make_post(platform: 'bluesky').bluesky?)
test("rss? true", true, make_post(platform: 'rss').rss?)
test("youtube? true", true, make_post(platform: 'youtube').youtube?)
test("social? true for twitter", true, make_post(platform: 'twitter').social?)
test("social? true for bluesky", true, make_post(platform: 'bluesky').social?)
test("social? false for rss", false, make_post(platform: 'rss').social?)
test("content? true for rss", true, make_post(platform: 'rss').content?)
test("content? true for youtube", true, make_post(platform: 'youtube').content?)
test("content? false for twitter", false, make_post(platform: 'twitter').content?)

section("Post: Content Checks")

test("has_media? false with no media", false, make_post.has_media?)
test("has_media? true with media", true,
     make_post(media: [Media.new(type: 'image', url: 'x')]).has_media?)

test("has_title? falsy with no title", true, !make_post.has_title?)
test("has_title? true with title", true, make_post(title: 'My Title').has_title?)
test("has_title? false with blank title", false, make_post(title: '   ').has_title?)

test("has_text? true", true, make_post(text: 'content').has_text?)
test("has_text? false with empty text", false, make_post(text: '').has_text?)
test("has_text? false with blank text", false, make_post(text: '   ').has_text?)

test("empty? true when no text/title/media", true,
     make_post(text: '', title: nil, media: []).empty?)
test("empty? false when has text", false, make_post(text: 'content').empty?)

test("has_video? true", true, make_post(has_video: true).has_video?)
test("has_video? false", false, make_post(has_video: false).has_video?)

section("Post: Author Helpers")

test("author_name returns display_name", 'Test User', make_post.author_name)
test("author_username returns username", 'testuser', make_post.author_username)

section("Post: Repost/Quote Helpers")

repost_self = make_post(
  is_repost: true,
  reposted_by: 'testuser',
  author: make_author(username: 'testuser')
)
test("self_repost? true when same user", true, repost_self.self_repost?)

repost_other = make_post(
  is_repost: true,
  reposted_by: 'other',
  author: make_author(username: 'testuser')
)
test("self_repost? false when different user", false, repost_other.self_repost?)
test("external_repost? true", true, repost_other.external_repost?)

section("Post: Thread Helpers")

thread_post = make_post(
  is_reply: true,
  is_thread_post: true,
  reply_to_handle: 'testuser',
  author: make_author(username: 'testuser')
)
test("self_reply? true when replying to self", true, thread_post.self_reply?)
test("thread_post? alias works", true, thread_post.thread_post?)
test("external_reply? false for self-reply", false, thread_post.external_reply?)

ext_reply = make_post(
  is_reply: true,
  reply_to_handle: 'other',
  author: make_author(username: 'testuser')
)
test("self_reply? false for external reply", false, ext_reply.self_reply?)
test("external_reply? true", true, ext_reply.external_reply?)

no_reply = make_post(is_reply: false)
test("self_reply? false when not a reply", false, no_reply.self_reply?)

section("Post: Thread Context")

test("thread_context_loaded? false by default", false, make_post.thread_context_loaded?)

ctx_post = make_post(is_thread_post: true, thread_context: { position: 2, total: 5 })
test("thread_context_loaded? true when set", true, ctx_post.thread_context_loaded?)
test("thread_position returns value", 2, ctx_post.thread_position)
test("thread_total returns value", 5, ctx_post.thread_total)

test("thread_position defaults to 1", 1, make_post.thread_position)
test("thread_total defaults to 1", 1, make_post.thread_total)

section("Post: Serialization")

ph = make_post(title: 'Test', is_repost: true).to_h
test("to_h includes platform", 'twitter', ph[:platform])
test("to_h includes id", '12345', ph[:id])
test("to_h includes is_repost", true, ph[:is_repost])
test("to_h is a Hash", true, ph.is_a?(Hash))

test("inspect includes platform", true, make_post.inspect.include?('twitter'))
test("inspect includes id", true, make_post.inspect.include?('12345'))

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
