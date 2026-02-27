#!/usr/bin/env ruby
# frozen_string_literal: true

# Test WebhookPayloadParser, WebhookEditHandler, WebhookThreadHandler, WebhookPublisher (Phase 14.2)
# Run: ruby test/test_webhook_split.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'stringio'
require_relative '../lib/support/loggable'
require_relative '../lib/webhook/webhook_payload_parser'
require_relative '../lib/webhook/webhook_edit_handler'
require_relative '../lib/webhook/webhook_thread_handler'
require_relative '../lib/webhook/webhook_publisher'

puts "=" * 60
puts "Webhook Split Tests (Phase 14.2)"
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

def test_raises(name, exception_class)
  begin
    yield
    puts "  \e[31m\u2717\e[0m #{name}"
    puts "    Expected: #{exception_class} to be raised"
    $failed += 1
  rescue exception_class
    puts "  \e[32m\u2713\e[0m #{name}"
    $passed += 1
  rescue => e
    puts "  \e[31m\u2717\e[0m #{name}"
    puts "    Expected: #{exception_class}"
    puts "    Actual:   #{e.class}: #{e.message}"
    $failed += 1
  end
end

def section(title)
  puts
  puts "--- #{title} ---"
end

# Suppress stdout during block (avoids Loggable emoji output confusing test runner)
def quiet
  old_stdout = $stdout
  $stdout = StringIO.new
  yield
ensure
  $stdout = old_stdout
end

# ===========================================
# WebhookPayloadParser Tests
# ===========================================

section "WebhookPayloadParser"

parser = Webhook::WebhookPayloadParser.new

# Basic parsing
payload = {
  'bot_id' => 'ct24',
  'username' => 'CT24zive',
  'text' => 'Breaking news: test',
  'link_to_tweet' => 'https://twitter.com/CT24zive/status/1234567890'
}
bot_config = { id: 'ct24_twitter', platform: 'twitter' }
config_finder = ->(_bot_id, _username) { bot_config }

parsed = parser.parse(payload, config_finder)

test "parse: extracts bot_id", 'ct24', parsed.bot_id
test "parse: extracts username", 'CT24zive', parsed.username
test "parse: extracts text", 'Breaking news: test', parsed.text
test "parse: extracts post_id from twitter URL", '1234567890', parsed.post_id
test "parse: resolves bot_config", bot_config, parsed.bot_config
test "parse: extracts source_id from config", 'ct24_twitter', parsed.source_id

# Post ID from x.com URL
payload_x = payload.merge('link_to_tweet' => 'https://x.com/user/status/9876543210')
parsed_x = parser.parse(payload_x, config_finder)
test "parse: extracts post_id from x.com URL", '9876543210', parsed_x.post_id

# Missing link_to_tweet
payload_no_link = payload.merge('link_to_tweet' => nil)
parsed_no_link = parser.parse(payload_no_link, config_finder)
test "parse: nil post_id when no link", nil, parsed_no_link.post_id

# Empty text defaults to ''
payload_no_text = { 'bot_id' => 'b', 'username' => 'u', 'text' => nil }
parsed_no_text = parser.parse(payload_no_text, config_finder)
test "parse: nil text defaults to empty string", '', parsed_no_text.text

# Invalid URL format
payload_bad_url = payload.merge('link_to_tweet' => 'https://example.com/not-twitter')
parsed_bad = parser.parse(payload_bad_url, config_finder)
test "parse: nil post_id for non-twitter URL", nil, parsed_bad.post_id

# Config finder is called with correct args
called_with = nil
tracking_finder = ->(bot_id, username) { called_with = [bot_id, username]; bot_config }
parser.parse(payload, tracking_finder)
test "parse: calls config_finder with bot_id and username", ['ct24', 'CT24zive'], called_with

# IFTTT text decoding: URL decode + HTML entity decode
section "WebhookPayloadParser: IFTTT text decoding"

