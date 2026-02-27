#!/usr/bin/env ruby
# frozen_string_literal: true

# UniversalFormatter Unit Tests
# Validates all post type formatting, URL handling, mentions, dedup, tier 3
# Run: ruby test/test_universal_formatter_unit.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/formatters/universal_formatter'
require_relative '../lib/models/post'
require_relative '../lib/models/author'
require_relative '../lib/models/media'

puts "=" * 60
puts "UniversalFormatter Unit Tests"
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

def test_not_includes(name, substring, actual)
  if !actual.to_s.include?(substring)
    puts "  \e[32m\u2713\e[0m #{name}"
    $passed += 1
  else
    puts "  \e[31m\u2717\e[0m #{name}"
    puts "    Expected NOT to include: #{substring.inspect}"
    puts "    Actual: #{actual.inspect}"
    $failed += 1
  end
end

def section(title)
  puts
  puts "--- #{title} ---"
end

# =============================================================================
# Helpers
# =============================================================================
def make_author(username: 'testuser', full_name: 'Test User')
  Author.new(username: username, full_name: full_name, url: "https://example.com/#{username}")
end

def make_post(overrides = {})
  defaults = {
    platform: 'twitter',
    id: '12345',
    url: 'https://x.com/testuser/status/12345',
    text: 'Hello world',
    published_at: Time.now,
    author: make_author
  }
  Post.new(**defaults.merge(overrides))
end

# =============================================================================
# 1. Regular Post
# =============================================================================
section("Regular Post")

formatter = Formatters::UniversalFormatter.new(platform: :twitter, source_name: 'TestBot')
post = make_post(text: 'Hello world')
result = formatter.format(post)

test_includes("Contains text", 'Hello world', result)
# Twitter: include_post_url_for_regular is false, so no URL for regular posts
test_not_includes("Twitter regular: no post URL appended", 'x.com/testuser', result)

# Bluesky regular: also no URL by default
bsky_formatter = Formatters::UniversalFormatter.new(platform: :bluesky, source_name: 'TestBot')
bsky_post = make_post(platform: 'bluesky', url: 'https://bsky.app/profile/test/post/abc')
result_bsky = bsky_formatter.format(bsky_post)
test_includes("Bluesky regular: contains text", 'Hello world', result_bsky)

# RSS: includes post URL
rss_formatter = Formatters::UniversalFormatter.new(platform: :rss, source_name: 'TestBot')
rss_post = make_post(platform: 'rss', url: 'https://example.com/article')
result_rss = rss_formatter.format(rss_post)
test_includes("RSS regular: includes post URL", 'https://example.com/article', result_rss)

# =============================================================================
# 2. Repost
# =============================================================================
section("Repost")

formatter_tw = Formatters::UniversalFormatter.new(platform: :twitter, source_name: 'CT24')
repost = make_post(
  text: 'Original tweet text',
  is_repost: true,
  reposted_by: 'ct24_cz',
  author: make_author(username: 'someuser')
)
result_rp = formatter_tw.format(repost)

test_includes("Repost: contains source_name", 'CT24', result_rp)
test_includes("Repost: contains prefix", "\u{1d54f}\u{1f501}", result_rp) # 𝕏🔁
test_includes("Repost: contains @author", '@someuser', result_rp)
test_includes("Repost: contains text", 'Original tweet text', result_rp)

# Self-repost uses self-reference text
self_repost = make_post(
  text: 'My own text',
  is_repost: true,
  reposted_by: 'testuser',
  author: make_author(username: 'testuser')
)
result_self = formatter_tw.format(self_repost)
test_includes("Self-repost: contains self-reference", "sv\u016Fj post", result_self)

# =============================================================================
# 3. Quote
# =============================================================================
section("Quote")

quote_post = make_post(
  text: 'My comment on this',
  is_quote: true,
  quoted_post: {
    text: 'Original text',
    author: Author.new(username: 'quoteduser', full_name: 'Quoted'),
    url: 'https://x.com/quoteduser/status/999'
  }
)
result_q = formatter_tw.format(quote_post)

test_includes("Quote: contains source_name", 'CT24', result_q)
test_includes("Quote: contains quote prefix", "\u{1d54f}\u{1f4ac}", result_q) # 𝕏💬
test_includes("Quote: contains @quoted_author", '@quoteduser', result_q)
test_includes("Quote: contains comment text", 'My comment on this', result_q)

# =============================================================================
# 4. Thread Post
# =============================================================================
section("Thread Post")

thread_post = make_post(
  text: 'Thread continuation',
  is_reply: true,
  is_thread_post: true,
  reply_to_handle: 'testuser'
)
result_th = formatter_tw.format(thread_post)

test_includes("Thread: contains thread prefix", "\u{1f9f5}", result_th) # 🧵
test_includes("Thread: contains text", 'Thread continuation', result_th)

