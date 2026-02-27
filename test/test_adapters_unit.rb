#!/usr/bin/env ruby
# frozen_string_literal: true

# Adapter Unit Tests (offline — no HTTP calls)
# Tests adapter-internal logic: config validation, URL handling, parsing helpers
# Run: ruby test/test_adapters_unit.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/adapters/twitter_adapter'
require_relative '../lib/adapters/bluesky_adapter'
require_relative '../lib/adapters/rss_adapter'
require_relative '../lib/adapters/youtube_adapter'

puts "=" * 60
puts "Adapter Unit Tests (Offline)"
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

def test_includes(name, substring, actual)
  if actual.to_s.include?(substring)
    puts "  \e[32m\u2713\e[0m #{name}"
    $passed += 1
  else
    puts "  \e[31m\u2717\e[0m #{name}"
    puts "    Expected to include: #{substring.inspect}"
    puts "    Actual: #{actual.inspect}"
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

# Suppress adapter log output during tests
$stdout_backup = $stdout

def suppress_output
  $stdout = File.open(File::NULL, 'w')
end

def restore_output
  $stdout = $stdout_backup
end

# =============================================================================
# TWITTER ADAPTER
# =============================================================================
section("TwitterAdapter: Initialization")

suppress_output
tw = Adapters::TwitterAdapter.new(handle: 'CT24_CZ')
restore_output

test("Handle lowercased", 'ct24_cz', tw.handle)
test("@ stripped from handle", 'ct24_cz',
     (suppress_output; a = Adapters::TwitterAdapter.new(handle: '@CT24_CZ'); restore_output; a.handle))
test("Nitter instance has default", true, tw.nitter_instance.is_a?(String))
test("Nitter instance has no trailing slash", false, tw.nitter_instance.end_with?('/'))

suppress_output
tw_custom = Adapters::TwitterAdapter.new(handle: 'test', nitter_instance: 'http://custom:8080/')
restore_output
test("Custom nitter_instance trimmed", 'http://custom:8080', tw_custom.nitter_instance)

section("TwitterAdapter: fix_media_url")

# Need to use send since it's private
suppress_output
tw_media = Adapters::TwitterAdapter.new(handle: 'test', nitter_instance: 'http://nitter:8080')
restore_output

# Nitter HTTPS URL -> use configured instance
result = tw_media.send(:fix_media_url, 'https://xn.zpravobot.news/pic/media%2Fimage.jpg')
test("fix_media_url: rewrites zpravobot URL", true, result.start_with?('http://nitter:8080/'))
test("fix_media_url: upgrades to orig", true, result.include?('/pic/orig/'))

# Video URL should NOT get /orig/
result_vid = tw_media.send(:fix_media_url, 'https://xn.zpravobot.news/pic/media%2Fvideo_thumb')
test("fix_media_url: video not upgraded to orig", false, result_vid.include?('/pic/orig/'))

# Relative URL
result_rel = tw_media.send(:fix_media_url, '/pic/media%2Fphoto.jpg')
test("fix_media_url: relative URL gets instance prefix", true, result_rel.start_with?('http://nitter:8080/'))
test("fix_media_url: relative URL gets orig", true, result_rel.include?('/pic/orig/'))

# Non-nitter URL unchanged
result_ext = tw_media.send(:fix_media_url, 'https://pbs.twimg.com/media/image.jpg')
test("fix_media_url: external URL unchanged", 'https://pbs.twimg.com/media/image.jpg', result_ext)

# Nil
test("fix_media_url: nil returns nil", nil, tw_media.send(:fix_media_url, nil))

# =============================================================================
# BLUESKY ADAPTER
# =============================================================================
section("BlueskyAdapter: Config Validation — Profile mode")

suppress_output
bsky = Adapters::BlueskyAdapter.new(handle: 'ct24.bsky.social')
restore_output
test("Bluesky platform", 'bluesky', bsky.platform)

section("BlueskyAdapter: Config Validation — Feed URL mode")

suppress_output
bsky_feed = Adapters::BlueskyAdapter.new(feed_url: 'https://bsky.app/profile/did:plc:abc/feed/whats-hot')
restore_output
test("Feed URL mode: no error", true, true)

section("BlueskyAdapter: Config Validation — Feed parts mode")

suppress_output
bsky_parts = Adapters::BlueskyAdapter.new(feed_creator: 'did:plc:abc', feed_rkey: 'whats-hot')
restore_output
test("Feed parts mode: no error", true, true)

section("BlueskyAdapter: Config Validation — Missing config")

