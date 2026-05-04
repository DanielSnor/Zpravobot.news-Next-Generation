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
# Heuristika 1: Emoji odstavce
# ------------------------------------------------------------------
puts "## Emoji jako oddělovač odstavců"

test(
  "Emoji na začátku textu (titulek) → nerozdělovat, druhé emoji → odstavec",
  "\u{1F4AC} VYJADRENIE M. VERSTAPPENA \u{1F4AC}\n\nText za titulkem.",
  processor.process("\u{1F4AC} VYJADRENIE M. VERSTAPPENA \u{1F4AC} Text za titulkem.")
)

test(
  "Emoji na začátku řádku po \n\n → nerozdělovat",
  "Predchozi odstavec.\n\n\u{1F4AC} NOVY TITULEK \u{1F4AC}\n\nText.",
  processor.process("Predchozi odstavec.\n\n\u{1F4AC} NOVY TITULEK \u{1F4AC} Text.")
)

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
# Heuristika 2: První věta zakončená vykřičníkem = nadpis
# ------------------------------------------------------------------
puts "## Nadpis zakončený vykřičníkem"

test(
  "První věta s ! → odstavec za ní",
  "Kimi Antonelli získává pole position pro VC Miami!\n\nMax Verstappen hlásí comeback a do závodu vystartuje z P2.",
  processor.process("Kimi Antonelli získává pole position pro VC Miami! Max Verstappen hlásí comeback a do závodu vystartuje z P2.")
)

test(
  "! uprostřed textu (ne první věta) → beze změny",
  "Tohle je první věta. Druhá věta! Třetí věta.",
  processor.process("Tohle je první věta. Druhá věta! Třetí věta.")
)

test(
  "Text bez ! → beze změny",
  "Prostý text bez vykřičníku na konci.",
  processor.process("Prostý text bez vykřičníku na konci.")
)

test(
  "Emoji titulek + text s ! uvnitř → emoji split, ne ! split",
  "\u{1F4AC} TITULEK \u{1F4AC}\n\nText s vykřičníkem! Pokračování.",
  processor.process("\u{1F4AC} TITULEK \u{1F4AC} Text s vykřičníkem! Pokračování.")
)

puts

# ------------------------------------------------------------------
# Heuristika 4: Seznamy
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

test(
  "Mix hashtag + @mention → hashtags první řádek, mentions druhý řádek",
  "Back on top - an untouchable pole lap from Kimi Antonelli \u{23F1}\u{FE0F}\n\n#F1 #Formula1 #MiamiGP\n@kimi.antonelli @mercedesamgf1",
  processor.process("Back on top - an untouchable pole lap from Kimi Antonelli \u{23F1}\u{FE0F} #F1 #Formula1 #MiamiGP @kimi.antonelli @mercedesamgf1")
)

test(
  "Pouze @mention na konci → zůstává v prose (NE tag block)",
  # Tag block musí začínat #hashtagem; samotný @mention je atribuce v prose,
  # ne tag, takže se nesplituje. Fixuje regresi item 26: "photos by @user".
  "Foto od \u{1F4F7} @photographer.name",
  processor.process("Foto od \u{1F4F7} @photographer.name")
)

test(
  "Atribuce '@author' v prose se NEsplituje (regression: item 26)",
  "This is how Sundays should feel. Owner and photos by @mr.20max\n\n#MINIClassic #classiccar #minifan",
  processor.process("This is how Sundays should feel. Owner and photos by @mr.20max #MINIClassic #classiccar #minifan")
)

test(
  "Tag block s @mentions ZA hashtagy se rozsekne (regression: item 14)",
  "The moment that makes it all worth it \u{1F62E}\u{200D}\u{1F4A8}\n\n#F1 #Formula1 #MiamiGP\n@kimi.antonelli @mercedesamgf1",
  processor.process("The moment that makes it all worth it \u{1F62E}\u{200D}\u{1F4A8} #F1 #Formula1 #MiamiGP @kimi.antonelli @mercedesamgf1")
)

