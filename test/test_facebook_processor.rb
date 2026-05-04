#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Test: Facebook Processor - Em-dash duplicate removal
# ============================================================
# Tests for Facebook-specific content processing
# 
# Run: ruby test/test_facebook_processor.rb
# ============================================================

require_relative '../lib/processors/facebook_processor'

# Test helper
def test(name, expected, actual)
  pass = expected == actual
  status = pass ? '✅' : '❌'
  puts "#{status} #{name}"
  unless pass
    puts "   Expected: #{expected.inspect}"
    puts "   Actual:   #{actual.inspect}"
  end
  pass
end

puts "=" * 60
puts "Facebook Processor Tests"
puts "=" * 60
puts

processor = Processors::FacebookProcessor.new

results = []

# ============================================================
# Test 1: Em-dash duplicate detection
# ============================================================
puts "## Em-dash Duplicate Detection"

results << test(
  "Detects exact duplicate",
  true,
  processor.duplicate_content?("Čo ďalšie odznelo?", "Čo ďalšie odznelo?")
)

results << test(
  "Detects truncated duplicate (first longer)",
  true,
  processor.duplicate_content?(
    "Čo ďalšie odznelo v Na telo? Pozrite si tu bit.ly/xxx",
    "Čo ďalšie odznelo v Na telo? Pozrite si tu bit.ly/xxx Jednou z…"
  )
)

results << test(
  "Detects truncated duplicate (second longer)",
  true,
  processor.duplicate_content?(
    "Čo ďalšie odznelo v Na telo…",
    "Čo ďalšie odznelo v Na telo? Pozrite si tu"
  )
)

results << test(
  "No false positive on different content",
  false,
  processor.duplicate_content?(
    "Breaking news about politics",
    "Weather forecast for tomorrow"
  )
)

results << test(
  "Handles hashtag differences",
  true,
  processor.duplicate_content?(
    "Viac tu bit.ly/xxx #tvnoviny #trump",
    "Viac tu bit.ly/xxx #tvnoviny"
  )
)

puts

# ============================================================
# Test 2: Em-dash duplicate removal
# ============================================================
puts "## Em-dash Duplicate Removal"

# Real example from Reels
results << test(
  "Removes exact duplicate after em-dash",
  "Čo ďalšie odznelo? bit.ly/xxx",
  processor.remove_emdash_duplicate("Čo ďalšie odznelo? bit.ly/xxx — Čo ďalšie odznelo? bit.ly/xxx")
)

# Truncated version
results << test(
  "Keeps longer part when truncated duplicate",
  "Čo ďalšie odznelo v Na telo? Pozrite si tu 👉 bit.ly/49X5Ex3 Jednou z tém bola témou aj cesta Roberta Fica do U…",
  processor.remove_emdash_duplicate(
    "Čo ďalšie odznelo v Na telo? Pozrite si tu 👉 bit.ly/49X5Ex3 Jednou z tém bola témou aj cesta Roberta Fica do U… — Čo ďalšie odznelo v Na telo? Pozrite si tu 👉 bit.ly/49X5Ex3 Jednou z…"
  )
)

# Second example
results << test(
  "Handles Reels with hashtags",
  "Viac o stretnutí si prečítate tu👉 bit.ly/4b6kPFc 🎥FB/Robert Fico\n#tvnoviny #trump\n#fico #usa\n#politika",
  processor.remove_emdash_duplicate(
    "Viac o stretnutí si prečítate tu👉 bit.ly/4b6kPFc 🎥FB/Robert Fico\n#tvnoviny #trump\n#fico #usa\n#politika — Viac o stretnutí si prečítate tu👉 bit.ly/4b6kPFc 🎥FB/Robert Fico\n#tvnoviny…"
  )
)

# Non-duplicate should be preserved
results << test(
  "Preserves non-duplicate em-dash content",
  "Breaking news — More details here",
  processor.remove_emdash_duplicate("Breaking news — More details here")
)

# No em-dash
results << test(
  "Preserves text without em-dash",
  "Regular post without separator",
  processor.remove_emdash_duplicate("Regular post without separator")
)

puts

# ============================================================
# Test 3: Full process method
# ============================================================
puts "## Full Process Method"