# URL decode: + → space, %xx → chars
payload_url_encoded = payload.merge('text' => 'Hello+world+%26+test')
parsed_url = parser.parse(payload_url_encoded, config_finder)
test "parse: URL-decodes + to spaces", 'Hello world & test', parsed_url.text

# URL decode: %25 (percent sign) — the crash case from production
payload_percent = payload.merge('text' => '92%25+accuracy')
parsed_pct = parser.parse(payload_percent, config_finder)
test "parse: URL-decodes %25 to % (no double-decode crash)", '92% accuracy', parsed_pct.text

# HTML entity decode: &gt; → >
payload_html = payload.merge('text' => 'time+-%26gt%3B+goals')
parsed_html = parser.parse(payload_html, config_finder)
test "parse: decodes URL-encoded HTML entities (&gt; → >)", 'time -> goals', parsed_html.text

# HTML entity decode: direct entities (not URL-encoded)
payload_direct_entity = payload.merge('text' => 'A+%26amp%3B+B')
parsed_direct = parser.parse(payload_direct_entity, config_finder)
test "parse: decodes &amp; → &", 'A & B', parsed_direct.text

# Czech HTML entities
payload_czech = payload.merge('text' => 'Pr%26aacute%3Bva+ob%26ccaron%3Ban%26uring%3B')
parsed_czech = parser.parse(payload_czech, config_finder)
test "parse: decodes Czech HTML entities", "Pr\u00E1va ob\u010Dan\u016F", parsed_czech.text

# Plain text without encoding (regression test)
payload_plain = payload.merge('text' => 'Hello world')
parsed_plain = parser.parse(payload_plain, config_finder)
test "parse: plain text passes through unchanged", 'Hello world', parsed_plain.text

# Complex production case: RT with %25
payload_rt_pct = payload.merge('text' => 'RT+%40business%3A+Syria+expects+growth+of+10%25+this+year')
parsed_rt_pct = parser.parse(payload_rt_pct, config_finder)
test "parse: production case RT with 10%25", 'RT @business: Syria expects growth of 10% this year', parsed_rt_pct.text

# ===========================================
# WebhookEditHandler Tests
# ===========================================

section "WebhookEditHandler"

# Mock edit detector
class MockEditDetector
  attr_accessor :check_result, :buffer_entries

  def initialize
    @check_result = { action: :publish_new }
    @buffer_entries = []
  end

  def check_for_edit(_source_id, _post_id, _username, _text)
    @check_result
  end

  def add_to_buffer(source_id, post_id, username, text, mastodon_id:)
    @buffer_entries << { source_id: source_id, post_id: post_id, mastodon_id: mastodon_id }
  end
end

# Mock state manager
class MockStateManager
  attr_reader :published, :updated

  def initialize
    @published = []
    @updated = []
  end

  def mark_published(source_id, post_id, post_url:, mastodon_status_id:, platform_uri: nil)
    @published << { source_id: source_id, post_id: post_id, mastodon_status_id: mastodon_status_id }
  end

  def mark_updated(mastodon_status_id, new_post_id, new_post_url: nil)
    @updated << { mastodon_status_id: mastodon_status_id, new_post_id: new_post_id }
  end
end

mock_detector = MockEditDetector.new
thread_cache = {}
handler = Webhook::WebhookEditHandler.new(mock_detector, thread_cache)

# Create a parsed payload struct
parsed_payload = Webhook::WebhookPayloadParser::ParsedPayload.new(
  bot_id: 'ct24',
  post_id: '123',
  username: 'CT24zive',
  text: 'Test text',
  bot_config: { id: 'ct24_twitter' },
  source_id: 'ct24_twitter'
)

# publish_new → nil (continue to normal flow)
mock_detector.check_result = { action: :publish_new }
result = quiet do
  handler.handle(
    parsed_payload,
    adapter: nil, payload: {}, force_tier2: false,
    publisher_getter: ->(_) { nil },
    formatter: ->(_post, _config) { '' },
    updater: ->(_id, _text, _config) { { success: false } },
    state_manager: MockStateManager.new,
    published_sources: Hash.new(0)
  )
