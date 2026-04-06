#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Zpravobot: Reset error_count pro zdroj
# ============================================================
# Resetuje error_count v DB na 0 — užitečné po záměrné pauze
# zdroje, aby health monitor přestal hlásit přetrvávající chyby.
#
# Použití:
#   ruby scripts/reset_error_count.rb SOURCE_ID
#   ruby scripts/reset_error_count.rb speedwaynewscz_rss
# ============================================================

$LOAD_PATH.unshift(File.join(__dir__, '..', 'lib'))
require_relative '../lib/source_wizard/source_manager'

source_id = ARGV[0]
if source_id.nil? || source_id.empty?
  puts "Použití: ruby scripts/reset_error_count.rb SOURCE_ID"
  exit 1
end

sm = SourceManager.new(config_dir: 'config', db_schema: 'zpravobot')
conn = sm.send(:get_db_connection)

before = conn.exec_params('SELECT error_count FROM zpravobot.source_state WHERE source_id=$1', [source_id])
if before.ntuples.zero?
  puts "Zdroj '#{source_id}' nenalezen v DB."
  conn.close
  exit 1
end

conn.exec_params('UPDATE zpravobot.source_state SET error_count=0 WHERE source_id=$1', [source_id])
puts "✔ #{source_id}: error_count #{before[0]['error_count']} → 0"
conn.close
