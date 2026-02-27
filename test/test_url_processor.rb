#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script for UrlProcessor
# Run: ruby test_url_processor.rb

require_relative '../lib/processors/url_processor'

# Helper for colored output
def pass(msg)
  puts "\e[32m✓ #{msg}\e[0m"
end

def fail(msg, expected, got)
  puts "\e[31m✗ #{msg}\e[0m"
  puts "  Expected: #{expected.inspect}"
  puts "  Got:      #{got.inspect}"
end

def test(name, expected, actual)
  if expected == actual
    pass(name)
    true
  else
    fail(name, expected, actual)
    false
  end
end

puts "=" * 60
puts "Testing UrlProcessor"
puts "=" * 60
puts

processor = Processors::UrlProcessor.new

results = []

# ============================================================
# Test 1: Query parameter trimming
# ============================================================
puts "## Query Parameter Trimming"

results << test(
  "Removes utm params",
  "https://example.com/article",
  processor.process_url("https://example.com/article?utm_source=twitter&utm_medium=social")
)

results << test(
  "Removes generic params",
  "https://news.site/story",
  processor.process_url("https://news.site/story?ref=homepage&tracking=123")
)

results << test(
  "Keeps URL without params unchanged",
  "https://example.com/page",
  processor.process_url("https://example.com/page")
)

puts

# ============================================================
# Test 2: No-trim domains (preserve query params)
# ============================================================
puts "## No-Trim Domains"

results << test(
  "Preserves YouTube short URL params",
  "https://youtu.be/abc123%26t=120",
  processor.process_url("https://youtu.be/abc123&t=120")
)

results << test(
  "Preserves Facebook params (encoded)",
  "https://facebook.com/post/123%26ref=share",
  processor.process_url("https://facebook.com/post/123&ref=share")
)

results << test(
  "Preserves bit.ly params (shortener keeps query)",
  "https://bit.ly/abc123?utm_source=x",
  processor.process_url("https://bit.ly/abc123?utm_source=x")
)

results << test(
  "Preserves Instagram params",
  "https://instagram.com/p/xyz%26igshid=abc",
  processor.process_url("https://instagram.com/p/xyz&igshid=abc")
)

puts

# ============================================================
# Test 3: Truncated URL detection
# ============================================================
puts "## Truncated URL Detection"

results << test(
  "Detects URL with ellipsis",
  true,
  processor.has_truncated_url?("Check https://example.com/very/long/path…")
)

results << test(
  "Detects URL with mid-ellipsis",
  true,
  processor.has_truncated_url?("Link: https://example.com/…/page")
)

results << test(
  "No false positive on normal text with ellipsis",
  false,
  processor.has_truncated_url?("This is nice… really nice")
)

results << test(
  "Detects www URL with ellipsis",
  true,
  processor.has_truncated_url?("Go to www.example.c…")
)

puts

# ============================================================
# Test 4: Truncated URL removal
# ============================================================
puts "## Truncated URL Removal"

results << test(
  "Removes truncated URL, keeps ellipsis marker",
  "Check this …",
  processor.remove_truncated_urls("Check this https://example.com/path…")
)

results << test(
  "Handles multiple truncated URLs",
  "Links: … and …",
  processor.remove_truncated_urls("Links: https://a.com/… and https://b.com/…")
)

results << test(
  "Normalizes multiple ellipses",
  "See …",
  processor.remove_truncated_urls("See https://example.com/…/path…")
)

puts

# ============================================================
# Test 5: Incomplete URL at end
# ============================================================
puts "## Incomplete URL at End"

results << test(
  "Detects URL ending with dot",
  true,
  processor.has_incomplete_url_at_end?("Check https://www.instagram.")
)

results << test(
  "Detects very short domain",
  true,
  processor.has_incomplete_url_at_end?("Go to https://www")
)

results << test(
  "Detects incomplete TLD",
  true,
  processor.has_incomplete_url_at_end?("Visit https://example.c")
)

results << test(
  "Detects protocol fragment",
  true,
  processor.has_incomplete_url_at_end?("More at http…")
)

results << test(
  "No false positive on complete URL",
  false,
  processor.has_incomplete_url_at_end?("See https://example.com/page")
)

puts

# ============================================================
# Test 6: Incomplete URL removal
# ============================================================
puts "## Incomplete URL Removal"

results << test(
  "Removes incomplete URL at end",
  "Check this article",
  processor.remove_incomplete_url_from_end("Check this article https://exampl")
)

results << test(
  "Keeps complete URL",
  "Read more https://example.com/article",
  processor.remove_incomplete_url_from_end("Read more https://example.com/article")
)

results << test(
  "Removes protocol fragment",
  "More info at",
  processor.remove_incomplete_url_from_end("More info at http…")
)

puts

# ============================================================
# Test 7: URL deduplication
# ============================================================
puts "## URL Deduplication"

results << test(
  "Removes duplicate URL at end",
  "Check https://example.com/page",
  processor.deduplicate_trailing_urls("Check https://example.com/page\nhttps://example.com/page")
)

results << test(
  "Handles URLs with different query params",
  "See https://example.com/page?a=1",
  processor.deduplicate_trailing_urls("See https://example.com/page?a=1\nhttps://example.com/page?b=2")
)

results << test(
  "Keeps different URLs",
  "Link https://a.com and https://b.com",
  processor.deduplicate_trailing_urls("Link https://a.com and https://b.com")
)

results << test(
  "Handles trailing newline",
  "Check https://example.com",
  processor.deduplicate_trailing_urls("Check https://example.com\n\nhttps://example.com")
)

puts

# ============================================================
# Test 8: Full content processing
# ============================================================
puts "## Full Content Processing"

results << test(
  "Processes URL with utm params in text",
  "Check https://example.com/article for more",
  processor.process_content("Check https://example.com/article?utm_source=x for more")
)

results << test(
  "Removes truncated URL and normalizes",
  "Read more …",
  processor.process_content("Read more https://example.com/very/long…")
)

results << test(
  "Deduplicates and trims in one pass",
  "News: https://news.com/story",
  processor.process_content("News: https://news.com/story?ref=tw\nhttps://news.com/story?ref=fb")
)

results << test(
  "Preserves YouTube URL in content",
  "Watch https://youtu.be/abc%26t=30",
  processor.process_content("Watch https://youtu.be/abc&t=30")
)

puts

# ============================================================
# Test 9: Edge cases
# ============================================================
puts "## Edge Cases"

results << test(
  "Empty string",
  "",
  processor.process_content("")
)

results << test(
  "Nil",
  "",
  processor.process_content(nil)
)

results << test(
  "Text without URLs",
  "Just plain text here",
  processor.process_content("Just plain text here")
)

results << test(
  "URL only",
  "https://example.com/page",
  processor.process_content("https://example.com/page?utm=x")
)

puts

# ============================================================
# Summary
# ============================================================
puts "=" * 60
passed = results.count(true)
total = results.length
puts "Results: #{passed}/#{total} tests passed"
puts "=" * 60

exit(passed == total ? 0 : 1)
