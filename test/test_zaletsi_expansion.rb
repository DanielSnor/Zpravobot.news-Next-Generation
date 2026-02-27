#!/usr/bin/env ruby
# frozen_string_literal: true

# Test expand_facet_urls with zaletsi.cz data
# Run: ruby test_zaletsi_expansion.rb

require 'net/http'
require 'json'

def expand_facet_urls(text, facets)
  return text if text.nil? || facets.nil? || facets.empty?
  
  link_facets = facets.select do |facet|
    features = facet['features'] || []
    features.any? { |f| f['$type'] == 'app.bsky.richtext.facet#link' }
  end
  
  return text if link_facets.empty?
  
  sorted_facets = link_facets.sort_by { |f| -(f.dig('index', 'byteStart') || 0) }
  
  result_bytes = text.dup.force_encoding('UTF-8').bytes
  
  sorted_facets.each do |facet|
    byte_start = facet.dig('index', 'byteStart')
    byte_end = facet.dig('index', 'byteEnd')
    
    uri = (facet['features'] || []).find { |f| 
      f['$type'] == 'app.bsky.richtext.facet#link' 
    }&.dig('uri')
    
    next unless uri && byte_start && byte_end
    next if byte_start < 0 || byte_end > result_bytes.length
    
    uri_bytes = uri.bytes
    result_bytes = result_bytes[0...byte_start] + uri_bytes + result_bytes[byte_end..]
  end
  
  result_bytes.pack('C*').force_encoding('UTF-8')
rescue => e
  puts "⚠️  Error: #{e.message}"
  text
end

puts "=" * 70
puts "Testing expand_facet_urls with zaletsi.cz"
puts "=" * 70

uri = URI("https://public.api.bsky.app/xrpc/app.bsky.feed.getAuthorFeed?actor=zaletsi.cz&limit=5")
response = Net::HTTP.get(uri)
data = JSON.parse(response)

if data['error']
  puts "❌ API Error: #{data['message']}"
  exit 1
end

passed = 0
failed = 0

data['feed'].each_with_index do |item, i|
  record = item.dig('post', 'record')
  next unless record
  
  text = record['text']
  facets = record['facets']
  
  next if facets.nil? || facets.empty?
  
  puts
  puts "-" * 70
  puts "POST #{i + 1}"
  puts "-" * 70
  
  puts "ORIGINAL TEXT:"
  puts text
  puts
  
  expanded = expand_facet_urls(text, facets)
  
  puts "EXPANDED TEXT:"
  puts expanded
  puts
  
  # Check if expansion worked
  has_truncated = text.include?('...')
  has_full_url = expanded.include?('https://')
  no_truncation = !expanded.include?('...')
  
  if has_truncated && has_full_url && no_truncation
    puts "✅ SUCCESS: URL expanded correctly"
    passed += 1
  elsif !has_truncated
    puts "ℹ️  SKIP: Original had no truncated URL"
  else
    puts "❌ FAILED: Expansion did not work"
    puts "   has_truncated in original: #{has_truncated}"
    puts "   has_full_url in expanded: #{has_full_url}"  
    puts "   no_truncation in expanded: #{no_truncation}"
    failed += 1
  end
end

puts
puts "=" * 70
puts "Results: #{passed} passed, #{failed} failed"
puts "=" * 70
