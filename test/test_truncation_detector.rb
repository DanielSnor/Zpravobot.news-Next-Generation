#!/usr/bin/env ruby
# frozen_string_literal: true

# Test Utils::TruncationDetector
# Run: ruby test/test_truncation_detector.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/utils/truncation_detector'

puts '=' * 60
puts 'TruncationDetector Tests'
puts '=' * 60
puts

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

T = Utils::TruncationDetector

# =============================================================================
# has_natural_terminator?
# =============================================================================
section 'has_natural_terminator?: positive cases'

test 'period', true, T.has_natural_terminator?('Ended with a period.')
test 'exclamation', true, T.has_natural_terminator?('Wow!')
test 'question', true, T.has_natural_terminator?('Really?')
test 'ellipsis char', true, T.has_natural_terminator?('Trailing off…')
test 'CJK punctuation', true, T.has_natural_terminator?('結束。')
test 'emoji', true, T.has_natural_terminator?('All good 👍')
test 'hashtag', true, T.has_natural_terminator?('Big news #breaking')
test 'mention', true, T.has_natural_terminator?('Reply to @someone')
test 'full URL', true, T.has_natural_terminator?('See https://example.com/article')

section 'has_natural_terminator?: negative cases'

test 'mid-sentence comma', false, T.has_natural_terminator?('Continuing on,')
test 'mid-word', false, T.has_natural_terminator?('Some long sentence that')
test 'trailing t.co stripped → no terminator', false,
     T.has_natural_terminator?('Cut mid-sentence with https://t.co/abc')
test 'trailing t.co stripped → exposes period', true,
     T.has_natural_terminator?('Ended. https://t.co/abc')
test 'empty', false, T.has_natural_terminator?('')
test 'nil', false, T.has_natural_terminator?(nil)

# =============================================================================
# detect_and_mark — below threshold
# =============================================================================
section 'detect_and_mark: below threshold returns unchanged'

short = 'Short text under any threshold'
r = T.detect_and_mark(short, threshold: 270)
test 'short text → text unchanged', short, r[:text]
test 'short text → not truncated', false, r[:truncated]
test 'short text → no ellipsis added', false, r[:ellipsis_added]

# =============================================================================
# detect_and_mark — at/above threshold
# =============================================================================
section 'detect_and_mark: at threshold, no terminator → adds ellipsis'

long_no_term = 'a' * 269 + ' and then'  # 278 chars, ends with conjunction
r = T.detect_and_mark(long_no_term, threshold: 270)
test 'ends with conjunction → truncated', true, r[:truncated]
test 'ends with conjunction → ellipsis added', true, r[:ellipsis_added]
test 'ends with conjunction → text ends with …', true, r[:text].end_with?('…')

section 'detect_and_mark: at threshold WITH terminator → no change'

long_with_period = 'a' * 269 + ' end.'  # ends with period
r = T.detect_and_mark(long_with_period, threshold: 270)
test 'ends with period → not truncated', false, r[:truncated]
test 'ends with period → no ellipsis', false, r[:ellipsis_added]
test 'ends with period → unchanged', long_with_period, r[:text]

long_with_emoji = 'a' * 269 + ' done 👍'
r = T.detect_and_mark(long_with_emoji, threshold: 270)
test 'ends with emoji → not truncated', false, r[:truncated]

long_with_hashtag = 'a' * 269 + ' #news'
r = T.detect_and_mark(long_with_hashtag, threshold: 270)
test 'ends with hashtag → not truncated', false, r[:truncated]

# =============================================================================
# detect_and_mark — trailing t.co
# =============================================================================
section 'detect_and_mark: trailing t.co is a truncation signal'

long_with_tco = 'a' * 240 + ' more words here https://t.co/abc123'
r = T.detect_and_mark(long_with_tco, threshold: 270)
test 'long with bare t.co → truncated', true, r[:truncated]
test 'long with bare t.co → ellipsis added', true, r[:ellipsis_added]
test 'long with bare t.co → ends with …', true, r[:text].end_with?('…')

# Even though text has a "URL terminator" pattern, t.co specifically signals cut
long_period_then_tco = 'a' * 240 + ' finished. https://t.co/abc'
r = T.detect_and_mark(long_period_then_tco, threshold: 270)
test 'period before t.co → not truncated (terminator wins)', false, r[:truncated]

# =============================================================================
# detect_and_mark — idempotence
# =============================================================================
section 'detect_and_mark: idempotence'

long_no_term2 = 'b' * 269 + ' and'
first  = T.detect_and_mark(long_no_term2, threshold: 270)
second = T.detect_and_mark(first[:text], threshold: 270)
test 'second pass → still ends with single …', true, second[:text].end_with?('…') && !second[:text].end_with?('……')
test 'second pass → ellipsis_added false', false, second[:ellipsis_added]
test 'second pass → truncated still true', true, second[:truncated]
test 'second pass → text identical to first', first[:text], second[:text]

# =============================================================================
# detect_and_mark — edge cases
# =============================================================================
section 'detect_and_mark: edge cases'

r = T.detect_and_mark(nil, threshold: 270)
test 'nil input → text nil', nil, r[:text]
test 'nil input → not truncated', false, r[:truncated]

r = T.detect_and_mark('', threshold: 270)
test 'empty input → text empty', '', r[:text]
test 'empty input → not truncated', false, r[:truncated]

# IFTTT threshold lower than syndication
long_257 = 'c' * 256 + ' and'  # 260 chars
r = T.detect_and_mark(long_257, threshold: T::IFTTT_THRESHOLD)
test 'IFTTT threshold catches 260-char no-terminator text', true, r[:truncated]

r = T.detect_and_mark(long_257, threshold: T::SYNDICATION_THRESHOLD)
test 'Syndication threshold lets 260-char text through (below 270)', false, r[:truncated]

# =============================================================================
# mark_as_truncated (force variant for definitive signal)
# =============================================================================
section 'mark_as_truncated: unconditional marking'

r = T.mark_as_truncated('Short text that ends with a period.')
test 'short text with period → still marked truncated', true, r[:truncated]
test 'short text with period → ellipsis appended', true, r[:text].end_with?('…')

r = T.mark_as_truncated('Already marked…')
test 'already marked → truncated true', true, r[:truncated]
test 'already marked → ellipsis_added false', false, r[:ellipsis_added]
test 'already marked → no double ellipsis', 'Already marked…', r[:text]

r = T.mark_as_truncated(nil)
test 'nil → text nil', nil, r[:text]
test 'nil → not truncated', false, r[:truncated]

r = T.mark_as_truncated('')
test 'empty → text empty', '', r[:text]
test 'empty → not truncated', false, r[:truncated]

# =============================================================================
# Summary
# =============================================================================
puts
puts '=' * 60
puts "Passed: #{$passed}, Failed: #{$failed}"
puts '=' * 60
exit($failed.zero? ? 0 : 1)
