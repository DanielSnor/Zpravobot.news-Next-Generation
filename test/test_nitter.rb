#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Nitter Instance Test Script
# ============================================================
# Otestuje připojení k Nitter instanci a základní funkčnost.
#
# Použití:
#   ruby test_nitter.rb
#   ruby test_nitter.rb ct24zive
#   ruby test_nitter.rb --rss ct24zive
#   ruby test_nitter.rb --html ct24zive
# ============================================================

require 'net/http'
require 'uri'

NITTER_INSTANCE = ENV['NITTER_INSTANCE'] || 'http://xn.zpravobot.news:8080'
DEFAULT_TEST_HANDLE = 'ct24zive'

# Test handles - známé aktivní české Twitter účty
TEST_HANDLES = %w[
  ct24zive
  iikiiki
  KudlaMichal
].freeze

def test_connection(instance)
  puts "🔗 Testing connection to #{instance}..."
  
  uri = URI(instance)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == 'https'
  http.open_timeout = 10
  http.read_timeout = 10
  
  request = Net::HTTP::Get.new('/')
  request['User-Agent'] = 'Zpravobot/1.0 (+https://zpravobot.news)'
  
  response = http.request(request)
  
  if response.code.to_i == 200
    puts "   ✅ Connection OK (HTTP #{response.code})"
    true
  else
    puts "   ⚠️  HTTP #{response.code}: #{response.message}"
    response.code.to_i < 500
  end
rescue StandardError => e
  puts "   ❌ Connection failed: #{e.message}"
  false
end

def test_rss_feed(instance, handle)
  puts "\n📡 Testing RSS feed for @#{handle}..."
  
  url = "#{instance}/#{handle}/rss"
  puts "   URL: #{url}"
  
  uri = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == 'https'
  http.open_timeout = 10
  http.read_timeout = 30
  
  request = Net::HTTP::Get.new(uri.request_uri)
  request['User-Agent'] = 'Zpravobot/1.0 (+https://zpravobot.news)'
  
  response = http.request(request)
  
  if response.code.to_i == 200
    body = response.body.force_encoding('UTF-8')
    
    # Check if it's valid RSS
    if body.include?('<rss') || body.include?('<feed')
      # Count items
      item_count = body.scan(/<item>/).count
      item_count = body.scan(/<entry>/).count if item_count == 0
      
      puts "   ✅ RSS feed OK (#{item_count} items)"
      
      # Show first item title if available
      if match = body.match(/<title>([^<]+)<\/title>/)
        puts "   📰 Channel: #{match[1]}"
      end
      
      # Show recent item
      if match = body.match(/<item>.*?<title>([^<]+)<\/title>/m)
        puts "   📝 Latest: #{match[1][0..60]}#{'...' if match[1].length > 60}"
      end
      
      return { success: true, items: item_count, body: body }
    else
      puts "   ⚠️  Response is not RSS/Atom feed"
      puts "   Content-Type: #{response['content-type']}"
      return { success: false, error: 'Not RSS' }
    end
  else
    puts "   ❌ HTTP #{response.code}: #{response.message}"
    return { success: false, error: "HTTP #{response.code}" }
  end
rescue StandardError => e
  puts "   ❌ Error: #{e.message}"
  { success: false, error: e.message }
end

def test_html_page(instance, handle)
  puts "\n🌐 Testing HTML page for @#{handle}..."
  
  url = "#{instance}/#{handle}"
  puts "   URL: #{url}"
  
  uri = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == 'https'
  http.open_timeout = 10
  http.read_timeout = 30
  
  request = Net::HTTP::Get.new(uri.request_uri)
  request['User-Agent'] = 'Zpravobot/1.0 (+https://zpravobot.news)'
  
  response = http.request(request)
  
  if response.code.to_i == 200
    body = response.body.force_encoding('UTF-8')
    
    # Extract profile info
    if match = body.match(/<title>([^<]+)<\/title>/)
      puts "   ✅ Page OK"
      puts "   👤 Title: #{match[1]}"
    end
    
    # Check for tweets
    tweet_count = body.scan(/class="tweet-/).count
    tweet_count = body.scan(/timeline-item/).count if tweet_count == 0
    puts "   📊 Tweets visible: #{tweet_count}"
    
    return { success: true, tweets: tweet_count }
  elsif response.code.to_i == 302 || response.code.to_i == 301
    puts "   ↪️  Redirect to: #{response['location']}"
    return { success: true, redirect: response['location'] }
  else
    puts "   ❌ HTTP #{response.code}: #{response.message}"
    return { success: false, error: "HTTP #{response.code}" }
  end
rescue StandardError => e
  puts "   ❌ Error: #{e.message}"
  { success: false, error: e.message }
end

def run_full_test(instance)
  puts <<~HEADER
    ╔══════════════════════════════════════════════════════════════════════╗
    ║                    Nitter Instance Test Suite                        ║
    ╚══════════════════════════════════════════════════════════════════════╝
    
    Instance: #{instance}
    Time: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}
    
  HEADER
  
  results = []
  
  # Test connection
  unless test_connection(instance)
    puts "\n❌ Cannot connect to Nitter instance. Aborting."
    return
  end
  
  # Test each handle
  TEST_HANDLES.each do |handle|
    puts "\n#{'─' * 60}"
    result = test_rss_feed(instance, handle)
    results << { handle: handle, rss: result }
  end
  
  # Summary
  puts <<~SUMMARY
    
    #{'═' * 60}
    SUMMARY
    #{'═' * 60}
  SUMMARY
  
  passed = results.count { |r| r[:rss][:success] }
  results.each do |r|
    status = r[:rss][:success] ? '✅' : '❌'
    items = r[:rss][:items] ? "(#{r[:rss][:items]} items)" : ''
    puts "  #{status} @#{r[:handle]} #{items}"
  end
  
  puts "\n  Total: #{passed}/#{results.count} passed"
  puts "\n#{'═' * 60}"
end

# Main
if __FILE__ == $0
  instance = NITTER_INSTANCE
  
  if ARGV.empty?
    run_full_test(instance)
  elsif ARGV[0] == '--rss'
    handle = ARGV[1] || DEFAULT_TEST_HANDLE
    test_rss_feed(instance, handle)
  elsif ARGV[0] == '--html'
    handle = ARGV[1] || DEFAULT_TEST_HANDLE
    test_html_page(instance, handle)
  else
    handle = ARGV[0].gsub(/^@/, '')
    test_connection(instance)
    test_rss_feed(instance, handle)
    test_html_page(instance, handle)
  end
end
