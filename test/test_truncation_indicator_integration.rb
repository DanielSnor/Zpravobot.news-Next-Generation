#!/usr/bin/env ruby
# frozen_string_literal: true

# Integration tests for PostProcessor#mark_source_truncation
# ==========================================================
# Covers:
#   - Tier 1.5 regression: Twitter source + long incomplete text → ellipsis + force_read_more
#   - Platform gating: Bluesky/RSS/YouTube → no indicator
#   - Source override beats platform default (both ways)
#   - Custom threshold per source
#   - Edit-path parity: trim_text(post:) marks identically to process
#   - Tier 3 fallback: short text retains force_read_more without ellipsis
#
# Run: ruby test/test_truncation_indicator_integration.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

# Minimal stubs — only what mark_source_truncation needs
module Processors
  class ContentProcessor
    def initialize(max_length:, strategy: :smart, tolerance_percent: 12)
      @max_length = max_length
    end

    def process(text)
      return text if text.length <= @max_length
      text[0...@max_length - 1] + '…'
    end
  end
end

require_relative '../lib/processors/post_processor'
require_relative '../lib/formatters/universal_formatter'

# Lightweight stand-ins
class StubPost
  attr_accessor :raw
  def initialize(raw: nil)
    @raw = raw
  end
end

class StubStateManager; end
class StubConfigLoader; end

$passed = 0
$failed = 0

def test(name, expected, actual)
  if expected == actual
    puts "  \e[32m✓\e[0m #{name}"
    $passed += 1
  else
    puts "  \e[31m✗\e[0m #{name}"
    puts "    Expected: #{expected.inspect}"
    puts "    Actual:   #{actual.inspect}"
    $failed += 1
  end
end

def section(title)
  puts
  puts "--- #{title} ---"
end

def build_processor
  Processors::PostProcessor.new(
    state_manager: StubStateManager.new,
    config_loader: StubConfigLoader.new
  )
end

def mark(processor, text, post, source_config)
  processor.send(:mark_source_truncation, text, post, source_config)
end

def resolve_cfg(processor, source_config)
  processor.send(:resolve_truncation_indicator_config, source_config)
end

LONG_NO_TERM     = 'a' * 269 + ' more words and'   # 285 chars, no terminator
LONG_WITH_PERIOD = 'b' * 269 + ' finished here.'   # ends with period
LONG_WITH_TCO    = 'c' * 240 + ' more words here https://t.co/abc123' # bare t.co
SHORT_TEXT       = 'Just a brief tweet'

processor = build_processor

puts '=' * 60
puts 'TruncationIndicator Integration Tests'
puts '=' * 60

# =============================================================================
# Twitter source (gating ON via PLATFORM_DEFAULTS)
# =============================================================================
section 'Twitter source: default gating'

twitter_config = { id: 'tw_test', platform: 'twitter', processing: {} }

post = StubPost.new
result = mark(processor, LONG_NO_TERM, post, twitter_config)
test 'long no-terminator → ends with …', true, result.end_with?('…')
test 'long no-terminator → force_read_more set', true, post.raw[:force_read_more]
test 'long no-terminator → truncated set', true, post.raw[:truncated]
test 'long no-terminator → ellipsis_added flag set', true, post.raw[:ellipsis_added]

post = StubPost.new
result = mark(processor, LONG_WITH_PERIOD, post, twitter_config)
test 'long with period → unchanged', LONG_WITH_PERIOD, result
test 'long with period → no raw flags', nil, post.raw

post = StubPost.new
result = mark(processor, SHORT_TEXT, post, twitter_config)
test 'short text → unchanged', SHORT_TEXT, result
test 'short text → no raw flags', nil, post.raw

post = StubPost.new
result = mark(processor, LONG_WITH_TCO, post, twitter_config)
test 'long with bare t.co → ends with …', true, result.end_with?('…')
test 'long with bare t.co → force_read_more', true, post.raw[:force_read_more]

# =============================================================================
# Bluesky / RSS / YouTube — gating OFF
# =============================================================================
section 'Platform gating OFF: no indicator applied'

%w[bluesky rss youtube].each do |platform|
  config = { id: "#{platform}_test", platform: platform, processing: {} }
  post = StubPost.new
  result = mark(processor, LONG_NO_TERM, post, config)
  test "#{platform}: long no-term → text unchanged", LONG_NO_TERM, result
  test "#{platform}: long no-term → no raw flags", nil, post.raw
end

# =============================================================================
# Per-source override
# =============================================================================
section 'Source override beats platform default'

# Twitter disabled by source
config = {
  id: 'tw_off', platform: 'twitter',
  processing: { truncation_indicator: { enabled: false } }
}
post = StubPost.new
result = mark(processor, LONG_NO_TERM, post, config)
test 'twitter + source disables → unchanged', LONG_NO_TERM, result
test 'twitter + source disables → no raw flags', nil, post.raw

# Bluesky enabled by source
config = {
  id: 'bsky_on', platform: 'bluesky',
  processing: { truncation_indicator: { enabled: true, threshold: 270 } }
}
post = StubPost.new
result = mark(processor, LONG_NO_TERM, post, config)
test 'bluesky + source enables → ellipsis added', true, result.end_with?('…')
test 'bluesky + source enables → force_read_more set', true, post.raw[:force_read_more]

