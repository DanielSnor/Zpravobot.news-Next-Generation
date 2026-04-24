#!/usr/bin/env ruby
# frozen_string_literal: true

# Run: ruby test/test_instagram_processor.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'processors/instagram_processor'

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

processor = Processors::InstagramProcessor.new

puts "=" * 60
puts "InstagramProcessor Tests"
puts "=" * 60
puts

# ------------------------------------------------------------------
# Heuristika 1+2: Emoji odstavce
# ------------------------------------------------------------------
puts "## Emoji jako oddělovač odstavců"

test(
  "Emoji na konci věty + velké písmeno → odstavec",
  "Häkkinen na nejvyšším stupínku za zvuku české hymny? Žádné sci-fi, ale realita 😁\n\nElla Häkkinen po tatínkovi rozhodně něco podědila 👀\n\nV nejnovějším EisKing speciálu jsme se zaměřili na největší talenty z Česka a Slovenska. Celou epizodu najdete na našem YouTube.",
  processor.process("Häkkinen na nejvyšším stupínku za zvuku české hymny? Žádné sci-fi, ale realita 😁 Ella Häkkinen po tatínkovi rozhodně něco podědila 👀 V nejnovějším EisKing speciálu jsme se zaměřili na největší talenty z Česka a Slovenska. Celou epizodu najdete na našem YouTube.")
)

test(
  "Otazník + emoji + velké písmeno → odstavec",
  "Megalomanský projekt závodní trati v Saúdské Arábii dokončen v roce 2030. Těšíte se? 🧐\n\nVíce vám poví Andrea v nejnovějším díle EisKingpedie.",
  processor.process("Megalomanský projekt závodní trati v Saúdské Arábii dokončen v roce 2030. Těšíte se? 🧐 Více vám poví Andrea v nejnovějším díle EisKingpedie.")
)

test(
  "Emoji jako bullet na začátku odstavce → odstavec před ním",
  "Libanon má další tři týdny příměří. 🇱🇧🇮🇱\n\nDohoda ale nepřichází v klidné chvíli.",
  processor.process("Libanon má další tři týdny příměří. 🇱🇧🇮🇱 Dohoda ale nepřichází v klidné chvíli.")
)

test(
  "Emoji uprostřed věty před malým písmenem → beze změny",
  "Navštívil 🇨🇿 prahu a byl nadšen.",
  processor.process("Navštívil 🇨🇿 prahu a byl nadšen.")
)

puts

# ------------------------------------------------------------------
# Heuristika 3: Seznamy
# ------------------------------------------------------------------
puts "## Rekonstrukce seznamu"

test(
  "Seznam odrážek oddělen od úvodního textu",
  "Mezi nejdůležitější změny patří:\n- Bod první\n- Bod druhý\n- Bod třetí",
  processor.process("Mezi nejdůležitější změny patří: - Bod první - Bod druhý - Bod třetí")
)

test(
  "Seznam na konci textu — správně rozdělen od úvodu",
  "Změny:\n- Bod A\n- Bod B",
  processor.process("Změny: - Bod A - Bod B")
)

puts

# ------------------------------------------------------------------
# Heuristika 4: Hashtag blok
# ------------------------------------------------------------------
puts "## Hashtag blok"

test(
  "Jeden hashtag na konci → odstavec",
  "Celou epizodu najdete na YouTube.\n\n#hakkinen",
  processor.process("Celou epizodu najdete na YouTube. #hakkinen")
)

test(
  "Více hashtagů na konci → odstavec",
  "Celou epizodu najdete na YouTube.\n\n#hakkinen #f1academy #eisking",
  processor.process("Celou epizodu najdete na YouTube. #hakkinen #f1academy #eisking")
)

test(
  "Hashtag uprostřed textu (ne na konci řádku) → beze změny",
  "Téma #f1academy je zajímavé pro mnoho lidí.",
  processor.process("Téma #f1academy je zajímavé pro mnoho lidí.")
)

puts

# ------------------------------------------------------------------
# Edge cases
# ------------------------------------------------------------------
puts "## Edge cases"

test("Nil → prázdný řetězec", "", processor.process(nil))
test("Prázdný řetězec → prázdný řetězec", "", processor.process(""))
test("Čistý text bez signálů → beze změny", "Prostý text bez emoji nebo hashtagů.", processor.process("Prostý text bez emoji nebo hashtagů."))

test(
  "Cleanup: více než 2 newlines → max 2",
  "Věta jedna.\n\nVěta dvě.",
  processor.process("Věta jedna.\n\n\n\nVěta dvě.")
)

puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
