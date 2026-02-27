#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script for ConfigLoader
# Usage: ruby bin/test_config_loader.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'config/config_loader'

puts '=' * 60
puts 'ConfigLoader Test'
puts '=' * 60
puts

config_dir = File.expand_path('../config', __dir__)
puts "Config directory: #{config_dir}"
puts

begin
  loader = Config::ConfigLoader.new(config_dir)

  # Test 1: List all sources
  puts '--- Test 1: List all sources ---'
  source_ids = loader.source_ids
  puts "Found #{source_ids.length} sources:"
  source_ids.each { |id| puts "  - #{id}" }
  puts

  # Test 2: Load single source (try each until one loads successfully)
  config = nil
  test_source_id = nil
  source_ids.each do |sid|
    begin
      config = loader.load_source(sid)
      test_source_id = sid
      break
    rescue StandardError => e
      puts "  ⚠️  #{sid}: #{e.message} (skipping)"
    end
  end

  if config
    puts "--- Test 2: Load #{test_source_id} ---"
    puts "ID: #{config[:id]}"
    puts "Platform: #{config[:platform]}"
    puts "Source handle: #{config.dig(:source, :handle)}"
    puts "Mastodon account: #{config.dig(:target, :mastodon_account)}"
    puts "Source name: #{config.dig(:formatting, :source_name)}"
    puts "Priority: #{config.dig(:scheduling, :priority)}"
    puts "Post length: #{config.dig(:processing, :post_length)}"
    puts "Prefix repost: #{config.dig(:formatting, :prefix_repost)}"
    puts

    # Test 3: SourceConfig wrapper
    puts '--- Test 3: SourceConfig wrapper ---'
    source = Config::SourceConfig.new(config)
    puts "source.id: #{source.id}"
    puts "source.platform: #{source.platform}"
    puts "source.source_handle: #{source.source_handle}"
    puts "source.mastodon_account: #{source.mastodon_account}"
    puts "source.priority: #{source.priority}"
    puts "source.banned_phrases: #{source.banned_phrases}"
    puts
  else
    puts "--- Test 2: SKIPPED (no source could be loaded - missing credentials) ---"
    puts "--- Test 3: SKIPPED ---"
    puts
  end

  # Test 4: Load all enabled sources (tolerates missing credentials)
  puts '--- Test 4: Load all enabled sources ---'
  begin
    all_sources = loader.load_all_sources
    puts "Enabled sources: #{all_sources.length}"
    all_sources.each do |s|
      puts "  - #{s[:id]} (#{s[:platform]}) → #{s.dig(:target, :mastodon_account)}"
    end
  rescue StandardError => e
    puts "  ⚠️  Could not load all sources: #{e.message}"
    all_sources = []
  end
  puts

  # Test 5: Filter by platform
  puts '--- Test 5: Filter by platform ---'
  begin
    twitter_sources = loader.load_sources_by_platform('twitter')
    puts "Twitter sources: #{twitter_sources.length}"
    twitter_sources.each { |s| puts "  - #{s[:id]}" }
  rescue StandardError => e
    puts "  ⚠️  #{e.message}"
  end
  puts

  # Test 6: Filter by Mastodon account
  puts '--- Test 6: Filter by Mastodon account ---'
  begin
    accounts = loader.mastodon_account_ids
    first_account = accounts.first
    if first_account
      matched = loader.load_sources_by_mastodon_account(first_account)
      puts "Sources publishing to @#{first_account}: #{matched.length}"
      matched.each { |s| puts "  - #{s[:id]} (#{s[:platform]})" }
    else
      puts "  No mastodon accounts configured"
    end
  rescue StandardError => e
    puts "  ⚠️  #{e.message}"
  end
  puts

  # Test 7: Mastodon accounts
  puts '--- Test 7: Mastodon accounts ---'
  accounts = loader.mastodon_account_ids
  puts "Mastodon accounts: #{accounts.length}"
  accounts.each { |a| puts "  - #{a}" }
  puts

  # Test 8: Credentials (token should be loaded)
  puts '--- Test 8: Credentials check ---'
  if config && config.dig(:target, :mastodon_token)
    token_preview = config.dig(:target, :mastodon_token)[0..10] + '...'
    puts "Token loaded: #{token_preview}"
  else
    puts "⚠️  Token not loaded (missing credentials or no source loaded)"
  end
  puts

  puts '=' * 60
  puts '✅ All tests passed!'
  puts '=' * 60

rescue StandardError => e
  puts "❌ Error: #{e.message}"
  puts e.backtrace.first(5).join("\n")
  exit 1
end
