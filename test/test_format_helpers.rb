#!/usr/bin/env ruby
# frozen_string_literal: true

# Test FormatHelpers module
# Validates clean_text and format_bytes
# Run: ruby test/test_format_helpers.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/utils/format_helpers'

puts "=" * 60
puts "FormatHelpers Tests"
puts "=" * 60
puts

$passed = 0
$failed = 0

def test(name, expected, actual)
  if expected == actual
    puts "  \e[32m\u2713\e[0m #{name}"
    $passed += 1
  else
    puts "  \e[31m\u2717\e[0m #{name}"
    puts "    Expected: #{expected.inspect}"
    puts "    Actual:   #{actual.inspect}"
    $failed += 1
  end
end

def section(title)
  puts
  puts "--- #{title} ---"
end

# =============================================================================
# clean_text
# =============================================================================
section("clean_text: Whitespace Normalization")

test("Multiple spaces to single", "hello world", FormatHelpers.clean_text("hello   world"))
test("Tabs to single space", "hello world", FormatHelpers.clean_text("hello\tworld"))
test("Mixed spaces and tabs", "hello world", FormatHelpers.clean_text("hello \t  world"))
test("Leading/trailing whitespace stripped", "hello", FormatHelpers.clean_text("  hello  "))

section("clean_text: Newline Handling")

test("Single newline preserved", "line1\nline2", FormatHelpers.clean_text("line1\nline2"))
test("Double newline preserved", "line1\n\nline2", FormatHelpers.clean_text("line1\n\nline2"))
test("Triple+ newlines reduced to double", "line1\n\nline2", FormatHelpers.clean_text("line1\n\n\nline2"))
test("Many newlines reduced", "a\n\nb", FormatHelpers.clean_text("a\n\n\n\n\nb"))

section("clean_text: Line Whitespace Trimming")

test("Leading whitespace on lines removed", "line1\nline2", FormatHelpers.clean_text("line1\n  line2"))
test("Trailing whitespace on lines removed", "line1\nline2", FormatHelpers.clean_text("line1  \nline2"))

section("clean_text: Edge Cases")

test("Nil returns empty string", '', FormatHelpers.clean_text(nil))
test("Empty string returns empty", '', FormatHelpers.clean_text(''))
test("Already clean text unchanged", 'hello world', FormatHelpers.clean_text('hello world'))

# =============================================================================
# format_bytes
# =============================================================================
section("format_bytes")

test("Bytes (small)", "500 B", FormatHelpers.format_bytes(500))
test("Bytes (zero)", "0 B", FormatHelpers.format_bytes(0))
test("Kilobytes", "1.5 KB", FormatHelpers.format_bytes(1536))
test("Megabytes", "2.0 MB", FormatHelpers.format_bytes(2 * 1024 * 1024))
test("Just under 1 KB", "1023 B", FormatHelpers.format_bytes(1023))
test("Exactly 1 KB", "1.0 KB", FormatHelpers.format_bytes(1024))
test("Exactly 1 MB", "1.0 MB", FormatHelpers.format_bytes(1024 * 1024))

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
