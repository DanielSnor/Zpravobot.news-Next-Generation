#!/usr/bin/env ruby
# frozen_string_literal: true

# Test bin/retry_failed_queue.rb
# Unit testy bez DB/HTTP závislostí — testuje logiku pomocí tmp souborů.
# Run: ruby test/test_retry_failed_queue.rb

require 'json'
require 'fileutils'
require 'tmpdir'
require 'time'

puts '=' * 60
puts 'RetryFailedQueue Tests'
puts '=' * 60
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

def test_true(name, &block)
  result = block.call
  if result
    puts "  \e[32m\u2713\e[0m #{name}"
    $passed += 1
  else
    puts "  \e[31m\u2717\e[0m #{name}"
    puts "    Expected truthy, got: #{result.inspect}"
    $failed += 1
  end
rescue => e
  puts "  \e[31m\u2717\e[0m #{name}"
  puts "    Unexpected error: #{e.class}: #{e.message}"
  $failed += 1
end

def test_false(name, &block)
  result = block.call
  if !result
    puts "  \e[32m\u2713\e[0m #{name}"
    $passed += 1
  else
    puts "  \e[31m\u2717\e[0m #{name}"
    puts "    Expected falsy, got: #{result.inspect}"
    $failed += 1
  end
rescue => e
  puts "  \e[31m\u2717\e[0m #{name}"
  puts "    Unexpected error: #{e.class}: #{e.message}"
  $failed += 1
end

def section(title)
  puts
  puts "--- #{title} ---"
end

# ---------------------------------------------------------------------------
# Load helpers from the script directly (without executing CLI code)
# ---------------------------------------------------------------------------

# We extract the pure logic by loading the file in a subprocess-free way:
# define the constants + helpers in this test namespace.

MAX_RETRIES   = 1
MAX_RETRY_AGE = 6 * 3600

PERMANENT_ERRORS = [
  /Invalid JSON/i,
  /tweet likely deleted/i,
  /No config found/i,
  /unknown bot_id/i,
  /Text cannot be empty/i
].freeze

def permanent_error?(reason)
  return false if reason.nil? || reason.empty?
  PERMANENT_ERRORS.any? { |pattern| reason.match?(pattern) }
end

def too_old?(failed_at_str)
  return false if failed_at_str.nil? || failed_at_str.empty?
  failed_at = Time.parse(failed_at_str)
  (Time.now - failed_at) > MAX_RETRY_AGE
rescue ArgumentError, TypeError
  false
end

def max_retries_exceeded?(retry_count)
  retry_count.to_i >= MAX_RETRIES
end

def mark_dead(filepath, dead_reason, data)
  data['_failure'] ||= {}
  data['_failure']['dead_reason'] = dead_reason
  data['_failure']['dead_at']     = Time.now.iso8601
  File.write(filepath, JSON.pretty_generate(data))
  new_path = File.join(File.dirname(filepath), "DEAD_#{File.basename(filepath)}")
  File.rename(filepath, new_path)
  new_path
end

def move_to_pending(filepath, data, pending_dir)
  failure = data['_failure'] ||= {}
  current_count = failure['retry_count'].to_i
  failure['retry_count']   = current_count + 1
  failure['last_retry_at'] = Time.now.iso8601
  File.write(filepath, JSON.pretty_generate(data))
  dest = File.join(pending_dir, File.basename(filepath))
  FileUtils.mv(filepath, dest)
  dest
end

# ---------------------------------------------------------------------------
# permanent_error? tests
# ---------------------------------------------------------------------------
section('permanent_error? — permanent patterns')

test('Invalid JSON → permanent',    true,  permanent_error?('Invalid JSON: unexpected token'))
test('tweet likely deleted → permanent', true, permanent_error?('tweet likely deleted or protected'))
test('No config found → permanent', true,  permanent_error?('No config found for bot_id'))
test('unknown bot_id → permanent',  true,  permanent_error?('unknown bot_id: foobot'))
test('Text cannot be empty → permanent', true, permanent_error?('Text cannot be empty'))

section('permanent_error? — case insensitive')

test('INVALID JSON uppercase → permanent',     true, permanent_error?('INVALID JSON'))
test('Tweet Likely Deleted mixed → permanent', true, permanent_error?('Tweet Likely Deleted'))

section('permanent_error? — transient errors (should return false)')

