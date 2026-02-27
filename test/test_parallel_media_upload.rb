#!/usr/bin/env ruby
# frozen_string_literal: true

# Test parallel media upload — Phase 12
# Verifies upload_media_parallel: order preservation, partial failure, limits.
# Uses mock HTTP via monkey-patching upload_media_from_url.
# Run: ruby test/test_parallel_media_upload.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/publishers/mastodon_publisher'

puts "=" * 60
puts "Parallel Media Upload Tests"
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
# Mock publisher that simulates upload_media_from_url without HTTP
# =============================================================================

class MockParallelPublisher < Publishers::MastodonPublisher
  attr_reader :upload_log

  def initialize
    @instance_url = 'https://example.com'
    @access_token = 'test_token'
    @upload_log = []
    @upload_delay = 0
    @fail_urls = []
    @mutex = Mutex.new
  end

  def set_upload_delay(seconds)
    @upload_delay = seconds
  end

  def set_fail_urls(urls)
    @fail_urls = urls
  end

  def upload_media_from_url(url, description: nil)
    sleep(@upload_delay) if @upload_delay > 0

    if @fail_urls.include?(url)
      raise StandardError, "Simulated upload failure for #{url}"
    end

    media_id = "media_#{url.split('/').last.gsub('.', '_')}"
    @mutex.synchronize do
      @upload_log << { url: url, description: description, media_id: media_id, thread: Thread.current.object_id }
    end
    media_id
  end
end

# =============================================================================
# Tests
# =============================================================================

section("Basic parallel upload")

pub = MockParallelPublisher.new
items = [
  { url: 'https://example.com/a.jpg', description: 'Image A' },
  { url: 'https://example.com/b.png', description: 'Image B' },
  { url: 'https://example.com/c.gif', description: nil }
]
result = pub.upload_media_parallel(items)

test("returns 3 media IDs for 3 items", 3, result.size)
test("first ID matches first item", 'media_a_jpg', result[0])
test("second ID matches second item", 'media_b_png', result[1])
test("third ID matches third item", 'media_c_gif', result[2])
test("all 3 uploads logged", 3, pub.upload_log.size)

# =============================================================================
section("Order preservation with delay")

pub2 = MockParallelPublisher.new
pub2.set_upload_delay(0.01)
items2 = [
  { url: 'https://example.com/1.jpg', description: 'First' },
  { url: 'https://example.com/2.jpg', description: 'Second' },
  { url: 'https://example.com/3.jpg', description: 'Third' },
  { url: 'https://example.com/4.jpg', description: 'Fourth' }
]
result2 = pub2.upload_media_parallel(items2)

test("preserves order: first", 'media_1_jpg', result2[0])
test("preserves order: second", 'media_2_jpg', result2[1])
test("preserves order: third", 'media_3_jpg', result2[2])
test("preserves order: fourth", 'media_4_jpg', result2[3])

# =============================================================================
section("Parallel execution (uses threads)")

pub3 = MockParallelPublisher.new
pub3.set_upload_delay(0.05)
items3 = [
  { url: 'https://example.com/p1.jpg', description: nil },
  { url: 'https://example.com/p2.jpg', description: nil },
  { url: 'https://example.com/p3.jpg', description: nil }
]

start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
pub3.upload_media_parallel(items3)
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

# Sequential would take >= 0.15s (3 * 0.05), parallel should be ~0.05s
test("parallel is faster than sequential (#{elapsed.round(3)}s < 0.12s)", true, elapsed < 0.12)

thread_ids = pub3.upload_log.map { |l| l[:thread] }.uniq
test("used multiple threads (#{thread_ids.size} unique)", true, thread_ids.size > 1)

# =============================================================================
section("Partial failure — one upload fails")

pub4 = MockParallelPublisher.new
pub4.set_fail_urls(['https://example.com/fail.jpg'])
items4 = [
  { url: 'https://example.com/ok1.jpg', description: 'OK 1' },
  { url: 'https://example.com/fail.jpg', description: 'Will fail' },
  { url: 'https://example.com/ok2.jpg', description: 'OK 2' }
]
result4 = pub4.upload_media_parallel(items4)

test("returns 2 IDs (1 failed)", 2, result4.size)
test("first successful ID preserved", 'media_ok1_jpg', result4[0])
test("second successful ID preserved", 'media_ok2_jpg', result4[1])

# =============================================================================
section("All uploads fail")

pub5 = MockParallelPublisher.new
pub5.set_fail_urls(['https://example.com/f1.jpg', 'https://example.com/f2.jpg'])
items5 = [
  { url: 'https://example.com/f1.jpg', description: nil },
  { url: 'https://example.com/f2.jpg', description: nil }
]
result5 = pub5.upload_media_parallel(items5)

test("returns empty array when all fail", [], result5)

# =============================================================================
section("MAX_MEDIA_COUNT enforcement")

pub6 = MockParallelPublisher.new
items6 = (1..7).map { |i| { url: "https://example.com/img#{i}.jpg", description: "Image #{i}" } }
result6 = pub6.upload_media_parallel(items6)

test("caps at MAX_MEDIA_COUNT (4)", 4, result6.size)
test("uploads only first 4", 4, pub6.upload_log.size)
test("first 4 in order", 'media_img1_jpg', result6[0])
test("last of 4 in order", 'media_img4_jpg', result6[3])

# =============================================================================
section("Edge cases")

pub7 = MockParallelPublisher.new

test("nil input returns empty array", [], pub7.upload_media_parallel(nil))
test("empty array returns empty array", [], pub7.upload_media_parallel([]))

# Single item
result_single = pub7.upload_media_parallel([{ url: 'https://example.com/solo.jpg', description: 'Solo' }])
test("single item works", 1, result_single.size)
test("single item correct ID", 'media_solo_jpg', result_single[0])

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
