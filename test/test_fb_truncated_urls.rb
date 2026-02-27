#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Test: URL Processor - Facebook Truncated URLs + Orphan Fragments
# ============================================================
# Tests for detecting and removing:
# - URLs truncated by Facebook/RSS.app
# - Orphan URL path fragments (after smart trim splits URL)
# 
# Run: ruby test/test_fb_truncated_urls.rb
# ============================================================

require_relative '../lib/processors/url_processor'

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
puts "URL Processor - Facebook Truncated URL Tests"
puts "=" * 60
puts

processor = Processors::UrlProcessor.new

results = []

# ============================================================
# Test 1: Ellipsis normalization
# ============================================================
puts "## Ellipsis Normalization"

results << test(
  "Normalizes three dots to Unicode ellipsis",
  "Check this…",
  processor.send(:normalize_ellipsis, "Check this...")
)

results << test(
  "Normalizes two dots to Unicode ellipsis",
  "Check this…",
  processor.send(:normalize_ellipsis, "Check this..")
)

results << test(
  "Normalizes four+ dots to single Unicode ellipsis",
  "Check this…",
  processor.send(:normalize_ellipsis, "Check this....")
)

results << test(
  "Preserves single dot",
  "End of sentence.",
  processor.send(:normalize_ellipsis, "End of sentence.")
)

puts

# ============================================================
# Test 2: Facebook-style truncated URL detection
# ============================================================
puts "## FB-style Truncated URL Detection"

results << test(
  "Detects FB path ellipsis with Unicode",
  true,
  processor.has_truncated_url?("https://www.noviny.sk/…/1158124-article…")
)

results << test(
  "Detects FB path ellipsis with ASCII dots",
  true,
  processor.has_truncated_url?("https://www.noviny.sk/.../1158124-article...")
)

results << test(
  "Detects URL ending with Unicode ellipsis",
  true,
  processor.has_truncated_url?("Check https://example.com/very/long/path…")
)

results << test(
  "Detects URL ending with ASCII dots",
  true,
  processor.has_truncated_url?("Check https://example.com/very/long/path...")
)

results << test(
  "Detects URL with mid-ellipsis (FB style)",
  true,
  processor.has_truncated_url?("Link: https://example.com/.../page")
)

results << test(
  "No false positive on normal URL",
  false,
  processor.has_truncated_url?("Check https://example.com/page")
)

results << test(
  "No false positive on text with ellipsis but no URL",
  false,
  processor.has_truncated_url?("This is nice… really nice")
)

puts

# ============================================================
# Test 3: Orphan URL fragment detection (NEW)
# ============================================================
puts "## Orphan URL Fragment Detection"

results << test(
  "Detects orphan path fragment with slash",
  true,
  processor.has_truncated_url?("Text /1158226-trump-chce-od-krajin-miliar…")
)

results << test(
  "Detects orphan path fragment with ASCII dots",
  true,
  processor.has_truncated_url?("Text /1158226-trump-chce-od-krajin...")
)

results << test(
  "Detects orphan slug fragment without slash",
  true,
  processor.has_truncated_url?("Text 1158226-trump-chce-od-krajin-miliar…")
)

results << test(
  "No false positive on short path",
  false,
  processor.has_truncated_url?("Check /123-ab…")  # Too short (less than 10 chars after digit)
)

results << test(
  "No false positive on normal number",
  false,
  processor.has_truncated_url?("There are 12345 items here")
)

results << test(
  "No false positive on date-like pattern",
  false,
  processor.has_truncated_url?("Meeting on 2024-01-15 at noon")
)

puts

# ============================================================
# Test 4: Truncated URL removal
# ============================================================
puts "## Truncated URL Removal"

results << test(
  "Removes FB-style truncated URL (Unicode)",
  "Sneh dosahujúci výšku… #sneh #Kamčatka …",
  processor.remove_truncated_urls("Sneh dosahujúci výšku… #sneh #Kamčatka https://www.noviny.sk/…/1158124-na-kamcatke-nasnezilo…")
)

