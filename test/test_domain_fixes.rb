#!/usr/bin/env ruby
# Test apply_domain_fixes s opravou pomocí placeholderů
# Spusť: ruby test_domain_fixes_v2.rb

def apply_domain_fixes_old(text, domains)
  return text if text.nil? || text.empty?
  return text if domains.nil? || domains.empty?
  result = text.dup
  domains.each do |domain|
    next if domain.nil? || domain.strip.empty?
    domain = domain.strip.downcase
    subdomain_pattern = '(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?\.)*'
    pattern = /(?<![\/\/:@])(#{subdomain_pattern}#{Regexp.escape(domain)})(\/[^\s]*|(?=[\s,;:.!?\)\]"]|$))/i
    result = result.gsub(pattern) do |_match|
      matched_domain = Regexp.last_match(1)
      path = Regexp.last_match(2) || ''
      "https://#{matched_domain.downcase}#{path}"
    end
  end
  result
end

def apply_domain_fixes_new(text, domains)
  return text if text.nil? || text.empty?
  return text if domains.nil? || domains.empty?
  
  result = text.dup
  
  # 1. Ochránit existující URL pomocí placeholderů
  url_pattern = /https?:\/\/[^\s]+/i
  urls = result.scan(url_pattern)
  urls.each_with_index do |url, i|
    result = result.sub(url, "___URL_PLACEHOLDER_#{i}___")
  end
  
  # 2. Aplikovat domain fixes na text BEZ URL
  domains.each do |domain|
    next if domain.nil? || domain.strip.empty?
    domain = domain.strip.downcase
    subdomain_pattern = '(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?\.)*'
    pattern = /(?<![a-zA-Z0-9\/\/:@])(#{subdomain_pattern}#{Regexp.escape(domain)})(\/[^\s]*|(?=[\s,;:.!?\)\]"]|$))/i
    result = result.gsub(pattern) do |_match|
      matched_domain = Regexp.last_match(1)
      path = Regexp.last_match(2) || ''
      "https://#{matched_domain.downcase}#{path}"
    end
  end
  
  # 3. Vrátit URL zpět
  urls.each_with_index do |url, i|
    result = result.sub("___URL_PLACEHOLDER_#{i}___", url)
  end
  
  result
end

domains = ["respekt.cz", "hn.cz"]

test_cases = [
  # Bez protokolu - mělo by přidat https://
  ["navštivte predplatne.respekt.cz", "navštivte https://predplatne.respekt.cz"],
  ["více na vikend.hn.cz/clanek", "více na https://vikend.hn.cz/clanek"],
  ["info: archiv.hn.cz", "info: https://archiv.hn.cz"],
  ["respekt.cz má nový web", "https://respekt.cz má nový web"],
  ["www.respekt.cz/tydenik", "https://www.respekt.cz/tydenik"],
  
  # S protokolem - NESMÍ poškodit
  ["čtěte https://www.respekt.cz/tydenik/2026/5", "čtěte https://www.respekt.cz/tydenik/2026/5"],
  ["👉 K přečtení - https://www.respekt.cz/tydenik/2026/5", "👉 K přečtení - https://www.respekt.cz/tydenik/2026/5"],
  ["https://predplatne.respekt.cz/info", "https://predplatne.respekt.cz/info"],
  ["http://vikend.hn.cz/clanek", "http://vikend.hn.cz/clanek"],
  
  # Kombinace - URL i plain doména
  ["web: respekt.cz, článek: https://www.respekt.cz/clanek", "web: https://respekt.cz, článek: https://www.respekt.cz/clanek"],
]

puts "=" * 80
puts "TEST apply_domain_fixes (nová verze s placeholdery)"
puts "=" * 80

errors_new = 0

test_cases.each do |input, expected|
  new_result = apply_domain_fixes_new(input, domains)
  new_ok = new_result == expected

  errors_new += 1 unless new_ok

  puts "\nInput:    #{input}"
  puts "Expected: #{expected}"
  puts "Result:   #{new_result} #{new_ok ? '✅' : '❌'}"
end

puts "\n" + "=" * 80
puts "VÝSLEDKY:"
puts "  Nová verze:  #{test_cases.length - errors_new}/#{test_cases.length} OK (#{errors_new} chyb)"
puts "=" * 80

exit(errors_new == 0 ? 0 : 1)