end
test "edit_handler: publish_new returns nil", nil, result

# publish_new with superseded → nil (continue)
mock_detector.check_result = { action: :publish_new, superseded_post_id: '100' }
result2 = quiet do
  handler.handle(
    parsed_payload,
    adapter: nil, payload: {}, force_tier2: false,
    publisher_getter: ->(_) { nil },
    formatter: ->(_post, _config) { '' },
    updater: ->(_id, _text, _config) { { success: false } },
    state_manager: MockStateManager.new,
    published_sources: Hash.new(0)
  )
end
test "edit_handler: publish_new with superseded returns nil", nil, result2

# skip_older_version → :skipped
mock_detector.check_result = {
  action: :skip_older_version,
  original_post_id: '100',
  similarity: 0.95
}
result3 = quiet do
  handler.handle(
    parsed_payload,
    adapter: nil, payload: {}, force_tier2: false,
    publisher_getter: ->(_) { nil },
    formatter: ->(_post, _config) { '' },
    updater: ->(_id, _text, _config) { { success: false } },
    state_manager: MockStateManager.new,
    published_sources: Hash.new(0)
  )
end
test "edit_handler: skip_older_version returns :skipped", :skipped, result3

# update_existing with adapter returning nil → :skipped
mock_adapter_nil = Object.new
def mock_adapter_nil.process_webhook(payload, config, force_tier2:); nil; end

mock_detector.check_result = {
  action: :update_existing,
  original_post_id: '100',
  mastodon_id: 'masto_123',
  similarity: 0.85
}
result4 = quiet do
  handler.handle(
    parsed_payload,
    adapter: mock_adapter_nil, payload: {}, force_tier2: false,
    publisher_getter: ->(_) { nil },
    formatter: ->(_post, _config) { '' },
    updater: ->(_id, _text, _config) { { success: false } },
    state_manager: MockStateManager.new,
    published_sources: Hash.new(0)
  )
end
test "edit_handler: update_existing with nil adapter → :skipped", :skipped, result4

# update_existing with no media → simple update success
mock_post_no_media = Struct.new(:url, :media).new('https://twitter.com/test/123', nil)
mock_adapter_post = Object.new
mock_adapter_post.define_singleton_method(:process_webhook) { |_p, _c, force_tier2:| mock_post_no_media }

mock_state = MockStateManager.new
mock_detector2 = MockEditDetector.new
mock_detector2.check_result = {
  action: :update_existing,
  original_post_id: '100',
  mastodon_id: 'masto_123',
  similarity: 0.85
}
handler2 = Webhook::WebhookEditHandler.new(mock_detector2, thread_cache)
published_sources = Hash.new(0)

result5 = quiet do
  handler2.handle(
    parsed_payload,
    adapter: mock_adapter_post, payload: {}, force_tier2: false,
    publisher_getter: ->(_) { nil },
    formatter: ->(_post, _config) { 'formatted text' },
    updater: ->(_id, _text, _config) { { success: true, data: {} } },
    state_manager: mock_state,
    published_sources: published_sources
  )
end
test "edit_handler: simple update success → :updated", :updated, result5
test "edit_handler: simple update records to state", 1, mock_state.updated.count
test "edit_handler: simple update increments published_sources", 1, published_sources['ct24_twitter']
test "edit_handler: simple update adds to buffer", 1, mock_detector2.buffer_entries.count

# update_existing with failed update → nil (fallthrough)
mock_detector3 = MockEditDetector.new
mock_detector3.check_result = {
  action: :update_existing,
  original_post_id: '100',
  mastodon_id: 'masto_123',
  similarity: 0.85
}
handler3 = Webhook::WebhookEditHandler.new(mock_detector3, thread_cache)

result6 = quiet do
  handler3.handle(
    parsed_payload,
    adapter: mock_adapter_post, payload: {}, force_tier2: false,
    publisher_getter: ->(_) { nil },
    formatter: ->(_post, _config) { 'formatted text' },
    updater: ->(_id, _text, _config) { { success: false, error: 'not found' } },
    state_manager: MockStateManager.new,
    published_sources: Hash.new(0)
  )
