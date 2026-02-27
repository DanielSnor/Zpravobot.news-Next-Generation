#!/usr/bin/env ruby
# frozen_string_literal: true

# Test Webhook::IftttQueueProcessor (Phase 15.1)
# Validates extract helpers, partition, detect authors, constants (no DB/HTTP)
# Uses allocate to bypass constructor (avoids StateManager/PostgreSQL)
# Run: ruby test/test_ifttt_queue_processor.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

# Stub 'pg' gem to avoid PostgreSQL dependency in unit tests
# IftttQueueProcessor requires state_manager → database_connection → pg
unless defined?(PG)
  module PG
    class Connection
      def initialize(*); end
    end
    class Error < StandardError; end
  end
  $LOADED_FEATURES << 'pg.rb'
end

require_relative '../lib/webhook/ifttt_queue_processor'

puts "=" * 60
puts "IftttQueueProcessor Tests"
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

# Create instance without calling initialize (avoids DB/config dependencies)
processor = Webhook::IftttQueueProcessor.allocate
processor.instance_variable_set(:@priority_cache, {})
processor.instance_variable_set(:@thread_cache, {})

# =============================================================================
# Constants
# =============================================================================
section("Constants")

test("BATCH_DELAY is 120", 120, Webhook::IftttQueueProcessor::BATCH_DELAY)
test("MAX_AGE is 1800", 1800, Webhook::IftttQueueProcessor::MAX_AGE)
test("PRIORITY_HIGH is 'high'", 'high', Webhook::IftttQueueProcessor::PRIORITY_HIGH)
test("PRIORITY_NORMAL is 'normal'", 'normal', Webhook::IftttQueueProcessor::PRIORITY_NORMAL)
test("PRIORITY_LOW is 'low'", 'low', Webhook::IftttQueueProcessor::PRIORITY_LOW)
test("DEFAULT_PRIORITY is PRIORITY_NORMAL", 'normal', Webhook::IftttQueueProcessor::DEFAULT_PRIORITY)
test("EDIT_BUFFER_CLEANUP_HOURS is 2", 2, Webhook::IftttQueueProcessor::EDIT_BUFFER_CLEANUP_HOURS)

# =============================================================================
# extract_username_from_filename
# =============================================================================
section("extract_username_from_filename")

test("standard filename extracts username",
     'andrewofpolesia',
     processor.send(:extract_username_from_filename, '20260128061014529_andrewofpolesia_2016392716460937235.json'))

test("filename with path prefix",
     'ct24zive',
     processor.send(:extract_username_from_filename, '/app/data/queue/20260128_ct24zive_12345.json'))

test("username is lowercased",
     'uppercase',
     processor.send(:extract_username_from_filename, '20260128_UPPERCASE_12345.json'))

test("fewer than 3 parts returns nil",
     nil,
     processor.send(:extract_username_from_filename, 'onlytwoparts.json'))

test("exactly 2 parts returns nil",
     nil,
     processor.send(:extract_username_from_filename, 'timestamp_username.json'))

# =============================================================================
# partition_by_priority
# =============================================================================
section("partition_by_priority")

# Pre-seed priority cache for known usernames
processor.instance_variable_set(:@priority_cache, {
  'highpri' => 'high',
  'lowpri' => 'low',
  'normalpri' => 'normal'
})

# Empty array
high, normal, low = processor.send(:partition_by_priority, [])
test("empty array: high is empty", [], high)
test("empty array: normal is empty", [], normal)
test("empty array: low is empty", [], low)

# Mixed priorities
files = [
  '20260128_highpri_111.json',
  '20260128_normalpri_222.json',
  '20260128_lowpri_333.json',
  '20260128_highpri_444.json'
]
high, normal, low = processor.send(:partition_by_priority, files)
test("high priority files collected",
     2, high.length)
test("normal priority files collected",
     1, normal.length)
test("low priority files collected",
     1, low.length)

# Unknown username defaults to normal
unknown_files = ['20260128_unknownuser_555.json']
processor.instance_variable_get(:@priority_cache).delete('unknownuser')
high, normal, low = processor.send(:partition_by_priority, unknown_files)
test("unknown username goes to normal",
     1, normal.length)

# =============================================================================
# detect_multi_tweet_authors
# =============================================================================
section("detect_multi_tweet_authors")

test("empty array returns empty Set",
     Set.new,
     processor.send(:detect_multi_tweet_authors, []))

# All unique
unique_files = [
  '20260128_alice_111.json',
  '20260128_bob_222.json',
  '20260128_charlie_333.json'
]
test("all unique authors returns empty Set",
     Set.new,
     processor.send(:detect_multi_tweet_authors, unique_files))

# Author with multiple files
multi_files = [
  '20260128_alice_111.json',
  '20260128_alice_222.json',
  '20260128_bob_333.json'
]
result = processor.send(:detect_multi_tweet_authors, multi_files)
test("author with 2 files appears in result",
     true, result.include?('alice'))
test("author with 1 file does not appear",
     false, result.include?('bob'))

# Three+ files from same author
triple_files = [
  '20260128_ct24zive_111.json',
  '20260128_ct24zive_222.json',
  '20260128_ct24zive_333.json',
  '20260128_other_444.json'
]
result2 = processor.send(:detect_multi_tweet_authors, triple_files)
test("author with 3 files appears in result",
     true, result2.include?('ct24zive'))
test("result is a Set",
     true, result2.is_a?(Set))

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
