#!/usr/bin/env ruby
# frozen_string_literal: true

# Test ContentFilter - verify identical behavior to IFTTT filter
# Run: ruby test/test_content_filter.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/processors/content_filter'

puts "=" * 70
puts "ContentFilter Test Suite - IFTTT Compatibility"
puts "=" * 70
puts

# Test counter
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

def section(title)
  puts
  puts "-" * 70
  puts "📋 #{title}"
  puts "-" * 70
end

# =============================================================================
# TEST 1: Simple string matching (case-insensitive substring)
# =============================================================================
section("1. Simple String Matching")

filter = Processors::ContentFilter.new(
  banned_phrases: ["spam", "NSFW", "🔞"]
)

test("Simple match - lowercase", true, filter.banned?("This is spam content"))
test("Simple match - uppercase", true, filter.banned?("This is SPAM content"))
test("Simple match - mixed case", true, filter.banned?("This is SpAm content"))
test("No match", false, filter.banned?("This is clean content"))
test("Emoji match", true, filter.banned?("Adult content 🔞 here"))
test("Empty string", false, filter.banned?(""))
test("Nil string", false, filter.banned?(nil))

# =============================================================================
# TEST 2: Literal type
# =============================================================================
section("2. Literal Type")

filter = Processors::ContentFilter.new(
  banned_phrases: [
    { type: "literal", pattern: "bad word" }
  ]
)

test("Literal match", true, filter.banned?("Contains bad word here"))
test("Literal case-insensitive", true, filter.banned?("Contains BAD WORD here"))
test("Literal no match", false, filter.banned?("Contains good content"))

# =============================================================================
# TEST 3: Regex type
# =============================================================================
section("3. Regex Type")

filter = Processors::ContentFilter.new(
  banned_phrases: [
    { type: "regex", pattern: "\\bsale\\b", flags: "i" },
    { type: "regex", pattern: "\\d{4}-\\d{4}-\\d{4}" }  # Credit card pattern
  ]
)

test("Regex word boundary match", true, filter.banned?("Big sale today!"))
test("Regex no match (partial)", false, filter.banned?("wholesale products"))
test("Regex pattern match", true, filter.banned?("Card: 1234-5678-9012"))
test("Regex no match", false, filter.banned?("Normal text here"))

# =============================================================================
# TEST 4: OR type (any must match)
# =============================================================================
section("4. OR Type")

filter = Processors::ContentFilter.new(
  banned_phrases: [
    { type: "or", content: ["spam", "scam", "phishing"] }
  ]
)

test("OR - first matches", true, filter.banned?("This is spam"))
test("OR - second matches", true, filter.banned?("Possible scam alert"))
test("OR - third matches", true, filter.banned?("Phishing attempt"))
test("OR - none match", false, filter.banned?("Clean content"))

# =============================================================================
# TEST 5: AND type (all must match)
# =============================================================================
section("5. AND Type")

filter = Processors::ContentFilter.new(
  banned_phrases: [
    { type: "and", content: ["urgent", "action", "required"] }
  ]
)

test("AND - all match", true, filter.banned?("URGENT: Action required immediately"))
test("AND - only two match", false, filter.banned?("Urgent action needed"))
test("AND - only one matches", false, filter.banned?("Urgent message"))

# =============================================================================
# TEST 6: NOT type (none should match)
# =============================================================================
section("6. NOT Type")

filter = Processors::ContentFilter.new(
  banned_phrases: [
    { type: "not", content: ["safe", "verified", "trusted"] }
  ]
)

test("NOT - contains safe", false, filter.banned?("This is safe content"))
test("NOT - contains verified", false, filter.banned?("Verified source"))
test("NOT - contains none", true, filter.banned?("Unknown content"))

# =============================================================================
# TEST 7: Complex type (nested rules)
# =============================================================================
section("7. Complex Type")

filter = Processors::ContentFilter.new(
  banned_phrases: [
    {
      type: "complex",
      operator: "and",
      rules: [
        { type: "literal", pattern: "bitcoin" },
        { type: "or", content: ["invest", "profit", "guarantee"] }
      ]
    }
  ]
)

test("Complex AND - all rules match", true, filter.banned?("Invest in bitcoin now!"))
test("Complex AND - only first rule", false, filter.banned?("Bitcoin news today"))
test("Complex AND - only second rule", false, filter.banned?("Invest in stocks"))

# OR operator
filter2 = Processors::ContentFilter.new(
  banned_phrases: [
    {
      type: "complex",
      operator: "or",
      rules: [
        { type: "regex", pattern: "\\bcrypto\\b" },
        { type: "regex", pattern: "\\bnft\\b" }
      ]
    }
  ]
)

test("Complex OR - first matches", true, filter2.banned?("Buy crypto now"))
test("Complex OR - second matches", true, filter2.banned?("New NFT collection"))
test("Complex OR - none match", false, filter2.banned?("Stock market news"))

