#!/usr/bin/env ruby
# frozen_string_literal: true

# Test for Catalog::DataAggregator
# Usage: ruby test/test_catalog_aggregator.rb
#
# Plně izolovaný — žádná síť ani DB. Config loader, Mastodon fetcher
# i snapshot store jsou nahrazeny stuby s předpřipravenými daty.

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'catalog/data_aggregator'

failures = 0
def check(label, expected, actual)
  ok = expected == actual
  puts "#{ok ? '✅' : '❌'} #{label}: expected=#{expected.inspect} actual=#{actual.inspect}"
  ok
end

# --- Stub config loader -------------------------------------------------
class StubLoader
  def initialize(accounts, sources)
    @accounts = accounts
    @sources  = sources
  end

  def load_all_mastodon_accounts = @accounts
  def load_all_sources = @sources
end

# --- Fixtures -----------------------------------------------------------
accounts = {
  ct24: { token: 't', aggregator: false, type: 'media', family: 'news',
          categories: %w[news journalism] },
  multilang: { token: 't', aggregator: false, type: 'person', family: 'culture',
               categories: ['art'] },
  external: { instance: 'https://mastodon.social', aggregator: false,
              type: 'media', family: 'news' },
  # Agregátor S family = plnohodnotný zdroj → patří do katalogu (např. DVTVcz)
  dvtv: { token: 't', aggregator: true, type: 'media', family: 'news' },
  # Agregátor BEZ family (sběrný/testovací bot, např. betabot) → ven
  betabot: { token: 't', aggregator: true, type: 'other' },
  # Agregátor na CIZÍ instanci → ven (i když má family)
  kafkycky: { instance: 'https://mastodonczech.cz', aggregator: true,
              type: 'news', family: 'news' },
  nofamily: { token: 't', aggregator: false, type: 'media' }
}

sources = [
  { id: 'ct24_twitter', platform: 'twitter', language: 'cs',
    source: { handle: 'ct24zive' }, target: { mastodon_account: 'ct24' } },
  { id: 'ct24_bluesky', platform: 'bluesky', language: 'cs',
    source: { handle: 'ct24.bsky.social' }, target: { mastodon_account: 'ct24' } },
  # multilang má dva různé jazyky → default cs; IG feed přes RSS (rss_source_type)
  { id: 'ml_en', platform: 'twitter', language: 'en',
    source: { handle: 'multilang' }, target: { mastodon_account: 'multilang' } },
  { id: 'ml_sk', platform: 'rss', rss_source_type: 'instagram', language: 'sk',
    source: { feed_url: 'https://rss.app/feeds/ml.xml' },
    target: { mastodon_account: 'multilang', social_profile: { handle: 'multilang.ig' } } }
]

# Mastodon fetcher stub — vrátí data jen pro ct24 (multilang "selže")
mastodon_fetcher = Object.new
def mastodon_fetcher.fetch_all(**)
  { 'ct24' => { display_name: 'ČT24', avatar: 'https://cdn/ct24.png',
                followers: 9999, username: 'ct24', note: '<p>Veřejnoprávní zprávy</p>',
                created_at: '2024-01-02T00:00:00.000Z' } }
end

# Snapshot store stub
snapshot_store = Object.new
def snapshot_store.latest_snapshot
  { 'ct24' => { followers: 1234, posts_week: 42, statuses: 5000, snapshot_date: '2026-09-20 20:00:00' } }
end

def snapshot_store.oldest_snapshot_dates
  { 'ct24' => '2024-03-15' }
end

# Předchozí týdenní snapshot pro výpočet skokanů (jen ct24). Zachytí kotvu:
# musí to být datum nejnovějšího snapshotu, ne datum buildu (build jede denně).
$previous_anchor = nil
def snapshot_store.previous_snapshot(date, weeks_back: 1)
  $previous_anchor = date
  { 'ct24' => { followers: 1000, posts_week: 30 } }
end

loader = StubLoader.new(accounts, sources)
agg = Catalog::DataAggregator.new(
  config_loader: loader, db: nil,
  mastodon_instance: 'https://zpravobot.news',
  mastodon_fetcher: mastodon_fetcher, snapshot_store: snapshot_store
)
records = agg.aggregate
by_id = records.to_h { |r| [r[:id], r] }