end
test "edit_handler: failed update → nil (fallthrough)", nil, result6

# ===========================================
# WebhookEditHandler: Delete+Republish Tests
# ===========================================

section "WebhookEditHandler: Delete+Republish"

# Mock publisher for delete+republish tests
class MockPublisherDR
  attr_reader :deleted_ids, :published_calls, :uploaded_media

  def initialize(publish_result: nil, delete_raises: nil, publish_raises: nil)
    @deleted_ids = []
    @published_calls = []
    @uploaded_media = []
    @publish_result = publish_result || { 'id' => 'masto_new_999' }
    @delete_raises = delete_raises
    @publish_raises = publish_raises
    @publish_call_count = 0
  end

  def delete_status(id)
    raise @delete_raises if @delete_raises
    @deleted_ids << id
  end

  def upload_media_parallel(items)
    @uploaded_media.concat(items)
    items.map.with_index { |_, i| "media_#{i}" }
  end

  def publish(text, media_ids: [], in_reply_to_id: nil, visibility: nil)
    @publish_call_count += 1
    if @publish_raises
      # Only raise on first call (the republish), not the emergency fallback
      if @publish_call_count == 1
        raise @publish_raises
      end
    end
    @published_calls << { text: text, media_ids: media_ids, in_reply_to_id: in_reply_to_id }
    @publish_result
  end
end

# Mock media item
MockMedia = Struct.new(:url, :alt_text)

# Mock post with media
MockPostWithMedia = Struct.new(:url, :media) do
  def respond_to?(method, *args)
    [:url, :media].include?(method) || super
  end
end

# Test: in_reply_to_id se vyčistí po DELETE (pointed to deleted status)
dr_detector = MockEditDetector.new
dr_detector.check_result = {
  action: :update_existing,
  original_post_id: '100',
  mastodon_id: 'masto_old',
  similarity: 0.85
}
# Thread cache points to the status we're about to delete
dr_thread_cache = { 'ct24_twitter' => { 'ct24zive' => 'masto_old' } }
dr_handler = Webhook::WebhookEditHandler.new(dr_detector, dr_thread_cache)

dr_publisher = MockPublisherDR.new(publish_result: { 'id' => 'masto_new_123' })
dr_post = MockPostWithMedia.new('https://twitter.com/test/123', [MockMedia.new('https://img.jpg', 'alt')])
dr_adapter = Object.new
dr_adapter.define_singleton_method(:process_webhook) { |_p, _c, force_tier2:| dr_post }

dr_parsed = Webhook::WebhookPayloadParser::ParsedPayload.new(
  bot_id: 'ct24', post_id: '200', username: 'CT24zive', text: 'edited text',
  bot_config: { id: 'ct24_twitter' }, source_id: 'ct24_twitter'
)

dr_result = quiet do
  dr_handler.handle(
    dr_parsed,
    adapter: dr_adapter, payload: {}, force_tier2: false,
    publisher_getter: ->(_) { dr_publisher },
    formatter: ->(_post, _config) { 'formatted text' },
    updater: ->(_id, _text, _config) { { success: false } },
    state_manager: MockStateManager.new,
    published_sources: Hash.new(0)
  )
end

test "delete+republish: returns :updated", :updated, dr_result
test "delete+republish: deleted the original status", ['masto_old'], dr_publisher.deleted_ids
test "delete+republish: in_reply_to cleared (was deleted status)", nil, dr_publisher.published_calls[0][:in_reply_to_id]

# Test: Thread cache updated after republish
test "delete+republish: thread cache updated to new ID", 'masto_new_123', dr_thread_cache.dig('ct24_twitter', 'ct24zive')

