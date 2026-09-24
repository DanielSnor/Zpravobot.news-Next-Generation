#!/usr/bin/env ruby
# frozen_string_literal: true

# Test for Catalog::PostsCollector
# Usage: ruby test/test_catalog_posts_collector.rb
#
# Izolovaný — žádná reálná DB. PG spojení je nahrazeno stubem, který vrátí
# předpřipravené řádky (jako z Mastodon statuses dotazu).

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'catalog/posts_collector'

failures = 0
def check(label, expected, actual)
  ok = expected == actual
  puts "#{ok ? '✅' : '❌'} #{label}: expected=#{expected.inspect} actual=#{actual.inspect}"
  ok
end

# --- Stub PG spojení ----------------------------------------------------
# Vrací rows bez ohledu na SQL; ověřuje, že se předal text[] param.
class StubConn
  attr_reader :last_params

  def initialize(rows)
    @rows = rows
  end

  def exec_params(_sql, params)
    @last_params = params
    @rows
  end
end

# --- Fixtures: 3 účty, různý engagement ---------------------------------
records = [
  { id: 'ct24', display_name: 'ČT24', avatar: 'https://cdn/ct24.png',
    family: 'news', categories: %w[news] },
  { id: 'sparta', display_name: 'AC Sparta', avatar: 'https://cdn/sparta.png',
    family: 'sport', categories: %w[football] }
]

# ct24 má 3 posty (kvůli skokanům RISER_MIN_POSTS=3), sparta 1.
rows = [
  { 'id' => '101', 'username' => 'ct24', 'text' => 'Velká zpráva #breaking na https://ct24.cz/x',
    'language' => 'cs', 'created_at' => '2026-06-01T10:00:00Z', 'url' => 'https://zpravobot.news/@ct24/101',
    'reblogs_count' => '10', 'favourites_count' => '20', 'has_media' => 't', 'hashtags' => 'breaking,zpravy' },
  { 'id' => '102', 'username' => 'ct24', 'text' => 'Druhá zpráva', 'language' => 'cs',
    'created_at' => '2026-06-02T10:00:00Z', 'url' => 'https://zpravobot.news/@ct24/102',
    'reblogs_count' => '1', 'favourites_count' => '1', 'has_media' => 'f', 'hashtags' => nil },
  { 'id' => '103', 'username' => 'ct24', 'text' => 'Třetí zpráva', 'language' => 'cs',
    'created_at' => '2026-06-03T10:00:00Z', 'url' => 'https://zpravobot.news/@ct24/103',
    'reblogs_count' => '0', 'favourites_count' => '0', 'has_media' => 'f', 'hashtags' => '' },
  { 'id' => '201', 'username' => 'sparta', 'text' => 'Gól! ⚽', 'language' => 'cs',
    'created_at' => '2026-06-04T10:00:00Z', 'url' => 'https://zpravobot.news/@sparta/201',
    'reblogs_count' => '50', 'favourites_count' => '100', 'has_media' => 't', 'hashtags' => 'fotbal' }
]

conn = StubConn.new(rows)
collector = Catalog::PostsCollector.new(
  conn: conn, records: records, mastodon_schema: 'public',
  instance_url: 'https://zpravobot.news'
)
result = collector.collect

puts '--- Struktura posts.json ---'
failures += 1 unless check('total_posts', 4, result['total_posts'])
failures += 1 unless check('má top_by_engagement', true, result.key?('top_by_engagement'))
failures += 1 unless check('má risers_ratio', true, result.key?('risers_ratio'))

puts '--- Řazení sekcí ---'
eng = result['top_by_engagement']
# sparta 201 (engagement 150) > ct24 101 (30) > 102 (2) > 103 (0)
failures += 1 unless check('top engagement post = sparta 201', '201', eng.first['id'])
failures += 1 unless check('engagement spočítán (150)', 150, eng.first['engagement'])
failures += 1 unless check('top_by_reblogs první = sparta', 'sparta', result['top_by_reblogs'].first['account_username'])
failures += 1 unless check('top_by_date první = nejnovější (201)', '201', result['top_by_date'].first['id'])

puts '--- Mapování řádku ---'
p101 = eng.find { |p| p['id'] == '101' }
failures += 1 unless check('account_display_name z records', 'ČT24', p101['account_display_name'])
failures += 1 unless check('account_avatar z records', 'https://cdn/ct24.png', p101['account_avatar'])
failures += 1 unless check('account_family', 'news', p101['account_family'])
failures += 1 unless check('account_instance', 'zpravobot.news', p101['account_instance'])
failures += 1 unless check('hashtags rozparsované', %w[breaking zpravy], p101['hashtags'])
failures += 1 unless check('has_media true', true, p101['has_media'])
failures += 1 unless check('content_plain = text', 'Velká zpráva #breaking na https://ct24.cz/x', p101['content_plain'])
failures += 1 unless check('created_at ISO8601', '2026-06-01T10:00:00Z', p101['created_at'])

puts '--- content_html linkify ---'
html = p101['content_html']
failures += 1 unless check('URL linkified', true, html.include?('<a href="https://ct24.cz/x"'))
failures += 1 unless check('hashtag linkified', true, html.include?('/tags/breaking" class="mention hashtag"'))
failures += 1 unless check('obalený <p>', true, html.start_with?('<p>') && html.end_with?('</p>'))

puts '--- Skokani (jen účty s ≥3 posty) ---'
# ct24 má 3 posty (avg engagement = (30+2+0)/3 = 10.67); sparta má 1 → vyloučena
abs_ids = result['risers_absolute'].map { |p| p['account_username'] }.uniq
failures += 1 unless check('skokani jen z ct24 (sparta má <3 posty)', ['ct24'], abs_ids)
top_riser = result['risers_absolute'].first
failures += 1 unless check('top skokan = post 101 (nejvíc nad průměrem)', '101', top_riser['id'])

puts '--- PG text[] param ---'
failures += 1 unless check('předán text[] literál účtů', true,
                           conn.last_params[0].include?('ct24') && conn.last_params[0].start_with?('{'))

puts
if failures.zero?
  puts '=' * 50
  puts '✅ All PostsCollector tests passed!'
  puts '=' * 50
  exit 0
else
  puts "❌ #{failures} test(s) failed"
  exit 1
end
