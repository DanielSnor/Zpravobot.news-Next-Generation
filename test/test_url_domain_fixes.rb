#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Test: URL Domain Fixes
# ============================================================
# Spusť: ruby test_url_domain_fixes.rb
# ============================================================

# Simulace metody apply_domain_fixes
def apply_domain_fixes(text, domains)
  return text if text.nil? || text.empty?
  return text if domains.nil? || domains.empty?

  result = text.dup

  domains.each do |domain|
    next if domain.nil? || domain.strip.empty?

    domain = domain.strip.downcase
    
    # Match domain at word boundary, not already prefixed with http(s)://
    pattern = /(?<![a-zA-Z0-9\/])(#{Regexp.escape(domain)})(\/[^\s]*|(?=[\s,;:.!?\)\]"]|$))/i

    result = result.gsub(pattern) do |_match|
      matched_domain = Regexp.last_match(1)
      path = Regexp.last_match(2) || ''
      "https://#{matched_domain.downcase}#{path}"
    end
  end

  result
end

# Test cases
puts "=" * 60
puts "URL Domain Fixes - Test Suite"
puts "=" * 60
puts

domains = ["idnes.cz", "ihned.cz", "rspkt.cz"]
puts "Testované domény: #{domains.inspect}"
puts

test_cases = [
  # [input, expected_output, description]
  ["Článek na idnes.cz/zpravy/clanek", "Článek na https://idnes.cz/zpravy/clanek", "Základní případ s cestou"],
  ["Více na ihned.cz a rspkt.cz/post", "Více na https://ihned.cz a https://rspkt.cz/post", "Více domén v textu"],
  ["Už má https://idnes.cz/test", "Už má https://idnes.cz/test", "Již má https:// - neměnit"],
  ["http://idnes.cz/stary", "http://idnes.cz/stary", "Již má http:// - neměnit"],
  ["Text bez URL", "Text bez URL", "Žádná URL"],
  ["xidnes.cz neni idnes", "xidnes.cz neni idnes", "Není word boundary - neměnit"],
  ["Link: idnes.cz konec", "Link: https://idnes.cz konec", "Doména bez cesty"],
  ["(idnes.cz/clanek)", "(https://idnes.cz/clanek)", "V závorkách"],
  ["idnes.cz", "https://idnes.cz", "Jen doména"],
  ["Viz idnes.cz, ihned.cz.", "Viz https://idnes.cz, https://ihned.cz.", "S čárkou a tečkou"],
]

passed = 0
failed = 0

test_cases.each_with_index do |(input, expected, description), idx|
  result = apply_domain_fixes(input, domains)
  status = result == expected ? "✅ PASS" : "❌ FAIL"
  
  if result == expected
    passed += 1
  else
    failed += 1
  end
  
  puts "Test #{idx + 1}: #{description}"
  puts "  Input:    #{input.inspect}"
  puts "  Expected: #{expected.inspect}"
  puts "  Got:      #{result.inspect}"
  puts "  Status:   #{status}"
  puts
end

puts "=" * 60
puts "Výsledky: #{passed} passed, #{failed} failed"
puts "=" * 60
