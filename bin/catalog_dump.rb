#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Catalog Dump — vizuální kontrola agregovaných dat katalogu
# ============================================================
#
# Vytiskne JSON agregovaných záznamů (DataAggregator#aggregate) na stdout.
# Slouží k ověření, že spojení tří zdrojů (mastodon_accounts.yml + sources/*.yml
# + Mastodon API/DB snapshot) dává smysl, ještě před generací HTML.
#
# Usage:
#   ruby bin/catalog_dump.rb                 # pretty JSON na stdout
#   ruby bin/catalog_dump.rb --no-mastodon   # přeskočit Mastodon API (rychlé, bez avatarů)
#   ruby bin/catalog_dump.rb --count         # jen počet záznamů + souhrn rodin
#   ruby bin/catalog_dump.rb --test          # zpravobot_test schema
#
# ============================================================

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'optparse'
require 'json'

require 'config/config_loader'
require 'state/database_connection'
require 'stats/mastodon_stats'
require 'stats/snapshot_store'
require 'catalog/data_aggregator'

options = { mastodon: true, count: false, test: false }
OptionParser.new do |opts|
  opts.banner = 'Usage: ruby bin/catalog_dump.rb [options]'
  opts.on('--no-mastodon', 'Skip Mastodon API (no avatars/display_names)') { options[:mastodon] = false }
  opts.on('--count', 'Print only counts/summary')                          { options[:count] = true }
  opts.on('--test', 'Use zpravobot_test schema')                           { options[:test] = true }
  opts.on('-h', '--help', 'Show this help') { puts opts; exit 0 }
end.parse!

config_dir = ENV.fetch('ZBNW_CONFIG_DIR',
               ENV['ZBNW_DIR'] ? "#{ENV['ZBNW_DIR']}/config" : 'config')
loader = Config::ConfigLoader.new(config_dir)
global = loader.load_global_config
instance = global.dig(:mastodon, :instance) || 'https://zpravobot.news'

db = State::DatabaseConnection.new(schema: options[:test] ? 'zpravobot_test' : nil)
db.connect

# Stub fetcher, který vrátí prázdná data — pro rychlé běhy bez síťových volání.
null_fetcher = Object.new.tap do |o|
  def o.fetch_all(**) = {}
end

agg = Catalog::DataAggregator.new(
  config_loader: loader,
  db: db,
  mastodon_instance: instance,
  mastodon_fetcher: options[:mastodon] ? nil : null_fetcher
)

records = agg.aggregate
db.disconnect

if options[:count]
  warn "Záznamů: #{records.size}"
  by_family = records.group_by { |r| r[:family] }.transform_values(&:size).sort_by { |_, v| -v }
  by_type   = records.group_by { |r| r[:type] }.transform_values(&:size).sort_by { |_, v| -v }
  by_lang   = records.group_by { |r| r[:language] }.transform_values(&:size).sort_by { |_, v| -v }
  warn "Rodiny:  #{by_family.map { |k, v| "#{k}=#{v}" }.join(', ')}"
  warn "Typy:    #{by_type.map { |k, v| "#{k}=#{v}" }.join(', ')}"
  warn "Jazyky:  #{by_lang.map { |k, v| "#{k}=#{v}" }.join(', ')}"
  no_avatar = records.count { |r| r[:avatar].nil? }
  warn "Bez avataru: #{no_avatar}"
else
  puts JSON.pretty_generate(records)
end
