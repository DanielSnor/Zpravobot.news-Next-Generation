#!/usr/bin/env ruby
# frozen_string_literal: true

# Test RecurringWarningsCheck (opakující se warningy v logách)
# Validates: warning detection, normalization, grouping, thresholds
# Run: ruby test/test_recurring_warnings_check.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/health/check_result'
require_relative '../lib/health/checks/recurring_warnings_check'
require 'tmpdir'
require 'fileutils'
require 'time'

puts "=" * 60
puts "RecurringWarningsCheck Tests"
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

def section(title)
  puts
  puts "--- #{title} ---"
end

# Helper: create a fake HealthConfig-like object
class FakeConfig
  def initialize(log_dir:, thresholds: {})
    @log_dir = log_dir
    @thresholds = {
      recurring_warn_threshold: 10,
      recurring_warn_critical: 100
    }.merge(thresholds)
  end

  def [](key)
    return @log_dir if key == :log_dir
    nil
  end

  def threshold(name)
    @thresholds[name.to_sym]
  end
end

# Helper: write runner log lines with timestamps
def write_runner_log(dir, lines)
  today = Time.now.strftime('%Y%m%d')
  path = File.join(dir, "runner_#{today}.log")
  File.write(path, lines.join("\n") + "\n")
  path
end

def ts(time)
  "[#{time.strftime('%Y-%m-%d %H:%M:%S')}]"
end

# =============================================================================
# No log file exists — should be OK
# =============================================================================
section("No log file")

tmp1 = Dir.mktmpdir('recurring_warn_test')
config1 = FakeConfig.new(log_dir: tmp1)
check1 = HealthChecks::RecurringWarningsCheck.new(config1)
result1 = check1.run

test("level is :ok when no logs", :ok, result1.level)
test("message says no warnings", true, result1.message.include?("Žádné opakující se warningy"))

FileUtils.rm_rf(tmp1)

# =============================================================================
# No warnings in log — should be OK
# =============================================================================
section("No warnings in log")

tmp2 = Dir.mktmpdir('recurring_warn_test')
now = Time.now
lines2 = [
  "#{ts(now - 300)} INFO: Processing 84 sources",
  "#{ts(now - 200)} INFO: Run complete. Published: 5, Skipped: 79, Failed: 0",
  "#{ts(now - 100)} INFO: Processing 84 sources",
  "#{ts(now - 60)} INFO: Run complete. Published: 3, Skipped: 81, Failed: 0"
]
write_runner_log(tmp2, lines2)

config2 = FakeConfig.new(log_dir: tmp2)
check2 = HealthChecks::RecurringWarningsCheck.new(config2)
result2 = check2.run

test("no warnings is :ok", :ok, result2.level)
test("message says no warnings", true, result2.message.include?("Žádné opakující se warningy"))

FileUtils.rm_rf(tmp2)

# =============================================================================
# Warnings below threshold — should be OK
# =============================================================================
section("Warnings below threshold")

tmp3 = Dir.mktmpdir('recurring_warn_test')
now = Time.now
lines3 = (1..5).map do |i|
  "#{ts(now - i * 60)} WARN: [RssAdapter] Error extracting media: unknown keyword: :size"
end
write_runner_log(tmp3, lines3)

config3 = FakeConfig.new(log_dir: tmp3)
check3 = HealthChecks::RecurringWarningsCheck.new(config3)
result3 = check3.run

test("5 warnings (below threshold 10) is :ok", :ok, result3.level)

FileUtils.rm_rf(tmp3)

# =============================================================================
# Recurring warnings at warning threshold
# =============================================================================
section("Recurring warnings — warning level")

tmp4 = Dir.mktmpdir('recurring_warn_test')
now = Time.now
lines4 = (1..15).map do |i|
  "#{ts(now - i * 30)} WARN: [RssAdapter] Error extracting media: unknown keyword: :size"
end
write_runner_log(tmp4, lines4)

config4 = FakeConfig.new(log_dir: tmp4)
check4 = HealthChecks::RecurringWarningsCheck.new(config4)
result4 = check4.run

test("15 recurring warnings is :warning", :warning, result4.level)
test("message mentions opakující se warning", true, result4.message.include?("opakující se warning"))
test("has details", true, result4.details.is_a?(Array) && result4.details.any?)
test("details contain count", true, result4.details.first.include?("15×/h"))
test("has remediation", true, !result4.remediation.nil?)

FileUtils.rm_rf(tmp4)

# =============================================================================
# Recurring warnings at critical threshold
# =============================================================================
section("Recurring warnings — critical level")