# Test: in_reply_to preserved when it points to a DIFFERENT status (not the deleted one)
dr_detector2 = MockEditDetector.new
dr_detector2.check_result = {
  action: :update_existing,
  original_post_id: '100',
  mastodon_id: 'masto_old',
  similarity: 0.85
}
dr_thread_cache2 = { 'ct24_twitter' => { 'ct24zive' => 'masto_parent_different' } }
dr_handler2 = Webhook::WebhookEditHandler.new(dr_detector2, dr_thread_cache2)
dr_publisher2 = MockPublisherDR.new(publish_result: { 'id' => 'masto_new_456' })

dr_result2 = quiet do
  dr_handler2.handle(
    dr_parsed,
    adapter: dr_adapter, payload: {}, force_tier2: false,
    publisher_getter: ->(_) { dr_publisher2 },
    formatter: ->(_post, _config) { 'formatted text' },
    updater: ->(_id, _text, _config) { { success: false } },
    state_manager: MockStateManager.new,
    published_sources: Hash.new(0)
  )
end

test "delete+republish: in_reply_to preserved when not deleted ID", 'masto_parent_different', dr_publisher2.published_calls[0][:in_reply_to_id]

# Test: After successful DELETE, publish fails → emergency publish as new (no simple update)
dr_detector3 = MockEditDetector.new
dr_detector3.check_result = {
  action: :update_existing,
  original_post_id: '100',
  mastodon_id: 'masto_old',
  similarity: 0.85
}
dr_thread_cache3 = {}
dr_handler3 = Webhook::WebhookEditHandler.new(dr_detector3, dr_thread_cache3)
dr_publisher3 = MockPublisherDR.new(
  publish_result: { 'id' => 'masto_emergency_789' },
  publish_raises: StandardError.new("Record not found")
)

update_called = false
dr_result3 = quiet do
  dr_handler3.handle(
    dr_parsed,
    adapter: dr_adapter, payload: {}, force_tier2: false,
    publisher_getter: ->(_) { dr_publisher3 },
    formatter: ->(_post, _config) { 'formatted text' },
    updater: ->(_id, _text, _config) { update_called = true; { success: false } },
    state_manager: MockStateManager.new,
    published_sources: Hash.new(0)
  )
end

test "delete+republish: emergency publish returns :updated", :updated, dr_result3
test "delete+republish: simple update NOT called after successful delete", false, update_called
# Emergency publish should have been called without in_reply_to_id
test "delete+republish: emergency publish has no in_reply_to", nil, dr_publisher3.published_calls[1]&.dig(:in_reply_to_id)

# Test: DELETE fails → fallback to simple update (existing behavior preserved)
dr_detector4 = MockEditDetector.new
dr_detector4.check_result = {
  action: :update_existing,
  original_post_id: '100',
  mastodon_id: 'masto_old',
  similarity: 0.85
}
dr_handler4 = Webhook::WebhookEditHandler.new(dr_detector4, {})
dr_publisher4 = MockPublisherDR.new(delete_raises: StandardError.new("Network error"))

simple_update_called = false
dr_result4 = quiet do
  dr_handler4.handle(
    dr_parsed,
    adapter: dr_adapter, payload: {}, force_tier2: false,
    publisher_getter: ->(_) { dr_publisher4 },
    formatter: ->(_post, _config) { 'formatted text' },
    updater: ->(_id, _text, _config) { simple_update_called = true; { success: true, data: {} } },
    state_manager: MockStateManager.new,
    published_sources: Hash.new(0)
  )
end

test "delete+republish: failed delete falls through to simple update", true, simple_update_called
test "delete+republish: failed delete → simple update returns :updated", :updated, dr_result4

# ===========================================
# WebhookThreadHandler Tests (TASK-10)
# ===========================================
# New interface: tweet_processor: instead of thread_processor_getter: + thread_parent_resolver:
# handle() returns Symbol (:published/:skipped/:failed) instead of ThreadResult

section "WebhookThreadHandler"

# Mock adapter: parse_ifttt_payload → ifttt_data hash, process_tier1 → Post
mock_wth_adapter = Object.new
mock_wth_adapter.define_singleton_method(:parse_ifttt_payload) do |payload|
  return nil unless payload.is_a?(Hash) && !payload.empty?
  { post_id: '456', text: payload['text'] || 'hello', username: 'test',
    embed_code: '', link_to_tweet: '', first_link_url: '', received_at: Time.now }
