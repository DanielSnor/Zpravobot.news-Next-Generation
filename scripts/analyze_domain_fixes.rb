#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# analyze_domain_fixes.rb
# ============================================================
# Analyzuje Twitter a Bluesky zdroje a navrhuje url_domain_fixes:
#
#   1. ANALYZE  — stáhne Mastodon profily, extrahuje domény
#                 z web: pole a bio textu, uloží do output/
#   2. APPLY    — aplikuje doporučení do yml souborů
#   3. CLEANUP  — odstraní domény které jsou v global.yml
#                 no_trim_domains (=globálně pokryté)
#
# Použití:
#   ruby scripts/analyze_domain_fixes.rb analyze
#   ruby scripts/analyze_domain_fixes.rb apply [--dry-run]
#   ruby scripts/analyze_domain_fixes.rb cleanup [--dry-run]
#   ruby scripts/analyze_domain_fixes.rb all [--dry-run]
#
# Volitelné přepínače:
#   --platform twitter|bluesky   (výchozí: oboje)
#   --source enkocz              konkrétní zdroj (mastodon_account nebo id bez _twitter/_bluesky)
#   --dry-run                    pouze výpis, bez zápisu
# ============================================================

require 'net/http'
require 'uri'
require 'json'
require 'yaml'
require 'fileutils'

# ============================================================
# Konfigurace
# ============================================================

DRY_RUN       = ARGV.include?('--dry-run')
MODE          = ARGV.reject { |a| a.start_with?('--') }.first || 'analyze'
PLATFORM_ARG  = (ARGV[ARGV.index('--platform') + 1] if ARGV.include?('--platform')) || 'all'
SOURCE_ARG    = (ARGV[ARGV.index('--source') + 1] if ARGV.include?('--source'))

BASE_DIR      = File.expand_path('..', __dir__)
SOURCES_DIR   = File.join(BASE_DIR, 'config', 'sources')
GLOBAL_YML    = File.join(BASE_DIR, 'config', 'global.yml')
OUT_DIR       = File.join(BASE_DIR, 'output')
OUT_FILE      = File.join(OUT_DIR, 'domain_fixes_recommendations.yml')

MASTODON_INSTANCE = 'https://zpravobot.news'
API_SLEEP         = 0.05  # sekund mezi voláními

# TLD která uznáváme jako platné domény
VALID_TLDS = %w[
  cz sk eu com net org io app
  es de fr pl at hu ro info
  online news media blog tv fm me
  ai us uk co nz br
  gov mil edu
].freeze

# Domény které nechceme přidávat (sociální sítě, agregátory, komunikace)
ALWAYS_SKIP = %w[
  twitter.com x.com tiktok.com linkedin.com
  linktr.ee linktree.com
  discord.gg discord.com
  lnk.bio
  buymeacoffee.com
].freeze

# ============================================================
# Helpers
# ============================================================

GREEN  = "\e[32m"
YELLOW = "\e[33m"
CYAN   = "\e[36m"
RED    = "\e[31m"
RESET  = "\e[0m"

def info(msg);  puts("#{CYAN}#{msg}#{RESET}");          end
def ok(msg);    puts("#{GREEN}✔ #{msg}#{RESET}");      end
def warn(msg);  puts("#{YELLOW}⚠ #{msg}#{RESET}");    end
def err(msg);   puts("#{RED}✘ #{msg}#{RESET}");        end
def dry(msg);   puts("#{YELLOW}[DRY] #{msg}#{RESET}"); end

def separator(title = nil)
  if title
    puts "\n#{"=" * 60}\n  #{title}\n#{"=" * 60}"
  else
    puts "=" * 60
  end
end

# ============================================================
# Načtení globálního configu — no_trim_domains
# ============================================================

def load_global_domains
  return [] unless File.exist?(GLOBAL_YML)

  global = YAML.safe_load(File.read(GLOBAL_YML)) || {}
  domains = global.dig('url', 'no_trim_domains') || []
  # Normalizace: odstranit www. prefix
  domains.map { |d| d.sub(/^www\./, '') }.uniq
end

# ============================================================
# Načtení zdrojových souborů
# ============================================================

def load_sources(platform_filter)
  patterns = case platform_filter
             when 'twitter' then ['*_twitter.yml']
             when 'bluesky' then ['*_bluesky.yml', '*_bluesky_feed.yml']
             else                ['*_twitter.yml', '*_bluesky.yml', '*_bluesky_feed.yml']
             end

  files = patterns.flat_map { |p| Dir.glob(File.join(SOURCES_DIR, p)) }.sort

  files.map do |path|
    content = File.read(path)
    account = content.match(/mastodon_account:\s*(\S+)/)&.[](1)
    next nil unless account

    # Filtr na konkrétní zdroj (--source): porovnáváme account nebo basename bez přípony/_platformy
    if SOURCE_ARG
      source_id = File.basename(path, '.yml').sub(/_twitter$|_bluesky(_feed)?$/, '')
      next nil unless account == SOURCE_ARG || source_id == SOURCE_ARG
    end

    existing = parse_existing_fixes(content)
    { file: File.basename(path), path: path, account: account, existing: existing }
  end.compact