results << test(
  "Processes Reels duplicate + odděluje hashtag block",
  "Viac tu 👉bit.ly/4qCYAvi\n\n#tvnoviny #tvmarkiza #raketa #artemis",
  processor.process("Viac tu 👉bit.ly/4qCYAvi #tvnoviny #tvmarkiza #raketa #artemis — Viac tu 👉bit.ly/4qCYAvi #tvnoviny #tvmarkiza #raketa #artemis")
)

results << test(
  "Handles empty string",
  "",
  processor.process("")
)

results << test(
  "Handles nil",
  "",
  processor.process(nil)
)

results << test(
  "Preserves normal FB post",
  "Americká administratíva bude chcieť najmenej jednu miliardu dolárov.",
  processor.process("Americká administratíva bude chcieť najmenej jednu miliardu dolárov.")
)

puts

# ============================================================
# Test 4: Similarity score
# ============================================================
puts "## Similarity Score"

results << test(
  "Perfect similarity",
  1.0,
  processor.similarity_score("hello world test", "hello world test")
)

results << test(
  "High similarity",
  true,
  processor.similarity_score("hello world test one", "hello world test two") > 0.5
)

results << test(
  "Low similarity",
  true,
  processor.similarity_score("apples oranges bananas", "cars trucks planes") < 0.3
)

puts

# ============================================================
# Test 5: Edge cases
# ============================================================
puts "## Edge Cases"

results << test(
  "Multiple em-dashes (takes first split)",
  "First part",
  processor.remove_emdash_duplicate("First part — First part — First part")
)

results << test(
  "Em-dash at start",
  " — Some text",
  processor.remove_emdash_duplicate(" — Some text")
)

results << test(
  "Em-dash at end",
  "Some text — ",
  processor.remove_emdash_duplicate("Some text — ")
)

results << test(
  "Only em-dash",
  " — ",
  processor.remove_emdash_duplicate(" — ")
)

puts

# ============================================================
# Test 6: Heuristiky sdílené s IG (paragraph break, hashtag block, long para)
# ============================================================
puts "## Heuristiky sdílené s IG"

results << test(
  "Emoji jako oddělovač odstavce (regression: VedatorCZ item 27)",
  "Srnci jsou SAVCI \u{1F98C}\n\nJejich předek sahá daleko.",
  processor.process("Srnci jsou SAVCI \u{1F98C} Jejich předek sahá daleko.")
)

results << test(
  "Hashtag blok na konci po sentence-end (regression: tvnoviny posty)",
  "Systém má diery.\n\n#domace #zdravie #tvnoviny",
  processor.process("Systém má diery. #domace #zdravie #tvnoviny")
)

results << test(
  "Mix hashtag + @mention v tag bloku",
  "Bewley on another level \u{1F525}\n\n#SGP #SpeedwayGP",
  processor.process("Bewley on another level \u{1F525} #SGP #SpeedwayGP")
)

results << test(
  "U+FFFD encoding artefakt → newline + dash list",
  "Mimo jiné:\n– A\n– B\n– C",
  processor.process("Mimo jiné:�– A�– B�– C")
)

puts

# ============================================================
# Test 7: FB-specific heuristika — split_before_hashtag_line
# ============================================================
puts "## FB-specific: split before hashtag-line"

results << test(
  "Sentence-end + #hashtag mixed s page mentions (item 22 NBL)",
  "\u{1F4FA} PLAY-OFF NBL DNES VEČER NA ČT SPORT \u{1F3C0}\n\nMatěj Burda na zimáku na Beksu!\n\n#MaxaNBL Sršni Photomate Písek BK Pardubice ČT sport",
  processor.process("\u{1F4FA} PLAY-OFF NBL DNES VEČER NA ČT SPORT \u{1F3C0} Matěj Burda na zimáku na Beksu! #MaxaNBL Sršni Photomate Písek BK Pardubice ČT sport")
)

results << test(
  "Hashtag uprostřed věty (NE začátek nové věty) → beze změny",
  "Sledujte #raketa naživo zde.",
  processor.process("Sledujte #raketa naživo zde.")
)

puts

# ============================================================
# Summary
# ============================================================
puts "=" * 60
passed = results.count(true)
failed = results.count(false)
total = results.length

puts "Results: #{passed}/#{total} passed"
if failed > 0
  puts "❌ #{failed} tests failed"
  exit 1
else
  puts "✅ All tests passed!"
  exit 0
end
