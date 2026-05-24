#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# PoC: Threads Profile Scraping via Browserless
# ============================================================
# Ověřuje, zda lze z threads.net/@handle extrahovat:
#   - bio/description
#   - avatar URL
#   - website (pokud je na profilu)
#
# Testuje postupně:
#   1. Bez cookies (Threads profily jsou veřejné)
#   2. Se session cookies (pokud jsou v ENV)
#
# Použití:
#   source env.sh
#   ruby scripts/poc_threads_profile.rb [handle]
#   ruby scripts/poc_threads_profile.rb jirikostaf1
#
# Výstup:
#   - Výsledky extrakce
#   - Části HTML (JSON bloky, meta tagy) pro diagnostiku
# ============================================================

require 'net/http'
require 'uri'
require 'json'

BROWSERLESS_API = 'https://chrome.browserless.io/content'

def fetch_via_browserless(url, cookies: [])
  token = ENV['BROWSERLESS_TOKEN']
  abort 'Chybí BROWSERLESS_TOKEN v ENV. Spusť: source env.sh' if token.nil? || token.empty?

  uri = URI("#{BROWSERLESS_API}?token=#{token}")

  body = {
    url: url,
    gotoOptions: { waitUntil: 'networkidle2', timeout: 30_000 }
  }
  body[:cookies] = cookies unless cookies.empty?

  req = Net::HTTP::Post.new(uri)
  req['Content-Type'] = 'application/json'
  req['User-Agent'] = 'Zpravobot/1.0 (+https://zpravobot.news)'
  req.body = JSON.generate(body)

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = 30
  http.read_timeout = 60

  http.request(req)
end

def extract_profile(html, handle)
  result = { bio: nil, avatar_url: nil, website: nil, notes: [] }

  # --- Bio ---
  # Threads embeduje stejný Meta Graph JSON jako Instagram
  if html =~ /"biography"\s*:\s*"((?:[^"\\]|\\.)*)"/
    bio = $1.gsub('\\n', "\n").gsub('\\"', '"').gsub('\\/', '/').gsub('\\\\', '\\')
    result[:bio] = bio unless bio.strip.empty?
    result[:notes] << 'bio: nalezeno v "biography" JSON poli'
  end

  # Fallback: og:description nebo meta description
  if result[:bio].nil?
    raw = html[/<meta\b[^>]*property="og:description"[^>]*content="([^"]+)"/i, 1] ||
          html[/<meta\b[^>]*content="([^"]+)"[^>]*property="og:description"/i, 1] ||
          html[/<meta\b[^>]*name="description"[^>]*content="([^"]+)"/i, 1]
    if raw
      # Dekóduj HTML entity
      decoded = raw.gsub('&quot;', '"').gsub('&amp;', '&').gsub('&#39;', "'").gsub('&lt;', '<').gsub('&gt;', '>')
      result[:bio] = decoded
      result[:notes] << 'bio: nalezeno v meta description (fallback)'
    end
  end

  # --- Avatar ---
  # Strategie 1: <img alt="[handle]'s profile picture">
  img_pattern = /#{Regexp.escape(handle)}'s profile picture/i
  html.scan(/<img\b[^>]*>/i) do |img_tag|
    alt = img_tag[/\balt="([^"]*)"/i, 1]
    if alt&.match?(img_pattern)
      src = img_tag[/\bsrc="([^"]+)"/i, 1]
      if src && !src.empty?
        result[:avatar_url] = src.gsub('&amp;', '&')
        result[:notes] << 'avatar: nalezen v <img alt="...profile picture">'
        break
      end
    end
  end

  # Strategie 2: og:image
  if result[:avatar_url].nil?
    og = html[/<meta\b[^>]*property="og:image"[^>]*content="([^"]+)"/i, 1] ||
         html[/<meta\b[^>]*content="([^"]+)"[^>]*property="og:image"/i, 1]
    if og
      result[:avatar_url] = og.gsub('&amp;', '&')
      result[:notes] << 'avatar: nalezen v og:image'
    end
  end

  # Strategie 3: JSON profile_pic_url_hd / profile_pic_url
  if result[:avatar_url].nil?
    if html =~ /"profile_pic_url_hd"\s*:\s*"([^"]+)"/
      result[:avatar_url] = $1.gsub('\\/', '/')
      result[:notes] << 'avatar: nalezen v JSON profile_pic_url_hd'
    elsif html =~ /"profile_pic_url"\s*:\s*"([^"]+)"/
      result[:avatar_url] = $1.gsub('\\/', '/')
      result[:notes] << 'avatar: nalezen v JSON profile_pic_url'
    end
  end

  # --- Website ---
  if html =~ /"external_url"\s*:\s*"([^"]+)"/
    website = $1.gsub('\\/', '/').gsub('&amp;', '&')
    result[:website] = website unless website.empty?
    result[:notes] << 'website: nalezena v JSON external_url'
  end

  result
end

def scan_for_json_signals(html)
  signals = []
  %w[biography profile_pic_url external_url username full_name follower_count].each do |key|
    signals << key if html.include?(key)
  end
  signals
end

def detect_login_wall(html)
  # "Log in" je součástí navigace na každé stránce Threads — samo o sobě nestačí.
  # Skutečný login wall: malá stránka + žádný profilový obsah.
  indicators = [
    ['login_required JSON', html.include?('"login_required"')],
    ['loginwall div', html.include?('loginwall') || html.include?('login-wall')],
    ['Prázdný <body>', html.match?(/<body[^>]*>\s*<\/body>/i)],
    ['Příliš malá stránka (<50 kB)', html.bytesize < 50_000]
  ]
  indicators.select { |_, present| present }.map(&:first)
