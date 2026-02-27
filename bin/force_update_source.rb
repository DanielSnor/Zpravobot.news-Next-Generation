#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# ZBNW-NG Force Update Tool
# ============================================================
# Resetuje stav source pro okamžité zpracování
#
# Použití:
#   ruby force_update_source.rb chmuchmi_twitter
#   ruby force_update_source.rb chmuchmi_twitter ihned_twitter ct24_twitter
#
# Co dělá:
#   - Nastaví last_check na NULL (source bude zpracován při příštím běhu)
#   - Resetuje error_count a last_error
#   - Nezasahuje do last_success ani posts_today
# ============================================================

require 'pg'
require_relative '../lib/utils/database_helpers'

# Detekce Cloudron nebo lokální databáze
def get_connection
  if ENV['CLOUDRON_POSTGRESQL_URL']
    PG.connect(ENV['CLOUDRON_POSTGRESQL_URL'])
  elsif ENV['DATABASE_URL']
    PG.connect(ENV['DATABASE_URL'])
  else
    PG.connect(
      host: ENV.fetch('ZPRAVOBOT_DB_HOST', 'localhost'),
      port: ENV.fetch('ZPRAVOBOT_DB_PORT', 5432).to_i,
      dbname: ENV.fetch('ZPRAVOBOT_DB_NAME', 'zpravobot'),
      user: ENV.fetch('ZPRAVOBOT_DB_USER', 'zpravobot_app'),
      password: ENV['ZPRAVOBOT_DB_PASSWORD']
    )
  end
end

def force_update(conn, source_id)
  schema = ENV.fetch('ZPRAVOBOT_SCHEMA', 'zpravobot')
  DatabaseHelpers.validate_schema!(schema)
  conn.exec("SET search_path TO #{schema}")
  
  # Získat aktuální stav
  result = conn.exec_params(
    'SELECT source_id, last_check, last_success, posts_today, error_count FROM source_state WHERE source_id = $1',
    [source_id]
  )
  
  if result.ntuples.zero?
    puts "❌ Source '#{source_id}' nenalezen v databázi"
    return false
  end
  
  state = result[0]
  puts "📋 Aktuální stav pro '#{source_id}':"
  puts "   last_check:   #{state['last_check'] || 'NULL'}"
  puts "   last_success: #{state['last_success'] || 'NULL'}"
  puts "   posts_today:  #{state['posts_today']}"
  puts "   error_count:  #{state['error_count']}"
  puts
  
  # Force update
  conn.exec_params(
    <<~SQL,
      UPDATE source_state
      SET last_check = NULL,
          error_count = 0,
          last_error = NULL,
          updated_at = NOW()
      WHERE source_id = $1
    SQL
    [source_id]
  )
  
  puts "✅ Force update proveden pro '#{source_id}'"
  puts "   Source bude zpracován při příštím běhu orchestrátoru"
  puts
  
  true
end

# Main
if ARGV.empty?
  puts 'Použití: ruby force_update_source.rb SOURCE_ID [SOURCE_ID2 ...]'
  puts 'Příklad: ruby force_update_source.rb chmuchmi_twitter'
  exit 1
end

begin
  conn = get_connection
  puts "🔌 Připojeno k databázi"
  puts
  
  success_count = 0
  ARGV.each do |source_id|
    success_count += 1 if force_update(conn, source_id)
  end
  
  puts "═" * 60
  puts "✅ Hotovo: #{success_count}/#{ARGV.length} sources aktualizováno"
  puts "═" * 60
  
rescue PG::Error => e
  puts "❌ Chyba databáze: #{e.message}"
  exit 1
ensure
  conn&.close
end