end
mock_wth_fallback = Struct.new(:url).new('https://twitter.com/test/456')
mock_wth_adapter.define_singleton_method(:process_tier1) { |_data, _config| mock_wth_fallback }

basic_parsed = Webhook::WebhookPayloadParser::ParsedPayload.new(
  bot_id: 'ct24', post_id: '456', username: 'test', text: 'hello',
  bot_config: { id: 'ct24_twitter' }, source_id: 'ct24_twitter'
)

# Returns :published
mock_tweet_proc = Object.new
mock_tweet_proc.define_singleton_method(:process) { |**_kwargs| :published }
thread_handler = Webhook::WebhookThreadHandler.new(mock_wth_adapter, tweet_processor: mock_tweet_proc)
result_published = quiet { thread_handler.handle(basic_parsed, payload: { 'text' => 'hello' }, force_tier2: false) }
test "thread_handler: returns :published", :published, result_published

# Returns :skipped
mock_tweet_proc_skip = Object.new
mock_tweet_proc_skip.define_singleton_method(:process) { |**_kwargs| :skipped }
thread_handler_skip = Webhook::WebhookThreadHandler.new(mock_wth_adapter, tweet_processor: mock_tweet_proc_skip)
result_skipped = quiet { thread_handler_skip.handle(basic_parsed, payload: { 'text' => 'hello' }, force_tier2: false) }
test "thread_handler: returns :skipped", :skipped, result_skipped

# Returns :failed
mock_tweet_proc_fail = Object.new
mock_tweet_proc_fail.define_singleton_method(:process) { |**_kwargs| :failed }
thread_handler_fail = Webhook::WebhookThreadHandler.new(mock_wth_adapter, tweet_processor: mock_tweet_proc_fail)
result_failed = quiet { thread_handler_fail.handle(basic_parsed, payload: { 'text' => 'hello' }, force_tier2: false) }
test "thread_handler: returns :failed", :failed, result_failed

# parse_ifttt_payload returns nil → fallback_post = nil, tweet_processor still called
nil_parse_adapter = Object.new
nil_parse_adapter.define_singleton_method(:parse_ifttt_payload) { |_p| nil }
nil_parse_adapter.define_singleton_method(:process_tier1) { |_d, _c| raise "should not be called" }

received_fallback_wth = nil
mock_tweet_proc_cap = Object.new
mock_tweet_proc_cap.define_singleton_method(:process) do |**kwargs|
  received_fallback_wth = kwargs[:fallback_post]
  :published
end
thread_handler_nil_parse = Webhook::WebhookThreadHandler.new(nil_parse_adapter, tweet_processor: mock_tweet_proc_cap)
quiet { thread_handler_nil_parse.handle(basic_parsed, payload: {}, force_tier2: false) }
test "thread_handler: nil parse_ifttt_payload → fallback_post = nil", nil, received_fallback_wth

# process_tier1 raises → fallback_post = nil (rescued), tweet_processor still called
raise_adapter = Object.new
raise_adapter.define_singleton_method(:parse_ifttt_payload) do |_p|
  { post_id: '1', text: 'test', username: 'test',
    embed_code: '', link_to_tweet: '', first_link_url: '', received_at: Time.now }
end
raise_adapter.define_singleton_method(:process_tier1) { |_d, _c| raise StandardError, "simulated tier1 error" }

received_fallback_wth2 = nil
mock_tweet_proc_cap2 = Object.new
mock_tweet_proc_cap2.define_singleton_method(:process) do |**kwargs|
  received_fallback_wth2 = kwargs[:fallback_post]
  :published
end
thread_handler_raise = Webhook::WebhookThreadHandler.new(raise_adapter, tweet_processor: mock_tweet_proc_cap2)
quiet { thread_handler_raise.handle(basic_parsed, payload: { 'text' => 'test' }, force_tier2: false) }
test "thread_handler: process_tier1 error → fallback_post = nil", nil, received_fallback_wth2