# Custom threshold (much lower than 270)
config = {
  id: 'tw_low', platform: 'twitter',
  processing: { truncation_indicator: { enabled: true, threshold: 50 } }
}
post = StubPost.new
short_no_term = 'a' * 60 + ' and'
result = mark(processor, short_no_term, post, config)
test 'custom low threshold → 60-char text marked', true, result.end_with?('…')

# =============================================================================
# resolve_truncation_indicator_config
# =============================================================================
section 'resolve_truncation_indicator_config'

cfg = resolve_cfg(processor, { platform: 'twitter', processing: {} })
test 'twitter default → enabled', true, cfg[:enabled]
test 'twitter default → threshold 270', 270, cfg[:threshold]

cfg = resolve_cfg(processor, { platform: 'bluesky', processing: {} })
test 'bluesky default → disabled', false, cfg[:enabled]

cfg = resolve_cfg(processor, {
  platform: 'twitter',
  processing: { truncation_indicator: { threshold: 200 } }
})
test 'source threshold overrides default', 200, cfg[:threshold]
test 'source partial override keeps platform enabled', true, cfg[:enabled]

cfg = resolve_cfg(processor, { platform: 'unknown_platform', processing: {} })
test 'unknown platform → disabled', false, cfg[:enabled]

# =============================================================================
# Edit-path parity: trim_text(post:) marks the same as process
# =============================================================================
section 'Edit-path parity: trim_text(post:)'

post = StubPost.new
result = processor.trim_text(LONG_NO_TERM, twitter_config, post: post)
test 'trim_text with post → ellipsis added', true, result.end_with?('…')
test 'trim_text with post → force_read_more set', true, post.raw[:force_read_more]

# Without post: → backward-compat, no indicator applied
post = StubPost.new
result = processor.trim_text(LONG_NO_TERM, twitter_config)
test 'trim_text without post → no force_read_more', nil, post.raw

# =============================================================================
# Idempotence: re-running on already-marked text
# =============================================================================
section 'Idempotence'

post = StubPost.new
once = mark(processor, LONG_NO_TERM, post, twitter_config)
twice = mark(processor, once, post, twitter_config)
test 'second pass → no double ellipsis', true, twice.end_with?('…') && !twice.end_with?('……')
test 'second pass → text identical', once, twice
test 'second pass → flags still set', true, post.raw[:force_read_more]

# =============================================================================
# Nil/empty text guard
# =============================================================================
section 'Edge cases'

post = StubPost.new
test 'nil text → nil', nil, mark(processor, nil, post, twitter_config)
test 'nil text → no raw flags', nil, post.raw

post = StubPost.new
test 'empty text → empty', '', mark(processor, '', post, twitter_config)
test 'empty text → no raw flags', nil, post.raw

# Existing raw hash preserved
post = StubPost.new(raw: { source: 'syndication', tier: 1.5 })
mark(processor, LONG_NO_TERM, post, twitter_config)
test 'existing raw → preserves source', 'syndication', post.raw[:source]
test 'existing raw → preserves tier', 1.5, post.raw[:tier]
test 'existing raw → adds force_read_more', true, post.raw[:force_read_more]

# =============================================================================
# is_note_tweet — definitive signal bypasses heuristic
# =============================================================================
section 'is_note_tweet: definitive truncation marker'

# Note Tweet ending with a period (heuristic would say "ok") → still marked truncated
note_with_period = 'a' * 269 + ' ends with a period.'
post = StubPost.new(raw: { is_note_tweet: true })
result = mark(processor, note_with_period, post, twitter_config)
test 'note_tweet + ends with period → ellipsis added (bypass heuristic)', true, result.end_with?('…')
test 'note_tweet → force_read_more set', true, post.raw[:force_read_more]
test 'note_tweet → truncated set', true, post.raw[:truncated]
test 'note_tweet → preserves is_note_tweet flag', true, post.raw[:is_note_tweet]

# Note Tweet short text (heuristic would skip below threshold) → still marked
short_note = 'Short text that ends fine.'
post = StubPost.new(raw: { is_note_tweet: true })
result = mark(processor, short_note, post, twitter_config)
test 'note_tweet + short text → still marked truncated', true, result.end_with?('…')
test 'note_tweet + short text → force_read_more set', true, post.raw[:force_read_more]

# is_note_tweet: false should not trigger (regression guard)
post = StubPost.new(raw: { is_note_tweet: false })
result = mark(processor, LONG_WITH_PERIOD, post, twitter_config)
test 'is_note_tweet=false + long with period → unchanged', LONG_WITH_PERIOD, result
test 'is_note_tweet=false + long with period → no force_read_more', nil, post.raw[:force_read_more]

# Gating still applies: Bluesky source with is_note_tweet → still off
bsky_config = { id: 'bsky_test', platform: 'bluesky', processing: {} }
post = StubPost.new(raw: { is_note_tweet: true })
result = mark(processor, note_with_period, post, bsky_config)
test 'bluesky + is_note_tweet → gating off, unchanged', note_with_period, result
test 'bluesky + is_note_tweet → no raw flips', nil, post.raw[:force_read_more]

# =============================================================================
# Summary
# =============================================================================
puts
puts '=' * 60
puts "Passed: #{$passed}, Failed: #{$failed}"
puts '=' * 60
exit($failed.zero? ? 0 : 1)
