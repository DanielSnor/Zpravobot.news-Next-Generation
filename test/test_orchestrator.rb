#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script for Orchestrator
#
# Hybridní test:
# - extract_since_time je čistá unit logika a běží vždy.
# - Načtení konfigurace + state manager + dry-run běh vyžadují source YAML
#   (config/sources/*.yml — nejsou v gitu, jen na serveru) a běžící PostgreSQL.
#   Pokud chybí buď jedno nebo druhé, ty bloky graceful-skipne a běh skončí 0.
#
# Usage:
#   ruby test/test_orchestrator.rb                     # default source 'nesestra_bluesky'
#   ruby test/test_orchestrator.rb my_source_id        # specifický source

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

# --- Always-run section: extract_since_time unit assertions ---
# Žádné DB ani souborové dependence — testuje čistou logiku přímo na Runner.

puts '--- Test: extract_since_time (unit, no DB) ---'

runner = Orchestrator::Runner.new(config_dir: 'config', schema: schema)
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

# --- Conditional section: integration s konfigurací a DB ---
# Source configs nejsou v gitu; DB nemusí být dostupná v každém prostředí.
# Pokud cokoliv chybí, blok graceful-skipneme a test stále uspěje.

source_yml = File.join('config', 'sources', "#{source_id}.yml")
unless File.exist?(source_yml)
  puts "ℹ️  Source config '#{source_yml}' neexistuje v tomto checkoutu."
  puts "   Integration testy (config load / DB / dry-run) přeskočeny."
  puts "   Pro plný běh dej do config/sources/ existující bota nebo předej jeho ID jako argument."
  puts
  puts '=' * 60
  puts '✅ Unit část prošla, integration část přeskočena (chybí source config).'
  puts '=' * 60
  exit 0
end

begin
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
  begin
    runner.state_manager.connect
  rescue PG::Error, StandardError => e
    puts "ℹ️  DB nedostupná (#{e.class}: #{e.message.lines.first&.strip})"
    puts "   Test 2 + Test 4 přeskočeny."
    puts
    puts '=' * 60
    puts '✅ Unit + config OK; DB testy přeskočeny.'
    puts '=' * 60
    exit 0
  end
  state = runner.state_manager.get_source_state(source_id)
  if state
    puts "✅ Source state exists"
    puts "   Last check: #{state[:last_check]}"
    puts "   Posts today: #{state[:posts_today]}"
  else
    puts "ℹ️  No previous state (first run)"
  end
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