# =============================================================================
# 5. Title-based Post (RSS/YouTube)
# =============================================================================
section("Title-based Post")

yt_formatter = Formatters::UniversalFormatter.new(platform: :youtube, source_name: 'DVTV')
yt_post = make_post(
  platform: 'youtube',
  title: 'Video Title',
  text: 'Video description text',
  url: 'https://www.youtube.com/watch?v=abc123'
)
result_yt = yt_formatter.format(yt_post)

test_includes("YouTube: contains title", 'Video Title', result_yt)
test_includes("YouTube: contains separator", "\u{2014}", result_yt) # —
test_includes("YouTube: contains description", 'Video description text', result_yt)

# show_title_as_content
rss_title_formatter = Formatters::UniversalFormatter.new(
  platform: :rss,
  source_name: 'Test',
  show_title_as_content: true
)
rss_title_post = make_post(platform: 'rss', title: 'RSS Title', text: 'RSS body')
result_title = rss_title_formatter.format(rss_title_post)
test_includes("show_title_as_content: shows title", 'RSS Title', result_title)

# =============================================================================
# 6. Video Post
# =============================================================================
section("Video Post")

video_post = make_post(
  text: 'Check out this video',
  has_video: true,
  raw: {}
)
result_vid = formatter_tw.format(video_post)

test_includes("Video: contains text", 'Check out this video', result_vid)
test_includes("Video: contains video prefix", "\u{1f3ac}", result_vid) # 🎬

# =============================================================================
# 7. Tier 3 (force_read_more)
# =============================================================================
section("Tier 3: force_read_more")

tier3_post = make_post(
  text: 'Truncated content...',
  raw: { force_read_more: true }
)
result_t3 = formatter_tw.format(tier3_post)

test_includes("Tier 3: contains read_more prefix", "\u{1f4d6}\u{27a1}\u{fe0f}", result_t3) # 📖➡️
test_includes("Tier 3: contains post URL", 'xcancel.com', result_t3)

# Tier 3 video
tier3_video = make_post(
  text: 'Truncated video...',
  has_video: true,
  raw: { force_read_more: true }
)
result_t3v = formatter_tw.format(tier3_video)
test_includes("Tier 3 video: contains video_read_more prefix", "\u{1f3ac}", result_t3v) # 🎬

# =============================================================================
# 8. URL Rewriting
# =============================================================================
section("URL Rewriting")

url_post = make_post(
  text: 'Check https://twitter.com/user/status/123',
  url: 'https://twitter.com/user/status/123'
)
result_url = formatter_tw.format(url_post)

test_includes("URL rewrite: twitter.com -> xcancel.com", 'xcancel.com', result_url)
test_not_includes("URL rewrite: no twitter.com in output", 'twitter.com', result_url)

# x.com also rewritten
url_post2 = make_post(
  text: 'Check https://x.com/user/status/456',
  url: 'https://x.com/user/status/456'
)
result_url2 = formatter_tw.format(url_post2)
test_includes("URL rewrite: x.com -> xcancel.com", 'xcancel.com', result_url2)

# =============================================================================
# 9. URL Deduplication
# =============================================================================
section("URL Deduplication")

# Test via internal method using send
fmt = Formatters::UniversalFormatter.new(platform: :rss)
test("url_already_in_content? true for same URL", true,
     fmt.send(:url_already_in_content?, 'Text https://example.com/page', 'https://example.com/page'))
test("url_already_in_content? false for different URL", false,
     fmt.send(:url_already_in_content?, 'Text https://example.com/page', 'https://other.com'))
test("url_already_in_content? true ignoring trailing slash", true,
     fmt.send(:url_already_in_content?, 'Text https://example.com/page/', 'https://example.com/page'))
test("url_already_in_content? nil content", false,
     fmt.send(:url_already_in_content?, nil, 'https://example.com'))
test("url_already_in_content? nil url", false,
     fmt.send(:url_already_in_content?, 'content', nil))

# =============================================================================
# 10. Self-reference Text (i18n)
# =============================================================================
section("Self-reference Texts")

fmt_cs = Formatters::UniversalFormatter.new(platform: :twitter, language: 'cs', source_name: 'Test')
sr_cs = fmt_cs.send(:self_reference_text, fmt_cs.instance_variable_get(:@config))
test("Czech self-reference", "sv\u016Fj post", sr_cs)

fmt_sk = Formatters::UniversalFormatter.new(platform: :twitter, language: 'sk', source_name: 'Test')
sr_sk = fmt_sk.send(:self_reference_text, fmt_sk.instance_variable_get(:@config))
test("Slovak self-reference", "vlastn\u00FD pr\u00EDspevok", sr_sk)

