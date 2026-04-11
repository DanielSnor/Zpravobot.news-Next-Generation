#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Test Suite: Trending::TrendingChecker
# ============================================================
#
# Covers all 8 acceptance scenarios.
# No DB, no real network — HTTP calls are stubbed via
# define_singleton_method on checker instances.
#
# Usage:
#   ruby test/test_trending_checker.rb
#   ruby test/test_trending_checker.rb --verbose
#
# ============================================================

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
$verbose = ARGV.include?('--verbose')

require 'tmpdir'
require 'json'
require 'time'
require 'stringio'
require 'trending/trending_checker'

puts '=' * 60
puts '  TrendingChecker Tests'
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

def test_nil(name, actual)
  test(name, nil, actual)
end

def test_not_nil(name, actual)
  if !actual.nil?
    puts "  \e[32m\u2713\e[0m #{name}"
    $passed += 1
  else
    puts "  \e[31m\u2717\e[0m #{name} — expected non-nil, got nil"
    $failed += 1
  end
end

def test_true(name, actual)
  test(name, true, actual)
end

def test_includes(name, substring, actual)
  if actual.to_s.include?(substring)
    puts "  \e[32m\u2713\e[0m #{name}"
    $passed += 1
  else
    puts "  \e[31m\u2717\e[0m #{name}"
    puts "    Expected to include: #{substring.inspect}"
    puts "    Actual: #{actual.to_s[0, 300].inspect}"
    $failed += 1
  end
end

def section(title)
  puts
  puts "--- #{title} ---"
end

# ----------------------------------------------------------------
# Helper: build a TrendingChecker with stubbed HTTP and temp state
# ----------------------------------------------------------------

# Builds a checker with:
#   - trends_response: array of status hashes returned by fetch_trends
#   - post_results: hash of status_id => true/nil for post_quote
#   - state_dir: temporary directory for state file
def build_checker(trends:, post_results: {}, dry_run: false)
  dir = Dir.mktmpdir('trending_test_')
  state_path = File.join(dir, 'trending_state.json')

  checker = Trending::TrendingChecker.new(
    instance_url: 'https://zpravobot.news',
    access_token:  'test_token',
    state_path:    state_path,
    dry_run:       dry_run
  )

  # Stub fetch_trends to return local data (no HTTP)
  checker.define_singleton_method(:fetch_trends) { trends }

  # Stub post_quote to return from post_results hash (no HTTP)
  # post_quote(trend) — extract id from the trend hash
  checker.define_singleton_method(:post_quote) do |trend|
    status_id = trend.is_a?(Hash) ? trend['id'] : trend
    post_results.fetch(status_id, true)
  end

  # Stub sleep to be instant
  checker.define_singleton_method(:sleep) { |_n| nil }

  [checker, state_path, dir]
end

def cleanup(dir)
  FileUtils.rm_rf(dir)
end

# ----------------------------------------------------------------
# Scenario 1: Empty trends — API returns []
# ----------------------------------------------------------------
section('Scenario 1: Empty trends')

checker, state_path, dir = build_checker(trends: [])
result = checker.run
test('posted: 0 when no trends', 0, result[:posted])
test('checked: 0', 0, result[:checked])
# state file should still be written (last_check_at updated)
test_true('state file created', File.exist?(state_path))
state = JSON.parse(File.read(state_path))
test('announced_ids empty', [], state['announced_ids'])
test_not_nil('last_check_at set', state['last_check_at'])
test_nil('last_post_at nil', state['last_post_at'])
cleanup(dir)

# ----------------------------------------------------------------
# Scenario 1b: Bot accounts always filtered; zpravobot quote posts filtered
# ----------------------------------------------------------------
section('Scenario 1b: Account filtering')

filter_trends = [
  # zpravobot regular post — allowed
  { 'id' => 'zp_ok', 'url' => 'https://zpravobot.news/@zpravobot/zp_ok',
    'account' => { 'acct' => 'zpravobot' }, 'quote' => nil },
  # zpravobot quote post (trending alert) — filtered
  { 'id' => 'zp_quote', 'url' => 'https://zpravobot.news/@zpravobot/zp_quote',
    'account' => { 'acct' => 'zpravobot' }, 'quote' => { 'id' => 'some_other' } },
  # bot accounts — always filtered
  { 'id' => 'bb', 'url' => 'https://zpravobot.news/@betabot/bb',
    'account' => { 'acct' => 'betabot' } },
  { 'id' => 'ub', 'url' => 'https://zpravobot.news/@udrzbot/ub',
    'account' => { 'acct' => 'udrzbot' } },
  { 'id' => 'tb', 'url' => 'https://zpravobot.news/@tlambot/tb',
    'account' => { 'acct' => 'tlambot' } },
  # regular user — allowed
  { 'id' => 'ok1', 'url' => 'https://zpravobot.news/@realuser/ok1',
    'account' => { 'acct' => 'realuser' } }
]
checker, state_path, dir = build_checker(trends: filter_trends)
result = checker.run
test('posted: 2 (zpravobot regular + realuser)', 2, result[:posted])
test('checked: 6', 6, result[:checked])

