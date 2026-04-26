#!/usr/bin/env ruby
# frozen_string_literal: true

# Test Pipeline Steps (Phase 8 — #26)
# Validates DeduplicationStep, ContentFilterStep, EditDetectionStep, UrlProcessingStep
# Run: ruby test/test_pipeline_steps.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/errors'
require_relative '../lib/processors/pipeline_steps'

# Need PostProcessor::Result for DeduplicationStep
require_relative '../lib/support/loggable'

# Minimal stub for PostProcessor::Result (if not loaded)
module Processors
  class PostProcessor
    Result = Struct.new(:status, :mastodon_id, :error, :skipped_reason, keyword_init: true) do
      def published?; status == :published; end
      def skipped?; status == :skipped; end
      def failed?; status == :failed; end
    end
  end
end

puts "=" * 60
puts "Pipeline Steps Tests (Phase 8 — #26)"
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

def test_no_error(name, &block)
  begin
    block.call
    puts "  \e[32m\u2713\e[0m #{name}"
    $passed += 1
  rescue => e
    puts "  \e[31m\u2717\e[0m #{name}"
    puts "    Unexpected error: #{e.class}: #{e.message}"
    $failed += 1
  end
end

def section(title)
  puts
  puts "--- #{title} ---"
end

# =============================================================================
# Mock objects
# =============================================================================

class MockStateManager
  def initialize(published_ids: [])
    @published_ids = published_ids
  end

  def published?(source_id, post_id)
    @published_ids.include?("#{source_id}:#{post_id}")
  end
end

class MockPost
  attr_accessor :text, :title, :url, :is_reply, :is_thread_post,
                :is_repost, :is_quote, :author, :id

  def initialize(attrs = {})
    attrs.each { |k, v| send("#{k}=", v) }
  end

  def respond_to?(method, include_private = false)
    [:text, :title, :url, :is_reply, :is_thread_post, :is_repost,
     :is_quote, :author, :id].include?(method) || super
  end
end

class MockAuthor
  attr_accessor :handle, :username

  def initialize(handle: nil, username: nil)
    @handle = handle
    @username = username
  end

  def respond_to?(method, include_private = false)
    [:handle, :username].include?(method) || super
  end
end

# =============================================================================
# 1. ProcessingContext
# =============================================================================
section("ProcessingContext")

ctx = Processors::ProcessingContext.new(
  post: 'mock_post', source_config: { id: 'src1' }, options: {},
  source_id: 'src1', post_id: 'post123', platform: 'twitter'
)

test("ctx.source_id", 'src1', ctx.source_id)
test("ctx.post_id", 'post123', ctx.post_id)
test("ctx.platform", 'twitter', ctx.platform)
test("ctx.post", 'mock_post', ctx.post)
test("ctx.formatted_text nil by default", nil, ctx.formatted_text)
test("ctx.mastodon_id nil by default", nil, ctx.mastodon_id)

ctx.formatted_text = "Hello world"
test("ctx.formatted_text mutable", "Hello world", ctx.formatted_text)

# =============================================================================
# 2. DeduplicationStep
# =============================================================================
section("DeduplicationStep")

sm_with_published = MockStateManager.new(published_ids: ['src1:post123'])
dedup = Processors::DeduplicationStep.new(sm_with_published)

ctx_published = Processors::ProcessingContext.new(
  source_id: 'src1', post_id: 'post123'
)
result = dedup.call(ctx_published)
test("Published post returns Result", true, !result.nil?)
test("Published post status is :skipped", :skipped, result.status)
test("Published post reason is already_published", 'already_published', result.skipped_reason)

ctx_new = Processors::ProcessingContext.new(
  source_id: 'src1', post_id: 'new_post'
)
result2 = dedup.call(ctx_new)
test("New post returns nil (continue)", nil, result2)

sm_empty = MockStateManager.new
dedup_empty = Processors::DeduplicationStep.new(sm_empty)
result3 = dedup_empty.call(ctx_published)
test("Empty state: post not published", nil, result3)