test_raises("Missing config raises ArgumentError", ArgumentError) do
  Adapters::BlueskyAdapter.new({})
end

test_raises("Invalid feed URL raises ArgumentError", ArgumentError) do
  Adapters::BlueskyAdapter.new(feed_url: 'https://not-bsky.com/invalid')
end

section("BlueskyAdapter: extract_did_from_uri")

suppress_output
bsky2 = Adapters::BlueskyAdapter.new(handle: 'test.bsky.social')
restore_output

test("extract_did: valid AT URI", 'did:plc:abc123',
     bsky2.send(:extract_did_from_uri, 'at://did:plc:abc123/app.bsky.feed.post/rkey'))
test("extract_did: nil", nil, bsky2.send(:extract_did_from_uri, nil))
test("extract_did: invalid URI", nil, bsky2.send(:extract_did_from_uri, 'not-an-at-uri'))

section("BlueskyAdapter: build_post_url")

test("build_post_url", 'https://bsky.app/profile/user.bsky.social/post/abc123',
     bsky2.send(:build_post_url, 'user.bsky.social', 'at://did:plc:xxx/app.bsky.feed.post/abc123'))

section("BlueskyAdapter: should_skip?")

def make_bsky_post(overrides = {})
  defaults = {
    platform: 'bluesky', id: 'test', url: 'https://bsky.app/test',
    text: 'text', published_at: Time.now,
    author: Author.new(username: 'test')
  }
  Post.new(**defaults.merge(overrides))
end

# Default: skip_replies=true, skip_reposts=false, skip_quotes=false
suppress_output
bsky_skip = Adapters::BlueskyAdapter.new(handle: 'test.bsky.social')
restore_output

test("should_skip: regular post", false, bsky_skip.send(:should_skip?, make_bsky_post))
test("should_skip: reply (skip_replies=true)", true,
     bsky_skip.send(:should_skip?, make_bsky_post(is_reply: true)))
test("should_skip: repost (skip_reposts=false)", false,
     bsky_skip.send(:should_skip?, make_bsky_post(is_repost: true)))

suppress_output
bsky_skip_rp = Adapters::BlueskyAdapter.new(handle: 'test.bsky.social', skip_reposts: true)
restore_output
test("should_skip: repost (skip_reposts=true)", true,
     bsky_skip_rp.send(:should_skip?, make_bsky_post(is_repost: true)))

section("BlueskyAdapter: expand_facet_urls")

text = "Check out example.com/lo..."
facets = [
  {
    'index' => { 'byteStart' => 10, 'byteEnd' => 27 },
    'features' => [{ '$type' => 'app.bsky.richtext.facet#link', 'uri' => 'https://example.com/long-url' }]
  }
]
expanded = bsky2.send(:expand_facet_urls, text, facets)
test("expand_facet_urls: replaces truncated URL", true, expanded.include?('https://example.com/long-url'))
test("expand_facet_urls: nil text", nil, bsky2.send(:expand_facet_urls, nil, facets))
test("expand_facet_urls: nil facets", 'text', bsky2.send(:expand_facet_urls, 'text', nil))
test("expand_facet_urls: empty facets", 'text', bsky2.send(:expand_facet_urls, 'text', []))

# =============================================================================
# RSS ADAPTER
# =============================================================================
section("RssAdapter: Config Validation")

suppress_output
rss = Adapters::RssAdapter.new(feed_url: 'https://example.com/rss')
restore_output
test("RSS platform", 'rss', rss.platform)

test_raises("Missing feed_url raises ArgumentError", ArgumentError) do
  Adapters::RssAdapter.new({})
end

section("RssAdapter: sanitize_xml")

rss2 = rss
# Trailing garbage after </rss>
test("sanitize_xml: strips after </rss>",
     '<rss><channel></channel></rss>',
     rss2.send(:sanitize_xml, '<rss><channel></channel></rss><script>alert(1)</script>'))

test("sanitize_xml: strips after </feed>",
     '<feed><entry/></feed>',
     rss2.send(:sanitize_xml, '<feed><entry/></feed><!-- tracking -->'))

test("sanitize_xml: clean XML unchanged",
     '<rss><channel></channel></rss>',
     rss2.send(:sanitize_xml, '<rss><channel></channel></rss>'))

section("RssAdapter: pre_truncate_html")

long_html = '<div>' + 'a' * 2000 + '</div><p>more content</p>'
result = rss2.send(:pre_truncate_html, long_html, 100)
test("pre_truncate_html: truncates long HTML", true, result.length <= 110)
test("pre_truncate_html: short HTML unchanged", '<p>short</p>',
     rss2.send(:pre_truncate_html, '<p>short</p>', 100))

