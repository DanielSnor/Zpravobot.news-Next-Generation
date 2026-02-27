#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script for StateManager on Cloudron
# Usage:
#   ruby bin/test_state_manager.rb           # Production schema (zpravobot)
#   ruby bin/test_state_manager.rb test      # Test schema (zpravobot_test)

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

begin
  require 'state/state_manager'
rescue LoadError => e
  puts "⚠️  Cannot load state_manager: #{e.message}"
  puts "   (pg gem may not be installed locally)"
  puts "   Skipping test_state_manager.rb"
  exit 0
end

# Determine schema
schema = ARGV[0] == 'test' ? 'zpravobot_test' : 'zpravobot'

puts '=' * 60
puts "StateManager Test (schema: #{schema})"
puts '=' * 60
puts

if ENV['CLOUDRON_POSTGRESQL_URL']
  puts "✅ Cloudron environment detected"
  puts "   Host: #{ENV['CLOUDRON_POSTGRESQL_HOST']}"
  puts "   Database: #{ENV['CLOUDRON_POSTGRESQL_DATABASE']}"
  puts "   Schema: #{schema}"
  puts
else
  puts "⚠️  No Cloudron environment, using defaults"
  puts
end

begin
  manager = State::StateManager.new(schema: schema)
  manager.connect
  puts "✅ Connected (schema: #{manager.schema})"
  puts

  # Test 1: Check published
  puts '--- Test 1: Check if post is published ---'
  test_source = 'test_source'
  test_post_id = "test_post_#{Time.now.to_i}"
  
  result = manager.published?(test_source, test_post_id)
  puts "published?: #{result}"
  puts result == false ? '✅ Correct' : '❌ Unexpected'
  puts

  # Test 2: Mark as published
  puts '--- Test 2: Mark post as published ---'
  manager.mark_published(
    test_source,
    test_post_id,
    post_url: 'https://example.com/post/123',
    mastodon_status_id: "test_status_#{Time.now.to_i}"
  )
  puts '✅ Marked as published'
  puts

  # Test 3: Verify
  puts '--- Test 3: Verify ---'
  result = manager.published?(test_source, test_post_id)
  puts "published?: #{result}"
  puts result == true ? '✅ Correct' : '❌ Unexpected'
  puts

  # Test 4: Source state
  puts '--- Test 4: Source state ---'
  manager.mark_check_success(test_source, posts_published: 1)
  state = manager.get_source_state(test_source)
  puts "State: #{state[:source_id]}, posts_today: #{state[:posts_today]}"
  puts '✅ OK'
  puts

  # Test 5: Activity log
  puts '--- Test 5: Activity log ---'
  manager.log_fetch(test_source, posts_found: 5)
  activities = manager.recent_activity(test_source, limit: 3)
  puts "Activities: #{activities.length}"
  puts '✅ OK'
  puts

  # Test 6: Stats
  puts '--- Test 6: Stats ---'
  stats = manager.stats
  puts "Published: #{stats[:total_published]}, Sources: #{stats[:total_sources]}"
  puts '✅ OK'
  puts

  manager.disconnect

  puts '=' * 60
  puts '✅ All tests passed!'
  puts '=' * 60

rescue PG::Error => e
  puts "❌ Database error: #{e.message}"
  puts
  puts 'Make sure migration has been run:'
  puts "  psql \"$CLOUDRON_POSTGRESQL_URL\" -f db/migrate_cloudron.sql"
  puts "  psql \"$CLOUDRON_POSTGRESQL_URL\" -f db/migrate_test_schema.sql" if schema == 'zpravobot_test'
  exit 1
rescue => e
  puts "❌ Error: #{e.message}"
  puts e.backtrace.first(3).join("\n")
  exit 1
end
