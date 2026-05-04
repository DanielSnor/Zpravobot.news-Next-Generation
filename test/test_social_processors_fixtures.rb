#!/usr/bin/env ruby
# frozen_string_literal: true
# encoding: utf-8

# ============================================================
# Test: regression na real-world RSS.app feedech (FB + IG)
# ============================================================
#
# Iteruje přes uložené RSS.app vzorky v test/fixtures/ a:
#   1. ověří, že processor neshodí žádnou položku (smoke)
#   2. checkuje invarianty výstupu (idempotence pro \n\n, ne-prázdný)
#   3. uplatňuje pevně zakotvená očekávání pro klíčové vzorky,
#      které pokrývají specifické heuristiky (item 22 NBL,
#      item 26 mini-classic @-mention bug, item 38 IG U+FFFD,
#      item 49 sponsored-by, item 27 VedatorCZ).
#
# Run: ruby test/test_social_processors_fixtures.rb
# ============================================================

require 'rexml/document'

ROOT = File.expand_path('..', __dir__)
$LOAD_PATH.unshift File.join(ROOT, 'lib')

require 'processors/instagram_processor'
require 'processors/facebook_processor'

$passed = 0
$failed = 0

def test(name, expected, actual)
  if expected == actual
    puts "✅ #{name}"
    $passed += 1
  else
    puts "❌ #{name}"
    puts "   Expected: #{expected.inspect}"
    puts "   Actual:   #{actual.inspect}"
    $failed += 1
  end
end

def assert(name, condition, detail = '')
  if condition
    puts "✅ #{name}"
    $passed += 1
  else
    puts "❌ #{name} #{detail}"
    $failed += 1
  end
end

def load_items(filename)
  path = File.join(ROOT, 'test', 'fixtures', filename)
  raise "Fixture missing: #{path}" unless File.exist?(path)
  doc = REXML::Document.new(File.read(path))
  doc.elements.to_a('rss/channel/item').map do |item|
    {
      desc: item.elements['description']&.text,
      source: item.elements['source']&.text || item.elements['dc:creator']&.text
    }
  end
end

# ============================================================
# Smoke test — 100 položek (50 FB + 50 IG) prochází bez exception
# ============================================================
puts '=' * 60
puts 'Smoke: všechny položky prošly bez exception'
puts '=' * 60

fb_items = load_items('rss_app_facebook_sample.xml')
ig_items = load_items('rss_app_instagram_sample.xml')

fb_processor = Processors::FacebookProcessor.new
ig_processor = Processors::InstagramProcessor.new

fb_outputs = fb_items.map { |it| it[:desc] && fb_processor.process(it[:desc]) }
ig_outputs = ig_items.map { |it| it[:desc] && ig_processor.process(it[:desc]) }

assert("FB: 50 items processed without exception", fb_outputs.length == 50)
assert("IG: 50 items processed without exception", ig_outputs.length == 50)

# Žádný výstup nesmí být kratší než vstup po normalizaci whitespace
# (procesory přidávají \n\n, neořezávají obsah)
fb_outputs.each_with_index do |out, i|
  next if out.nil?
  input_words = fb_items[i][:desc].split(/\s+/).length
  output_words = out.split(/\s+/).length
  assert("FB[#{i + 1}]: word count preserved (#{input_words} → #{output_words})",
         output_words >= input_words - 2, # tolerance: hashtag block deduplikuje | separátory
         "input=#{fb_items[i][:desc].inspect}\n   output=#{out.inspect}")
end

ig_outputs.each_with_index do |out, i|
  next if out.nil?
  input_words = ig_items[i][:desc].split(/\s+/).length
  output_words = out.split(/\s+/).length
  assert("IG[#{i + 1}]: word count preserved (#{input_words} → #{output_words})",
         output_words >= input_words - 2,
         "input=#{ig_items[i][:desc].inspect}\n   output=#{out.inspect}")
end

# ============================================================
# Idempotence — opakovaná aplikace nepřidává další \n\n
# ============================================================
puts
puts '=' * 60
puts 'Idempotence: process(process(x)) == process(x)'
puts '=' * 60

fb_outputs.each_with_index do |out, i|
  next if out.nil?
  twice = fb_processor.process(out)
  assert("FB[#{i + 1}]: idempotent", twice == out)
end

ig_outputs.each_with_index do |out, i|
  next if out.nil?
  twice = ig_processor.process(out)
  assert("IG[#{i + 1}]: idempotent", twice == out)
end

# ============================================================
# Klíčové vzorky — fix očekávání (regression anchors)
# ============================================================
puts
puts '=' * 60
puts 'Regression anchors'
puts '=' * 60

# FB item 22 — NBL: emoji split + sentence-end + hashtag-line
test(
  'FB item 22: NBL play-off (uživatelem schválený formát)',
  "📺 PLAY-OFF NBL DNES VEČER NA ČT SPORT 🏀\n\n" \
  "Matěj Burda na zimáku na Beksu!\n\n" \
  "#MaxaNBL Sršni Photomate Písek BK Pardubice ČT sport",
  fb_processor.process(
    '📺 PLAY-OFF NBL DNES VEČER NA ČT SPORT 🏀 Matěj Burda na zimáku na Beksu! ' \
    '#MaxaNBL Sršni Photomate Písek BK Pardubice ČT sport'
  )
)

