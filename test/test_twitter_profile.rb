#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Twitter Profile Parser Test
# ============================================================
# Testuje parsování profilu z Nitter HTML pro:
# - TwitterProfileSyncer
# - create_source.rb (fetch_twitter_display_name)
#
# Použití:
#   ruby test/test_twitter_profile.rb ct24zive
#   ruby test/test_twitter_profile.rb chmuchmi
# ============================================================

require 'net/http'
require 'uri'

NITTER_INSTANCE = ENV['NITTER_INSTANCE'] || 'http://xn.zpravobot.news:8080'
USER_AGENT = 'Zpravobot/1.0 (+https://zpravobot.news)'

def fetch_html(handle)
  url = "#{NITTER_INSTANCE}/#{handle}"
  puts "📡 Fetching: #{url}"
  
  uri = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == 'https'
  http.open_timeout = 10
  http.read_timeout = 30
  
  request = Net::HTTP::Get.new(uri.request_uri)
  request['User-Agent'] = USER_AGENT
  
  response = http.request(request)
  
  if response.code.to_i == 200
    response.body.force_encoding('UTF-8')
  else
    puts "❌ HTTP #{response.code}"
    nil
  end
rescue => e
  puts "❌ Error: #{e.message}"
  nil
end

def decode_html_entities(text)
  return '' if text.nil?
  
  text
    .gsub('&amp;', '&')
    .gsub('&lt;', '<')
    .gsub('&gt;', '>')
    .gsub('&quot;', '"')
    .gsub('&#39;', "'")
    .gsub('&nbsp;', ' ')
    .gsub(/&#(\d+);/) { [$1.to_i].pack('U') }
    .gsub(/&#x([0-9a-fA-F]+);/) { [$1.to_i(16)].pack('U') }
end

def test_existing_regex(html, handle)
  puts "\n" + "=" * 60
  puts "TEST 1: Existing regex patterns (from TwitterProfileSyncer)"
  puts "=" * 60
  
  profile = {}
  
  # Pattern 1: Display name (current)
  if html =~ /<a[^>]*class="profile-card-fullname"[^>]*>([^<]+)<\/a>/
    profile[:display_name] = decode_html_entities($1.strip)
    puts "✅ display_name: #{profile[:display_name]}"
  else
    puts "❌ display_name: NOT FOUND with current regex"
  end
  
  # Pattern 2: Bio/description (current)
  if html =~ /<div[^>]*class="profile-bio"[^>]*>(.*?)<\/div>/m
    bio = $1.strip
    bio = bio.gsub(/<br\s*\/?>/, "\n").gsub(/<[^>]+>/, '')
    profile[:description] = decode_html_entities(bio).strip
    puts "✅ description: #{profile[:description][0..60]}..."
  else
    puts "❌ description: NOT FOUND with current regex"
  end
  
  # Pattern 3: Avatar (current)
  if html =~ /<a[^>]*class="profile-card-avatar"[^>]*href="([^"]+)"/
    profile[:avatar_url] = $1
    puts "✅ avatar_url: #{profile[:avatar_url][0..60]}..."
  else
    puts "❌ avatar_url: NOT FOUND with current regex"
  end
  
  # Pattern 4: Banner (current)  
  if html =~ /<div[^>]*class="profile-banner"[^>]*>\s*<a[^>]*href="([^"]+)"/m
    profile[:banner_url] = $1
    puts "✅ banner_url: #{profile[:banner_url][0..60]}..."
  else
    puts "❌ banner_url: NOT FOUND with current regex"
  end
  
  profile
end

def analyze_html_structure(html)
  puts "\n" + "=" * 60
  puts "TEST 2: Analyzing actual HTML structure"
  puts "=" * 60
  
  # Find profile-related classes
  classes = html.scan(/class="([^"]*profile[^"]*)"/).flatten.uniq
  puts "\n📋 Profile-related classes found:"
  classes.each { |c| puts "   - #{c}" }
  
  # Find title tag
  if html =~ /<title>([^<]+)<\/title>/
    puts "\n📰 Title: #{$1}"
  end
  
  # Find profile image patterns
  puts "\n🖼️  Image patterns:"
  html.scan(/profile[^"]*"[^>]*(?:src|href)="([^"]+)"/).flatten.uniq.first(5).each do |url|
    puts "   - #{url[0..80]}..."
  end
  
  # Find fullname patterns
  puts "\n👤 Fullname patterns:"
  if html =~ /fullname[^>]*>([^<]+)</
    puts "   - Found: #{$1.strip}"
  end
  
  # Alternative: look for profile-card patterns
  puts "\n🔍 Profile-card sections:"
  html.scan(/<[^>]*class="[^"]*profile-card[^"]*"[^>]*>/).each do |match|
    puts "   - #{match[0..80]}..."
  end
end

def try_alternative_patterns(html)
  puts "\n" + "=" * 60
  puts "TEST 3: Trying alternative regex patterns"
  puts "=" * 60
  
  # Alt pattern 1: fullname anywhere
  patterns = {
    'fullname' => /class="[^"]*fullname[^"]*"[^>]*>([^<]+)</,
    'profile-card-fullname' => /<[^>]*profile-card-fullname[^>]*>([^<]+)</,
    'title with @' => /<title>([^(@]+)/,
    'avatar src' => /avatar[^>]*src="([^"]+)"/,
    'avatar href' => /avatar[^>]*href="([^"]+)"/,
    'profile pic' => /profile[^>]*pic[^>]*(?:src|href)="([^"]+)"/,
    'banner href' => /banner[^>]*href="([^"]+)"/,
    'bio div' => /<div[^>]*bio[^>]*>(.*?)<\/div>/m,
    'description div' => /<div[^>]*description[^>]*>(.*?)<\/div>/m
  }
  
  patterns.each do |name, pattern|
    match = html.match(pattern)
    if match
      value = match[1].to_s.strip[0..60]
      puts "✅ #{name}: #{value}#{'...' if match[1].to_s.length > 60}"
    else
      puts "❌ #{name}: not found"
    end
  end
end

def save_html_sample(html, handle)
  filename = "/tmp/nitter_#{handle}.html"
  File.write(filename, html)
  puts "\n💾 HTML saved to: #{filename}"
  puts "   View with: head -100 #{filename}"
end

# Main
handle = ARGV[0]&.gsub(/^@/, '') || 'ct24zive'

puts <<~HEADER
  ╔══════════════════════════════════════════════════════════════════════╗
  ║              Twitter Profile Parser Test                             ║
  ╚══════════════════════════════════════════════════════════════════════╝
  
  Handle: @#{handle}
  Instance: #{NITTER_INSTANCE}
  Time: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}
  
HEADER

html = fetch_html(handle)
exit 1 unless html

puts "✅ HTML fetched (#{html.bytesize} bytes)"

# Run tests
test_existing_regex(html, handle)
analyze_html_structure(html)
try_alternative_patterns(html)
save_html_sample(html, handle)

puts "\n" + "=" * 60
puts "DONE"
puts "=" * 60