end

def parse_existing_fixes(content)
  fixes = []
  in_fixes = false
  content.each_line do |line|
    if line.match?(/^\s+url_domain_fixes:/)
      return [] if line.include?('[]')

      in_fixes = true
      next
    end
    if in_fixes
      m = line.match(/^\s+-\s+"?([^"#\n]+)"?\s*$/)
      if m
        fixes << m[1].strip
      elsif line.strip.empty? || (!line.start_with?(' ') && !line.start_with?("\t"))
        break
      end
    end
  end
  fixes
end

# ============================================================
# Mastodon API
# ============================================================

def fetch_mastodon_profile(account)
  uri = URI("#{MASTODON_INSTANCE}/api/v1/accounts/lookup?acct=#{account}@zpravobot.news")
  req = Net::HTTP::Get.new(uri)
  req['User-Agent'] = 'ZBNW-DomainFixes/1.0'

  resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                         open_timeout: 10, read_timeout: 10) do |http|
    http.request(req)
  end

  return nil unless resp.is_a?(Net::HTTPSuccess)

  JSON.parse(resp.body)
rescue StandardError
  nil
end

# ============================================================
# Extrakce domén
# ============================================================

def extract_web_domain(fields)
  web_field = fields.find { |f| f['name'].to_s.downcase.start_with?('web') }
  return nil unless web_field

  # Odstranit HTML tagy
  value = web_field['value'].to_s.gsub(/<[^>]+>/, '').strip
  return nil if value.empty? || value == '""' || value == '—' || value == '-'

  # Extrahuj doménu
  m = value.match(%r{(?:https?://)?(?:www\.)?([a-zA-Z0-9][a-zA-Z0-9.\-]+\.[a-zA-Z]{2,})})
  return nil unless m

  domain = m[1].downcase.sub(/^www\./, '').sub(%r{/.*$}, '')
  valid_domain?(domain) ? domain : nil
end

def extract_bio_domains(note_html)
  # Odstranit HTML
  text = note_html.to_s.gsub(/<[^>]+>/, ' ')
  # Odstranit existující URL s protokolem
  text = text.gsub(%r{https?://\S+}, '')

  domains = Set.new

  # Vzor pro holé domény
  text.scan(/(?<![:\/@\w])(?:www\.)?([a-zA-Z0-9](?:[a-zA-Z0-9\-]*[a-zA-Z0-9])?
            (?:\.[a-zA-Z0-9](?:[a-zA-Z0-9\-]*[a-zA-Z0-9])?)*
            \.[a-zA-Z]{2,})(?:\/[^\s,;'"<)\]]*)?/x) do |m|
    domain = m[0].downcase.sub(/^www\./, '').split('/').first
    domains << domain if valid_domain?(domain)
  end

  domains
end

def valid_domain?(domain)
  return false if domain.nil? || domain.length < 4
  return false unless domain.include?('.')

  tld = domain.split('.').last
  return false unless VALID_TLDS.include?(tld)

  true
end

# ============================================================
# STEP 1: ANALYZE
# ============================================================

def run_analyze(platform_filter)
  separator('ANALYZE')
  info("Platforma: #{platform_filter} | Mastodon instance: #{MASTODON_INSTANCE}")

  global_domains = load_global_domains
  info("Globálně pokryté domény (no_trim_domains): #{global_domains.size}")

  skip_domains = (ALWAYS_SKIP + global_domains).map(&:downcase).to_set

  sources = load_sources(platform_filter)
  info("Zdrojů ke zpracování: #{sources.size}\n")

  recommendations = []
  errors = []

  sources.each_with_index do |source, i|
    print "\r  [#{i + 1}/#{sources.size}] #{source[:account].ljust(30)}"

    profile = fetch_mastodon_profile(source[:account])
    unless profile
      errors << source[:account]
      sleep(API_SLEEP)
      next
    end

    fields   = profile['fields'] || []
    note     = profile['note'] || ''

    web_domain  = extract_web_domain(fields)
    bio_domains = extract_bio_domains(note)

    # Kombinuj doporučení, filtruj globální domény
    existing = source[:existing].map(&:downcase).to_set
    new_domains = Set.new

    new_domains << web_domain if web_domain && !skip_domains.include?(web_domain) && !existing.include?(web_domain)
    bio_domains.each do |d|
      new_domains << d unless skip_domains.include?(d) || existing.include?(d)
    end

    recommendations << {
      'file'        => source[:file],
      'account'     => source[:account],
      'existing'    => source[:existing],
      'web_domain'  => web_domain,
      'bio_domains' => bio_domains.to_a.sort,
      'new_domains' => new_domains.to_a.sort,
      'recommended' => (source[:existing] + new_domains.to_a).uniq.sort
    }

    sleep(API_SLEEP)
  end

  puts  # nový řádek po progress

  # Uložit výsledky
  FileUtils.mkdir_p(OUT_DIR)
  File.write(OUT_FILE, recommendations.to_yaml)

  # Shrnutí
  to_update = recommendations.count { |r| r['new_domains'].any? }
  no_change = recommendations.count { |r| r['new_domains'].empty? }

  separator('Výsledky')
  puts "Celkem zpracováno:  #{recommendations.size}"
  puts "K aktualizaci:      #{to_update}"
  puts "Bez změny:          #{no_change}"
  puts "Chyby API:          #{errors.size}"
  puts
  info("Doporučení uložena: #{OUT_FILE}")
  info("Dalsi krok: ruby scripts/analyze_domain_fixes.rb apply [--dry-run]")

  # Preview
  to_show = recommendations.select { |r| r['new_domains'].any? }
  if to_show.any?
    separator('Navrhované změny')
    to_show.each do |r|
      puts "\n#{r['file']}"
      puts "  stávající:  #{r['existing']}" if r['existing'].any?
      puts "  web: pole:  #{r['web_domain']}" if r['web_domain']
      puts "  bio domény: #{r['bio_domains']}" if r['bio_domains'].any?
      puts "  => PŘIDAT:  #{r['new_domains']}"
    end
  end
end

# ============================================================
# STEP 2: APPLY
# ============================================================

def run_apply
  separator('APPLY')

  unless File.exist?(OUT_FILE)
    err("Soubor #{OUT_FILE} neexistuje — spusť nejdřív 'analyze'")
    exit 1
  end

  recommendations = YAML.safe_load(File.read(OUT_FILE)) || []
  to_update = recommendations.select { |r| r['new_domains']&.any? }

  info("Souborů k aktualizaci: #{to_update.size}")
  puts

  updated = 0
  to_update.each do |r|
    path = File.join(SOURCES_DIR, r['file'])
    unless File.exist?(path)
      warn("Soubor nenalezen: #{r['file']}")
      next
    end

    all_domains = r['recommended'] || (r['existing'] + r['new_domains'])

    if DRY_RUN
      dry("#{r['file']}: url_domain_fixes → #{all_domains}")
      next
    end

    content = File.read(path)
    new_content = apply_fixes_to_content(content, all_domains)

    if new_content == content
      warn("Žádná změna: #{r['file']}")
      next
    end

    File.write(path, new_content)
    ok("#{r['file']}: +#{r['new_domains']}")
    updated += 1
  end

  puts
  puts DRY_RUN ? "#{YELLOW}DRY RUN — žádné změny zapsány#{RESET}" : "Aktualizováno: #{updated} souborů"
end

def apply_fixes_to_content(content, all_domains)
  domain_block = all_domains.map { |d| "    - \"#{d}\"" }.join("\n")

  if content.match?(/url_domain_fixes: \[\]/)
    content.sub(/url_domain_fixes: \[\]/, "url_domain_fixes:\n#{domain_block}")
  elsif content.match?(/url_domain_fixes:\n(\s+- .+\n)+/)
    content.sub(/url_domain_fixes:\n(\s+- .+\n)+/) do
      "url_domain_fixes:\n#{domain_block}\n"
    end
  else
    content
  end
end

# ============================================================
# STEP 3: CLEANUP
# ============================================================

def run_cleanup(platform_filter)
  separator('CLEANUP')

  global_domains = load_global_domains.to_set
  info("Globální domény k odstranění: #{global_domains.size}")

  sources = load_sources(platform_filter)
  sources.select! { |s| s[:existing].any? }

  info("Zdrojů s neprázdným url_domain_fixes: #{sources.size}\n")

  cleaned = 0
  removed_total = 0

  sources.each do |source|
    to_remove = source[:existing].select { |d| global_domains.include?(d.sub(/^www\./, '')) }
    next if to_remove.empty?

    kept = source[:existing] - to_remove

    if DRY_RUN
      dry("#{source[:file]}: odebrány #{to_remove}")
      next
    end

    content = File.read(source[:path])
    new_content = apply_fixes_to_content(content, kept)

    next if new_content == content

    File.write(source[:path], new_content)
    ok("#{source[:file]}: odebrány #{to_remove}")
    cleaned += 1
    removed_total += to_remove.size
  end

  puts
  puts DRY_RUN ? "#{YELLOW}DRY RUN — žádné změny zapsány#{RESET}" : "Vyčištěno: #{cleaned} souborů, odebráno #{removed_total} domén"
end

# ============================================================
# Main
# ============================================================

require 'set'

case MODE
when 'analyze'
  run_analyze(PLATFORM_ARG)
when 'apply'
  run_apply
when 'cleanup'
  run_cleanup(PLATFORM_ARG)
when 'all'
  run_analyze(PLATFORM_ARG)
  run_apply
  run_cleanup(PLATFORM_ARG)
else
  puts "Neznámý mód: #{MODE}"
  puts "Použití: ruby scripts/analyze_domain_fixes.rb [analyze|apply|cleanup|all] [--dry-run] [--platform twitter|bluesky] [--source ID]"
  exit 1
end
