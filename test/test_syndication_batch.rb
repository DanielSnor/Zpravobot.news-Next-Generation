#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Twitter Syndication API Batch Test
# ============================================================
# Testuje spolehlivost syndication API na více tweetech.
#
# Použití:
#   ruby test_syndication_batch.rb
#
# ============================================================

require 'net/http'
require 'uri'
require 'json'

class SyndicationBatchTest
  ENDPOINT = 'https://cdn.syndication.twimg.com/tweet-result'
  
  # Testovací tweety - různé typy
  TEST_TWEETS = [
    # Tvůj konkrétní tweet
    { id: '2018350356577526100', desc: 'Nezvaný host - s obrázkem' },
    
    # Známé tweety pro test (nahraď aktuálními)
    # { id: '1234567890123456789', desc: 'Test tweet 1' },
  ]
  
  def initialize
    @results = []
  end
  
  def generate_token(tweet_id)
    (((tweet_id.to_f / 1e15) * Math::PI).to_s(36)).gsub(/[0.]/, '')
  end
  
  def fetch_one(tweet_id)
    token = generate_token(tweet_id)
    uri = URI("#{ENDPOINT}?id=#{tweet_id}&token=#{token}")
    
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 5
    http.read_timeout = 5
    
    request = Net::HTTP::Get.new(uri)
    request['User-Agent'] = 'Mozilla/5.0 (compatible; Googlebot/2.1)'
    
    start_time = Time.now
    response = http.request(request)
    elapsed = ((Time.now - start_time) * 1000).round
    
    result = {
      tweet_id: tweet_id,
      status: response.code.to_i,
      elapsed_ms: elapsed,
      success: false,
      has_text: false,
      has_media: false,
      media_count: 0,
      media_urls: [],
      error: nil
    }
    
    if response.code == '200' && response.body && !response.body.empty?
      begin
        data = JSON.parse(response.body)
        result[:success] = true
        result[:has_text] = !data['text'].to_s.empty?
        
        media = data['mediaDetails'] || []
        result[:has_media] = media.any?
        result[:media_count] = media.count
        result[:media_urls] = media.map { |m| m['media_url_https'] }.compact
        result[:text_preview] = data['text'].to_s[0..50]
      rescue JSON::ParserError => e
        result[:error] = "JSON parse: #{e.message}"
      end
    else
      result[:error] = "HTTP #{response.code}"
    end
    
    result
    
  rescue StandardError => e
    {
      tweet_id: tweet_id,
      status: 0,
      elapsed_ms: 0,
      success: false,
      error: "#{e.class}: #{e.message}"
    }
  end
  
  def run
    puts "=" * 70
    puts "🧪 Twitter Syndication API Batch Test"
    puts "=" * 70
    puts
    puts "Testování #{TEST_TWEETS.count} tweetů..."
    puts
    
    TEST_TWEETS.each do |tweet|
      print "  Testing #{tweet[:id]} (#{tweet[:desc]})... "
      
      result = fetch_one(tweet[:id])
      result[:desc] = tweet[:desc]
      @results << result
      
      if result[:success]
        media_info = result[:has_media] ? "📷 #{result[:media_count]} media" : "no media"
        puts "✅ #{result[:elapsed_ms]}ms - #{media_info}"
      else
        puts "❌ #{result[:error]}"
      end
      
      sleep 0.5  # Rate limiting
    end
    
    print_summary
  end
  
  def print_summary
    puts
    puts "=" * 70
    puts "📊 Results Summary"
    puts "=" * 70
    puts
    
    success_count = @results.count { |r| r[:success] }
    media_count = @results.count { |r| r[:has_media] }
    
    puts "Total requests:  #{@results.count}"
    puts "Successful:      #{success_count} (#{(success_count.to_f / @results.count * 100).round}%)"
    puts "With media:      #{media_count}"
    puts
    
    puts "-" * 70
    puts "Detailed Results:"
    puts "-" * 70
    puts
    
    @results.each do |r|
      status = r[:success] ? '✅' : '❌'
      media = r[:has_media] ? "📷#{r[:media_count]}" : '  -'
      
      puts "#{status} #{r[:tweet_id]} | #{r[:status]} | #{r[:elapsed_ms]}ms | #{media}"
      puts "   #{r[:desc]}"
      if r[:has_media]
        r[:media_urls].each { |url| puts "   → #{url}" }
      end
      if r[:error]
        puts "   ⚠️  #{r[:error]}"
      end
      puts
    end
    
    puts "=" * 70
    puts "🎯 Conclusion"
    puts "=" * 70
    puts
    
    if success_count == @results.count
      puts "✅ API je funkční pro všechny testované tweety"
    elsif success_count > 0
      puts "⚠️  API je částečně funkční (#{success_count}/#{@results.count})"
    else
      puts "❌ API nefunguje"
    end
    
    if media_count > 0
      puts "✅ Media URLs jsou dostupné"
    else
      puts "⚠️  Žádné media URLs nebyly získány"
    end
  end
end

# ============================================================
# Main
# ============================================================

if __FILE__ == $PROGRAM_NAME
  # Přidat tweet ID z argumentu pokud je zadán
  if ARGV[0] && ARGV[0].match?(/^\d+$/)
    SyndicationBatchTest::TEST_TWEETS.unshift({
      id: ARGV[0],
      desc: 'User provided tweet'
    })
  end
  
  tester = SyndicationBatchTest.new
  tester.run
end
