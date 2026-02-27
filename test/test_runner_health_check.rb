#!/usr/bin/env ruby
# frozen_string_literal: true

# Test RunnerHealthCheck (crash detection)
# Validates: staleness detection, consecutive crash counting, threshold logic
# Run: ruby test/test_runner_health_check.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/health/check_result'
require_relative '../lib/health/checks/runner_health_check'
require 'tmpdir'
require 'fileutils'
require 'time'

puts "=" * 60
puts "RunnerHealthCheck Tests"
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
      runner_stale_minutes: 30,
      runner_critical_minutes: 60,
      runner_consecutive_crashes: 3
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
def write_log(dir, lines)
  today = Time.now.strftime('%Y%m%d')
  path = File.join(dir, "runner_#{today}.log")
  File.write(path, lines.join("\n") + "\n")
  path
end

def ts(time)
  "[#{time.strftime('%Y-%m-%d %H:%M:%S')}]"
end

# =============================================================================
# No log file exists
# =============================================================================
section("No log file")

tmp1 = Dir.mktmpdir('runner_health_test')
config1 = FakeConfig.new(log_dir: tmp1)
check1 = HealthChecks::RunnerHealthCheck.new(config1)
result1 = check1.run

test("level is :ok when no log", :ok, result1.level)
test("message mentions log neexistuje", true, result1.message.include?("Log neexistuje"))

FileUtils.rm_rf(tmp1)

# =============================================================================
# Healthy runner — recent Run complete, no crashes
# =============================================================================
section("Healthy runner")

tmp2 = Dir.mktmpdir('runner_health_test')
now = Time.now
lines2 = [
  "#{ts(now - 900)} === Starting ZBNW runner (non_twitter) ===",
  "#{ts(now - 890)} INFO: Processing 84 sources",
  "#{ts(now - 600)} INFO: Run complete. Published: 5, Skipped: 79, Failed: 0",
  "#{ts(now - 300)} === Starting ZBNW runner (non_twitter) ===",
  "#{ts(now - 290)} INFO: Processing 84 sources",
  "#{ts(now - 60)} INFO: Run complete. Published: 3, Skipped: 81, Failed: 0"
]
write_log(tmp2, lines2)

config2 = FakeConfig.new(log_dir: tmp2)
check2 = HealthChecks::RunnerHealthCheck.new(config2)
result2 = check2.run

test("healthy runner is :ok", :ok, result2.level)
test("message includes time of last run", true, result2.message.include?(format_time = (now - 60).strftime('%H:%M:%S')))
test("no remediation for healthy runner", nil, result2.remediation)

FileUtils.rm_rf(tmp2)

# =============================================================================
# Runner crashing repeatedly (no Run complete today)
# =============================================================================
section("Repeated crashes — no success")

tmp3 = Dir.mktmpdir('runner_health_test')
now = Time.now
lines3 = [
  "#{ts(now - 3600)} === Starting ZBNW runner (non_twitter) ===",
  "#{ts(now - 3599)} === ZBNW runner finished (exit code: 1) ===",
  "#{ts(now - 3000)} === Starting ZBNW runner (non_twitter) ===",
  "#{ts(now - 2999)} === ZBNW runner finished (exit code: 1) ===",
  "#{ts(now - 2400)} === Starting ZBNW runner (non_twitter) ===",
  "#{ts(now - 2399)} === ZBNW runner finished (exit code: 1) ===",
  "#{ts(now - 1800)} === Starting ZBNW runner (non_twitter) ===",
  "#{ts(now - 1799)} === ZBNW runner finished (exit code: 1) ===",
  "#{ts(now - 1200)} === Starting ZBNW runner (non_twitter) ===",
  "#{ts(now - 1199)} === ZBNW runner finished (exit code: 1) ===",
  "#{ts(now - 600)} === Starting ZBNW runner (non_twitter) ===",
  "#{ts(now - 599)} === ZBNW runner finished (exit code: 1) ==="
]
write_log(tmp3, lines3)

config3 = FakeConfig.new(log_dir: tmp3)
check3 = HealthChecks::RunnerHealthCheck.new(config3)
result3 = check3.run

test("repeated crashes with no success is :critical", :critical, result3.level)
test("message mentions crash count", true, result3.message.include?("6 crashů"))
test("message mentions no success", true, result3.message.include?("žádný úspěšný run"))
test("has remediation", true, !result3.remediation.nil?)

FileUtils.rm_rf(tmp3)

# =============================================================================
# Runner success then crashes — stale > critical threshold
# =============================================================================
section("Stale runner — critical")