tmp5 = Dir.mktmpdir('recurring_warn_test')
now = Time.now
lines5 = (1..120).map do |i|
  "#{ts(now - i * 5)} WARN: [RssAdapter] Error extracting media: unknown keyword: :size"
end
write_runner_log(tmp5, lines5)

config5 = FakeConfig.new(log_dir: tmp5)
check5 = HealthChecks::RecurringWarningsCheck.new(config5)
result5 = check5.run

test("120 recurring warnings is :critical", :critical, result5.level)
test("message mentions opakující se warning", true, result5.message.include?("opakující se warning"))
test("details contain count", true, result5.details.first.include?("120×/h"))

FileUtils.rm_rf(tmp5)

# =============================================================================
# Multiple different warning patterns
# =============================================================================
section("Multiple warning patterns")

tmp6 = Dir.mktmpdir('recurring_warn_test')
now = Time.now
lines6 = []
# 20 of one type
20.times { |i| lines6 << "#{ts(now - i * 30)} WARN: [RssAdapter] Error extracting media: unknown keyword: :size" }
# 15 of another type
15.times { |i| lines6 << "#{ts(now - i * 30)} WARN: [PostProcessor] MIME type mismatch for image" }
# 3 of a third type (below threshold)
3.times { |i| lines6 << "#{ts(now - i * 30)} WARN: [BlueskyAdapter] Rate limit approaching" }
write_runner_log(tmp6, lines6)

config6 = FakeConfig.new(log_dir: tmp6)
check6 = HealthChecks::RecurringWarningsCheck.new(config6)
result6 = check6.run

test("multiple patterns is :warning", :warning, result6.level)
test("message says 2 recurring warnings", true, result6.message.include?("2 opakující se warning"))
test("details has 2 entries", 2, result6.details.size)

FileUtils.rm_rf(tmp6)

# =============================================================================
# Normalization — different URLs should group together
# =============================================================================
section("Normalization — URLs")

tmp7 = Dir.mktmpdir('recurring_warn_test')
now = Time.now
lines7 = []
12.times do |i|
  lines7 << "#{ts(now - i * 30)} WARN: Fetch error for https://example.com/feed/#{i + 1}: timeout"
end
write_runner_log(tmp7, lines7)

config7 = FakeConfig.new(log_dir: tmp7)
check7 = HealthChecks::RecurringWarningsCheck.new(config7)
result7 = check7.run

test("URL-varying warnings grouped together is :warning", :warning, result7.level)
test("grouped into 1 pattern", true, result7.message.include?("1 opakující se warning"))

FileUtils.rm_rf(tmp7)

# =============================================================================
# Normalization — different numbers should group together
# =============================================================================
section("Normalization — numbers")

tmp8 = Dir.mktmpdir('recurring_warn_test')
now = Time.now
lines8 = []
12.times do |i|
  lines8 << "#{ts(now - i * 30)} WARN: HTTP 429 retry after #{i + 1} seconds"
end
write_runner_log(tmp8, lines8)

config8 = FakeConfig.new(log_dir: tmp8)
check8 = HealthChecks::RecurringWarningsCheck.new(config8)
result8 = check8.run

test("number-varying warnings grouped together is :warning", :warning, result8.level)
test("grouped into 1 pattern", true, result8.message.include?("1 opakující se warning"))

FileUtils.rm_rf(tmp8)

# =============================================================================
# Exclude patterns — false positives should be filtered
# =============================================================================
section("Exclude patterns")

tmp9 = Dir.mktmpdir('recurring_warn_test')
now = Time.now
lines9 = []
# These should be excluded (false positives that contain WARN-like text)
20.times do |i|
  lines9 << "#{ts(now - i * 30)} WARN: Queue processing complete. Published: 5, failed: 0, errors: 0"
end
write_runner_log(tmp9, lines9)

config9 = FakeConfig.new(log_dir: tmp9)
check9 = HealthChecks::RecurringWarningsCheck.new(config9)
result9 = check9.run

test("excluded warnings are :ok", :ok, result9.level)

FileUtils.rm_rf(tmp9)

# =============================================================================
# Custom thresholds
# =============================================================================
section("Custom thresholds")

tmp10 = Dir.mktmpdir('recurring_warn_test')
now = Time.now
lines10 = (1..7).map do |i|
  "#{ts(now - i * 60)} WARN: [RssAdapter] Something broken"
end
write_runner_log(tmp10, lines10)

# With threshold = 5, these 7 warnings should trigger
config10 = FakeConfig.new(log_dir: tmp10, thresholds: { recurring_warn_threshold: 5, recurring_warn_critical: 20 })
check10 = HealthChecks::RecurringWarningsCheck.new(config10)
result10 = check10.run

