#!/usr/bin/env ruby
# Test video tweet přes Syndication API

require 'net/http'
require 'uri'
require 'json'

tweet_id = ARGV[0] || '2018344887041593818'  # Video tweet od andrewofpolesia
token = ('a'..'z').to_a.sample(10).join

uri = URI("https://cdn.syndication.twimg.com/tweet-result?id=#{tweet_id}&token=#{token}")

puts "=" * 60
puts "🎬 Testing VIDEO tweet: #{tweet_id}"
puts "=" * 60
puts "URL: #{uri}"
puts

http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl = true
http.open_timeout = 10
http.read_timeout = 10

request = Net::HTTP::Get.new(uri)
request['User-Agent'] = 'Mozilla/5.0 (compatible; Googlebot/2.1)'

response = http.request(request)

puts "HTTP: #{response.code}"
puts

if response.code == '200' && response.body && !response.body.empty?
  data = JSON.parse(response.body)
  
  puts "-" * 60
  puts "📝 Text:"
  puts "-" * 60
  puts data['text']
  puts
  
  puts "-" * 60
  puts "🎬 Video object:"
  puts "-" * 60
  if data['video']
    puts "  Poster (thumbnail): #{data['video']['poster']}"
    puts "  Aspect ratio: #{data['video']['aspectRatio']}"
    puts "  Duration: #{data['video']['durationMs']}ms" if data['video']['durationMs']
    puts
    puts "  Variants:"
    (data['video']['variants'] || []).each do |v|
      puts "    #{v['type']} - #{v['src']}"
    end
  else
    puts "  (no 'video' key in response)"
  end
  puts
  
  puts "-" * 60
  puts "🖼️  mediaDetails:"
  puts "-" * 60
  (data['mediaDetails'] || []).each_with_index do |m, i|
    puts "  [#{i+1}] Type: #{m['type']}"
    puts "      media_url_https: #{m['media_url_https']}"
    if m['video_info']
      puts "      video_info:"
      puts "        aspect_ratio: #{m['video_info']['aspect_ratio']}"
      puts "        duration_millis: #{m['video_info']['duration_millis']}"
      puts "        variants:"
      (m['video_info']['variants'] || []).each do |v|
        bitrate = v['bitrate'] ? "(#{v['bitrate']} bps)" : ""
        puts "          #{v['content_type']} #{bitrate}"
        puts "            #{v['url']}"
      end
    end
    puts
  end
  
  puts "-" * 60
  puts "📊 Summary:"
  puts "-" * 60
  has_video = data['video'] || data['mediaDetails']&.any? { |m| m['type'] == 'video' }
  thumbnail = data.dig('video', 'poster') || 
              data['mediaDetails']&.find { |m| m['type'] == 'video' }&.dig('media_url_https')
  
  puts "  Has video:  #{has_video ? '✅' : '❌'}"
  puts "  Thumbnail:  #{thumbnail || 'N/A'}"
  puts
  
  # Uložit raw JSON pro debug
  puts "-" * 60
  puts "📦 Raw JSON saved to: /tmp/syndication_video_response.json"
  puts "-" * 60
  File.write('/tmp/syndication_video_response.json', JSON.pretty_generate(data))
  
else
  puts "❌ Failed"
  puts "Body: #{response.body[0..500]}" if response.body
end
