#!/usr/bin/env ruby
# frozen_string_literal: true

# Test Logging module (Phase 10.6)
# Validates format_message, format_message_short, log_path_for_date, setup, MultiLogger
# Run: ruby test/test_logging.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

# Reset Logging module state before requiring (in case other tests set it up)
# We require it fresh and test carefully
require_relative '../lib/logging'
require 'tmpdir'
require 'fileutils'
require 'date'

puts "=" * 60
puts "Logging Module Tests"
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
# format_message (full format for file)
# =============================================================================
section("format_message")

time = Time.new(2026, 1, 19, 14, 30, 45)
msg = Logging.send(:format_message, 'INFO', time, nil, 'Test message')

test("format contains date", true, msg.include?('2026-01-19'))
test("format contains time", true, msg.include?('14:30:45'))
test("format contains severity", true, msg.include?('INFO'))
test("format contains message", true, msg.include?('Test message'))
test("format ends with newline", true, msg.end_with?("\n"))

# =============================================================================
# format_message_short (stdout format)
# =============================================================================
section("format_message_short")

short_msg = Logging.send(:format_message_short, 'INFO', time, nil, 'Short msg')
test("short format does not contain date", false, short_msg.include?('2026-01-19'))
test("short format contains time", true, short_msg.include?('14:30:45'))
test("short format contains message", true, short_msg.include?('Short msg'))

error_msg = Logging.send(:format_message_short, 'ERROR', time, nil, 'Err')
test("ERROR severity gets cross prefix", true, error_msg.include?("\u274c"))

warn_msg = Logging.send(:format_message_short, 'WARN', time, nil, 'Warn')
test("WARN severity gets warning prefix", true, warn_msg.include?("\u26a0"))

info_msg = Logging.send(:format_message_short, 'INFO', time, nil, 'Info')
test("INFO severity gets info prefix", true, info_msg.include?("\u2139"))

# =============================================================================
# log_path_for_date
# =============================================================================
section("log_path_for_date")

# Setup with known values to test path generation
test_dir = File.join(Dir.tmpdir, "zbnw_log_test_#{$$}")
FileUtils.mkdir_p(test_dir)

# We need to setup first to set @name and @dir
Logging.setup(name: 'testlog', dir: test_dir, stdout: false)

date = Date.new(2026, 2, 10)
path = Logging.send(:log_path_for_date, date)
test("path has YYYYMMDD format", true, path.include?('testlog_20260210.log'))
test("path has correct dir", true, path.start_with?(test_dir))

# =============================================================================
# setup + file I/O
# =============================================================================
section("setup + file I/O")

test("setup? returns true after setup", true, Logging.setup?)

# Check that log file was created
today_path = Logging.send(:log_path_for_date, Date.today)
test("log file created in dir", true, File.exist?(today_path))

# Write a log message and verify it appears in file
Logging.info("Test log entry XYZ123")
# Flush and read
content = File.read(today_path)
test("log entry written to file", true, content.include?('XYZ123'))

# =============================================================================
# MultiLogger
# =============================================================================
section("MultiLogger")

test("logger is MultiLogger when stdout: true", true, Logging.setup(name: 'multi_test', dir: test_dir, stdout: true).is_a?(Logging::MultiLogger))

test_no_error("MultiLogger handles info") do
  ml = Logging::MultiLogger.new(Logger.new(File.join(test_dir, 'ml1.log')), Logger.new(IO::NULL))
  ml.info("test")
end

test_no_error("MultiLogger handles error") do
  ml = Logging::MultiLogger.new(Logger.new(File.join(test_dir, 'ml2.log')), Logger.new(IO::NULL))
  ml.error("test error")
end

# =============================================================================
# DEFAULT_KEEP_DAYS constant
# =============================================================================
section("Constants")

test("DEFAULT_KEEP_DAYS is 7", 7, Logging::DEFAULT_KEEP_DAYS)

# =============================================================================
# Cleanup
# =============================================================================
FileUtils.rm_rf(test_dir)

# Reset logging state for any subsequent tests
Logging.instance_variable_set(:@logger, nil)
Logging.instance_variable_set(:@file_logger, nil)

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
