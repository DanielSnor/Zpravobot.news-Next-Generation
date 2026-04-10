#!/usr/bin/env ruby
# frozen_string_literal: true

# Jednorázový cleanup script pro osiřelé záznamy v mastodon_accounts.yml.
#
# Prochází všechny účty v mastodon_accounts.yml a ověřuje, zda mají
# alespoň jeden aktivní zdroj v config/sources/*.yml.
#
# Použití:
#   ruby bin/cleanup_orphaned_accounts.rb          — vypíše osiřelé účty
#   ruby bin/cleanup_orphaned_accounts.rb --fix    — interaktivně nabídne smazání

require 'set'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require_relative '../lib/source_wizard/source_manager'

# Speciální účty vyloučené z reportu (testovací, systémové)
EXCLUDED_ACCOUNTS = %w[betabot].freeze

BASE_DIR      = File.expand_path('..', __dir__)
ACCOUNTS_FILE = File.join(BASE_DIR, 'config', 'mastodon_accounts.yml')
SOURCES_DIR   = File.join(BASE_DIR, 'config', 'sources')

fix_mode = ARGV.include?('--fix')

# ── Načtení mastodon_accounts.yml ────────────────────────────

unless File.exist?(ACCOUNTS_FILE)
  puts "❌ Soubor nenalezen: #{ACCOUNTS_FILE}"
  exit 1
end

content = File.read(ACCOUNTS_FILE, encoding: 'UTF-8')

# Extrahovat account IDs (top-level klíče — řádky tvaru "account_id:")
account_ids = []
content.each_line do |line|
  next if line.match?(/^\s*#/)  # přeskočit komentáře
  if (m = line.match(/^([A-Za-z0-9_]+):\s*$/))
    account_ids << m[1]
  end
end

# ── Načtení aktivních účtů ze sources/*.yml ──────────────────

unless Dir.exist?(SOURCES_DIR)
  puts "❌ Adresář zdrojů nenalezen: #{SOURCES_DIR}"
  exit 1
end

active_accounts = Set.new
Dir.glob(File.join(SOURCES_DIR, '*.yml')).each do |path|
  source_content = File.read(path, encoding: 'UTF-8') rescue next
  ma = source_content[/^\s*mastodon_account:\s*(.+)$/, 1]&.strip
  active_accounts.add(ma) if ma
end

# ── Detekce osiřelých účtů ────────────────────────────────────

orphaned = account_ids.reject { |id| EXCLUDED_ACCOUNTS.include?(id) || active_accounts.include?(id) }

if orphaned.empty?
  puts '✅ Žádné osiřelé záznamy v mastodon_accounts.yml.'
  exit 0
end

puts "🔍 Nalezeny osiřelé záznamy (#{orphaned.size}) v mastodon_accounts.yml:"
orphaned.each { |id| puts "   • #{id}" }
puts

unless fix_mode
  puts 'Spusť s --fix pro interaktivní smazání.'
  exit 0
end

# ── Fix mode: interaktivní smazání ────────────────────────────

manager = SourceManager.new(config_dir: File.join(BASE_DIR, 'config'), db_schema: 'zpravobot')

orphaned.each do |account_id|
  print "  Smazat '#{account_id}' z mastodon_accounts.yml? [y/N] "
  $stdout.flush
  answer = $stdin.gets&.strip&.downcase
  if answer == 'y'
    manager.send(:remove_from_mastodon_accounts, account_id)
  else
    puts "  ⏭️  '#{account_id}' ponechán."
  end
  puts
end

puts '✅ Hotovo.'
