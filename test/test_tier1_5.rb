#!/usr/bin/env ruby
# frozen_string_literal: true

# Test Tier 1.5 Implementation
# Run from project root: ruby test/test_tier1_5.rb

require_relative '../lib/services/syndication_media_fetcher'

puts "=" * 60
puts "🧪 Tier 1.5 (Syndication) Integration Test"
puts "=" * 60
puts

# Test 1: Photo tweet
puts "Test 1: Photo tweet"
puts "-" * 40
result = Services::SyndicationMediaFetcher.fetch('2018350356577526100')
puts "Success: #{result[:success]}"
puts "Photos:  #{result[:photos].count}"
puts "Text:    #{result[:text]&.slice(0, 50)}..."
puts result[:success] ? "✅ PASS" : "❌ FAIL"
puts

# Test 2: Video tweet
puts "Test 2: Video tweet"
puts "-" * 40
result = Services::SyndicationMediaFetcher.fetch('2018344887041593818')
puts "Success:   #{result[:success]}"
puts "Thumbnail: #{result[:video_thumbnail] ? 'yes' : 'no'}"
puts "Text:      #{result[:text]&.slice(0, 50)}..."
puts result[:success] && result[:video_thumbnail] ? "✅ PASS" : "❌ FAIL"
puts

# Test 3: Invalid tweet
puts "Test 3: Invalid tweet (should fail gracefully)"
puts "-" * 40
result = Services::SyndicationMediaFetcher.fetch('99999999999999999999')
puts "Success: #{result[:success]}"
puts "Error:   #{result[:error]}"
puts !result[:success] ? "✅ PASS (expected failure)" : "❌ FAIL"
puts

puts "=" * 60
puts "Tests complete!"
puts "=" * 60
