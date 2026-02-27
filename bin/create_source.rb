#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Zprávobot ZBNW-NG Source Configuration Generator
# ============================================================
# Interaktivní průvodce pro vytváření nových source YAML souborů.
#
# Použití:
#   ruby bin/create_source.rb           # Plný průvodce
#   ruby bin/create_source.rb --quick   # Pouze povinné údaje
#   ruby bin/create_source.rb --test    # Použít testovací prostředí
#   ruby bin/create_source.rb --help    # Nápověda
#
# Výstup:
#   - config/sources/{id}.yml
#   - (volitelně) přidá záznam do config/mastodon_accounts.yml
#   - inicializuje source_state v databázi
#
# ============================================================

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'source_wizard/source_generator'

# ============================================
# Entry Point
# ============================================

if __FILE__ == $PROGRAM_NAME
  # Ctrl+C = ciste ukonceni
  trap('INT') do
    puts
    puts
    puts '  ⚠️  Přerušeno uživatelem (Ctrl+C). Nic nebylo uloženo.'
    puts
    exit 130
  end

  if ARGV.include?('--help') || ARGV.include?('-h')
    puts
    puts 'ZBNW-NG Source Configuration Generator'
    puts '=' * 40
    puts
    puts 'Použití:'
    puts '  ruby bin/create_source.rb           # Plný průvodce'
    puts '  ruby bin/create_source.rb --quick   # Pouze povinné údaje'
    puts '  ruby bin/create_source.rb --test    # Použít testovací prostředí'
    puts '  ruby bin/create_source.rb --help    # Tato nápověda'
    puts
    puts 'Kombinace:'
    puts '  ruby bin/create_source.rb --quick --test'
    puts
    puts 'Popis:'
    puts '  Interaktivní průvodce pro vytváření konfiguračních souborů'
    puts '  pro nové zdroje (boty) v systému ZBNW-NG.'
    puts
    puts 'Podporované platformy:'
    puts '  • Twitter (via Nitter)'
    puts '  • Bluesky'
    puts '  • RSS (včetně Facebook/Instagram via RSS.app + profile sync)'
    puts '  • YouTube'
    puts
    puts 'Výstup:'
    puts '  • config/sources/{id}.yml'
    puts '  • config/mastodon_accounts.yml (pokud nový účet)'
    puts '  • source_state záznam v databázi'
    puts
    puts 'Prostředí:'
    config_base = ENV['ZBNW_DIR'] || '.'
    puts "  Produkce: #{config_base}/config, schéma zpravobot"
    puts "  Test:     #{config_base}/config, schéma zpravobot_test"
    puts
    exit 0
  end

  generator = SourceGenerator.new
  generator.run
end