# =============================================================================
# TEST 8: Required keywords (hasRequiredKeywords equivalent)
# =============================================================================
section("8. Required Keywords")

# Empty required = always satisfied
filter = Processors::ContentFilter.new(required_keywords: [])
test("Empty required - always true", true, filter.has_required?("Any content"))

# With required keywords
filter = Processors::ContentFilter.new(
  required_keywords: ["breaking", "news", "alert"]
)

test("Required - first matches", true, filter.has_required?("Breaking story today"))
test("Required - second matches", true, filter.has_required?("Latest news update"))
test("Required - none match", false, filter.has_required?("Regular content"))
test("Required - empty string", false, filter.has_required?(""))
test("Required - nil", false, filter.has_required?(nil))

# =============================================================================
# TEST 9: Content Replacements
# =============================================================================
section("9. Content Replacements")

filter = Processors::ContentFilter.new(
  content_replacements: [
    { pattern: "twitter", replacement: "X", flags: "gi" },
    { pattern: "tweet", replacement: "post", flags: "gi" },
    { pattern: "\\bRT\\b", replacement: "repost", flags: "gi" }
  ]
)

test("Replace twitter->X", "Check X for updates", filter.apply_replacements("Check Twitter for updates"))
test("Replace case-insensitive", "X and X", filter.apply_replacements("Twitter and TWITTER"))
test("Replace tweet->post", "New post today", filter.apply_replacements("New tweet today"))
test("Replace with regex", "repost this please", filter.apply_replacements("RT this please"))
test("Multiple replacements", "X post shared", filter.apply_replacements("Twitter tweet shared"))

# Literal flag
filter2 = Processors::ContentFilter.new(
  content_replacements: [
    { pattern: "a.b", replacement: "X", literal: true },
    { pattern: "a.b", replacement: "Y" }  # regex (default)
  ]
)

test("Literal vs regex - literal", "X", filter2.apply_replacements("a.b"))
# Note: regex "a.b" matches "aXb" too, but we test the order of processing

# Invalid regex should be skipped
filter3 = Processors::ContentFilter.new(
  content_replacements: [
    { pattern: "[invalid(regex", replacement: "X" },
    { pattern: "valid", replacement: "VALID" }
  ]
)

test("Invalid regex skipped", "VALID text", filter3.apply_replacements("valid text"))

# =============================================================================
# TEST 10: Combined check() method
# =============================================================================
section("10. Combined Check")

filter = Processors::ContentFilter.new(
  banned_phrases: ["spam"],
  required_keywords: ["news"]
)

result = filter.check("spam news")
test("Check - banned wins", false, result[:pass])
test("Check - reason is banned", "banned_phrase", result[:reason])

result = filter.check("regular content")
test("Check - missing required", false, result[:pass])
test("Check - reason is missing", "missing_required_keyword", result[:reason])

result = filter.check("breaking news")
test("Check - passes", true, result[:pass])
test("Check - no reason", nil, result[:reason])

# =============================================================================
# TEST 11: Regex with contentRegex array
# =============================================================================
section("11. Unified Filter with contentRegex")

filter = Processors::ContentFilter.new(
  banned_phrases: [
    {
      type: "or",
      content: ["spam"],
      contentRegex: ["\\bfree\\s+money\\b", "\\bclick\\s+here\\b"]
    }
  ]
)

test("contentRegex match 1", true, filter.banned?("Get free money now!"))
test("contentRegex match 2", true, filter.banned?("Click here to win"))
test("content literal match", true, filter.banned?("This is spam"))
test("no match", false, filter.banned?("Normal newsletter"))

# =============================================================================
# TEST 12: Edge cases
# =============================================================================
section("12. Edge Cases")

filter = Processors::ContentFilter.new(
  banned_phrases: ["test"],
  required_keywords: ["required"]
)

test("Empty banned list", false, Processors::ContentFilter.new.banned?("anything"))
test("Empty required list", true, Processors::ContentFilter.new.has_required?("anything"))
test("Apply replacements to empty", "", filter.apply_replacements(""))
test("Apply replacements to nil", "", filter.apply_replacements(nil))

# Unicode handling
filter = Processors::ContentFilter.new(
  banned_phrases: ["škoda", "člověk"]
)

test("Czech chars - match", true, filter.banned?("Velká škoda"))
test("Czech chars - case insensitive", true, filter.banned?("ŠKODA auto"))

# =============================================================================
# SUMMARY
# =============================================================================
puts
puts "=" * 70
puts "SUMMARY"
puts "=" * 70
puts "Passed: #{$passed}"
puts "Failed: #{$failed}"
puts
if $failed == 0
  puts "✅ All tests passed! Implementation is compatible with IFTTT filter."
else
  puts "❌ Some tests failed. Please review the implementation."
end
puts