state = JSON.parse(File.read(state_path))
test_true("zpravobot regular post IS announced",  state['announced_ids'].include?('zp_ok'))
test("zpravobot quote post NOT announced",        false, state['announced_ids'].include?('zp_quote'))
test("betabot NOT announced",                     false, state['announced_ids'].include?('bb'))
test("udrzbot NOT announced",                     false, state['announced_ids'].include?('ub'))
test("tlambot NOT announced",                     false, state['announced_ids'].include?('tb'))
test_true("realuser IS announced",                state['announced_ids'].include?('ok1'))
cleanup(dir)

# ----------------------------------------------------------------
# Scenario 2: All trends already announced
# ----------------------------------------------------------------
section('Scenario 2: All trends already announced')

trends = [
  { 'id' => '111', 'url' => 'https://zpravobot.news/@foo/111' },
  { 'id' => '222', 'url' => 'https://zpravobot.news/@bar/222' }
]
checker, state_path, dir = build_checker(trends: trends)

# Pre-populate state
File.write(state_path, JSON.generate(
  'announced_ids' => ['111', '222'],
  'last_check_at' => nil,
  'last_post_at'  => nil
))

result = checker.run
test('posted: 0 when all already announced', 0, result[:posted])
test('checked: 2', 2, result[:checked])
cleanup(dir)

# ----------------------------------------------------------------
# Scenario 3: New trends — IDs added to state
# ----------------------------------------------------------------
section('Scenario 3: New trends published')

trends = [
  { 'id' => '111', 'url' => 'https://zpravobot.news/@foo/111' },
  { 'id' => '222', 'url' => 'https://zpravobot.news/@bar/222' }
]
checker, state_path, dir = build_checker(trends: trends, post_results: { '111' => true, '222' => true })
result = checker.run
test('posted: 2', 2, result[:posted])
test('checked: 2', 2, result[:checked])

state = JSON.parse(File.read(state_path))
test_true("'111' in announced_ids", state['announced_ids'].include?('111'))
test_true("'222' in announced_ids", state['announced_ids'].include?('222'))
test_not_nil('last_post_at set after publish', state['last_post_at'])
cleanup(dir)

# ----------------------------------------------------------------
# Scenario 4: MAX_POSTS_PER_RUN cap (5)
# ----------------------------------------------------------------
section('Scenario 4: MAX_POSTS_PER_RUN cap')

many_trends = (1..10).map { |i| { 'id' => i.to_s, 'url' => "https://example.com/#{i}" } }
checker, state_path, dir = build_checker(trends: many_trends)
result = checker.run
test('posted <= MAX_POSTS_PER_RUN (5)', Trending::TrendingChecker::MAX_POSTS_PER_RUN, result[:posted])
test('checked: 10', 10, result[:checked])

state = JSON.parse(File.read(state_path))
test('announced_ids count = 5', 5, state['announced_ids'].size)
cleanup(dir)

# ----------------------------------------------------------------
# Scenario 5: State rotation — max 200 IDs (FIFO)
# ----------------------------------------------------------------
section('Scenario 5: State rotation (MAX_ANNOUNCED_IDS = 200)')

# Pre-populate with 199 IDs
existing_ids = (1..199).map(&:to_s)
checker, state_path, dir = build_checker(
  trends: [{ 'id' => '999', 'url' => 'https://zpravobot.news/@x/999' }]
)

File.write(state_path, JSON.generate(
  'announced_ids' => existing_ids,
  'last_check_at' => nil,
  'last_post_at'  => nil
))

result = checker.run
test('posted: 1', 1, result[:posted])

state = JSON.parse(File.read(state_path))
test('announced_ids count = 200', 200, state['announced_ids'].size)
test_true("'999' present", state['announced_ids'].include?('999'))
cleanup(dir)