test("custom threshold 5 triggers :warning with 7 warnings", :warning, result10.level)

# With threshold = 5 and critical = 20, 25 warnings should trigger critical
lines10b = (1..25).map do |i|
  "#{ts(now - i * 10)} WARN: [RssAdapter] Something broken"
end
write_runner_log(tmp10, lines10b)

check10b = HealthChecks::RecurringWarningsCheck.new(config10)
result10b = check10b.run

test("custom critical 20 triggers :critical with 25 warnings", :critical, result10b.level)

FileUtils.rm_rf(tmp10)

# =============================================================================
# Old warnings (outside 1h window) — should be ignored
# =============================================================================
section("Old warnings ignored")

tmp11 = Dir.mktmpdir('recurring_warn_test')
now = Time.now
lines11 = (1..20).map do |i|
  # All warnings are 2+ hours old
  "#{ts(now - 7200 - i * 60)} WARN: [RssAdapter] Error extracting media: old bug"
end
# Add one recent INFO so the log has timestamps the parser can find
lines11 << "#{ts(now - 60)} INFO: Run complete"
write_runner_log(tmp11, lines11)

config11 = FakeConfig.new(log_dir: tmp11)
check11 = HealthChecks::RecurringWarningsCheck.new(config11)
result11 = check11.run

test("old warnings (>1h) are :ok", :ok, result11.level)

FileUtils.rm_rf(tmp11)

# =============================================================================
# Emoji warnings (⚠️ pattern)
# =============================================================================
section("Emoji warnings")

tmp12 = Dir.mktmpdir('recurring_warn_test')
now = Time.now
lines12 = (1..12).map do |i|
  "#{ts(now - i * 30)} ⚠️ [Bluesky] Rate limit hit"
end
write_runner_log(tmp12, lines12)

config12 = FakeConfig.new(log_dir: tmp12)
check12 = HealthChecks::RecurringWarningsCheck.new(config12)
result12 = check12.run

test("emoji warnings detected is :warning", :warning, result12.level)

FileUtils.rm_rf(tmp12)

# =============================================================================
# CheckResult format
# =============================================================================
section("CheckResult format")

tmp13 = Dir.mktmpdir('recurring_warn_test')
now = Time.now
write_runner_log(tmp13, ["#{ts(now - 60)} INFO: All good"])

config13 = FakeConfig.new(log_dir: tmp13)
check13 = HealthChecks::RecurringWarningsCheck.new(config13)
result13 = check13.run

test("check name is 'Recurring Warnings'", 'Recurring Warnings', result13.name)

FileUtils.rm_rf(tmp13)

# =============================================================================
# Error handling — invalid log_dir
# =============================================================================
section("Error handling")

config_err = FakeConfig.new(log_dir: nil)
check_err = HealthChecks::RecurringWarningsCheck.new(config_err)
result_err = check_err.run

test("error returns :warning level", :warning, result_err.level)
test("error message includes Error:", true, result_err.message.start_with?("Error:"))

# =============================================================================
# Incident reproduction: 54 WARN/h like the :size bug
# =============================================================================
section("Incident reproduction — 54 warnings/h (:size bug)")

tmp14 = Dir.mktmpdir('recurring_warn_test')
now = Time.now
lines14 = (1..54).map do |i|
  "#{ts(now - i * 66)} WARN: [RssAdapter] Error extracting media: unknown keyword: :size"
end
write_runner_log(tmp14, lines14)

config14 = FakeConfig.new(log_dir: tmp14)
check14 = HealthChecks::RecurringWarningsCheck.new(config14)
result14 = check14.run

test("54 warnings (like :size bug) is :warning", :warning, result14.level)
test("details mention the pattern", true, result14.details.first.include?("Error extracting media"))
test("details mention count", true, result14.details.first.include?("54×/h"))

FileUtils.rm_rf(tmp14)

# =============================================================================
# HH:MM:SS timestamp format (daily log)
# =============================================================================
section("HH:MM:SS timestamp format")

tmp15 = Dir.mktmpdir('recurring_warn_test')
now = Time.now
lines15 = (1..15).map do |i|
  t = now - i * 30
  "[#{t.strftime('%H:%M:%S')}] WARN: [RssAdapter] Some recurring issue"
end
write_runner_log(tmp15, lines15)

config15 = FakeConfig.new(log_dir: tmp15)
check15 = HealthChecks::RecurringWarningsCheck.new(config15)
result15 = check15.run

test("HH:MM:SS format detected is :warning", :warning, result15.level)

FileUtils.rm_rf(tmp15)

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
