#!/usr/bin/env ruby
# frozen_string_literal: true

# Test Support::BatchSelector — výběr dávky pro jeden běh runneru
# a rozhodnutí o posunu `since` watermarku.
#
# Regresní pojistka proti vadě naměřené na produkci: dávka se brala
# `.last(max_posts)`, tedy nejnovější posty, a zbytek se nevratně zahodil.
# U vlákna delšího než limit tím zmizel jeho začátek.
#
# Run: ruby test/test_batch_selector.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/support/batch_selector'

puts '=' * 60
puts 'Support::BatchSelector Tests'
puts '=' * 60
puts

$passed = 0
$failed = 0

def test(name, expected, actual)
  if expected == actual
    puts "  \e[32m✓\e[0m #{name}"
    $passed += 1
  else
    puts "  \e[31m✗\e[0m #{name}"
    puts "    Expected: #{expected.inspect}"
    puts "    Actual:   #{actual.inspect}"
    $failed += 1
  end
end

def section(title)
  puts
  puts "--- #{title} ---"
end

# Minimální dvojník Postu — stačí id a published_at
FakePost = Struct.new(:id, :published_at, keyword_init: true)

T0 = Time.at(1_770_000_000)

# Vlákno o 23 postech po minutě + tři starší samostatné posty.
# Vstup je záměrně promíchaný, aby se ověřilo řazení.
THREAD = (1..23).map { |i| FakePost.new(id: format('v%02d', i), published_at: T0 + (i * 60)) }
OLDER  = (1..3).map { |i| FakePost.new(id: "s#{i}", published_at: T0 - (i * 3600)) }
MIXED  = (OLDER + THREAD).shuffle(random: Random.new(42))

def ids(posts) = posts.map(&:id)

# =============================================================================
section('Řazení a výběr nejstarší dávky')

b = Support::BatchSelector.call(MIXED, max_posts: 10)
test('vybere se 10 postů', 10, b.selected.length)
test('odloží se zbytek (26 - 10)', 16, b.deferred)
test('začíná NEJSTARŠÍM postem', 's3', b.selected.first.id)
test('bere odpředu, ne odzadu', %w[s3 s2 s1 v01 v02 v03 v04 v05 v06 v07], ids(b.selected))
test('vybrané jsou chronologicky vzestupně', true,
     b.selected.each_cons(2).all? { |x, y| x.published_at <= y.published_at })
test('complete? je false, když se odkládalo', false, b.complete?)

# =============================================================================
section('Vlákno se vejde celé, když limit stačí')

b30 = Support::BatchSelector.call(MIXED, max_posts: 30)
test('vybere se všech 26', 26, b30.selected.length)
test('nic se neodloží', 0, b30.deferred)
test('complete? je true', true, b30.complete?)
test('celé vlákno je v dávce', [], THREAD.map(&:id) - ids(b30.selected))
test('a začátek vlákna v ní je', true, ids(b30.selected).include?('v01'))

# =============================================================================
section('Druhý běh navazuje bez mezery i bez přeskoku')

done = ids(b.selected)
b2 = Support::BatchSelector.call(MIXED, max_posts: 10) { |p| done.include?(p.id) }
test('už publikované se odfiltrují', 10, b2.already_published)
test('naváže hned za v07', 'v08', b2.selected.first.id)
test('žádný post se nezpracuje dvakrát', [], ids(b2.selected) & done)
test('zbývá odložených 6', 6, b2.deferred)

third = done + ids(b2.selected)
b3 = Support::BatchSelector.call(MIXED, max_posts: 10) { |p| third.include?(p.id) }
test('třetí běh dobere posledních 6', 6, b3.selected.length)
test('a je hotovo', 0, b3.deferred)
test('dohromady prošlo všech 26 bez duplicit', 26, (third + ids(b3.selected)).uniq.length)

# =============================================================================
section('Dedup se počítá před limitem')

all_known = Support::BatchSelector.call(MIXED, max_posts: 10) { |_p| true }
test('vše publikované → nic k práci', 0, all_known.selected.length)
test('nic se neodkládá', 0, all_known.deferred)
test('a je to complete', true, all_known.complete?)
test('započítá všech 26 jako známých', 26, all_known.already_published)

