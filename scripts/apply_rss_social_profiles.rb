#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# apply_rss_social_profiles.rb
# ============================================================
# Načte výsledky z:
#   output/rss_social_profiles.yml   — solo sources (primary: true)
#   output/rss_shared_accounts.yml   — skupinové účty (primary: true/false)
#
# A pro každý RSS source YAML:
#   - primary: true  → přidá profile_sync: enabled: true + social_profile
#   - primary: false → přidá profile_sync: enabled: false  # secondary source
#
# Kontrola před spuštěním:
#   - Všechny skupiny v rss_shared_accounts.yml musí mít právě jedno
#     primary: true. Jinak skript odmítne pokračovat.
#
# Použití:
#   ruby scripts/apply_rss_social_profiles.rb             # Aplikuje změny
#   ruby scripts/apply_rss_social_profiles.rb --dry-run   # Jen preview
# ============================================================

require 'yaml'
require 'fileutils'

DRY_RUN = ARGV.include?('--dry-run')

BASE_DIR     = File.expand_path('..', __dir__)
SOURCES      = File.join(BASE_DIR, 'config', 'sources')
OUT_FILE     = File.join(BASE_DIR, 'output', 'rss_social_profiles.yml')
SHARED_FILE  = File.join(BASE_DIR, 'output', 'rss_shared_accounts.yml')

# ============================================================
# Načtení a validace vstupních souborů
# ============================================================

solo_entries   = []
shared_entries = []

if File.exist?(OUT_FILE)
  solo_entries = YAML.safe_load(File.read(OUT_FILE), symbolize_names: false) || []
end

if File.exist?(SHARED_FILE)
  shared_groups = YAML.safe_load(File.read(SHARED_FILE), symbolize_names: false) || []

  # Validace: žádný source nesmí mít primary: null (nerozhodnuto)
  # Povoleno: právě jedno true (standardní skupina) nebo všechny false (všechny secondary)
  validation_errors = []
  shared_groups.each do |group|
    account   = group['account']
    sources   = group['sources'] || []
    primaries = sources.select { |s| s['primary'] == true }
    undecided = sources.select { |s| s['primary'].nil? }

    if undecided.any?
      validation_errors << "  @#{account}: #{undecided.size} source(s) mají primary: null — rozhodni true/false"
    elsif primaries.size > 1
      validation_errors << "  @#{account}: #{primaries.size} sources mají primary: true (max 1 povoleno)"
    end
    # primaries.size == 0 je OK — záměrně všechny secondary (primární source je jinde)

    # Rozbal do shared_entries
    sources.each do |s|
      shared_entries << {
        'source_id'  => s['source_id'],
        'account'    => account,
        'platform'   => s['platform'],
        'handle'     => s['handle'],
        'primary'    => s['primary'] == true
      }
    end
  end

  unless validation_errors.empty?
    puts "=" * 60
    puts "CHYBA VALIDACE — nelze pokračovat"
    puts "=" * 60
    puts
    puts "Následující skupiny v #{SHARED_FILE} nejsou kompletní:"
    puts
    validation_errors.each { |e| puts e }
    puts
    puts "Uprav soubor a spusť skript znovu."
    exit 1
  end
end

if solo_entries.empty? && shared_entries.empty?
  abort "ERROR: Nenalezeny žádné výsledky.\nNejprve spusť: ruby scripts/fetch_rss_social_profiles.rb"
end

all_entries = solo_entries + shared_entries

puts "=" * 60
puts "Apply RSS Social Profiles"
puts "Mode:     #{DRY_RUN ? 'DRY-RUN (nic nezapisuje)' : 'LIVE (zapisuje do souborů)'}"
puts "Solo:     #{solo_entries.size} sources"
puts "Shared:   #{shared_entries.size} sources (#{shared_entries.count { |e| e['primary'] }} primárních, #{shared_entries.count { |e| !e['primary'] }} sekundárních)"
puts "=" * 60
puts

# ============================================================
# Aplikace do YAML souborů
# ============================================================

skipped  = []
applied  = []
errors   = []

all_entries.each do |entry|
  source_id = entry['source_id']
  primary   = entry['primary']
  platform  = entry['platform']
  raw_handle = entry['handle'].to_s
  # Normalizace handle: odstraň @ prefix a @twitter.com / @x.com suffix (Mastodon metadata formát)
  handle    = raw_handle.gsub(/^@/, '').gsub(/@(twitter|x)\.com$/, '')
  language  = entry['language'] || 'cs'
  retention = entry['retention_days'] || 90

  path = File.join(SOURCES, "#{source_id}.yml")

  unless File.exist?(path)
    errors << "#{source_id}: soubor nenalezen"
    next
  end

  content = File.read(path)

  # Přeskoč pokud profile_sync sekce již existuje
  if content.match?(/^profile_sync:/)
    skipped << source_id
    puts "  [SKIP] #{source_id} — profile_sync již existuje"
    next
  end

  # Sestavení profile_sync bloku
  sync_block = if primary
                 <<~YAML

                   # Synchronizace profilu
                   profile_sync:
                     enabled: true
                     language: #{language}
                     retention_days: #{retention}
                     social_profile:
                       platform: #{platform}
                       handle: #{handle}
                 YAML
               else
                 <<~YAML

                   # Synchronizace profilu — sekundární zdroj, sync řídí primární source
                   profile_sync:
                     enabled: false  # secondary source
                 YAML
               end

  # Vložení — před "# Zpracování obsahu" nebo "processing:", jinak na konec
  new_content = if content.match?(/^# Zpracování obsahu|^processing:/)
                  content.sub(/(\n*)(# Zpracování obsahu\n|processing:)/) do
                    "#{sync_block}\n#{$2}"
                  end
                else
                  content.rstrip + "\n" + sync_block
                end

  label = primary ? "#{platform} / #{handle}" : "disabled (secondary)"

  if DRY_RUN
    puts "  [DRY]  #{source_id.ljust(45)} → #{label}"
  else
    File.write(path, new_content)
    puts "  [OK]   #{source_id.ljust(45)} → #{label}"
    applied << source_id
  end
end

# ============================================================
# Shrnutí
# ============================================================

puts
puts "=" * 60
puts "SHRNUTÍ"
puts "=" * 60

if DRY_RUN
  enabled_count  = all_entries.count { |e| e['primary'] } - skipped.size - errors.size
  disabled_count = all_entries.count { |e| !e['primary'] }
  puts "  Bylo by aplikováno (enabled):  #{enabled_count}"
  puts "  Bylo by aplikováno (disabled): #{disabled_count}"
else
  enabled_count  = applied.count { |id| all_entries.find { |e| e['source_id'] == id }&.fetch('primary', false) }
  disabled_count = applied.size - enabled_count
  puts "  Aplikováno (enabled):  #{enabled_count}"
  puts "  Aplikováno (disabled): #{disabled_count}"
end

puts "  Přeskočeno:            #{skipped.size}"
puts "  Chyby:                 #{errors.size}"

unless errors.empty?
  puts
  puts "CHYBY:"
  errors.each { |e| puts "  #{e}" }
end

if !DRY_RUN && applied.any?
  puts
  puts "Hotovo. Ověř:"
  puts "  bundle exec ruby bin/sync_profiles.rb --platform rss --dry-run"
end