tmp4 = Dir.mktmpdir('runner_health_test')
now = Time.now
lines4 = [
  "#{ts(now - 7200)} INFO: Run complete. Published: 5, Skipped: 79, Failed: 0",
  "#{ts(now - 6600)} === Starting ZBNW runner (non_twitter) ===",
  "#{ts(now - 6599)} === ZBNW runner finished (exit code: 1) ===",
  "#{ts(now - 6000)} === Starting ZBNW runner (non_twitter) ===",
  "#{ts(now - 5999)} === ZBNW runner finished (exit code: 1) ===",
  "#{ts(now - 5400)} === Starting ZBNW runner (non_twitter) ===",
  "#{ts(now - 5399)} === ZBNW runner finished (exit code: 1) ==="
]
write_log(tmp4, lines4)

config4 = FakeConfig.new(log_dir: tmp4)
check4 = HealthChecks::RunnerHealthCheck.new(config4)
result4 = check4.run

test("stale > 60min is :critical", :critical, result4.level)
test("message mentions neběží", true, result4.message.include?("neběží"))
test("has remediation", true, !result4.remediation.nil?)

FileUtils.rm_rf(tmp4)

# =============================================================================
# Runner success then crashes — stale > warning but < critical
# =============================================================================
section("Stale runner — warning")

tmp5 = Dir.mktmpdir('runner_health_test')
now = Time.now
lines5 = [
  "#{ts(now - 2400)} INFO: Run complete. Published: 5, Skipped: 79, Failed: 0",
  "#{ts(now - 1800)} === Starting ZBNW runner (non_twitter) ===",
  "#{ts(now - 1799)} === ZBNW runner finished (exit code: 1) ===",
  "#{ts(now - 1200)} === Starting ZBNW runner (non_twitter) ===",
  "#{ts(now - 1199)} === ZBNW runner finished (exit code: 1) ==="
]
write_log(tmp5, lines5)

config5 = FakeConfig.new(log_dir: tmp5)
check5 = HealthChecks::RunnerHealthCheck.new(config5)
result5 = check5.run

test("stale 40min is :warning", :warning, result5.level)
test("message mentions Poslední OK run", true, result5.message.include?("Poslední OK run"))

FileUtils.rm_rf(tmp5)

# =============================================================================
# Recent success but 3+ consecutive crashes after
# =============================================================================
section("Consecutive crashes after recent success")

tmp6 = Dir.mktmpdir('runner_health_test')
now = Time.now
lines6 = [
  "#{ts(now - 600)} INFO: Run complete. Published: 5, Skipped: 79, Failed: 0",
  "#{ts(now - 300)} === Starting ZBNW runner (non_twitter) ===",
  "#{ts(now - 299)} === ZBNW runner finished (exit code: 1) ===",
  "#{ts(now - 200)} === Starting ZBNW runner (non_twitter) ===",
  "#{ts(now - 199)} === ZBNW runner finished (exit code: 1) ===",
  "#{ts(now - 100)} === Starting ZBNW runner (non_twitter) ===",
  "#{ts(now - 99)} === ZBNW runner finished (exit code: 1) ==="
]
write_log(tmp6, lines6)

config6 = FakeConfig.new(log_dir: tmp6)
check6 = HealthChecks::RunnerHealthCheck.new(config6)
result6 = check6.run

test("3 consecutive crashes after recent success is :warning", :warning, result6.level)
test("message mentions 3 po sobě", true, result6.message.include?("3 po sobě"))
test("has remediation", true, !result6.remediation.nil?)

FileUtils.rm_rf(tmp6)

# =============================================================================
# Exit code 0 is not counted as crash
# =============================================================================
section("Exit code 0 is not a crash")

tmp7 = Dir.mktmpdir('runner_health_test')
now = Time.now
lines7 = [
  "#{ts(now - 600)} INFO: Run complete. Published: 5, Skipped: 79, Failed: 0",
  "#{ts(now - 300)} === Starting ZBNW runner (non_twitter) ===",
  "#{ts(now - 60)} === ZBNW runner finished (exit code: 0) ==="
]
write_log(tmp7, lines7)

config7 = FakeConfig.new(log_dir: tmp7)
check7 = HealthChecks::RunnerHealthCheck.new(config7)
result7 = check7.run

test("exit code 0 after Run complete is :ok", :ok, result7.level)

FileUtils.rm_rf(tmp7)

# =============================================================================
# Mixed: some crashes, then success, then 1 crash (below threshold)
# =============================================================================
section("Below crash threshold")

tmp8 = Dir.mktmpdir('runner_health_test')
now = Time.now
lines8 = [
  "#{ts(now - 1200)} === ZBNW runner finished (exit code: 1) ===",
  "#{ts(now - 900)} === ZBNW runner finished (exit code: 1) ===",
  "#{ts(now - 600)} INFO: Run complete. Published: 5, Skipped: 79, Failed: 0",
  "#{ts(now - 300)} === Starting ZBNW runner (non_twitter) ===",
  "#{ts(now - 299)} === ZBNW runner finished (exit code: 1) ==="
]
write_log(tmp8, lines8)