# =============================================================================
# 3. ContentFilterStep
# =============================================================================
section("ContentFilterStep: Reply Handling")

filter = Processors::ContentFilterStep.new

# Test skip_replies
post_reply = MockPost.new(is_reply: true, is_thread_post: false, text: 'reply text')
config_skip_replies = { filtering: { skip_replies: true } }
test("External reply skipped", 'is_external_reply', filter.call(post_reply, config_skip_replies))

config_no_skip = { filtering: { skip_replies: false } }
test("External reply not skipped when disabled", nil, filter.call(post_reply, config_no_skip))

# Self-reply (thread)
post_self_reply = MockPost.new(is_reply: true, is_thread_post: true, text: 'thread post')
config_skip_self = { filtering: { skip_self_replies: true } }
test("Self-reply skipped", 'is_self_reply_thread', filter.call(post_self_reply, config_skip_self))

config_no_skip_self = { filtering: { skip_self_replies: false } }
test("Self-reply not skipped when disabled", nil, filter.call(post_self_reply, config_no_skip_self))

section("ContentFilterStep: Repost/Quote Handling")

post_repost = MockPost.new(is_repost: true, text: 'repost text')
config_skip_rt = { filtering: { skip_retweets: true } }
test("Repost skipped", 'is_retweet', filter.call(post_repost, config_skip_rt))

post_quote = MockPost.new(is_quote: true, text: 'quote text')
config_skip_quote = { filtering: { skip_quotes: true } }
test("Quote skipped", 'is_quote', filter.call(post_quote, config_skip_quote))

section("ContentFilterStep: Banned Phrases")

post_text = MockPost.new(text: 'This post contains SPAM content')
config_banned = { filtering: { banned_phrases: ['spam'] } }
test("Banned phrase detected (case-insensitive)", 'banned_phrase',
     filter.call(post_text, config_banned))

config_no_banned = { filtering: { banned_phrases: ['nothing_here'] } }
test("No banned phrase: passes", nil, filter.call(post_text, config_no_banned))

section("ContentFilterStep: Required Keywords")

config_required = { filtering: { required_keywords: ['important'] } }
post_without = MockPost.new(text: 'This is a normal post')
test("Missing required keyword", 'missing_required_keyword',
     filter.call(post_without, config_required))

post_with = MockPost.new(text: 'This is an IMPORTANT announcement')
test("Required keyword present (case-insensitive)", nil,
     filter.call(post_with, config_required))

section("ContentFilterStep: Regex Patterns")

config_regex = { filtering: { banned_phrases: [/\bspam\b/i] } }
post_spam = MockPost.new(text: 'This is spam content')
test("Regex banned phrase matched", 'banned_phrase', filter.call(post_spam, config_regex))

post_no_spam = MockPost.new(text: 'This is legitimate content')
test("Regex banned phrase not matched", nil, filter.call(post_no_spam, config_regex))

section("ContentFilterStep: Combined Content Fields")

post_title_url = MockPost.new(text: 'clean text', title: 'SPAM title', url: 'https://example.com')
config_banned2 = { filtering: { banned_phrases: ['spam'] } }
test("Banned phrase in title detected", 'banned_phrase',
     filter.call(post_title_url, config_banned2))

section("ContentFilterStep: Empty/No Filtering")

post_normal = MockPost.new(text: 'Normal post')
config_empty = {}
test("No filtering config: passes", nil, filter.call(post_normal, config_empty))

config_empty_filter = { filtering: {} }
test("Empty filtering hash: passes", nil, filter.call(post_normal, config_empty_filter))

# =============================================================================
# 4. EditDetectionStep
# =============================================================================
section("EditDetectionStep: Platform Check")

edit_step = Processors::EditDetectionStep.new(MockStateManager.new, true)
test("Bluesky enabled", true, edit_step.enabled?('bluesky'))
test("Twitter enabled", true, edit_step.enabled?('twitter'))
test("RSS not enabled", false, edit_step.enabled?('rss'))
test("YouTube not enabled", false, edit_step.enabled?('youtube'))
test("Nil platform not enabled", false, edit_step.enabled?(nil))

