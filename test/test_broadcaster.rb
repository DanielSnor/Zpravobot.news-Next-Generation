#!/usr/bin/env ruby
# frozen_string_literal: true

# Test Broadcaster — pure logic methods (no I/O, no HTTP)
# Run: ruby test/test_broadcaster.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/broadcast/broadcaster'

puts '=' * 60
puts 'Broadcaster Tests (offline)'
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

def test_raises(name, exception_class, &block)
  block.call
  puts "  \e[31m\u2717\e[0m #{name} (no exception raised)"
  $failed += 1
rescue exception_class
  puts "  \e[32m\u2713\e[0m #{name}"
  $passed += 1
rescue StandardError => e
  puts "  \e[31m\u2717\e[0m #{name}"
  puts "    Expected: #{exception_class}"
  puts "    Got:      #{e.class}: #{e.message}"
  $failed += 1
end

def section(title)
  puts
  puts "--- #{title} ---"
end

# ============================================================
# Constants
# ============================================================
section('Constants')

test('VALID_TARGETS includes zpravobot', true,
     Broadcast::Broadcaster::VALID_TARGETS.include?('zpravobot'))
test('VALID_TARGETS includes all', true,
     Broadcast::Broadcaster::VALID_TARGETS.include?('all'))
test('VALID_VISIBILITIES includes public', true,
     Broadcast::Broadcaster::VALID_VISIBILITIES.include?('public'))
test('VALID_VISIBILITIES includes unlisted', true,
     Broadcast::Broadcaster::VALID_VISIBILITIES.include?('unlisted'))
test('VALID_VISIBILITIES includes direct', true,
     Broadcast::Broadcaster::VALID_VISIBILITIES.include?('direct'))
test('ZPRAVOBOT_DOMAIN is zpravobot.news', 'zpravobot.news',
     Broadcast::Broadcaster::ZPRAVOBOT_DOMAIN)

# ============================================================
# Create a broadcaster instance for testing
# ============================================================
broadcaster = Broadcast::Broadcaster.new

# ============================================================
# validate_inputs
# ============================================================
section('validate_inputs')

# Redirect stderr to suppress error messages during tests
original_stderr = $stderr
$stderr = File.open(File::NULL, 'w')

test('valid target zpravobot', true,
     broadcaster.validate_inputs('zpravobot', 'public', nil))
test('valid target all + unlisted', true,
     broadcaster.validate_inputs('all', 'unlisted', nil))
test('valid target all + direct', true,
     broadcaster.validate_inputs('all', 'direct', nil))
test('invalid target rejects', false,
     broadcaster.validate_inputs('invalid', 'public', nil))
test('invalid visibility rejects', false,
     broadcaster.validate_inputs('zpravobot', 'private', nil))
test('nonexistent media file rejects', false,
     broadcaster.validate_inputs('zpravobot', 'public', '/nonexistent/file.png'))
test('invalid target OK with account_filter', true,
     broadcaster.validate_inputs('whatever', 'public', nil, account_filter: [:betabot]))
test('unknown account rejects', false,
     broadcaster.validate_inputs('zpravobot', 'public', nil, account_filter: [:neexistuje_xyz_99]))

$stderr = original_stderr

# ============================================================
# parse_account_filter
# ============================================================
section('parse_account_filter')

test('nil returns nil', nil, broadcaster.parse_account_filter(nil))
test('empty string returns nil', nil, broadcaster.parse_account_filter(''))
test('single account', [:betabot], broadcaster.parse_account_filter('betabot'))
test('multiple accounts', [:betabot, :enkocz], broadcaster.parse_account_filter('betabot,enkocz'))
test('strips whitespace', [:betabot, :enkocz], broadcaster.parse_account_filter(' betabot , enkocz '))

# ============================================================
# format_duration
# ============================================================
section('format_duration')