puts

# ------------------------------------------------------------------
# Heuristika 5: Citace v uvozovkách
# ------------------------------------------------------------------
puts "## Citace v uvozovkách"

test(
  "Tečka + straight quote + velké písmeno → odstavec",
  "Verí v posun v sezóne.\n\n\"Od fanúšikov, pre fanúšikov!\" \u{1F3CE}",
  processor.process("Verí v posun v sezóne. \"Od fanúšikov, pre fanúšikov!\" \u{1F3CE}")
)

test(
  "Tečka + curly quote (\\u201C) + velké písmeno → odstavec",
  "Verí v posun v sezóne.\n\n\u{201C}Od fanúšikov, pre fanúšikov!\u{201D} \u{1F3CE}",
  processor.process("Verí v posun v sezóne. \u{201C}Od fanúšikov, pre fanúšikov!\u{201D} \u{1F3CE}")
)

test(
  "Vykřičník + quote → odstavec",
  "Skvelé výsledky!\n\n\"Makáme na tom každý deň.\"",
  processor.process("Skvelé výsledky! \"Makáme na tom každý deň.\"")
)

test(
  "Citace uprostřed věty (bez předchozí interpunkce) → beze změny",
  "Povedal \"nie\" a odišiel.",
  processor.process("Povedal \"nie\" a odišiel.")
)

puts

# ------------------------------------------------------------------
# Heuristika 5: Příliš dlouhý blok textu
# ------------------------------------------------------------------
puts "## Dlouhý blok textu"

# Věta delší než 250 znaků — hranice ". V" je AŽ po prahové pozici
long_s1 = "Podla najnovsich sprav z prostredia FIA a AMuS sa pre rok 2031 vazne uvazuje o prechode na novu generaciu turbomotorov s hybridnym systemom. Tato motorizacia bude podla dostupnych informacii radikalne odlisna od sucasnych pohonov a prinesie fanusikom ocakavane zvukove zazitky."
long_s2 = "Viac informacii zakratko."

test(
  "Blok >250 znaků se větnou hranicí po prahové pozici → rozdělení",
  "#{long_s1}\n\n#{long_s2}",
  processor.process("#{long_s1} #{long_s2}")
)

test(
  "Blok <250 znaků → beze změny",
  "Kratky text bez signalu, ktery neprekracuje prah.",
  processor.process("Kratky text bez signalu, ktery neprekracuje prah.")
)

# Větné hranice PŘED prahem 250 — algoritmus nesplituje (správné chování)
long_under = "Podla najnovsich sprav sa pre rok 2031 uvazuje o V8 motoroch. Cielom je znizit naklady. Jan Monchaux potvrdil navrh."
test(
  "Větné hranice pouze před prahem 250 → beze změny",
  long_under,
  processor.process(long_under)
)

test(
  "Blok >250 znaků bez větné hranice → beze změny (jen strip)",
  ("slovo " * 50).strip,
  processor.process("slovo " * 50)
)

test(
  "Hashtag blok za dlouhým textem → správně odděleno",
  "#{long_s1}\n\n#{long_s2}\n\n#f1",
  processor.process("#{long_s1} #{long_s2} #f1")
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

# ------------------------------------------------------------------
# RSS.app encoding artefakty (�)
# ------------------------------------------------------------------
puts "## RSS.app encoding artefakty"

test(
  "U+FFFD + en-dash → newline + dash (regression: item 38 IG)",
  "Mimo jiné:\n– stažení sil\n– konec blokády\n– uvolnění aktiv",
  processor.process("Mimo jiné:�– stažení sil�– konec blokády�– uvolnění aktiv")
)

test(
  "Osamocený U+FFFD → odstraněn",
  "Text bez chyby.",
  processor.process("Text� bez chyby.")
)

puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