edit_step_disabled = Processors::EditDetectionStep.new(MockStateManager.new, false)
test("Bluesky disabled when detector unavailable", false, edit_step_disabled.enabled?('bluesky'))
test("Twitter disabled when detector unavailable", false, edit_step_disabled.enabled?('twitter'))

section("EditDetectionStep: Case Insensitive Platform")

test("BLUESKY enabled", true, edit_step.enabled?('BLUESKY'))
test("Twitter (mixed case) enabled", true, edit_step.enabled?('Twitter'))

# =============================================================================
# 5. UrlProcessingStep
# =============================================================================
section("UrlProcessingStep: Initialization")

# We can't test call() without a real UrlProcessor, but we can test initialization
class MockConfigLoader
  def load_global_config
    { url: { no_trim_domains: ['example.com'] } }
  end
end

test_no_error("UrlProcessingStep initializes") do
  Processors::UrlProcessingStep.new(MockConfigLoader.new)
end

# =============================================================================
# 6. MediaEnrichmentStep
# =============================================================================

# Stub dependencies so the step can run without requiring the real implementations
require_relative '../lib/models/media'
require_relative '../lib/models/author'
require_relative '../lib/models/post'

module Processors
  module ThumbnailPhash
    def self.compute(_data); 12345; end
  end

  class MediaDedup
    def initialize(state_manager, logger: nil); @dupes = []; end
    def duplicate_by_phash?(source_id, phash, hours:); @dupes.include?(phash); end
    def mark_duplicate(phash); @dupes << phash; end
  end
end

module Utils
  class OgpFetcher
    def fetch_og_image(url); "https://cdn.example.com/og.jpg"; end
  end
end

class MockHttpClient
  class Response
    attr_reader :body
    def initialize(body); @body = body; end
  end
  @@response = nil
  def self.set_response(r); @@response = r; end
  def self.download(url, max_size: nil); @@response; end
  def self.head(url, **opts); nil; end
end

HttpClient = MockHttpClient unless defined?(HttpClient)

def build_post_with_media(type:, url:)
  Post.new(
    platform: 'twitter', id: '1', url: 'https://x.com/u/status/1',
    text: 'Hello', published_at: Time.now,
    author: Author.new(username: 'testuser'),
    media: [Media.new(type: type, url: url)]
  )
end

def build_post_no_media
  Post.new(
    platform: 'rss', id: '2', url: 'https://example.com/article',
    text: 'Article text https://example.com/article',
    published_at: Time.now,
    author: Author.new(username: 'feed')
  )
end

section("MediaEnrichmentStep: no video_dedup_hours → continue, no cache")

step = Processors::MediaEnrichmentStep.new(MockStateManager.new, dry_run: false)
post = build_post_with_media(type: 'video', url: 'https://cdn.example.com/vid.mp4')
result = step.call(post, 'src1', 'p1', 'text', { processing: {} })
test("no dedup config → action :continue", :continue, result[:action])
test("no dedup config → video_data_cache nil", nil, result[:video_data_cache])

section("MediaEnrichmentStep: dry_run skips video dedup")

step_dry = Processors::MediaEnrichmentStep.new(MockStateManager.new, dry_run: true)
post2 = build_post_with_media(type: 'video', url: 'https://cdn.example.com/vid.mp4')
MockHttpClient.set_response(MockHttpClient::Response.new('video_bytes'))
result2 = step_dry.call(post2, 'src1', 'p1', 'text', { processing: { video_dedup_hours: 72 } })
test("dry_run skips dedup → action :continue", :continue, result2[:action])
test("dry_run → video_data_cache nil", nil, result2[:video_data_cache])

section("MediaEnrichmentStep: new video → cache returned")