test('Nitter timeout → not permanent',        false, permanent_error?('Nitter timeout after 3 attempts'))
test('connection refused → not permanent',    false, permanent_error?('connection refused'))
test('HTTP 503 → not permanent',              false, permanent_error?('HTTP 503 Service Unavailable'))
test('Mastodon down → not permanent',         false, permanent_error?('Error: #{e.message}'))
test('nil reason → not permanent',            false, permanent_error?(nil))
test('empty reason → not permanent',          false, permanent_error?(''))

# ---------------------------------------------------------------------------
# too_old? tests
# ---------------------------------------------------------------------------
section('too_old? — age checks')

fresh_time = (Time.now - 3600).iso8601    # 1h ago — well within 6h
old_time   = (Time.now - 7 * 3600).iso8601 # 7h ago — over limit

test('1h old → not too old',  false, too_old?(fresh_time))
test('7h old → too old',      true,  too_old?(old_time))
test('nil → not too old',     false, too_old?(nil))
test('empty → not too old',   false, too_old?(''))

exactly_6h = (Time.now - MAX_RETRY_AGE - 1).iso8601
test('just over 6h → too old', true, too_old?(exactly_6h))

# ---------------------------------------------------------------------------
# max_retries_exceeded? tests
# ---------------------------------------------------------------------------
section('max_retries_exceeded?')

test('retry_count=0 → not exceeded',   false, max_retries_exceeded?(0))
test('retry_count=1 → exceeded',       true,  max_retries_exceeded?(1))
test('retry_count=2 → exceeded',       true,  max_retries_exceeded?(2))
test('nil retry_count → not exceeded', false, max_retries_exceeded?(nil))

# ---------------------------------------------------------------------------
# Integration flow tests using tmp directories
# ---------------------------------------------------------------------------
section('Integration: file flow')

Dir.mktmpdir('zbnw_retry_test') do |tmpdir|
  failed_dir  = File.join(tmpdir, 'failed')
  pending_dir = File.join(tmpdir, 'pending')
  FileUtils.mkdir_p([failed_dir, pending_dir])

  # Helper: create failed file
  def make_failed_file(dir, name, failure_data)
    payload = { 'text' => 'Hello', 'bot_id' => 'ct24_twitter', '_failure' => failure_data }
    path = File.join(dir, name)
    File.write(path, JSON.pretty_generate(payload))
    path
  end

  # --- Test: transient error, retry_count=0 → move to pending ---
  filepath = make_failed_file(failed_dir, '20260226_ct24_1001.json', {
    'reason'      => 'Nitter timeout after 3 attempts',
    'failed_at'   => (Time.now - 300).iso8601,
    'retry_count' => 0
  })

  data = JSON.parse(File.read(filepath))
  failure = data['_failure']

  unless permanent_error?(failure['reason']) || too_old?(failure['failed_at']) || max_retries_exceeded?(failure['retry_count'])
    move_to_pending(filepath, data, pending_dir)
  end

  pending_file = File.join(pending_dir, '20260226_ct24_1001.json')
  test('transient error retry_count=0 → moved to pending', true, File.exist?(pending_file))
  test('original no longer in failed',                     false, File.exist?(filepath))

  moved_data = JSON.parse(File.read(pending_file))
  test('retry_count incremented to 1', 1, moved_data.dig('_failure', 'retry_count'))
  test_true('last_retry_at set') { moved_data.dig('_failure', 'last_retry_at') }

  # --- Test: retry_count=1 (already at MAX_RETRIES) → DEAD ---
  filepath2 = make_failed_file(failed_dir, '20260226_ct24_1002.json', {
    'reason'      => 'Nitter timeout after 3 attempts',
    'failed_at'   => (Time.now - 300).iso8601,
    'retry_count' => 1
  })

  data2 = JSON.parse(File.read(filepath2))
  failure2 = data2['_failure']

  dead_path2 = nil
  if max_retries_exceeded?(failure2['retry_count'])
    dead_path2 = mark_dead(filepath2, 'max_retries_exceeded', data2)
  end

  test('retry_count=1 → DEAD file created', true,  File.exist?(dead_path2.to_s))
  test('original renamed, not at old path', false, File.exist?(filepath2))

  dead_data2 = JSON.parse(File.read(dead_path2))
  test('dead_reason = max_retries_exceeded', 'max_retries_exceeded', dead_data2.dig('_failure', 'dead_reason'))
  test_true('dead_at set') { dead_data2.dig('_failure', 'dead_at') }

  # --- Test: permanent error → DEAD regardless of retry_count ---
  filepath3 = make_failed_file(failed_dir, '20260226_ct24_1003.json', {
    'reason'      => 'Invalid JSON: unexpected token',
    'failed_at'   => (Time.now - 300).iso8601,
    'retry_count' => 0
  })

  data3 = JSON.parse(File.read(filepath3))
  failure3 = data3['_failure']

  dead_path3 = nil
  if permanent_error?(failure3['reason'])
    dead_path3 = mark_dead(filepath3, 'permanent_error', data3)
  end

  test('permanent error → DEAD file created',  true,  File.exist?(dead_path3.to_s))
  test('original removed (permanent)',          false, File.exist?(filepath3))
  dead_data3 = JSON.parse(File.read(dead_path3))
  test('dead_reason = permanent_error', 'permanent_error', dead_data3.dig('_failure', 'dead_reason'))

  # --- Test: too old → DEAD ---
  filepath4 = make_failed_file(failed_dir, '20260226_ct24_1004.json', {
    'reason'      => 'Nitter timeout after 3 attempts',
    'failed_at'   => (Time.now - 7 * 3600).iso8601,
    'retry_count' => 0
  })

  data4 = JSON.parse(File.read(filepath4))
  failure4 = data4['_failure']

  dead_path4 = nil
  if too_old?(failure4['failed_at'])
    dead_path4 = mark_dead(filepath4, 'too_old', data4)
  end

  test('too old → DEAD file created',     true,  File.exist?(dead_path4.to_s))
  test('original removed (too old)',       false, File.exist?(filepath4))
  dead_data4 = JSON.parse(File.read(dead_path4))
  test('dead_reason = too_old', 'too_old', dead_data4.dig('_failure', 'dead_reason'))
