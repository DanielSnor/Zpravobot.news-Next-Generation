#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script pro resolve_facets funkci
# Spuštění: ruby test_facets.rb

puts "=" * 60
puts "Test: Bluesky Facet Resolution"
puts "=" * 60
puts

# Simulace resolve_facets metody
def resolve_facets(text, facets)
  return text || '' if text.nil? || text.empty?
  return text if facets.nil? || facets.empty?
  
  bytes = text.dup.force_encoding('UTF-8').bytes
  
  link_facets = facets
    .select { |f| f.dig('features', 0, '$type') == 'app.bsky.richtext.facet#link' }
    .sort_by { |f| -(f.dig('index', 'byteStart') || 0) }
  
  link_facets.each do |facet|
    byte_start = facet.dig('index', 'byteStart')
    byte_end = facet.dig('index', 'byteEnd')
    uri = facet.dig('features', 0, 'uri')
    
    next unless byte_start && byte_end && uri
    next if byte_start < 0 || byte_end > bytes.length || byte_start >= byte_end
    
    uri_bytes = uri.encode('UTF-8').bytes
    bytes[byte_start...byte_end] = uri_bytes
  end
  
  bytes.pack('C*').force_encoding('UTF-8')
end

# Test cases
tests = [
  {
    name: "Zkrácená URL na konci",
    text: "Odleť v úterý na Kanáry! 🌴🌊 Čeká tě týdenní pobyt v pěkném 4🌟 hotelu s polopenzí. ➡️ zaletsi.cz/zajezdy/lm-z...",
    facets: [
      {
        'index' => { 'byteStart' => 108, 'byteEnd' => 133 },
        'features' => [
          { '$type' => 'app.bsky.richtext.facet#link', 'uri' => 'https://zaletsi.cz/zajezdy/lanzarote-margarita/123456' }
        ]
      }
    ],
    expected_contains: "https://zaletsi.cz/zajezdy/lanzarote-margarita/123456"
  },
  {
    name: "Jednoduchý text bez emojis",
    text: "Check this link: example.com/short...",
    facets: [
      {
        'index' => { 'byteStart' => 17, 'byteEnd' => 37 },
        'features' => [
          { '$type' => 'app.bsky.richtext.facet#link', 'uri' => 'https://example.com/very/long/path/to/article' }
        ]
      }
    ],
    expected_contains: "https://example.com/very/long/path/to/article"
  },
  {
    name: "Více odkazů v textu",
    text: "Link 1: a.com Link 2: b.com",
    facets: [
      {
        'index' => { 'byteStart' => 8, 'byteEnd' => 13 },
        'features' => [
          { '$type' => 'app.bsky.richtext.facet#link', 'uri' => 'https://alpha.example.com/page1' }
        ]
      },
      {
        'index' => { 'byteStart' => 22, 'byteEnd' => 27 },
        'features' => [
          { '$type' => 'app.bsky.richtext.facet#link', 'uri' => 'https://beta.example.com/page2' }
        ]
      }
    ],
    expected_contains: "https://alpha.example.com/page1"
  },
  {
    name: "Bez facets",
    text: "Plain text without any links",
    facets: nil,
    expected_contains: "Plain text without any links"
  },
  {
    name: "Prázdné facets",
    text: "Text with empty facets array",
    facets: [],
    expected_contains: "Text with empty facets array"
  }
]

passed = 0
failed = 0

tests.each do |test|
  print "#{test[:name]}... "
  
  result = resolve_facets(test[:text], test[:facets])
  
  if result.include?(test[:expected_contains])
    puts "✅ PASS"
    passed += 1
  else
    puts "❌ FAIL"
    puts "  Input:    #{test[:text]}"
    puts "  Output:   #{result}"
    puts "  Expected: #{test[:expected_contains]}"
    failed += 1
  end
end

puts
puts "=" * 60
puts "Results: #{passed} passed, #{failed} failed"
puts "=" * 60

# Ukázka skutečného případu
puts
puts "Ukázka transformace:"
puts "-" * 60

original = "Odleť v úterý na Kanáry! 🌴🌊 Čeká tě týdenní pobyt v pěkném 4🌟 hotelu s polopenzí. ➡️ zaletsi.cz/zajezdy/lm-z..."
# Spočítáme byte offset
prefix = "Odleť v úterý na Kanáry! 🌴🌊 Čeká tě týdenní pobyt v pěkném 4🌟 hotelu s polopenzí. ➡️ "
truncated_url = "zaletsi.cz/zajezdy/lm-z..."

byte_start = prefix.bytesize
byte_end = byte_start + truncated_url.bytesize

puts "Original text:"
puts "  #{original}"
puts
puts "Byte offsets: #{byte_start} - #{byte_end}"
puts

facets = [
  {
    'index' => { 'byteStart' => byte_start, 'byteEnd' => byte_end },
    'features' => [
      { '$type' => 'app.bsky.richtext.facet#link', 'uri' => 'https://zaletsi.cz/zajezdy/lanzarote-full-url' }
    ]
  }
]

resolved = resolve_facets(original, facets)
puts "Resolved text:"
puts "  #{resolved}"