section("RssAdapter: guess_media_type")

test("guess_media_type: image/jpeg", 'image', rss2.send(:guess_media_type, 'image/jpeg'))
test("guess_media_type: image/png", 'image', rss2.send(:guess_media_type, 'image/png'))
test("guess_media_type: video/mp4", 'video', rss2.send(:guess_media_type, 'video/mp4'))
test("guess_media_type: audio/mpeg", 'audio', rss2.send(:guess_media_type, 'audio/mpeg'))
test("guess_media_type: application/pdf", 'unknown', rss2.send(:guess_media_type, 'application/pdf'))
test("guess_media_type: nil", 'unknown', rss2.send(:guess_media_type, nil))

section("RssAdapter: entry_media (enclosure extraction)")

# Mock enclosure object (like RSS::Rss::Channel::Item::Enclosure)
MockEnclosure = Struct.new(:url, :type, :length, keyword_init: true)

# Mock entry with enclosure
mock_entry_with_enc = Struct.new(:enclosure).new(
  MockEnclosure.new(url: 'https://example.com/image.jpg', type: 'image/jpeg', length: 123456)
)
media_result = rss2.send(:entry_media, mock_entry_with_enc)
test("entry_media: returns array with 1 Media", 1, media_result.size)
test("entry_media: Media type is image", 'image', media_result[0].type)
test("entry_media: Media url is correct", 'https://example.com/image.jpg', media_result[0].url)
test("entry_media: Media alt_text is empty string", '', media_result[0].alt_text)

# Mock entry without enclosure
mock_entry_no_enc = Struct.new(:enclosure).new(nil)
test("entry_media: nil enclosure returns []", [], rss2.send(:entry_media, mock_entry_no_enc))

# Mock entry that doesn't respond to :enclosure
mock_entry_plain = Object.new
test("entry_media: no enclosure method returns []", [], rss2.send(:entry_media, mock_entry_plain))

section("RssAdapter: Constants")

test("MAX_REDIRECTS is 5", 5, Adapters::RssAdapter::MAX_REDIRECTS)
test("REDIRECT_CODES includes 301", true, Adapters::RssAdapter::REDIRECT_CODES.include?('301'))
test("REDIRECT_CODES includes 302", true, Adapters::RssAdapter::REDIRECT_CODES.include?('302'))
test("REDIRECT_CODES includes 307", true, Adapters::RssAdapter::REDIRECT_CODES.include?('307'))
test("REDIRECT_CODES includes 308", true, Adapters::RssAdapter::REDIRECT_CODES.include?('308'))
test("REDIRECT_CODES does not include 200", false, Adapters::RssAdapter::REDIRECT_CODES.include?('200'))
test("REDIRECT_CODES is frozen", true, Adapters::RssAdapter::REDIRECT_CODES.frozen?)

section("RssAdapter: fetch_url with redirects")

# Mock HTTP responses for redirect testing
MockHTTPResponse = Struct.new(:code, :message, :body, :headers, keyword_init: true) do
  def [](key)
    headers&.dig(key.downcase)
  end
end

# Note: frozen_string_literal is true, so use +'' to get mutable strings for mock HTTP bodies
RSS_XML = +'<?xml version="1.0"?><rss version="2.0"><channel><title>Test</title><item><title>Post</title><link>https://example.com/1</link></item></channel></rss>'

suppress_output
rss_redir = Adapters::RssAdapter.new(feed_url: 'https://old.example.com/rss')
restore_output

call_log = []
original_get = HttpClient.method(:get)

# Test 1: Single redirect (301) is followed
call_log = []
HttpClient.define_singleton_method(:get) do |url, **kwargs|
  call_log << url.to_s
  case url.to_s
  when 'https://old.example.com/rss'
    MockHTTPResponse.new(code: '301', message: 'Moved Permanently', body: '', headers: { 'location' => 'https://new.example.com/feed' })
  when 'https://new.example.com/feed'
    MockHTTPResponse.new(code: '200', message: 'OK', body: RSS_XML.dup, headers: {})
  else
    MockHTTPResponse.new(code: '404', message: 'Not Found', body: '', headers: {})
  end
end

begin
  result_body = nil
  suppress_output
  rss_redir.send(:fetch_url, 'https://old.example.com/rss') { |io| result_body = io.read }
  restore_output
  test("fetch_url: follows 301 redirect", true, result_body.include?('<rss'))
  test("fetch_url: made 2 requests", 2, call_log.size)
  test("fetch_url: first request to original URL", 'https://old.example.com/rss', call_log[0])
  test("fetch_url: second request to redirect target", 'https://new.example.com/feed', call_log[1])