# Overflow: 205 existing + 1 new → last 200
checker2, state_path2, dir2 = build_checker(
  trends: [{ 'id' => '9999', 'url' => 'https://zpravobot.news/@x/9999' }]
)
existing_ids2 = (1..205).map(&:to_s)
File.write(state_path2, JSON.generate(
  'announced_ids' => existing_ids2,
  'last_check_at' => nil,
  'last_post_at'  => nil
))
checker2.run
state2 = JSON.parse(File.read(state_path2))
test('overflow rotated to 200', 200, state2['announced_ids'].size)
test_true("'9999' present after rotation", state2['announced_ids'].include?('9999'))
cleanup(dir2)

# ----------------------------------------------------------------
# Scenario 6: Corrupted state file — graceful fallback
# ----------------------------------------------------------------
section('Scenario 6: Corrupted state file')

checker, state_path, dir = build_checker(
  trends: [{ 'id' => '42', 'url' => 'https://zpravobot.news/@z/42' }]
)
File.write(state_path, 'NOT_VALID_JSON{{{')

result = nil
begin
  result = checker.run
rescue => e
  result = { error: e.message }
end

test_not_nil('run does not raise on corrupted state', result)
test('posted: 1 after fallback to empty state', 1, result[:posted])
cleanup(dir)

# ----------------------------------------------------------------
# Scenario 7: Quote denied (422) — run continues, ID not stored
# ----------------------------------------------------------------
section('Scenario 7: Quote denied (422)')

trends = [
  { 'id' => 'deny', 'url' => 'https://zpravobot.news/@a/deny' },
  { 'id' => 'ok',   'url' => 'https://zpravobot.news/@b/ok'   }
]
# 'deny' returns nil (simulates 422), 'ok' returns true
checker, state_path, dir = build_checker(
  trends:       trends,
  post_results: { 'deny' => nil, 'ok' => true }
)

result = checker.run
test('posted: 1 (deny skipped)', 1, result[:posted])
test('checked: 2', 2, result[:checked])

state = JSON.parse(File.read(state_path))
test("'deny' NOT in announced_ids", false, state['announced_ids'].include?('deny'))
test_true("'ok' in announced_ids", state['announced_ids'].include?('ok'))
cleanup(dir)

# ----------------------------------------------------------------
# Scenario 8: Dry run — no real HTTP POST, IDs added to state (not saved)
# ----------------------------------------------------------------
section('Scenario 8: Dry run mode')

# Capture stdout
output = StringIO.new
$stdout = output

trends = [
  { 'id' => 'dryA', 'url' => 'https://zpravobot.news/@x/dryA' },
  { 'id' => 'dryB', 'url' => 'https://zpravobot.news/@y/dryB' }
]
# post_results irrelevant in dry_run (post_quote should never be called)
# We override post_quote to raise if it IS called
checker, state_path, dir = build_checker(trends: trends, dry_run: true)
checker.define_singleton_method(:post_quote) do |_id|
  raise 'post_quote called in dry_run mode!'
end

result = checker.run

$stdout = STDOUT
output_str = output.string

test('dry run posted: 2', 2, result[:posted])
test_includes('dry run prints [DRY RUN]', '[DRY RUN]', output_str)
test_includes('dry run shows status ID dryA', 'dryA', output_str)
cleanup(dir)

# ----------------------------------------------------------------
# Constant checks
# ----------------------------------------------------------------
section('Constants')

test('MAX_POSTS_PER_RUN = 5',  5,   Trending::TrendingChecker::MAX_POSTS_PER_RUN)
test('MAX_ANNOUNCED_IDS = 200', 200, Trending::TrendingChecker::MAX_ANNOUNCED_IDS)
test('THROTTLE_SECONDS = 2',   2,   Trending::TrendingChecker::THROTTLE_SECONDS)
test('HEADER_LINE contains 📈', true, Trending::TrendingChecker::HEADER_LINE.include?('📈'))
test('HEADER_LINE non-empty',   true, !Trending::TrendingChecker::HEADER_LINE.empty?)
test('HASHTAGS_LINE non-empty', true, !Trending::TrendingChecker::HASHTAGS_LINE.empty?)

# ----------------------------------------------------------------
# Summary
# ----------------------------------------------------------------
puts
puts '=' * 60
puts "  Passed: #{$passed}  Failed: #{$failed}"
puts '=' * 60

exit($failed > 0 ? 1 : 0)