# FB item 27 — VedatorCZ: 3 odstavce, emoji-terminované
test(
  'FB item 27: VedatorCZ srnci/klokani (uživatelem schválený formát)',
  "🦌 Fskutečnosti jsou samozřejmě srnci našimi příbuznými SAVCI - PLACENTÁLY, " \
  "zatímco klokani jsou (taky savci, ale) VAČNATCI . 🦘\n\n" \
  "Jejich poslední společný předek tedy sahá až 160 milionů let nazpět v době " \
  "oddělení Austrálie od kontinentu Pangea. Vy sami (pokud jste člověk) jste " \
  "tedy srnci BLÍŽE než klokan! 😅\n\n" \
  "Ale – jejich vnější podobnost je fskutečnosti projevem konvergentní evoluce. " \
  'Čili toho, že různé druhy mají tendenci se vyvíjet do podobných "tvarů", ' \
  "pokud žijí v podobném biomu a plní podobnou úlohu ve svém prostředí. " \
  "Jiným příkladem téhož jsou tučňáci (vodní ptáci s ploutvema) a velryby " \
  "(vodní savci... taky překvapivě s ploutvema), které jsou podobné jiným... " \
  "rybám s ploutvema! 🧬",
  fb_processor.process(
    '🦌 Fskutečnosti jsou samozřejmě srnci našimi příbuznými SAVCI - PLACENTÁLY, ' \
    'zatímco klokani jsou (taky savci, ale) VAČNATCI . 🦘 Jejich poslední ' \
    'společný předek tedy sahá až 160 milionů let nazpět v době oddělení ' \
    'Austrálie od kontinentu Pangea. Vy sami (pokud jste člověk) jste tedy ' \
    'srnci BLÍŽE než klokan! 😅 Ale – jejich vnější podobnost je fskutečnosti ' \
    'projevem konvergentní evoluce. Čili toho, že různé druhy mají tendenci ' \
    'se vyvíjet do podobných "tvarů", pokud žijí v podobném biomu a plní ' \
    'podobnou úlohu ve svém prostředí. Jiným příkladem téhož jsou tučňáci ' \
    '(vodní ptáci s ploutvema) a velryby (vodní savci... taky překvapivě ' \
    's ploutvema), které jsou podobné jiným... rybám s ploutvema! 🧬'
  )
)

# IG item 26 — @-mention atribuce v prose, NE tag block
test(
  'IG item 26: official_miniclassic — @-mention v prose nesplit (bug fix)',
  "This is how Sundays should feel. Owner and photos by @mr.20max\n\n" \
  '#MINIClassic #classiccar #minifan',
  ig_processor.process(
    'This is how Sundays should feel. Owner and photos by @mr.20max ' \
    '#MINIClassic #classiccar #minifan'
  )
)

# IG item 49 — Sponsored by : @a @b #tags : block musí začínat #
test(
  'IG item 49: britishminiclub — "Sponsored by : @x @y" zůstává v prose',
  ['📅 7 DAYS TO GO 🚗 7 DAYS TO GO! 🇬🇧',
   "The countdown is officially on… British Mini Day is just around the corner! " \
   "Join us at Himley Hall for a full celebration of MINI culture — from iconic " \
   "classics to modern favourites. 📅",
   'Sunday 10th May 📍',
   'Himley Hall, DY3 4DF 🎟️ britishminiclub.co.uk 🔗',
   'Check out bio for ticket links Sponsored by : @woodandpickett @autoglymuk',
   '#BritishMiniDay #MiniLife #ClassicMini #MiniCooper #britishminiclub #modernmini'
  ].join("\n\n"),
  ig_processor.process(
    '📅 7 DAYS TO GO 🚗 7 DAYS TO GO! 🇬🇧 The countdown is officially on… ' \
    'British Mini Day is just around the corner! Join us at Himley Hall for ' \
    'a full celebration of MINI culture — from iconic classics to modern ' \
    'favourites. 📅 Sunday 10th May 📍 Himley Hall, DY3 4DF 🎟️ ' \
    'britishminiclub.co.uk 🔗 Check out bio for ticket links Sponsored by : ' \
    '@woodandpickett @autoglymuk #BritishMiniDay #MiniLife #ClassicMini ' \
    '#MiniCooper #britishminiclub #modernmini'
  )
)

# IG item 38 — U+FFFD encoding artifact → newline + dash list
ig_item38_input = ig_items.find { |i| i[:source]&.include?('andreas_ppdp') && i[:desc]&.include?('Hormuz') }&.dig(:desc)
if ig_item38_input
  out = ig_processor.process(ig_item38_input)
  assert(
    'IG item 38: U+FFFD encoding artefakty rozpoznány',
    !out.include?("�") && out.include?("\n– stažení amerických sil"),
    "(output:\n#{out}\n)"
  )
  assert(
    'IG item 38: hashtag block #Iran ... #Geopolitika na konci',
    out.end_with?('#Iran #USA #Hormuz #MiddleEast #Geopolitika')
  )
else
  puts '⚠️  IG item 38 nenalezen ve fixture — fixture mohl být refreshován'
end

# IG item 14 — mix # + @, hashtags na 1. řádku, mentions na 2. řádku
test(
  'IG item 14: mix #/@ — hashtags první řádek, mentions druhý řádek',
  "The moment that makes it all worth it 😮‍💨\n\n" \
  "#F1 #Formula1 #MiamiGP\n@kimi.antonelli @mercedesamgf1",
  ig_processor.process(
    'The moment that makes it all worth it 😮‍💨 #F1 #Formula1 #MiamiGP ' \
    '@kimi.antonelli @mercedesamgf1'
  )
)

puts
puts '=' * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts '=' * 60

exit($failed.zero? ? 0 : 1)
