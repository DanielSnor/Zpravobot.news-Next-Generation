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
# Summary
# =============================================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