test('< 60s shows sekund', true, broadcaster.format_duration(30).include?('sekund'))
test('0s shows ~0 sekund', true, broadcaster.format_duration(0).include?('0 sekund'))
test('60s shows minuty', true, broadcaster.format_duration(60).include?('minut'))
test('120s shows minuty', true, broadcaster.format_duration(120).include?('minut'))
test('300s shows minut', true, broadcaster.format_duration(300).include?('minut'))
test('3600s shows hodin', true, broadcaster.format_duration(3600).include?('hodin'))

# ============================================================
# format_progress
# ============================================================
section('format_progress')

progress = broadcaster.format_progress(5, 100, 0)
test('progress contains current/total', true, progress.include?('5/100'))
test('progress contains bar brackets', true, progress.include?('[') && progress.include?(']'))
test('progress without failures has no failed text', false, progress.include?('failed'))

progress_fail = broadcaster.format_progress(50, 100, 3)
test('progress shows failure count', true, progress_fail.include?('3 failed'))

progress_done = broadcaster.format_progress(100, 100, 0)
test('completed progress shows 100/100', true, progress_done.include?('100/100'))

# ============================================================
# estimate_time
# ============================================================
section('estimate_time')

est_text = broadcaster.estimate_time(100, false)
test('text-only estimate is positive', true, est_text > 0)
est_media = broadcaster.estimate_time(100, true)
test('media estimate > text estimate', true, est_media > est_text)
test('zero accounts = 0 time', 0.0, broadcaster.estimate_time(0, false))
test('single account text estimate reasonable', true,
     broadcaster.estimate_time(1, false) > 0 && broadcaster.estimate_time(1, false) < 10)

# ============================================================
# filter_blacklisted
# ============================================================
section('filter_blacklisted')

accounts_mock = {
  betabot: { token: 't', instance: 'https://zpravobot.news' },
  udrzbot: { token: 't', instance: 'https://zpravobot.news' },
  enkocz: { token: 't', instance: 'https://zpravobot.news' }
}
blacklisted = broadcaster.filter_blacklisted(accounts_mock)
test('filter_blacklisted returns array', true, blacklisted.is_a?(Array))
test('udrzbot is blacklisted', true, blacklisted.include?(:udrzbot))
test('betabot is not blacklisted', false, blacklisted.include?(:betabot))
test('enkocz is not blacklisted', false, blacklisted.include?(:enkocz))

empty_blacklisted = broadcaster.filter_blacklisted({})
test('empty accounts returns empty', [], empty_blacklisted)

# ============================================================
# resolve_accounts
# ============================================================
section('resolve_accounts')

zpravobot_accounts = broadcaster.resolve_accounts('zpravobot')
test('zpravobot returns hash', true, zpravobot_accounts.is_a?(Hash))
test('zpravobot has accounts', true, zpravobot_accounts.size > 0)

# All zpravobot accounts should have zpravobot.news in instance
all_zpravobot = zpravobot_accounts.values.all? { |c| c[:instance].to_s.include?('zpravobot.news') }
test('all zpravobot accounts have zpravobot.news instance', true, all_zpravobot)

# Account filter
filtered = broadcaster.resolve_accounts('zpravobot', account_filter: [:betabot])
test('account_filter returns only specified account', 1, filtered.size)
test('account_filter returns betabot', true, filtered.key?(:betabot))

# ============================================================
# BroadcastLogger
# ============================================================
section('BroadcastLogger')

logger = Broadcast::BroadcastLogger.new(log_dir: '/tmp/zbnw_test_broadcast_logs')
test('logger initializes', true, !logger.nil?)
test('log_file is nil before start', true, logger.log_file.nil?)

# log_account_result before start does nothing (no error)
logger.log_account_result(account_id: :test, success: true, status_id: '123')
test('log_account_result before start does not crash', true, true)

# finish before start does nothing
logger.finish(success_count: 0, fail_count: 0, duration_seconds: 0)
test('finish before start does not crash', true, true)

# Clean up test log dir
require 'fileutils'
FileUtils.rm_rf('/tmp/zbnw_test_broadcast_logs')

# ============================================================
# Summary
# ============================================================
puts
puts '=' * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts '=' * 60

exit($failed > 0 ? 1 : 0)