# source_handle from bot_config[:source][:handle] overrides IFTTT username
received_username_wth = nil
mock_tweet_proc_user = Object.new
mock_tweet_proc_user.define_singleton_method(:process) do |**kwargs|
  received_username_wth = kwargs[:username]
  :published
end
parsed_with_handle = Webhook::WebhookPayloadParser::ParsedPayload.new(
  bot_id: 'drozd', post_id: '999', username: 'drozd',
  bot_config: { id: 'drozd_twitter', source: { handle: 'mzvcr' } },
  source_id: 'drozd_twitter'
)
thread_handler_handle = Webhook::WebhookThreadHandler.new(mock_wth_adapter, tweet_processor: mock_tweet_proc_user)
quiet { thread_handler_handle.handle(parsed_with_handle, payload: { 'text' => 'test' }, force_tier2: false) }
test "thread_handler: source_handle overrides IFTTT username", 'mzvcr', received_username_wth

# ===========================================
# WebhookPublisher Tests
# ===========================================

section "WebhookPublisher"

# Mock PostProcessor result
MockResult = Struct.new(:status, :mastodon_id, :skipped_reason, :error, keyword_init: true)

# Mock PostProcessor
class MockPostProcessor
  attr_accessor :result

  def initialize(result)
    @result = result
  end

  def process(_post, _config, _options)
    @result
  end
end

# Mock edit detector for publisher
mock_detector_pub = MockEditDetector.new

# Published successfully
mock_pp = MockPostProcessor.new(MockResult.new(status: :published, mastodon_id: 'masto_999'))
cache_updates = []
publisher = Webhook::WebhookPublisher.new(
  mock_pp, mock_detector_pub,
  thread_cache_updater: ->(source_id, post, mastodon_id) { cache_updates << [source_id, mastodon_id] }
)

pub_parsed = Webhook::WebhookPayloadParser::ParsedPayload.new(
  bot_id: 'ct24', post_id: '111', username: 'test', text: 'publish me',
  bot_config: { id: 'ct24_twitter' }, source_id: 'ct24_twitter'
)
mock_post = Struct.new(:url).new('https://twitter.com/test/111')
pub_sources = Hash.new(0)

result_pub = quiet do
  publisher.publish(
    pub_parsed, mock_post,
    in_reply_to_id: nil,
    published_sources: pub_sources
  )
end
test "webhook_publisher: published → :published", :published, result_pub
test "webhook_publisher: increments published_sources", 1, pub_sources['ct24_twitter']
test "webhook_publisher: adds to edit buffer", 1, mock_detector_pub.buffer_entries.count
test "webhook_publisher: buffer entry has correct mastodon_id", 'masto_999', mock_detector_pub.buffer_entries[0][:mastodon_id]
test "webhook_publisher: updates thread cache", 1, cache_updates.count
test "webhook_publisher: thread cache has correct data", ['ct24_twitter', 'masto_999'], cache_updates[0]

# Skipped
mock_pp_skip = MockPostProcessor.new(MockResult.new(status: :skipped, skipped_reason: 'duplicate'))
publisher_skip = Webhook::WebhookPublisher.new(
  mock_pp_skip, MockEditDetector.new,
  thread_cache_updater: ->(_s, _p, _m) { }
)
result_skip = quiet { publisher_skip.publish(pub_parsed, mock_post, in_reply_to_id: nil, published_sources: Hash.new(0)) }
test "webhook_publisher: skipped → :skipped", :skipped, result_skip

# Failed
mock_pp_fail = MockPostProcessor.new(MockResult.new(status: :failed, error: 'network error'))
publisher_fail = Webhook::WebhookPublisher.new(
  mock_pp_fail, MockEditDetector.new,
  thread_cache_updater: ->(_s, _p, _m) { }
)
result_fail = quiet { publisher_fail.publish(pub_parsed, mock_post, in_reply_to_id: nil, published_sources: Hash.new(0)) }
test "webhook_publisher: failed → :failed", :failed, result_fail

