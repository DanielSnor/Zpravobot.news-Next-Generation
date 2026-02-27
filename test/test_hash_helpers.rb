#!/usr/bin/env ruby
# frozen_string_literal: true

# Test HashHelpers module
# Validates symbolize_keys, deep_merge, deep_merge_all
# Run: ruby test/test_hash_helpers.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/utils/hash_helpers'

puts "=" * 60
puts "HashHelpers Tests"
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
# symbolize_keys
# =============================================================================
section("symbolize_keys: Basic")

test("String keys to symbols", { a: 1, b: 2 }, HashHelpers.symbolize_keys('a' => 1, 'b' => 2))
test("Symbol keys unchanged", { a: 1 }, HashHelpers.symbolize_keys(a: 1))
test("Mixed keys", { a: 1, b: 2 }, HashHelpers.symbolize_keys('a' => 1, b: 2))
test("Empty hash", {}, HashHelpers.symbolize_keys({}))

section("symbolize_keys: Nested")

input = { 'outer' => { 'inner' => 'value' } }
expected = { outer: { inner: 'value' } }
test("Nested hashes symbolized", expected, HashHelpers.symbolize_keys(input))

deep_input = { 'a' => { 'b' => { 'c' => 1 } } }
deep_expected = { a: { b: { c: 1 } } }
test("Deeply nested hashes", deep_expected, HashHelpers.symbolize_keys(deep_input))

section("symbolize_keys: Edge Cases")

test("Non-hash input returns empty hash", {}, HashHelpers.symbolize_keys(nil))
test("String input returns empty hash", {}, HashHelpers.symbolize_keys("not a hash"))
test("Array values preserved", { a: [1, 2, 3] }, HashHelpers.symbolize_keys('a' => [1, 2, 3]))

# =============================================================================
# deep_merge
# =============================================================================
section("deep_merge: Basic")

test("Flat merge", { a: 1, b: 2, c: 3 },
     HashHelpers.deep_merge({ a: 1, b: 2 }, { c: 3 }))

test("Override wins", { a: 2 },
     HashHelpers.deep_merge({ a: 1 }, { a: 2 }))

test("Nil in override preserves base", { a: 1 },
     HashHelpers.deep_merge({ a: 1 }, { a: nil }))

section("deep_merge: Nested")

base = { settings: { timeout: 10, retries: 3 }, name: 'base' }
override = { settings: { timeout: 20 }, name: 'override' }
expected = { settings: { timeout: 20, retries: 3 }, name: 'override' }
test("Nested merge preserves unset keys", expected, HashHelpers.deep_merge(base, override))

section("deep_merge: Edge Cases")

test("Empty override returns base", { a: 1 }, HashHelpers.deep_merge({ a: 1 }, {}))
test("Empty base returns override", { a: 1 }, HashHelpers.deep_merge({}, { a: 1 }))
test("Both empty", {}, HashHelpers.deep_merge({}, {}))

# Override replaces non-hash with hash
test("Non-hash replaced by hash", { a: { b: 1 } },
     HashHelpers.deep_merge({ a: 'string' }, { a: { b: 1 } }))

# =============================================================================
# deep_merge_all
# =============================================================================
section("deep_merge_all")

result = HashHelpers.deep_merge_all(
  { a: 1, b: { x: 1 } },
  { b: { y: 2 }, c: 3 },
  { a: 10 }
)
test("Three hashes merged", { a: 10, b: { x: 1, y: 2 }, c: 3 }, result)

test("Single hash returns itself", { a: 1 }, HashHelpers.deep_merge_all({ a: 1 }))
test("No hashes returns empty", {}, HashHelpers.deep_merge_all)

# Skips nil
result2 = HashHelpers.deep_merge_all({ a: 1 }, nil, { b: 2 })
test("Skips nil arguments", { a: 1, b: 2 }, result2)

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