results << test(
  "Removes FB-style truncated URL (ASCII dots)",
  "Check this article …",
  processor.remove_truncated_urls("Check this article https://www.noviny.sk/.../1158124-article...")
)

results << test(
  "Removes URL with ellipsis at end",
  "Check this …",
  processor.remove_truncated_urls("Check this https://example.com/path…")
)

results << test(
  "Handles multiple truncated URLs",
  "Links: … and …",
  processor.remove_truncated_urls("Links: https://a.com/… and https://b.com/path...")
)

results << test(
  "Normalizes multiple ellipses to single",
  "See …",
  processor.remove_truncated_urls("See https://example.com/…/path…")
)

puts

# ============================================================
# Test 5: Orphan fragment removal (NEW)
# ============================================================
puts "## Orphan Fragment Removal"

results << test(
  "Removes orphan path fragment",
  "Text …",
  processor.remove_truncated_urls("Text /1158226-trump-chce-od-krajin-miliar…")
)

results << test(
  "Removes orphan slug fragment (no slash)",
  "Text …",
  processor.remove_truncated_urls("Text 1158226-trump-chce-od-krajin-miliar…")
)

results << test(
  "Removes orphan fragment with ASCII dots",
  "Article about …",
  processor.remove_truncated_urls("Article about /1158226-some-long-article-slug...")
)

results << test(
  "Preserves normal text with numbers",
  "There are 12345 items here",
  processor.remove_truncated_urls("There are 12345 items here")
)

puts

# ============================================================
# Test 6: Full content processing (real-world FB example)
# ============================================================
puts "## Full Content Processing (Real FB Examples)"

# Simulated FB post through RSS.app
fb_input = "Sneh dosahujúci výšku až štyroch metrov spôsobil dopravný kolaps a vyžiadal si aj dve obete. #sneh #Kamčatka #kalamita #novinysk https://www.noviny.sk/.../1158124-na-kamcatke-nasnezilo..."

results << test(
  "Processes real FB post - removes truncated external URL",
  "Sneh dosahujúci výšku až štyroch metrov spôsobil dopravný kolaps a vyžiadal si aj dve obete. #sneh #Kamčatka #kalamita #novinysk …",
  processor.process_content(fb_input)
)

# Another example with Unicode ellipsis
fb_input2 = "Breaking news: Významná událost… více na https://www.idnes.cz/…/clanek-nazev…"

results << test(
  "Processes FB post with Unicode ellipsis",
  "Breaking news: Významná událost… více na …",
  processor.process_content(fb_input2)
)

# Post with valid URL should be preserved
valid_input = "Důležitá zpráva: https://www.idnes.cz/zpravy/clanek-nazev"

results << test(
  "Preserves valid complete URLs",
  "Důležitá zpráva: https://www.idnes.cz/zpravy/clanek-nazev",
  processor.process_content(valid_input)
)

# Real case: orphan fragment after smart trim
orphan_input = "Americká administratíva bude chcieť najmenej jednu miliardu dolárov od každej krajiny. /1158226-trump-chce-od-krajin-miliar…"

results << test(
  "Processes post with orphan path fragment",
  "Americká administratíva bude chcieť najmenej jednu miliardu dolárov od každej krajiny. …",
  processor.process_content(orphan_input)
)

# Orphan slug without slash
orphan_slug_input = "Zprávy z politiky 1158226-trump-chce-od-krajin-miliardove-prispevky…"

results << test(
  "Processes post with orphan slug fragment",
  "Zprávy z politiky …",
  processor.process_content(orphan_slug_input)
)

puts

# ============================================================
# Test 7: process_url rejects truncated URLs
# ============================================================
puts "## process_url Rejects Truncated URLs"

results << test(
  "Rejects URL with Unicode ellipsis",
  "",
  processor.process_url("https://example.com/path…")
)

results << test(
  "Rejects URL with ASCII dots in path",
  "",
  processor.process_url("https://example.com/.../path")
)

results << test(
  "Accepts valid URL",
  "https://example.com/page",
  processor.process_url("https://example.com/page?utm_source=fb")
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