# With in_reply_to_id
process_called_with = nil
class TrackingPostProcessor
  attr_reader :last_options
  def initialize(result)
    @result = result
  end
  def process(_post, _config, options)
    @last_options = options
    @result
  end
end

tracking_pp = TrackingPostProcessor.new(MockResult.new(status: :published, mastodon_id: 'masto_thread'))
publisher_thread = Webhook::WebhookPublisher.new(
  tracking_pp, MockEditDetector.new,
  thread_cache_updater: ->(_s, _p, _m) { }
)
quiet { publisher_thread.publish(pub_parsed, mock_post, in_reply_to_id: 'parent_555', published_sources: Hash.new(0)) }
test "webhook_publisher: passes in_reply_to_id to PostProcessor", 'parent_555', tracking_pp.last_options[:in_reply_to_id]

# ===========================================
# BUG-7: find_bot_config lookup order (bot_id first)
# ===========================================

section "BUG-7: bot_id lookup priority"

# Simulate two sources sharing the same Twitter handle (watchdog pattern)
config_chmuchmi = { id: 'chmuchmi_twitter', platform: 'twitter', source: { handle: 'chmuchmi' } }
config_vystrahy = { id: 'vystrahy_chmuchmi_twitter', platform: 'twitter', source: { handle: 'chmuchmi' } }

# Config finder that resolves bot_id → config directly
shared_handle_finder = ->(bot_id, _username) do
  case bot_id&.downcase
  when 'chmuchmi_twitter' then config_chmuchmi
  when 'vystrahy_chmuchmi_twitter' then config_vystrahy
  else nil
  end
end

# bot_id=vystrahy_chmuchmi_twitter, username=chmuchmi → must find vystrahy config
parsed_vystrahy = parser.parse(
  { 'bot_id' => 'vystrahy_chmuchmi_twitter', 'username' => 'chmuchmi',
    'text' => 'Test', 'link_to_tweet' => 'https://twitter.com/chmuchmi/status/111' },
  shared_handle_finder
)
test "BUG-7: bot_id=vystrahy finds vystrahy config", 'vystrahy_chmuchmi_twitter', parsed_vystrahy.source_id

# bot_id=chmuchmi_twitter, username=chmuchmi → must find chmuchmi config
parsed_chmuchmi = parser.parse(
  { 'bot_id' => 'chmuchmi_twitter', 'username' => 'chmuchmi',
    'text' => 'Test', 'link_to_tweet' => 'https://twitter.com/chmuchmi/status/222' },
  shared_handle_finder
)
test "BUG-7: bot_id=chmuchmi finds chmuchmi config", 'chmuchmi_twitter', parsed_chmuchmi.source_id

# bot_id=unknown, username=chmuchmi → finder returns nil (fallback scenario)
parsed_unknown = parser.parse(
  { 'bot_id' => 'unknown', 'username' => 'chmuchmi',
    'text' => 'Test', 'link_to_tweet' => 'https://twitter.com/chmuchmi/status/333' },
  shared_handle_finder
)
test "BUG-7: unknown bot_id → nil config (finder returns nil)", nil, parsed_unknown&.source_id

# ===========================================
# BUG-2: nil config_finder result
# ===========================================

section "BUG-2: nil config guard"

nil_finder = ->(_bot_id, _username) { nil }
parsed_nil = parser.parse(
  { 'bot_id' => 'unknown', 'username' => 'nobody',
    'text' => 'Test', 'link_to_tweet' => 'https://twitter.com/nobody/status/444' },
  nil_finder
)
test "BUG-2: nil config_finder result → parse returns nil", nil, parsed_nil

# ===========================================
# Summary
# ===========================================

puts
puts "=" * 60
if $failed == 0
  puts "\e[32m\u2705 All #{$passed} tests passed!\e[0m"
else
  puts "\e[31m\u274c #{$failed} failed, #{$passed} passed\e[0m"
end
puts "=" * 60

exit($failed > 0 ? 1 : 0)
