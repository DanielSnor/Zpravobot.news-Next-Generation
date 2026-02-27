#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/utils/html_cleaner'

puts "=" * 80
puts "HTML Cleaner Production Test"
puts "=" * 80
puts ""

test_cases = [
  # Original tests
  {
    name: "Czech characters (named entities)",
    input: "Vl&aacute;da schv&aacute;lila nov&yacute; rozpo&ccaron;et",
    expected: "Vláda schválila nový rozpočet"
  },
  {
    name: "Numeric entities (decimal + hex)",
    input: "&#268;esk&#225; republika a &#x010C;esk&#x00E1; vlajka",
    expected: "Česká republika a Česká vlajka"
  },
  
  # New production features
  {
    name: "Script/style removal",
    input: "<script>alert('xss')</script>Text<style>.bad{}</style>More",
    expected: "Text More"
  },
  {
    name: "Line break preservation (<br>)",
    input: "První řádek<br>Druhý řádek<BR/>Třetí řádek",
    expected: "První řádek\nDruhý řádek\nTřetí řádek"
  },
  {
    name: "Paragraph preservation (</p>)",
    input: "<p>První odstavec</p><p>Druhý odstavec</p>",
    expected: "První odstavec\n\nDruhý odstavec"
  },
  {
    name: "Soft hyphen removal",
    input: "ne&shy;roz&shy;lu&shy;ci&shy;telny slovo",
    expected: "nerozlucitelny slovo"
  },
  {
    name: "Angle quotes (laquo/raquo)",
    input: "&laquo;Citace v ceskem textu&raquo;",
    expected: "\u00ABCitace v ceskem textu\u00BB"
  },
  {
    name: "German quotes (bdquo/ldquo)",
    input: "&bdquo;Nemecke uvozovky&ldquo;",
    expected: "\u201ENemecke uvozovky\u201C"
  },
  {
    name: "Invalid codepoint (out of range)",
    input: "Text &#999999999; more",
    expected: "Text &#999999999; more"
  },
  {
    name: "Mixed HTML + entities",
    input: "<p>Ministr &ndash; jak rekl &ndash; je spokojen.<br/>Konec.</p>",
    expected: "Ministr \u2013 jak rekl \u2013 je spokojen.\nKonec."
  },
  {
    name: "Real RSS feed example",
    input: "<p>Vl&aacute;da dnes schv&aacute;lila st&aacute;tn&iacute; rozpo&ccaron;et.<br/>" \
           "Deficit by m&ecaron;l &ccaron;init 230&nbsp;miliard korun.</p>",
    expected: "Vláda dnes schválila státní rozpočet.\nDeficit by měl činit 230 miliard korun."
  },
  {
    name: "Idempotence test",
    input: "<p>&scaron;test&nbsp;text</p>",
    expected_idempotent: true
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
  
  result = HtmlCleaner.clean(test[:input])
  
  success = true
  errors = []
  
  # Check expected output
  if test[:expected]
    if result != test[:expected]
      success = false
      errors << "Expected: #{test[:expected].inspect}"
      errors << "Got: #{result.inspect}"
    end
  end
  
  # Check idempotence
  if test[:expected_idempotent]
    second_result = HtmlCleaner.clean(result)
    if result != second_result
      success = false
      errors << "Not idempotent!"
      errors << "First: #{result}"
      errors << "Second: #{second_result}"
    end
  end
  
  if success
    puts "  ✅ PASSED"
    puts "  Output: #{result}"
    passed += 1
  else
    puts "  ❌ FAILED"
    puts "  Output: #{result}"
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
puts "  Passed: #{passed}"
puts "  Failed: #{failed}"
puts ""

if failed == 0
  puts "All tests passed!"
else
  puts "Some tests failed"
  exit 1
end
