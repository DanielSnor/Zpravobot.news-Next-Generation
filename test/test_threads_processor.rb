#!/usr/bin/env ruby
# frozen_string_literal: true

# Run: ruby test/test_threads_processor.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'processors/threads_processor'

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

processor = Processors::ThreadsProcessor.new

puts "=" * 60
puts "ThreadsProcessor Tests"
puts "=" * 60
puts

# ------------------------------------------------------------------
# Heuristika 1: Emoji odstavce (sdílené s IG via SocialTextHeuristics)
# ------------------------------------------------------------------
puts "## Emoji jako oddělovač odstavců"

test(
  "Emoji na konci věty + velké písmeno → odstavec",
  "FIA oznámila nová pravidla pro rok 2027. 🏎️\n\nVíce detailů zveřejní příští týden.",
  processor.process("FIA oznámila nová pravidla pro rok 2027. 🏎️ Více detailů zveřejní příští týden.")
)

test(
  "Emoji titulek (uzavírací emoji) → odstavec za ním",
  "🎤 TV Presenter & Commentator 🎤\n\nOdkaz na epizodu níže.",
  processor.process("🎤 TV Presenter & Commentator 🎤 Odkaz na epizodu níže.")
)

test(
  "Emoji uprostřed věty před malým písmenem → beze změny",
  "Jel do 🇨🇿 prahy a byl nadšen.",
  processor.process("Jel do 🇨🇿 prahy a byl nadšen.")
)

puts

# ------------------------------------------------------------------
# Heuristika 2: První věta zakončená vykřičníkem = nadpis
# ------------------------------------------------------------------
puts "## Nadpis zakončený vykřičníkem"

test(
  "Reálný Threads post: exclamation title → odstavec",
  "Drama až do cíle!\n\nAntonelli P1, Norris P2, Piastri P3.",
  processor.process("Drama až do cíle! Antonelli P1, Norris P2, Piastri P3.")
)

test(
  "! uprostřed textu (ne první věta) → beze změny",
  "Tohle je první věta. Druhá věta! Třetí věta.",
  processor.process("Tohle je první věta. Druhá věta! Třetí věta.")
)

test(
  "Text bez ! → beze změny",
  "Motorsport bude povolen ve Švýcarsku od července 2026.",
  processor.process("Motorsport bude povolen ve Švýcarsku od července 2026.")
)

puts

# ------------------------------------------------------------------
# Heuristika 3: Rekonstrukce odstavců (sdílená heuristika)
# ------------------------------------------------------------------
puts "## Rekonstrukce odstavců z plochého textu"

test(
  "Exclamation title + zbývající text zůstane jako jeden odstavec (<250 znaků)",
  "SBOHEM 50/50!\n\nFIA oznámila rozdělení výkonu v poměru 60/40. FIA potvrdila zvýšení výkonu spalovacího motoru o 50 kW.",
  processor.process("SBOHEM 50/50! FIA oznámila rozdělení výkonu v poměru 60/40. FIA potvrdila zvýšení výkonu spalovacího motoru o 50 kW.")
)

test(
  "Krátký post bez struktury → beze změny",
  "Colton Herta letos absolvuje čtyři první volné tréninky pro Cadillac.",
  processor.process("Colton Herta letos absolvuje čtyři první volné tréninky pro Cadillac.")
)

puts

# ------------------------------------------------------------------
# Heuristika 4: Citace v uvozovkách → vlastní odstavec
# ------------------------------------------------------------------
puts "## Citace v uvozovkách"

test(
  "Tečka + straight quote + velké písmeno → odstavec",
  "Jezdec komentoval výsledky závodu.\n\n\"Jsme spokojeni s tempem auta.\" 🏎️",
  processor.process("Jezdec komentoval výsledky závodu. \"Jsme spokojeni s tempem auta.\" 🏎️")
)

test(
  "Citace uprostřed věty → beze změny",
  "Povedal \"nie\" a odišiel.",
  processor.process("Povedal \"nie\" a odišiel.")
)

puts

# ------------------------------------------------------------------
# Heuristika 5: Hashtag blok
# ------------------------------------------------------------------
puts "## Hashtag blok"

test(
  "Hashtag na konci → odstavec",
  "Závod skončil dramaticky.\n\n#f1",
  processor.process("Závod skončil dramaticky. #f1")
)

test(
  "Více hashtagů na konci → odstavec",
  "Závod skončil dramaticky.\n\n#f1 #formula1 #miami",
  processor.process("Závod skončil dramaticky. #f1 #formula1 #miami")
)

test(
  "Threads typicky nepoužívá hashtag bloky — post bez hashtagů → beze změny",
  "Motorsport bude povolen ve Švýcarsku po sedmi dekádách.",
  processor.process("Motorsport bude povolen ve Švýcarsku po sedmi dekádách.")
)

puts

# ------------------------------------------------------------------
# Edge cases
# ------------------------------------------------------------------
puts "## Edge cases"

test("Nil → prázdný řetězec", "", processor.process(nil))
test("Prázdný řetězec → prázdný řetězec", "", processor.process(""))

test(
  "Cleanup: více než 2 newlines → max 2",
  "Věta jedna.\n\nVěta dvě.",
  processor.process("Věta jedna.\n\n\n\nVěta dvě.")
)

test(
  "Reálný post: Švýcarsko závody — krátký text (<250 znaků) zůstane jako jeden odstavec",
  "Motorsport bude oficiálně povolen ve Švýcarsku po sedmi dekádách. Ukončí se tak zákaz, který vstoupil v platnost po katastrofě v Le Mans v roce 1955.",
  processor.process("Motorsport bude oficiálně povolen ve Švýcarsku po sedmi dekádách. Ukončí se tak zákaz, který vstoupil v platnost po katastrofě v Le Mans v roce 1955.")
)

puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
