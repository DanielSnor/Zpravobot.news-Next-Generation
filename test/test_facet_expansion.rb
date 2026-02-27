#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script for expand_facet_urls
# Run: ruby test_facet_expansion.rb
#
# Tests the facet URL expansion with real Bluesky API data

require 'net/http'
require 'json'

# ============================================
# expand_facet_urls implementation (standalone for testing)
# ============================================

def expand_facet_urls(text, facets)
  return text if text.nil? || facets.nil? || facets.empty?
  
  # Find all link facets
  link_facets = facets.select do |facet|
    features = facet['features'] || []
    features.any? { |f| f['$type'] == 'app.bsky.richtext.facet#link' }
  end
  
  return text if link_facets.empty?
  
  # Sort by byteStart descending - replace from end to preserve byte indices
  sorted_facets = link_facets.sort_by { |f| -(f.dig('index', 'byteStart') || 0) }
  
  # Work with bytes since Bluesky uses byte indices
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
  puts "⚠️  Warning: expand_facet_urls failed: #{e.message}"
  text
end

# ============================================
# Test with synthetic data
# ============================================

puts "=" * 60
puts "TEST 1: Synthetic data (zaletsi.cz example)"
puts "=" * 60

test_text = "Odleť v úterý na Kanáry! 🌴🌊 ➡️ zaletsi.cz/zajezdy/lm-z..."
# Note: byte positions need to be calculated for the actual text
# For Czech text with emoji, character != byte position

# Let's calculate correct byte positions
text_before_url = "Odleť v úterý na Kanáry! 🌴🌊 ➡️ "
byte_start = text_before_url.bytesize
url_part = "zaletsi.cz/zajezdy/lm-z..."
byte_end = byte_start + url_part.bytesize

test_facets = [
  {
    "index" => { "byteStart" => byte_start, "byteEnd" => byte_end },
    "features" => [
      {
        "$type" => "app.bsky.richtext.facet#link",
        "uri" => "https://zaletsi.cz/zajezdy/lm-zajezd-z-prahy-na-lanzarote-v-druhe-pulce-ledna-4-hotel-s-polopenzi/"
      }
    ]
  }
]

puts "Input text:  #{test_text}"
puts "Byte range:  #{byte_start}..#{byte_end}"
result = expand_facet_urls(test_text, test_facets)
puts "Output text: #{result}"
puts

if result.include?("https://zaletsi.cz/zajezdy/lm-zajezd")
  puts "✅ TEST 1 PASSED: Full URL restored"
else
  puts "❌ TEST 1 FAILED: URL not expanded"
end

# ============================================
# Test with real API data
# ============================================

puts
puts "=" * 60
puts "TEST 2: Real Bluesky API data"
puts "=" * 60

handles_to_test = [
  'zaletsi.bsky.social',
  'denikn.cz',
  'respektcz.bsky.social'
]

handles_to_test.each do |handle|
  puts
  puts "--- Testing @#{handle} ---"
  
  begin
    uri = URI("https://public.api.bsky.app/xrpc/app.bsky.feed.getAuthorFeed?actor=#{handle}&limit=5")
    response = Net::HTTP.get(uri)
    data = JSON.parse(response)
    
    if data['error']
      puts "⚠️  API Error: #{data['message']}"
      next
    end
    
    posts_with_facets = 0
    urls_expanded = 0
    
    (data['feed'] || []).each_with_index do |item, i|
      record = item.dig('post', 'record')
      next unless record
      
      text = record['text']
      facets = record['facets']
      
      if facets && !facets.empty?
        link_facets = facets.select { |f| 
          (f['features'] || []).any? { |feat| feat['$type'] == 'app.bsky.richtext.facet#link' }
        }
        
        if link_facets.any?
          posts_with_facets += 1
          
          expanded = expand_facet_urls(text, facets)
          
          # Check if expansion happened (text changed)
          if expanded != text
            urls_expanded += 1
            puts
            puts "Post #{i + 1}:"
            puts "  Original: #{text[0..80]}#{text.length > 80 ? '...' : ''}"
            puts "  Expanded: #{expanded[0..80]}#{expanded.length > 80 ? '...' : ''}"
            
            # Show the URLs from facets
            link_facets.each do |f|
              uri = f.dig('features', 0, 'uri')
              puts "  Facet URL: #{uri}" if uri
            end
          end
        end
      end
    end
    
    puts "  Found #{posts_with_facets} posts with link facets, expanded #{urls_expanded}"
    
  rescue => e
    puts "⚠️  Error fetching @#{handle}: #{e.message}"
  end
end

puts
puts "=" * 60
puts "TEST 3: Edge cases"
puts "=" * 60

# Test nil handling
puts "nil text: #{expand_facet_urls(nil, []).nil? ? '✅ returns nil' : '❌ error'}"
puts "nil facets: #{expand_facet_urls('test', nil) == 'test' ? '✅ returns original' : '❌ error'}"
puts "empty facets: #{expand_facet_urls('test', []) == 'test' ? '✅ returns original' : '❌ error'}"

# Test multiple URLs in one post
multi_url_text = "Check out site1.com/x and also site2.com/y for more"
multi_facets = [
  {
    "index" => { "byteStart" => 10, "byteEnd" => 21 },
    "features" => [{ "$type" => "app.bsky.richtext.facet#link", "uri" => "https://site1.com/full-path-1" }]
  },
  {
    "index" => { "byteStart" => 31, "byteEnd" => 42 },
    "features" => [{ "$type" => "app.bsky.richtext.facet#link", "uri" => "https://site2.com/full-path-2" }]
  }
]
multi_result = expand_facet_urls(multi_url_text, multi_facets)
puts "Multiple URLs: #{multi_result.include?('full-path-1') && multi_result.include?('full-path-2') ? '✅ both expanded' : '❌ error'}"
puts "  Result: #{multi_result}"

puts
puts "=" * 60
puts "Done!"
puts "=" * 60
