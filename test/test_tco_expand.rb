#!/usr/bin/env ruby
# frozen_string_literal: true

# Test t.co URL expansion
# Usage: ruby test/test_tco_expand.rb

require 'net/http'
require 'uri'

def expand_tco(tco_url)
  return nil unless tco_url&.match?(%r{https?://t\.co/})
  
  uri = URI.parse(tco_url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = 5
  http.read_timeout = 5
  
  response = http.head(uri.path)
  
  case response
  when Net::HTTPRedirection
    response['location']
  else
    puts "   Response: #{response.code} #{response.message}"
    nil
  end
rescue StandardError => e
  puts "   Error: #{e.message}"
  nil
end

# Test URLs z reálných IFTTT dat
test_urls = [
  "https://t.co/AnS1WCAT8v",  # ČHMÚ foto
  "https://t.co/geAx7IhCTa",  # Dárek pro Putina foto
  "https://t.co/rkrNhzrIAA",  # Další foto
  "https://t.co/m5LbEHKjvD",  # Reply foto
  "https://t.co/DuI0Dw7TmY",  # Quote tweet link
]

puts "Testing t.co URL expansion"
puts "=" * 60

test_urls.each do |url|
  puts "\n#{url}"
  expanded = expand_tco(url)
  if expanded
    puts "   → #{expanded}"
  else
    puts "   → FAILED"
  end
end

puts "\n" + "=" * 60
puts "Done!"
