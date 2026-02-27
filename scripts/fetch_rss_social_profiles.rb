#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# fetch_rss_social_profiles.rb
# ============================================================
# Přečte všechny *_rss.yml source soubory, pro každý načte
# Mastodon profil a z metadata polí (x:, bsky:, fb:) odvodí
# social_profile.platform a social_profile.handle.
#
# Skupinové účty (více RSS sources → stejný mastodon_account)
# jsou detekovány a označeny jako SHARED. Skript NEVYBÍRÁ
# primární zdroj automaticky — výsledek vyžaduje ruční review
# a rozhodnutí před spuštěním apply skriptu.
#
# Výstup:
#   - Přehled na terminál (includuję sekci SHARED ACCOUNTS)
#   - output/rss_social_profiles.yml — zdroje připravené k aplikaci
#     (pouze ty kde primary: true nebo shared: false)
#   - output/rss_shared_accounts.yml — skupinové účty k rozhodnutí
#
# Použití:
#   ruby scripts/fetch_rss_social_profiles.rb
#   ruby scripts/fetch_rss_social_profiles.rb --dry-run   # bez API volání
# ============================================================

require 'yaml'
require 'net/http'
require 'uri'
require 'json'
require 'fileutils'

DRY_RUN = ARGV.include?('--dry-run')

BASE_DIR     = File.expand_path('..', __dir__)
SOURCES      = File.join(BASE_DIR, 'config', 'sources')
ACCOUNTS     = File.join(BASE_DIR, 'config', 'mastodon_accounts.yml')
GLOBAL       = File.join(BASE_DIR, 'config', 'global.yml')
OUT_DIR      = File.join(BASE_DIR, 'output')
OUT_FILE     = File.join(OUT_DIR, 'rss_social_profiles.yml')
SHARED_FILE  = File.join(OUT_DIR, 'rss_shared_accounts.yml')

# Pole → platform + extrakce handle z URL nebo Mastodon @handle@domain.tld formátu
FIELD_MATCHERS = [
  {
    prefix: 'x:',
    platform: 'twitter',
    extract: ->(v) {
      # Mastodon formát: @handle@twitter.com nebo @handle@x.com
      if v =~ /\A@(.+?)@(twitter|x)\.com\z/i
        $1
      else
        # URL formát: https://x.com/handle nebo https://twitter.com/handle
        v.split('/').last
      end
    }
  },
  { prefix: 'bsky:', platform: 'bluesky',  extract: ->(v) { v.split('/').last } },
  { prefix: 'fb:',   platform: 'facebook', extract: ->(v) { v.split('/').last } },
].freeze

# ============================================================
# Helpers
# ============================================================

def load_yaml(path)
  YAML.safe_load(File.read(path), symbolize_names: false) || {}
rescue => e
  warn "WARN: Cannot load #{path}: #{e.message}"
  {}
end

def mastodon_instance(global)
  global.dig('mastodon', 'instance') || 'https://zpravobot.news'
end

def fetch_mastodon_fields(token, instance)
  uri = URI("#{instance}/api/v1/accounts/verify_credentials")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == 'https'
  http.open_timeout = 8
  http.read_timeout = 10

  req = Net::HTTP::Get.new(uri)
  req['Authorization'] = "Bearer #{token}"
  req['User-Agent'] = 'Zpravobot/1.0'

  res = http.request(req)
  return nil unless res.is_a?(Net::HTTPSuccess)

  data = JSON.parse(res.body)
  (data['fields'] || []).map { |f| { name: f['name'].to_s.strip.downcase, value: strip_html(f['value'].to_s.strip) } }
rescue => e
  warn "  API error: #{e.message}"
  nil
end

def strip_html(str)
  str.gsub(/<[^>]+>/, '').strip
end

def detect_social_profile(fields)
  return nil if fields.nil? || fields.empty?

  FIELD_MATCHERS.each do |m|
    field = fields.find { |f| f[:name].start_with?(m[:prefix]) }
    next unless field

    url = field[:value]
    next if url.nil? || url.empty? || url == '""'

    handle = m[:extract].call(url)
    next if handle.nil? || handle.empty?

    return { platform: m[:platform], handle: handle, source_url: url }
  end

  nil
end

# ============================================================
# Main
# ============================================================

global   = load_yaml(GLOBAL)
accounts = load_yaml(ACCOUNTS)
instance = mastodon_instance(global)

rss_sources = Dir.glob(File.join(SOURCES, '*_rss.yml')).sort