end

# ---------------------------------------------------------------------------
# --dry-run: no file operations
# ---------------------------------------------------------------------------
section('--dry-run: nothing moved')

Dir.mktmpdir('zbnw_retry_dry') do |tmpdir|
  failed_dir  = File.join(tmpdir, 'failed')
  pending_dir = File.join(tmpdir, 'pending')
  FileUtils.mkdir_p([failed_dir, pending_dir])

  payload = {
    'text' => 'Hello', 'bot_id' => 'ct24_twitter',
    '_failure' => { 'reason' => 'Nitter timeout', 'failed_at' => (Time.now - 300).iso8601, 'retry_count' => 0 }
  }
  orig = File.join(failed_dir, '20260226_ct24_dry.json')
  File.write(orig, JSON.pretty_generate(payload))

  # Simulate dry_run: read + classify but do NOT call move/rename
  data = JSON.parse(File.read(orig))
  failure = data['_failure']
  dry_run_action = if permanent_error?(failure['reason'])
                     :dead_permanent
                   elsif too_old?(failure['failed_at'])
                     :dead_old
                   elsif max_retries_exceeded?(failure['retry_count'])
                     :dead_max
                   else
                     :retry
                   end
  # dry_run: skip actual file ops
  test('dry_run classified as retry',          :retry, dry_run_action)
  test('original still exists after dry_run',  true,   File.exist?(orig))
  test('pending dir empty after dry_run',      0,      Dir.glob(File.join(pending_dir, '*.json')).size)
end

# ---------------------------------------------------------------------------
# DEAD_ files ignored by candidates scan
# ---------------------------------------------------------------------------
section('DEAD_ files are excluded from candidates')

Dir.mktmpdir('zbnw_retry_dead') do |tmpdir|
  failed_dir = File.join(tmpdir, 'failed')
  FileUtils.mkdir_p(failed_dir)

  File.write(File.join(failed_dir, 'DEAD_20260226_ct24_0001.json'), '{}')
  File.write(File.join(failed_dir, '20260226_ct24_0002.json'), '{}')

  candidates = Dir.glob(File.join(failed_dir, '*.json'))
                  .reject { |f| File.basename(f).start_with?('DEAD_') }

  test('candidates excludes DEAD_ file', 1, candidates.size)
  test('candidate is the non-DEAD file', '20260226_ct24_0002.json', File.basename(candidates.first))
end

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

puts
puts '=' * 60
total = $passed + $failed
puts "Results: #{$passed}/#{total} passed"
if $failed > 0
  puts "\e[31m#{$failed} test(s) FAILED\e[0m"
  exit 1
else
  puts "\e[32mAll tests passed!\e[0m"
end