rescue => e
  restore_output
  test("fetch_url: follows 301 redirect", true, false)
  test("fetch_url: made 2 requests", 2, 0)
  test("fetch_url: first request to original URL", 'expected', e.message)
  test("fetch_url: second request to redirect target", 'expected', e.message)
end

# Test 2: Multiple redirects (chain)
call_log = []
HttpClient.define_singleton_method(:get) do |url, **kwargs|
  call_log << url.to_s
  case url.to_s
  when 'https://a.com/rss'
    MockHTTPResponse.new(code: '301', message: 'Moved', body: '', headers: { 'location' => 'https://b.com/rss' })
  when 'https://b.com/rss'
    MockHTTPResponse.new(code: '302', message: 'Found', body: '', headers: { 'location' => 'https://c.com/feed' })
  when 'https://c.com/feed'
    MockHTTPResponse.new(code: '200', message: 'OK', body: RSS_XML.dup, headers: {})
  else
    MockHTTPResponse.new(code: '404', message: 'Not Found', body: '', headers: {})
  end
end

begin
  result_body = nil
  suppress_output
  rss_redir.send(:fetch_url, 'https://a.com/rss') { |io| result_body = io.read }
  restore_output
  test("fetch_url: follows chain of redirects", true, result_body.include?('<rss'))
  test("fetch_url: chain made 3 requests", 3, call_log.size)
rescue => e
  restore_output
  test("fetch_url: follows chain of redirects", true, false)
  test("fetch_url: chain made 3 requests", 3, 0)
end

# Test 3: Redirect 308 (Permanent Redirect)
call_log = []
HttpClient.define_singleton_method(:get) do |url, **kwargs|
  call_log << url.to_s
  case url.to_s
  when 'https://heroine.cz/rss'
    MockHTTPResponse.new(code: '308', message: 'Permanent Redirect', body: '', headers: { 'location' => 'https://heroine.cz/feed' })
  when 'https://heroine.cz/feed'
    MockHTTPResponse.new(code: '200', message: 'OK', body: RSS_XML.dup, headers: {})
  else
    MockHTTPResponse.new(code: '404', message: 'Not Found', body: '', headers: {})
  end
end

begin
  result_body = nil
  suppress_output
  rss_redir.send(:fetch_url, 'https://heroine.cz/rss') { |io| result_body = io.read }
  restore_output
  test("fetch_url: follows 308 redirect", true, result_body.include?('<rss'))
rescue => e
  restore_output
  test("fetch_url: follows 308 redirect", true, false)
end

# Test 4: Too many redirects
call_log = []
HttpClient.define_singleton_method(:get) do |url, **kwargs|
  call_log << url.to_s
  n = call_log.size
  MockHTTPResponse.new(code: '301', message: 'Moved', body: '', headers: { 'location' => "https://hop#{n}.com/rss" })
end

begin
  suppress_output
  rss_redir.send(:fetch_url, 'https://start.com/rss') { |io| io.read }
  restore_output
  test("fetch_url: raises on too many redirects", 'should have raised', 'did not raise')
rescue RuntimeError
  restore_output
  test("fetch_url: raises on too many redirects", true, true)
end
test("fetch_url: stopped after MAX_REDIRECTS requests", Adapters::RssAdapter::MAX_REDIRECTS, call_log.size)

# Test 5: Redirect loop detection
call_log = []
HttpClient.define_singleton_method(:get) do |url, **kwargs|
  call_log << url.to_s
  case url.to_s
  when 'https://loop-a.com/rss'
    MockHTTPResponse.new(code: '301', message: 'Moved', body: '', headers: { 'location' => 'https://loop-b.com/rss' })
  when 'https://loop-b.com/rss'
    MockHTTPResponse.new(code: '301', message: 'Moved', body: '', headers: { 'location' => 'https://loop-a.com/rss' })
  else
    MockHTTPResponse.new(code: '404', message: 'Not Found', body: '', headers: {})
  end
end

begin
  suppress_output
  rss_redir.send(:fetch_url, 'https://loop-a.com/rss') { |io| io.read }
  restore_output
  test("fetch_url: detects redirect loop", true, false)
rescue RuntimeError => e
  restore_output
  test("fetch_url: detects redirect loop", true, e.message.include?('Redirect loop detected'))
end