end

# ============================================================
# Main
# ============================================================

handle = (ARGV[0] || 'jirikostaf1').gsub(/^@/, '')
url = "https://www.threads.net/@#{handle}"

puts '=' * 60
puts 'PoC: Threads Profile Scraping'
puts '=' * 60
puts "Handle: @#{handle}"
puts "URL:    #{url}"
puts

# --- Pokus 1: Bez cookies ---
puts '## 1. Fetch bez cookies'
puts '   (Threads profily jsou veřejné — nemělo by být potřeba přihlášení)'
puts

response = fetch_via_browserless(url, cookies: [])

if response.is_a?(Net::HTTPSuccess)
  html = response.body.force_encoding('UTF-8')
  puts "   HTTP: #{response.code} OK  (#{html.bytesize / 1024} kB)"
  puts

  login_wall = detect_login_wall(html)
  html_no_cookies = html

  if login_wall.any?
    puts "   ⚠️  Login wall signály: #{login_wall.join(', ')}"
  else
    puts '   ✅ Žádný login wall'
  end
  puts

  profile = extract_profile(html, handle)

  puts '   Výsledky extrakce:'
  puts "   Bio:     #{profile[:bio] ? profile[:bio][0..80].inspect + (profile[:bio].length > 80 ? '...' : '') : '❌ nenalezena'}"
  puts "   Avatar:  #{profile[:avatar_url] ? '✅ ' + profile[:avatar_url][0..80] + '...' : '❌ nenalezena'}"
  puts "   Website: #{profile[:website] || '— (žádná na profilu)'}"
  puts
  puts '   Zdroje:'
  profile[:notes].each { |n| puts "   • #{n}" }
  if profile[:notes].empty?
    puts '   • žádná data nenalezena'
  end
  puts

  puts '   JSON signály nalezené v HTML:'
  signals = scan_for_json_signals(html)
  if signals.any?
    puts "   • #{signals.join(', ')}"
  else
    puts '   • žádné Meta Graph JSON signály nenalezeny'
  end
else
  puts "   ❌ HTTP #{response.code}: #{response.message}"
  html_no_cookies = nil
end

puts

# --- Pokus 2: Se session cookies (pokud jsou v ENV) ---
threads_session = ENV['THREADS_COOKIE_SESSIONID']

if threads_session.nil? || threads_session.empty?
  puts '## 2. Fetch se cookies'
  puts '   Přeskočeno — THREADS_COOKIE_SESSIONID není v ENV'
  puts '   (Nastav ho v env.sh pokud chceš otestovat přihlášený pohled)'
else
  puts '## 2. Fetch se session cookies'
  puts

  cookies = [
    { name: 'sessionid', value: threads_session, domain: '.threads.net' }
  ]
  csrftoken = ENV['THREADS_COOKIE_CSRFTOKEN']
  cookies << { name: 'csrftoken', value: csrftoken, domain: '.threads.net' } if csrftoken

  response2 = fetch_via_browserless(url, cookies: cookies)

  if response2.is_a?(Net::HTTPSuccess)
    html2 = response2.body.force_encoding('UTF-8')
    puts "   HTTP: #{response2.code} OK  (#{html2.bytesize / 1024} kB)"
    puts

    profile2 = extract_profile(html2, handle)

    puts '   Výsledky extrakce (s cookies):'
    puts "   Bio:     #{profile2[:bio] ? profile2[:bio][0..80].inspect + (profile2[:bio].length > 80 ? '...' : '') : '❌ nenalezena'}"
    puts "   Avatar:  #{profile2[:avatar_url] ? '✅ ' + profile2[:avatar_url][0..80] + '...' : '❌ nenalezena'}"
    puts "   Website: #{profile2[:website] || '— (žádná na profilu)'}"
    puts
    puts "   Zdroje:"
    profile2[:notes].each { |n| puts "   • #{n}" }
  else
    puts "   ❌ HTTP #{response2.code}: #{response2.message}"
  end
end

puts
puts '=' * 60
puts 'Diagnostika: surové HTML fragmenty'
puts '=' * 60

html_diag = html_no_cookies || (defined?(html2) ? html2 : nil)

if html_diag
  # Vypiš prvních 5 nalezených JSON bloků s klíčovými poli
  puts
  puts '### og: meta tagy'
  html_diag.scan(/<meta\b[^>]*(?:og:|twitter:)[^>]*>/i).first(5).each { |m| puts "  #{m[0..160]}" }

  puts
  puts '### JSON výskyty "biography"'
  html_diag.scan(/.{0,20}"biography".{0,80}/).first(3).each { |m| puts "  #{m}" }

  puts
  puts '### JSON výskyty "profile_pic"'
  html_diag.scan(/.{0,20}"profile_pic[^"]*".{0,80}/).first(3).each { |m| puts "  #{m}" }

  puts
  puts '### JSON výskyty "external_url"'
  html_diag.scan(/.{0,20}"external_url".{0,80}/).first(3).each { |m| puts "  #{m}" }
else
  puts '(Žádné HTML k dispozici pro diagnostiku)'
end

puts
puts '=' * 60