# =============================================================================
section('Okrajové vstupy')

empty = Support::BatchSelector.call([], max_posts: 10)
test('prázdný vstup: nic vybráno', 0, empty.selected.length)
test('prázdný vstup: complete', true, empty.complete?)

nils = Support::BatchSelector.call(
  [FakePost.new(id: 'a', published_at: nil), FakePost.new(id: 'b', published_at: T0)],
  max_posts: 10
)
test('published_at = nil neshodí řazení', %w[a b], ids(nils.selected))

test('nil vstup se snese', 0, Support::BatchSelector.call(nil, max_posts: 10).selected.length)
test('limit 0 nevybere nic', 0, Support::BatchSelector.call(MIXED, max_posts: 0).selected.length)
test('limit 0 odloží všechno', 26, Support::BatchSelector.call(MIXED, max_posts: 0).deferred)

single = Support::BatchSelector.call([THREAD.first], max_posts: 30)
test('jeden post projde', %w[v01], ids(single.selected))

# =============================================================================
section('Watermark: hodnota, ne příznak')

def sel(selected:, deferred:, newest: nil)
  Support::BatchSelection.new(selected: selected, deferred: deferred,
                              already_published: 0, newest_selected_at: newest)
end

hotovo   = sel(selected: THREAD.first(3), deferred: 0, newest: THREAD[2].published_at)
zbylo    = sel(selected: THREAD.first(3), deferred: 20, newest: THREAD[2].published_at)
nic      = sel(selected: [], deferred: 26, newest: nil)

test('hotovo → nil (= NOW())', nil,
     Support::BatchSelector.watermark_for(hotovo))
test('zbylo → čas posledního zpracovaného', THREAD[2].published_at,
     Support::BatchSelector.watermark_for(zbylo))
test('rate limit → čas posledního zpracovaného', THREAD[2].published_at,
     Support::BatchSelector.watermark_for(hotovo, interrupted: true))
test('shutdown → čas posledního zpracovaného', THREAD[2].published_at,
     Support::BatchSelector.watermark_for(hotovo, shutdown: true))

section('Watermark: RSS okno se nepoužívá, vždy NOW()')

test('RSS se zbytkem → nil', nil,
     Support::BatchSelector.watermark_for(zbylo, window_used: false))
test('RSS po rate limitu → nil', nil,
     Support::BatchSelector.watermark_for(hotovo, interrupted: true, window_used: false))

section('Watermark: past nového zdroje (žádný state řádek)')

# 🪤 Nalezeno při dry-runu na testu. Dřív se předával jen příznak „neposouvat",
# ale INSERT větev nemá co ponechat a nastavila by NOW() — odložené posty by
# u nového zdroje vypadly z okna hned při prvním běhu.
test('nový zdroj + zbytek → hranice na zpracovaném postu, ne NOW()', THREAD[2].published_at,
     Support::BatchSelector.watermark_for(zbylo, previous: nil))
test('hranice je STARŠÍ než teď (odložené tedy zůstanou v okně)', true,
     Support::BatchSelector.watermark_for(zbylo, previous: nil) < Time.now)
test('nic nezpracováno + zbytek → drž dosavadní hodnotu', T0,
     Support::BatchSelector.watermark_for(nic, previous: T0))
test('nic nezpracováno, žádná dosavadní → nil (degenerovaný případ)', nil,
     Support::BatchSelector.watermark_for(nic, previous: nil))
test('window_used se bere z platformy: bluesky', true, 'bluesky' != 'rss')
test('window_used se bere z platformy: rss', false, 'rss' != 'rss')

# =============================================================================
section('Regrese: stará logika by tuhle dávku uřízla')

# Přesně to, co se stalo vladafoltanovi: vlákno delší než limit.
old_way = MIXED.sort_by { |p| p.published_at || Time.at(0) }.last(10)
test('stará logika vzala konec vlákna', %w[v14 v15 v16 v17 v18 v19 v20 v21 v22 v23], ids(old_way))
test('stará logika NEMĚLA začátek vlákna', false, ids(old_way).include?('v01'))
test('nová logika začátek vlákna má', true, ids(b.selected).include?('v01'))

# =============================================================================
puts
puts '=' * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts '=' * 60

exit($failed.zero? ? 0 : 1)