step3 = Processors::MediaEnrichmentStep.new(MockStateManager.new, dry_run: false)
post3 = build_post_with_media(type: 'video', url: 'https://cdn.example.com/vid.mp4')
MockHttpClient.set_response(MockHttpClient::Response.new('video_bytes'))
result3 = step3.call(post3, 'src1', 'p1', 'text', { processing: { video_dedup_hours: 72 } })
test("new video → action :continue", :continue, result3[:action])
test("new video → cache is hash", true, result3[:video_data_cache].is_a?(Hash))
test("new video → cache has data", true, result3[:video_data_cache]&.key?(:data))
test("new video → cache has phash", true, result3[:video_data_cache]&.key?(:phash))

section("MediaEnrichmentStep: duplicate video → :skip")

sm_dup = MockStateManager.new
step4 = Processors::MediaEnrichmentStep.new(sm_dup, dry_run: false)
# Pre-seed the dedup store with the phash that ThumbnailPhash will return (12345)
step4.instance_variable_get(:@dedup_store)&.mark_duplicate(12345) rescue nil
# Force dedup store creation and mark duplicate
dedup_store = Processors::MediaDedup.new(sm_dup)
dedup_store.mark_duplicate(12345)
step4.instance_variable_set(:@dedup_store, dedup_store)
post4 = build_post_with_media(type: 'video', url: 'https://cdn.example.com/vid.mp4')
MockHttpClient.set_response(MockHttpClient::Response.new('video_bytes'))
result4 = step4.call(post4, 'src1', 'p1', 'text', { processing: { video_dedup_hours: 72 } })
test("duplicate video → action :skip", :skip, result4[:action])
test("duplicate video → reason", 'duplicate_video', result4[:reason])

section("MediaEnrichmentStep: OGP fetch adds to post.media")

step5 = Processors::MediaEnrichmentStep.new(MockStateManager.new, dry_run: false)
post5 = build_post_no_media
post5.raw = {}
original_media_count = post5.media.length
result5 = step5.call(post5, 'src2', 'p2', 'https://example.com/article', {
  processing: { ogp_fetch_link_card: true }
})
test("OGP → action :continue", :continue, result5[:action])
test("OGP → media added to post", 1, post5.media.length)
test("OGP → media type image", 'image', post5.media.first&.type)

section("MediaEnrichmentStep: OGP skipped when post already has media")

step6 = Processors::MediaEnrichmentStep.new(MockStateManager.new, dry_run: false)
post6 = build_post_with_media(type: 'image', url: 'https://img.example.com/pic.jpg')
result6 = step6.call(post6, 'src2', 'p3', 'text', { processing: { ogp_fetch_link_card: true } })
test("OGP skipped when media present → :continue", :continue, result6[:action])
test("OGP skipped → media count unchanged", 1, post6.media.length)

section("MediaEnrichmentStep: link card thumbnail extraction")

step7 = Processors::MediaEnrichmentStep.new(MockStateManager.new, dry_run: false)
link_card = Media.new(type: 'link_card', url: 'https://example.com/article',
                      thumbnail_url: 'https://img.example.com/thumb.jpg')
post7 = Post.new(
  platform: 'bluesky', id: '3', url: 'https://example.com/article',
  text: 'Article', published_at: Time.now,
  author: Author.new(username: 'user'),
  media: [link_card]
)
result7 = step7.call(post7, 'src3', 'p4', 'text', { processing: { ogp_fetch_link_card: true } })
test("link card thumbnail → :continue", :continue, result7[:action])
test("link card thumbnail → image appended", 2, post7.media.length)
test("link card thumbnail → appended is image", 'image', post7.media.last&.type)

section("MediaEnrichmentStep: OGP_SKIP_DOMAINS constant")
test("OGP_SKIP_DOMAINS includes twitter.com", true,
     Processors::MediaEnrichmentStep::OGP_SKIP_DOMAINS.include?('twitter.com'))
test("OGP_SKIP_DOMAINS includes bsky.app", true,
     Processors::MediaEnrichmentStep::OGP_SKIP_DOMAINS.include?('bsky.app'))

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