fmt_en = Formatters::UniversalFormatter.new(platform: :twitter, language: 'en', source_name: 'Test')
sr_en = fmt_en.send(:self_reference_text, fmt_en.instance_variable_get(:@config))
test("English self-reference", 'own post', sr_en)

# =============================================================================
# 11. Title/Content Duplicate Detection
# =============================================================================
section("Title/Content Duplicate Detection")

test("Exact duplicate detected", true,
     fmt.send(:title_content_duplicate?, 'Same text here', 'Same text here'))
test("Not duplicate", false,
     fmt.send(:title_content_duplicate?, 'Title one', 'Completely different content'))
test("Nil title", false,
     fmt.send(:title_content_duplicate?, nil, 'content'))
test("Empty title", false,
     fmt.send(:title_content_duplicate?, '', 'content'))

# =============================================================================
# 12. Mention Formatting
# =============================================================================
section("Mention Formatting")

# type: none (default)
fmt_none = Formatters::UniversalFormatter.new(platform: :twitter)
config_none = fmt_none.instance_variable_get(:@config)
test("Mentions none: unchanged", '@user hello',
     fmt_none.send(:format_mentions, '@user hello', config_none))

# type: prefix
fmt_prefix = Formatters::UniversalFormatter.new(
  platform: :rss,
  mentions: { type: 'prefix', value: 'https://x.com/' }
)
config_prefix = fmt_prefix.instance_variable_get(:@config)
result_m = fmt_prefix.send(:format_mentions, '@user hello', config_prefix)
test("Mentions prefix: transforms", 'https://x.com/user hello', result_m)

# type: domain_suffix
fmt_suffix = Formatters::UniversalFormatter.new(
  platform: :rss,
  mentions: { type: 'domain_suffix', value: 'twitter.com' }
)
config_suffix = fmt_suffix.instance_variable_get(:@config)
result_ds = fmt_suffix.send(:format_mentions, 'Hi @user!', config_suffix)
test("Mentions domain_suffix: transforms", true, result_ds.include?('@user@twitter.com'))

# Skip author's own mention
result_skip = fmt_prefix.send(:format_mentions, '@author @other hello', config_prefix, skip: 'author')
test("Mentions skip: author unchanged", true, result_skip.include?('@author'))
test("Mentions skip: other transformed", true, result_skip.include?('https://x.com/other'))

# =============================================================================
# 13. Platform Defaults
# =============================================================================
section("Platform Defaults")

tw_fmt = Formatters::UniversalFormatter.new(platform: :twitter)
tw_config = tw_fmt.instance_variable_get(:@config)
test("Twitter: url_domain is xcancel.com", 'xcancel.com', tw_config[:url_domain])
test("Twitter: prefix_repost", "\u{1d54f}\u{1f501}", tw_config[:prefix_repost])
test("Twitter: include_post_url_for_regular false", false, tw_config[:include_post_url_for_regular])

bsky_fmt = Formatters::UniversalFormatter.new(platform: :bluesky)
bsky_config = bsky_fmt.instance_variable_get(:@config)
test("Bluesky: prefix_repost", "\u{1f98b}\u{1f501}", bsky_config[:prefix_repost])
test("Bluesky: include_post_url_for_regular false", false, bsky_config[:include_post_url_for_regular])

rss_fmt = Formatters::UniversalFormatter.new(platform: :rss)
rss_config = rss_fmt.instance_variable_get(:@config)
test("RSS: move_url_to_end true", true, rss_config[:move_url_to_end])

yt_fmt = Formatters::UniversalFormatter.new(platform: :youtube)
yt_config = yt_fmt.instance_variable_get(:@config)
test("YouTube: combine_title_and_content true", true, yt_config[:combine_title_and_content])

# =============================================================================
# 14. Author Header (feed sources)
# =============================================================================
section("Author Header")

feed_fmt = Formatters::UniversalFormatter.new(
  platform: :bluesky,
  show_author_header: true,
  platform_emoji: "\u{1f98b}"
)
feed_post = make_post(
  platform: 'bluesky',
  text: 'Post content',
  author: make_author(username: 'newsbot', full_name: 'News Bot')
)
result_header = feed_fmt.format(feed_post)
test_includes("Author header: contains display_name", 'News Bot', result_header)
test_includes("Author header: contains handle", '@newsbot', result_header)

# =============================================================================
# 15. RT Prefix Removal
# =============================================================================
section("RT Prefix Removal")

rt_fmt = Formatters::UniversalFormatter.new(platform: :twitter, source_name: 'Test')
rt_post = make_post(
  text: 'RT @original: This is the original text',
  is_repost: true,
  reposted_by: 'test',
  author: make_author(username: 'original')
)
result_rt = rt_fmt.format(rt_post)
test_not_includes("RT prefix removed from text", 'RT @original:', result_rt)
test_includes("RT: original text preserved", 'This is the original text', result_rt)

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