puts "=" * 60
puts "RSS Social Profile Fetcher"
puts "Instance: #{instance}"
puts "Sources:  #{rss_sources.size} RSS YAMLs"
puts "Mode:     #{DRY_RUN ? 'dry-run (no API calls)' : 'live'}"
puts "=" * 60
puts

# --- Fáze 1: Načti všechny sources a detekuj skupinové účty ---

# account_id → [source_id, source_id, ...]
account_to_sources = Hash.new { |h, k| h[k] = [] }

rss_sources.each do |path|
  source_id  = File.basename(path, '.yml')
  data       = load_yaml(path)
  account_id = data.dig('target', 'mastodon_account')
  next unless account_id

  ps = data['profile_sync']
  # Přeskoč záměrně disabled (enabled: false) — ty se nepočítají do skupiny
  next if ps.is_a?(Hash) && ps['enabled'] == false

  account_to_sources[account_id] << source_id
end

shared_accounts = account_to_sources.select { |_, sources| sources.size > 1 }

unless shared_accounts.empty?
  puts "⚠️  SKUPINOVÉ ÚČTY (více RSS sources → stejný Mastodon účet):"
  puts "   Tyto účty vyžadují manuální rozhodnutí o primárním zdroji."
  puts
  shared_accounts.each do |account_id, sources|
    puts "   @#{account_id} (#{sources.size} sources):"
    sources.each { |s| puts "     - #{s}" }
  end
  puts
end

# --- Fáze 2: Fetch Mastodon API + sestavení výsledků ---

# Optimalizace: pro skupinové účty fetchni API jen jednou (sdílený token/profil)
results   = []
no_token  = []
no_field  = []
disabled  = []
already   = []
errors    = []

fetched_fields  = {}   # account_id → fields array | :error
reported        = {}   # account_id → true (byl výsledek vypsán na terminál?)

rss_sources.each do |path|
  source_id = File.basename(path, '.yml')
  data      = load_yaml(path)

  # Přeskoč záměrně disabled
  ps = data['profile_sync']
  if ps.is_a?(Hash) && ps['enabled'] == false
    disabled << source_id
    next
  end

  # Přeskoč již nakonfigurované
  if ps.is_a?(Hash) && ps['social_profile']
    already << source_id
    next
  end

  account_id = data.dig('target', 'mastodon_account')
  unless account_id
    errors << { source: source_id, reason: 'no target.mastodon_account' }
    next
  end

  token = accounts.dig(account_id, 'token')
  unless token
    no_token << { source: source_id, account: account_id }
    next
  end

  if DRY_RUN
    shared = shared_accounts.key?(account_id) ? ' [SHARED]' : ''
    puts "  [DRY]  #{source_id} → @#{account_id}#{shared}"
    next
  end

  # Fetch API (cachuj per account_id — vždy jen jedno volání na účet)
  unless fetched_fields.key?(account_id)
    print "  Fetching @#{account_id.ljust(28)} ... "
    fields = fetch_mastodon_fields(token, instance)
    fetched_fields[account_id] = fields || :error
    sleep 0.15
  end

  fields = fetched_fields[account_id]

  if fields == :error
    puts "ERROR" unless reported[account_id]
    reported[account_id] = true
    errors << { source: source_id, account: account_id, reason: 'API error' }
    next
  end

  profile = detect_social_profile(fields)

  if profile.nil?
    puts "no social field  (@#{account_id})" unless reported[account_id]
    reported[account_id] = true
    no_field << { source: source_id, account: account_id, fields: fields.map { |f| f[:name] } }
    next
  end

  # Vypiš výsledek jen jednou per account
  unless reported[account_id]
    puts "#{profile[:platform]} / #{profile[:handle]}"
    reported[account_id] = true
  end

  is_shared = shared_accounts.key?(account_id)

  results << {
    source_id:  source_id,
    account:    account_id,
    platform:   profile[:platform],
    handle:     profile[:handle],
    source_url: profile[:source_url],
    shared:     is_shared,
    # primary: nil znamená "nerozhodnuto" — uživatel musí rozhodnout
    primary:    is_shared ? nil : true
  }
end

# ============================================================
# Report
# ============================================================

solo    = results.select { |r| !r[:shared] }
shared  = results.select { |r| r[:shared] }