puts '--- Skokani: kotva předchozího snapshotu ---'
failures += 1 unless check('previous_snapshot dostal datum nejnovějšího snapshotu', Date.new(2026, 9, 20), $previous_anchor)

puts '--- Filtrování ---'
# Projdou: ct24, multilang, dvtv (agregátor s family).
# Vypadnou: external (cizí instance), betabot (agregátor bez family),
#           kafkycky (agregátor na cizí instanci), nofamily (bez family).
failures += 1 unless check('počet záznamů', 3, records.size)
failures += 1 unless check('agregátor s family je v katalogu', true, by_id.key?('dvtv'))
failures += 1 unless check('agregátor bez family vyloučen', false, by_id.key?('betabot'))
failures += 1 unless check('agregátor na cizí instanci vyloučen', false, by_id.key?('kafkycky'))
failures += 1 unless check('external instance vyloučena', false, by_id.key?('external'))
failures += 1 unless check('bez family vyloučen', false, by_id.key?('nofamily'))

puts '--- ct24 záznam ---'
ct24 = by_id['ct24']
failures += 1 unless check('display_name z API', 'ČT24', ct24[:display_name])
failures += 1 unless check('avatar z API', 'https://cdn/ct24.png', ct24[:avatar])
failures += 1 unless check('followers ze snapshotu', 1234, ct24[:followers])
failures += 1 unless check('posts_week ze snapshotu', 42, ct24[:posts_week])
failures += 1 unless check('family', 'news', ct24[:family])
failures += 1 unless check('type', 'media', ct24[:type])
failures += 1 unless check('language jednotná', 'cs', ct24[:language])
failures += 1 unless check('profile_url', 'https://zpravobot.news/@ct24', ct24[:profile_url])
failures += 1 unless check('source_platforms dedup+sort', %w[bluesky twitter], ct24[:source_platforms])
failures += 1 unless check('categories', %w[news journalism], ct24[:categories])
failures += 1 unless check('bio (raw HTML note)', '<p>Veřejnoprávní zprávy</p>', ct24[:bio])
# API created_at (verify_credentials) má přednost před snapshotem (2024-03-15)
failures += 1 unless check('created_at z API instance (přebíjí snapshot)', '2024-01-02', ct24[:created_at])
failures += 1 unless check('source_details twitter URL', 'https://x.com/ct24zive',
                           ct24[:source_details].find { |d| d[:platform] == 'twitter' }[:url])
failures += 1 unless check('source_details bluesky URL', 'https://bsky.app/profile/ct24.bsky.social',
                           ct24[:source_details].find { |d| d[:platform] == 'bluesky' }[:url])
# Skokani: delta = aktuální snapshot − předchozí týden (followers 1234−1000, posts 42−30)
failures += 1 unless check('followers_delta (skokan sledující)', 234, ct24[:followers_delta])
failures += 1 unless check('activity_delta (skokan aktivita)', 12, ct24[:activity_delta])

puts '--- multilang fallbacky ---'
ml = by_id['multilang']
failures += 1 unless check('display_name fallback na id', 'multilang', ml[:display_name])
failures += 1 unless check('avatar nil při selhání API', nil, ml[:avatar])
failures += 1 unless check('bio nil při selhání API', nil, ml[:bio])
failures += 1 unless check('created_at nil bez snapshotu', nil, ml[:created_at])
failures += 1 unless check('followers_delta nil bez předchozího snapshotu', nil, ml[:followers_delta])
failures += 1 unless check('activity_delta nil bez předchozího snapshotu', nil, ml[:activity_delta])
failures += 1 unless check('followers 0 bez snapshotu', 0, ml[:followers])
failures += 1 unless check('posts_week 0 bez snapshotu', 0, ml[:posts_week])
failures += 1 unless check('různé jazyky → default cs', 'cs', ml[:language])
# rss_source_type: instagram → efektivní platforma 'instagram', ne 'rss'
failures += 1 unless check('rss_source_type → instagram platforma', %w[instagram twitter], ml[:source_platforms])
failures += 1 unless check('source_details IG handle z social_profile', 'https://www.instagram.com/multilang.ig',
                           ml[:source_details].find { |d| d[:platform] == 'instagram' }[:url])

puts
if failures.zero?
  puts '=' * 50
  puts '✅ All catalog aggregator tests passed!'
  puts '=' * 50
  exit 0
else
  puts "❌ #{failures} test(s) failed"
  exit 1
end
