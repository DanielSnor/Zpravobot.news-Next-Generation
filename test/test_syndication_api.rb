#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Twitter Syndication API Test
# ============================================================
# Testuje možnost získání tweet dat (včetně obrázků) z veřejného
# syndication API, které Twitter používá pro embedy.
#
# Použití:
#   ruby test_syndication_api.rb <tweet_id>
#   ruby test_syndication_api.rb 2018350356577526100
#
# ============================================================

require 'net/http'
require 'uri'
require 'json'

class SyndicationApiTest
  ENDPOINT = 'https://cdn.syndication.twimg.com/tweet-result'
  
  def initialize(tweet_id)
    @tweet_id = tweet_id.to_s
  end
  
  # Generování tokenu
  # Podle dokumentace funguje i náhodný token
  def generate_token
    random_token
  end
  
  # Alternativní token - náhodný string (také funguje podle dokumentace)
  def random_token
    chars = ('a'..'z').to_a + ('0'..'9').to_a
    10.times.map { chars.sample }.join
  end
  
  def fetch
    token = generate_token
    
    uri = URI("#{ENDPOINT}?id=#{@tweet_id}&token=#{token}")
    
    puts "=" * 60
    puts "🧪 Twitter Syndication API Test"
    puts "=" * 60
    puts
    puts "Tweet ID:  #{@tweet_id}"
    puts "Token:     #{token}"
    puts "URL:       #{uri}"
    puts
    puts "-" * 60
    puts "Fetching..."
    puts "-" * 60
    puts
    
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 10
    
    request = Net::HTTP::Get.new(uri)
    request['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
    request['Accept'] = 'application/json'
    
    response = http.request(request)
    
    puts "HTTP Status: #{response.code} #{response.message}"
    puts "Content-Type: #{response['content-type']}"
    puts "Content-Length: #{response['content-length']}"
    puts
    
    if response.code == '200' && response.body && !response.body.empty?
      parse_response(response.body)
    else
      puts "❌ Request failed or empty response"
      puts "Body: #{response.body[0..500]}" if response.body
      
      # Zkusit s náhodným tokenem
      puts
      puts "Retrying with random token..."
      retry_with_random_token(uri)
    end
    
  rescue StandardError => e
    puts "❌ Error: #{e.class} - #{e.message}"
    puts e.backtrace.first(5).join("\n")
  end
  
  def retry_with_random_token(original_uri)
    token = random_token
    uri = URI("#{ENDPOINT}?id=#{@tweet_id}&token=#{token}")
    
    puts "New token: #{token}"
    
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 10
    
    request = Net::HTTP::Get.new(uri)
    request['User-Agent'] = 'Googlebot/2.1'
    
    response = http.request(request)
    
    puts "HTTP Status: #{response.code}"
    
    if response.code == '200' && response.body && !response.body.empty?
      parse_response(response.body)
    else
      puts "❌ Retry also failed"
    end
  end
  
  def parse_response(body)
    data = JSON.parse(body)
    
    puts "✅ Got JSON response!"
    puts
    puts "=" * 60
    puts "📋 Tweet Data"
    puts "=" * 60
    puts
    
    # Základní info
    puts "Type:       #{data['__typename']}"
    puts "ID:         #{data['id_str']}"
    puts "Created:    #{data['created_at']}"
    puts "Lang:       #{data['lang']}"
    puts
    
    # Text
    puts "-" * 60
    puts "📝 Text:"
    puts "-" * 60
    puts data['text']
    puts
    
    # User
    if data['user']
      puts "-" * 60
      puts "👤 User:"
      puts "-" * 60
      puts "  Username:     @#{data['user']['screen_name']}"
      puts "  Display name: #{data['user']['name']}"
      puts "  Avatar:       #{data['user']['profile_image_url_https']}"
      puts
    end
    
    # Media - hlavní část testu!
    puts "-" * 60
    puts "🖼️  Media (mediaDetails):"
    puts "-" * 60
    
    media_details = data['mediaDetails'] || []
    
    if media_details.empty?
      puts "  (žádná média)"
    else
      media_details.each_with_index do |media, i|
        puts "  [#{i + 1}] Type: #{media['type']}"
        puts "      URL:  #{media['media_url_https']}"
        puts "      Expanded: #{media['expanded_url']}"
        puts
      end
    end
    
    # Photos array (alternativní struktura)
    if data['photos'] && !data['photos'].empty?
      puts "-" * 60
      puts "🖼️  Photos array:"
      puts "-" * 60
      data['photos'].each_with_index do |photo, i|
        puts "  [#{i + 1}] #{photo['url']}"
      end
      puts
    end
    
    # Video
    if data['video']
      puts "-" * 60
      puts "🎬 Video:"
      puts "-" * 60
      puts "  Poster: #{data['video']['poster']}"
      data['video']['variants']&.each do |v|
        puts "  Variant: #{v['type']} - #{v['src']}"
      end
      puts
    end
    
    # Entities (t.co mappings)
    if data['entities'] && data['entities']['urls']
      puts "-" * 60
      puts "🔗 URL Entities:"
      puts "-" * 60
      data['entities']['urls'].each do |url|
        puts "  #{url['url']} → #{url['expanded_url']}"
      end
      puts
    end
    
    # Raw JSON pro debug
    puts "-" * 60
    puts "📦 Raw JSON (first 2000 chars):"
    puts "-" * 60
    puts JSON.pretty_generate(data)[0..2000]
    puts "..." if JSON.pretty_generate(data).length > 2000
    
    # Summary
    puts
    puts "=" * 60
    puts "📊 Summary"
    puts "=" * 60
    puts "  Has text:     #{!data['text'].to_s.empty? ? '✅' : '❌'}"
    puts "  Has media:    #{media_details.any? ? '✅' : '❌'}"
    puts "  Media count:  #{media_details.count}"
    puts "  Media URLs:   #{media_details.map { |m| m['media_url_https'] }.compact}"
    puts
    
    # Vrátit extrahované media URLs
    media_details.map { |m| m['media_url_https'] }.compact
    
  rescue JSON::ParserError => e
    puts "❌ JSON parse error: #{e.message}"
    puts "Raw body (first 500 chars): #{body[0..500]}"
  end
end

# ============================================================
# Main
# ============================================================

if __FILE__ == $PROGRAM_NAME
  if ARGV.empty?
    puts "Použití: ruby test_syndication_api.rb <tweet_id>"
    puts
    puts "Příklady:"
    puts "  ruby test_syndication_api.rb 2018350356577526100"
    puts "  ruby test_syndication_api.rb 1234567890123456789"
    exit 1
  end
  
  tweet_id = ARGV[0]
  
  # Validace
  unless tweet_id.match?(/^\d+$/)
    puts "❌ Tweet ID musí být číslo"
    exit 1
  end
  
  tester = SyndicationApiTest.new(tweet_id)
  tester.fetch
end