puts
puts "=" * 60
puts "VÝSLEDKY"
puts "=" * 60
puts "  Nalezeny (solo):         #{solo.size}"
puts "  Nalezeny (shared):       #{shared.size} sources v #{shared_accounts.size} skupinách"
puts "  Bez social pole:         #{no_field.size}"
puts "  Bez tokenu:              #{no_token.size}"
puts "  Záměrně disabled:        #{disabled.size}  (#{disabled.join(', ')})"
puts "  Již nakonfigurovány:     #{already.size}"
puts "  Chyby:                   #{errors.size}"
puts

unless solo.empty?
  puts "-" * 60
  puts "PLATFORMY (solo sources — připraveny k aplikaci):"
  solo.group_by { |r| r[:platform] }.sort.each do |platform, group|
    puts "  #{platform}: #{group.size}"
  end
  puts
end

unless shared.empty?
  puts "-" * 60
  puts "⚠️  SHARED SOURCES — VYŽADUJÍ ROZHODNUTÍ:"
  puts "   Uprav output/rss_shared_accounts.yml:"
  puts "   - nastav primary: true u jednoho zdroje per skupinu"
  puts "   - ostatní nech primary: false (dostanou enabled: false)"
  puts
  shared.group_by { |r| r[:account] }.each do |account_id, group|
    puts "   @#{account_id}:"
    group.each { |r| puts "     - #{r[:source_id]} (#{r[:platform]} / #{r[:handle]})" }
  end
  puts
end

unless no_field.empty?
  puts "-" * 60
  puts "BEZ SOCIAL POLE (#{no_field.size}) — vyžadují manuální doplnění:"
  no_field.each { |r| puts "  #{r[:source]} (@#{r[:account]}) — pole: #{r[:fields].join(', ')}" }
  puts
end

unless no_token.empty?
  puts "-" * 60
  puts "BEZ TOKENU (#{no_token.size}):"
  no_token.each { |r| puts "  #{r[:source]} (@#{r[:account]})" }
  puts
end

unless errors.empty?
  puts "-" * 60
  puts "CHYBY (#{errors.size}):"
  errors.each { |r| puts "  #{r[:source]}: #{r[:reason]}" }
  puts
end

# ============================================================
# Uložení výsledků
# ============================================================

unless DRY_RUN
  FileUtils.mkdir_p(OUT_DIR)

  # --- output/rss_social_profiles.yml — solo sources (připraveny k apply) ---
  unless solo.empty?
    solo_output = solo.map do |r|
      {
        'source_id'  => r[:source_id],
        'account'    => r[:account],
        'platform'   => r[:platform],
        'handle'     => r[:handle],
        'source_url' => r[:source_url],
        'primary'    => true
      }
    end
    File.write(OUT_FILE, solo_output.to_yaml)
    puts "Solo sources uloženy: #{OUT_FILE} (#{solo.size} zdrojů)"
  end

  # --- output/rss_shared_accounts.yml — skupinové účty k rozhodnutí ---
  unless shared.empty?
    shared_output = shared.group_by { |r| r[:account] }.map do |account_id, group|
      {
        'account' => account_id,
        'note'    => 'Nastav primary: true u jednoho zdroje, ostatni budou disabled.',
        'sources' => group.map do |r|
          {
            'source_id'  => r[:source_id],
            'platform'   => r[:platform],
            'handle'     => r[:handle],
            'source_url' => r[:source_url],
            'primary'    => nil   # ← uživatel vyplní true / false
          }
        end
      }
    end
    File.write(SHARED_FILE, shared_output.to_yaml)
    puts "Shared accounts uloženy: #{SHARED_FILE} (#{shared_accounts.size} skupin, #{shared.size} sources)"
    puts
    puts "⚠️  NUTNÝ MANUÁLNÍ KROK:"
    puts "   1. Otevři #{SHARED_FILE}"
    puts "   2. U každé skupiny nastav primary: true u jednoho zdroje"
    puts "   3. Ostatní nech primary: false"
    puts "   4. Spusť: ruby scripts/apply_rss_social_profiles.rb"
  end

  puts
  puts "Další krok:"
  if shared.empty?
    puts "  ruby scripts/apply_rss_social_profiles.rb --dry-run"
    puts "  ruby scripts/apply_rss_social_profiles.rb"
  else
    puts "  Nejprve rozhodní o shared accounts (viz výše), pak:"
    puts "  ruby scripts/apply_rss_social_profiles.rb --dry-run"
    puts "  ruby scripts/apply_rss_social_profiles.rb"
  end
end
