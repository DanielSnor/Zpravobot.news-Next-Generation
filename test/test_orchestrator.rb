#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script for Orchestrator
# Usage:
#   ruby bin/test_orchestrator.rb                     # Test with test schema
#   ruby bin/test_orchestrator.rb --source nesestra   # Test specific source

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

begin
  require 'orchestrator'
rescue LoadError => e
  puts "⚠️  Cannot load orchestrator: #{e.message}"
  puts "   (pg gem or other dependency may not be installed locally)"
  puts "   Skipping test_orchestrator.rb"
  exit 0
end

source_id = ARGV.find { |a| !a.start_with?('-') } || 'nesestra_bluesky'
schema = 'zpravobot_test'

puts '=' * 60
puts 'Orchestrator Test'
puts '=' * 60
puts "Source: #{source_id}"
puts "Schema: #{schema}"
puts "Mode: DRY RUN (no actual publishing)"
puts '=' * 60
puts

begin
  runner = Orchestrator::Runner.new(
    config_dir: 'config',
    schema: schema
  )

  # Test 1: Load config
  puts '--- Test 1: Config loading ---'
  config = runner.config_loader.load_source(source_id)
  puts "✅ Config loaded for #{config['id']}"
  puts "   Platform: #{config['platform']}"
  puts "   Source: #{config.dig('source', 'handle') || config.dig('source', 'feed_url')}"
  puts "   Target: #{config.dig('target', 'mastodon_account')}"
  puts

  # Test 2: State manager
  puts '--- Test 2: State manager ---'
  runner.state_manager.connect
  state = runner.state_manager.get_source_state(source_id)
  if state
    puts "✅ Source state exists"
    puts "   Last check: #{state[:last_check]}"
    puts "   Posts today: #{state[:posts_today]}"
  else
    puts "ℹ️  No previous state (first run)"
  end
  puts

  # Test 3: extract_since_time — unit assertions (no DB needed)
  puts '--- Test 3: extract_since_time ---'
  now = Time.now

  # last_success preferováno před last_check
  state_with_both = { last_check: now.iso8601, last_success: (now - 3600).iso8601 }
  result = runner.send(:extract_since_time, state_with_both)
  expected_last_success = Time.parse((now - 3600).iso8601)
  raise "extract_since_time should prefer last_success" unless result.to_i == expected_last_success.to_i
  puts "✅ extract_since_time prefers last_success over last_check"

  # Fallback na last_check pokud last_success nil (první run po chybě bez předchozího úspěchu)
  state_no_success = { last_check: (now - 1800).iso8601, last_success: nil }
  result2 = runner.send(:extract_since_time, state_no_success)
  expected_last_check = Time.parse((now - 1800).iso8601)
  raise "extract_since_time should fall back to last_check" unless result2.to_i == expected_last_check.to_i
  puts "✅ extract_since_time falls back to last_check when last_success is nil"

  # nil state → nil
  result3 = runner.send(:extract_since_time, nil)
  raise "extract_since_time(nil) should return nil" unless result3.nil?
  puts "✅ extract_since_time returns nil for nil state"
  puts

  # Test 4: Dry run
  puts '--- Test 4: Dry run ---'
  stats = runner.run_source(source_id, dry_run: true)
  puts "✅ Dry run complete (Test 4)"
  puts "   Processed: #{stats[:processed]}"
  puts "   Would publish: #{stats[:published]}"
  puts "   Skipped: #{stats[:skipped]}"
  puts "   Errors: #{stats[:errors]}"
  puts

  puts '=' * 60
  puts '✅ All tests passed!'
  puts '=' * 60
  puts
  puts 'To run for real (publish to Mastodon):'
  puts "  bundle exec ruby bin/run_scraper.rb --source #{source_id} --test"
  puts

rescue StandardError => e
  puts "❌ Error: #{e.message}"
  puts e.backtrace.first(10).join("\n")
  exit 1
end
