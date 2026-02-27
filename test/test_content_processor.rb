#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/processors/content_processor'

puts "=" * 80
puts "Content Processor Test"
puts "=" * 80
puts ""

test_cases = [
  {
    name: "Short text (no trimming needed)",
    input: "Krátký text, který se vejde.",
    max: 500,
    should_not_trim: true
  },
  {
    name: "Long text with sentence boundary",
    input: "První věta je docela dlouhá a obsahuje spoustu informací o aktuální situaci. " \
           "Druhá věta je také dlouhá a popisuje další detaily. " \
           "Třetí věta by se neměla vejít do limitu pokud je nastaven nízko.",
    max: 90,
    should_include: "…",
    should_not_include: "Druhá věta"
  },
  {
    name: "Text with URL (should not break at .com)",
    input: "Přečtěte si článek na https://example.com/clanek.html a dozvíte se více informací. " \
           "Je to velmi zajímavé čtení o aktuálních událostech v naší zemi.",
    max: 80,
    should_include: "…",
    should_not_include: ".html a"  # Should cut before URL ends
  },
  {
    name: "Text with abbreviation (Dr., U.S.)",
    input: "Dr. Smith z U.S. Health Department řekl, že situace je pod kontrolou. " \
           "Další informace budou zveřejněny zítra a pak pozítří.",
    max: 60,
    should_include: "…"
  },
  {
    name: "Text with emoji (unicode-aware)",
    input: "Skvělá zpráva! 🎉 Projekt byl úspěšně dokončen a všichni jsou spokojeni. " \
           "Budeme slavit zítra večer! 🍾",
    max: 60,
    should_include: "🎉"
  },
  {
    name: "Text with incomplete URL after trim",
    input: "Podívejte se na tento článek: https://very-long-domain-name.com/very/long/path/to/article?with=many&params=here",
    max: 50,
    should_not_match: /https?:\/\/[^\s]+$/  # No incomplete URL at end
  },
  {
    name: "Multiple spaces and newlines",
    input: "Text    s     mnoha\n\n\n\nmezerami    a    řádky",
    max: 500,
    expected: "Text s mnoha\n\nmezerami a řádky"
  },
  {
    name: "Multiple ellipsis normalization",
    input: "Text s třemi tečkami... a více…… a ještě......",
    max: 500,
    expected: "Text s třemi tečkami… a více… a ještě…"
  },
  {
    name: "Real RSS example (long)",
    input: "Vláda dnes schválila státní rozpočet na rok 2026. " \
           "Deficit by měl činit 230 miliard korun. " \
           "Ministr financí na tiskové konferenci uvedl, že jde o důležitý krok k fiskální konsolidaci. " \
           "Opozice kritizuje vysoký deficit a požaduje další úsporná opatření. " \
           "Rozpočet nyní míří do Poslanecké sněmovny, kde bude projednán v prvním čtení. " \
           "Očekává se bouřlivá debata která může trvat několik dní.",
    max: 150,
    should_include: "…",
    should_not_include: "Očekává se"  # This should be cut off
  },
  {
    name: "Sentence boundary with URL inside",
    input: "Více informací najdete na https://example.com/page.html které je velmi užitečné. " \
           "Doporučujeme si to přečíst.",
    max: 70,
    should_include: "…",
    # Should break before second sentence, not inside URL
  }
]

# Run tests
passed = 0
failed = 0

test_cases.each_with_index do |test, i|
  puts "Test #{i + 1}: #{test[:name]}"
  input_preview = test[:input][0..60]
  input_preview += '...' if test[:input].length > 60
  puts "  Input: #{input_preview}"
  
  result = Processors::ContentProcessor.new(max_length: test[:max]).process(test[:input])
  
  success = true
  errors = []
  
  # Check should not trim
  if test[:should_not_trim]
    was_trimmed = result.include?('…')
    if was_trimmed
      success = false
      errors << "Should NOT trim, but ellipsis was added"
    end
  end
  
  # Check exact expected output
  if test[:expected]
    if result != test[:expected]
      success = false
      errors << "Expected: #{test[:expected]}"
      errors << "Got: #{result}"
    end
  end
  
  # Check should include
  if test[:should_include]
    unless result.include?(test[:should_include])
      success = false
      errors << "Should include '#{test[:should_include]}'"
    end
  end
  
  # Check should not include
  if test[:should_not_include]
    if result.include?(test[:should_not_include])
      success = false
      errors << "Should NOT include '#{test[:should_not_include]}'"
    end
  end
  
  # Check regex match
  if test[:should_not_match]
    if result =~ test[:should_not_match]
      success = false
      errors << "Should NOT match incomplete URL pattern"
    end
  end
  
  # Check length
  if result.length > test[:max]
    success = false
    errors << "Result too long: #{result.length} > #{test[:max]}"
  end
  
  if success
    puts "  ✅ PASSED"
    puts "  Output: #{result[0..80]}#{'...' if result.length > 80}"
    puts "  Length: #{result.length}/#{test[:max]}"
    passed += 1
  else
    puts "  ❌ FAILED"
    puts "  Output: #{result[0..80]}#{'...' if result.length > 80}"
    puts "  Length: #{result.length}/#{test[:max]}"
    puts "  Errors:"
    errors.each { |e| puts "    - #{e}" }
    failed += 1
  end
  
  puts ""
end

# Summary
puts "=" * 80
puts "Test Results"
puts "=" * 80
puts "  Total:  #{test_cases.count}"
puts "  ✅ Passed: #{passed}"
puts "  ❌ Failed: #{failed}"
puts ""

if failed == 0
  puts "🎉 All tests passed!"
else
  puts "⚠️  Some tests failed"
  exit 1
end
