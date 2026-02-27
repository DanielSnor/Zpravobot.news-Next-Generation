#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# ZBNW-NG Source Manager
# ============================================================
# Správa životního cyklu zdrojů: pause, resume, retire.
#
# Použití:
#   ruby bin/manage_source.rb                              # interaktivní menu
#   ruby bin/manage_source.rb pause  ct24_twitter          # přímý příkaz
#   ruby bin/manage_source.rb pause  ct24_twitter --reason "Nefunkční Nitter"
#   ruby bin/manage_source.rb resume ct24_twitter
#   ruby bin/manage_source.rb retire ct24_twitter
#
# Přepínače:
#   --test          Testovací prostředí (schema zpravobot_test)
#   --reason "..."  Důvod pauzy (pouze pro pause)
#   --help          Zobrazí tuto nápovědu
# ============================================================

$LOAD_PATH.unshift(File.join(__dir__, '..', 'lib'))

require_relative '../lib/source_wizard/source_manager'

# ── Pomocníky pro výpis ─────────────────────────────────────

def print_banner(test_mode)
  puts
  puts '═' * 60
  puts '  ⚙️  ZBNW-NG Source Manager'
  puts '═' * 60
  puts
  if test_mode
    puts '  Režim: TEST (schema: zpravobot_test)'
  else
    puts '  Režim: PRODUCTION (schema: zpravobot)'
  end
  puts "  Config: #{config_dir}"
  puts
end

def print_help
  puts <<~HELP

    Použití:
      ruby bin/manage_source.rb [AKCE] [SOURCE_ID] [PŘEPÍNAČE]

    Akce:
      pause  SOURCE_ID [--reason "TEXT"]   Dočasně pozastaví zdroj
      resume SOURCE_ID                     Reaktivuje pozastavený zdroj
      retire SOURCE_ID                     Trvale vyřadí zdroj

    Přepínače:
      --test          Testovací prostředí
      --reason "..."  Důvod pauzy (volitelný)
      --help          Tato nápověda

    Příklady:
      ruby bin/manage_source.rb pause  ct24_twitter
      ruby bin/manage_source.rb pause  ct24_twitter --reason "Nefunkční Nitter"
      ruby bin/manage_source.rb resume ct24_twitter
      ruby bin/manage_source.rb retire ct24_twitter
      ruby bin/manage_source.rb pause  ct24_twitter --test

  HELP
end

# ── Konfigurace prostředí ────────────────────────────────────

def config_dir
  @config_dir ||=
    if ENV['ZBNW_CONFIG_DIR']
      ENV['ZBNW_CONFIG_DIR']
    elsif ENV['ZBNW_DIR']
      File.join(ENV['ZBNW_DIR'], 'config')
    else
      File.expand_path('../config', __dir__)
    end
end

def db_schema(test_mode)
  test_mode ? 'zpravobot_test' : ENV.fetch('ZPRAVOBOT_SCHEMA', 'zpravobot')
end

# ── Interaktivní menu ────────────────────────────────────────

def interactive_menu(manager)
  include Support::UiHelpers

  sources = manager.list_sources

  puts '  Dostupné zdroje:'
  puts
  if sources.empty?
    puts '    (žádné zdroje nenalezeny)'
    puts
    return
  end

  sources.each do |s|
    status_icon = s[:yaml_enabled] ? '▶' : '⏸'
    db_note     = s[:disabled_at] ? " [DB disabled]" : ''
    puts "    #{status_icon} #{s[:source_id]}#{db_note}"
  end

  puts

  source_ids = sources.map { |s| s[:source_id] }
  choice     = ask_choice('Vyber zdroj', source_ids)

  puts
  action = ask_choice('Akce', ['pause', 'resume', 'retire'])
  reason = nil

  if action == 'pause'
    puts
    reason = ask('Důvod pauzy (volitelný)')
    reason = nil if reason.empty?
  end

  puts

  case action
  when 'pause'  then manager.pause(choice, reason: reason)
  when 'resume' then manager.resume(choice)
  when 'retire' then manager.retire(choice)
  end
end

# ── Parsování CLI argumentů ──────────────────────────────────

args = ARGV.dup

if args.include?('--help') || args.include?('-h')
  print_help
  exit 0
end

test_mode = args.delete('--test')

reason_idx = args.index('--reason')
reason = nil
if reason_idx
  reason = args[reason_idx + 1]
  args.delete_at(reason_idx + 1)
  args.delete_at(reason_idx)
end

action    = args[0]
source_id = args[1]

# ── Spuštění ─────────────────────────────────────────────────

print_banner(test_mode)

manager = SourceManager.new(
  config_dir: config_dir,
  db_schema:  db_schema(test_mode)
)

if action.nil?
  # Interaktivní režim — extend pro přístup k UiHelpers mimo třídu
  extend Support::UiHelpers
  interactive_menu(manager)
elsif source_id.nil?
  puts "  ❌ Chybí SOURCE_ID pro akci '#{action}'"
  print_help
  exit 1
else
  case action
  when 'pause'
    success = manager.pause(source_id, reason: reason)
    exit(success ? 0 : 1)
  when 'resume'
    success = manager.resume(source_id)
    exit(success ? 0 : 1)
  when 'retire'
    success = manager.retire(source_id)
    exit(success ? 0 : 1)
  else
    puts "  ❌ Neznámá akce: '#{action}'"
    print_help
    exit 1
  end
end