config8 = FakeConfig.new(log_dir: tmp8)
check8 = HealthChecks::RunnerHealthCheck.new(config8)
result8 = check8.run

test("1 crash after success (below threshold) is :ok", :ok, result8.level)

FileUtils.rm_rf(tmp8)

# =============================================================================
# Custom thresholds
# =============================================================================
section("Custom thresholds")

tmp9 = Dir.mktmpdir('runner_health_test')
now = Time.now
lines9 = [
  "#{ts(now - 900)} INFO: Run complete. Published: 5, Skipped: 79, Failed: 0",
  "#{ts(now - 300)} === ZBNW runner finished (exit code: 1) ===",
  "#{ts(now - 200)} === ZBNW runner finished (exit code: 1) ==="
]
write_log(tmp9, lines9)

# With crash threshold = 2, this should trigger warning
config9 = FakeConfig.new(log_dir: tmp9, thresholds: { runner_consecutive_crashes: 2 })
check9 = HealthChecks::RunnerHealthCheck.new(config9)
result9 = check9.run

test("custom threshold 2 triggers :warning with 2 crashes", :warning, result9.level)

FileUtils.rm_rf(tmp9)

# =============================================================================
# Staleness with custom thresholds
# =============================================================================
section("Custom stale threshold")

tmp10 = Dir.mktmpdir('runner_health_test')
now = Time.now
lines10 = [
  "#{ts(now - 1200)} INFO: Run complete. Published: 5, Skipped: 79, Failed: 0"
]
write_log(tmp10, lines10)

# stale_minutes=10 -> 1200s > 600s -> warning
config10 = FakeConfig.new(log_dir: tmp10, thresholds: { runner_stale_minutes: 10, runner_critical_minutes: 30 })
check10 = HealthChecks::RunnerHealthCheck.new(config10)
result10 = check10.run

test("stale 20min with threshold 10min is :warning", :warning, result10.level)

FileUtils.rm_rf(tmp10)

# =============================================================================
# Incident reproduction: 26 consecutive crashes (simpleidn scenario)
# =============================================================================
section("Incident reproduction — 26 crashes")

tmp11 = Dir.mktmpdir('runner_health_test')
now = Time.now
lines11 = [
  "#{ts(now - 14400)} INFO: Run complete. Published: 5, Skipped: 79, Failed: 0"
]
26.times do |i|
  t = now - 14400 + ((i + 1) * 600)
  lines11 << "#{ts(t)} === Starting ZBNW runner (non_twitter) ==="
  lines11 << "#{ts(t + 1)} === ZBNW runner finished (exit code: 1) ==="
end
write_log(tmp11, lines11)

config11 = FakeConfig.new(log_dir: tmp11)
check11 = HealthChecks::RunnerHealthCheck.new(config11)
result11 = check11.run

test("26 crashes after old success is :critical", :critical, result11.level)
test("message mentions 26 crashů", true, result11.message.include?("26 crashů"))
test("has remediation with tail command", true, result11.remediation.include?("tail"))

FileUtils.rm_rf(tmp11)

# =============================================================================
# CheckResult name
# =============================================================================
section("CheckResult format")

tmp12 = Dir.mktmpdir('runner_health_test')
now = Time.now
write_log(tmp12, ["#{ts(now - 60)} INFO: Run complete. Published: 3, Skipped: 81, Failed: 0"])

config12 = FakeConfig.new(log_dir: tmp12)
check12 = HealthChecks::RunnerHealthCheck.new(config12)
result12 = check12.run

test("check name is 'Runner Health'", 'Runner Health', result12.name)

FileUtils.rm_rf(tmp12)

# =============================================================================
# Error handling — StandardError rescue
# =============================================================================
section("Error handling")

# Simulate error by passing invalid log_dir type
config_err = FakeConfig.new(log_dir: nil)
check_err = HealthChecks::RunnerHealthCheck.new(config_err)
result_err = check_err.run

test("error returns :warning level", :warning, result_err.level)
test("error message includes Error:", true, result_err.message.start_with?("Error:"))

# =============================================================================
# Only runner starting — no Run complete, no crash (just started)
# =============================================================================
section("Runner just started — no complete yet")

tmp13 = Dir.mktmpdir('runner_health_test')
now = Time.now
lines13 = [
  "#{ts(now - 30)} === Starting ZBNW runner (non_twitter) ===",
  "#{ts(now - 29)} INFO: Processing 84 sources"
]
write_log(tmp13, lines13)

config13 = FakeConfig.new(log_dir: tmp13)
check13 = HealthChecks::RunnerHealthCheck.new(config13)
result13 = check13.run

test("runner just started (no complete, no crash) is :ok", :ok, result13.level)
test("message says not yet finished", true, result13.message.include?("ještě nedokončil"))

FileUtils.rm_rf(tmp13)

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