# Test 6: Redirect without Location header
HttpClient.define_singleton_method(:get) do |url, **kwargs|
  MockHTTPResponse.new(code: '301', message: 'Moved', body: '', headers: {})
end

begin
  suppress_output
  rss_redir.send(:fetch_url, 'https://no-location.com/rss') { |io| io.read }
  restore_output
  test("fetch_url: raises on redirect without Location", 'should have raised', 'did not raise')
rescue RuntimeError
  restore_output
  test("fetch_url: raises on redirect without Location", true, true)
end

# Test 7: Relative redirect
call_log = []
HttpClient.define_singleton_method(:get) do |url, **kwargs|
  call_log << url.to_s
  case url.to_s
  when 'https://example.com/old-rss'
    MockHTTPResponse.new(code: '301', message: 'Moved', body: '', headers: { 'location' => '/new-feed' })
  when 'https://example.com/new-feed'
    MockHTTPResponse.new(code: '200', message: 'OK', body: RSS_XML.dup, headers: {})
  else
    MockHTTPResponse.new(code: '404', message: 'Not Found', body: '', headers: {})
  end
end

begin
  result_body = nil
  suppress_output
  rss_redir.send(:fetch_url, 'https://example.com/old-rss') { |io| result_body = io.read }
  restore_output
  test("fetch_url: handles relative redirect", true, result_body.include?('<rss'))
  test("fetch_url: resolved relative URL correctly", 'https://example.com/new-feed', call_log[1])
rescue => e
  restore_output
  test("fetch_url: handles relative redirect", true, false)
  test("fetch_url: resolved relative URL correctly", 'expected', e.message)
end

# Test 8: No redirect (direct 200) still works
call_log = []
HttpClient.define_singleton_method(:get) do |url, **kwargs|
  call_log << url.to_s
  MockHTTPResponse.new(code: '200', message: 'OK', body: RSS_XML.dup, headers: {})
end

begin
  result_body = nil
  suppress_output
  rss_redir.send(:fetch_url, 'https://direct.com/rss') { |io| result_body = io.read }
  restore_output
  test("fetch_url: direct 200 still works", true, result_body.include?('<rss'))
  test("fetch_url: direct 200 makes 1 request", 1, call_log.size)
rescue => e
  restore_output
  test("fetch_url: direct 200 still works", true, false)
  test("fetch_url: direct 200 makes 1 request", 1, 0)
end

# Test 9: Non-redirect error (404) still raises
HttpClient.define_singleton_method(:get) do |url, **kwargs|
  MockHTTPResponse.new(code: '404', message: 'Not Found', body: '', headers: {})
end

begin
  suppress_output
  rss_redir.send(:fetch_url, 'https://gone.com/rss') { |io| io.read }
  restore_output
  test("fetch_url: 404 still raises error", 'should have raised', 'did not raise')
rescue RuntimeError
  restore_output
  test("fetch_url: 404 still raises error", true, true)
end

# Restore original HttpClient.get
HttpClient.define_singleton_method(:get, original_get)

# =============================================================================
# YOUTUBE ADAPTER
# =============================================================================
section("YouTubeAdapter: Config Validation")

suppress_output
yt = Adapters::YouTubeAdapter.new(channel_id: 'UCFb-u3ISt99gxZ9TxIQW7UA', source_name: 'DVTV')
restore_output
test("YouTube platform", 'youtube', yt.platform)

test_raises("Missing channel_id and handle raises ArgumentError", ArgumentError) do
  Adapters::YouTubeAdapter.new({})
end

section("YouTubeAdapter: feed_url")

suppress_output
yt_normal = Adapters::YouTubeAdapter.new(channel_id: 'UCabc123', source_name: 'Test')
restore_output
test("feed_url: normal channel",
     'https://www.youtube.com/feeds/videos.xml?channel_id=UCabc123',
     yt_normal.feed_url)

suppress_output
yt_shorts = Adapters::YouTubeAdapter.new(channel_id: 'UCabc123', source_name: 'Test', no_shorts: true)
restore_output
test("feed_url: no_shorts uses UULF playlist",
     'https://www.youtube.com/feeds/videos.xml?playlist_id=UULFabc123',
     yt_shorts.feed_url)

section("YouTubeAdapter: sanitize_username")

test("sanitize_username: basic", 'dvtv', yt.send(:sanitize_username, 'DVTV'))
test("sanitize_username: with spaces", 'test_channel', yt.send(:sanitize_username, 'Test Channel'))
test("sanitize_username: special chars", 'test_123', yt.send(:sanitize_username, 'Test! @#$% 123'))

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
