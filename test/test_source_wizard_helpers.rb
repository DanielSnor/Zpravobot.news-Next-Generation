#!/usr/bin/env ruby
# frozen_string_literal: true

# Test SourceGenerator helpers (Phase 10.8)
# Validates sanitize_handle, parse_categories, sanitize_id, extract_domain, yaml_quote
# Run: ruby test/test_source_wizard_helpers.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/source_wizard/helpers'

puts "=" * 60
puts "SourceGenerator Helpers Tests"
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

gen = SourceGenerator.new

# =============================================================================
# sanitize_handle
# =============================================================================
section("sanitize_handle")

test("strips leading @", 'username', gen.sanitize_handle('@username'))
test("strips leading @ after strip", 'user', gen.sanitize_handle('@user  '))
test("leading whitespace before @ preserved as-is", '@user', gen.sanitize_handle('  @user  '))
test("nil returns empty string", '', gen.sanitize_handle(nil))
test("plain handle unchanged", 'alice', gen.sanitize_handle('alice'))

# =============================================================================
# parse_categories
# =============================================================================
section("parse_categories")

test("comma-separated string", ['a', 'b', 'c'], gen.parse_categories('a, b, c'))
test("nil returns empty array", [], gen.parse_categories(nil))
test("empty string returns empty array", [], gen.parse_categories(''))
test("empty entries rejected", ['a', 'b'], gen.parse_categories('a,,b'))
test("strips whitespace from each", ['foo', 'bar'], gen.parse_categories('  foo , bar  '))

# =============================================================================
# sanitize_id
# =============================================================================
section("sanitize_id")

test("strips @ and .bsky.social", 'alice', gen.sanitize_id('@alice.bsky.social'))
test("non-alphanumeric to underscore", 'hello_world', gen.sanitize_id('hello.world'))
test("multiple underscores collapsed", 'a_b', gen.sanitize_id('a___b'))
test("lowercased", 'foobar', gen.sanitize_id('FooBar'))
test("leading/trailing underscores stripped", 'test', gen.sanitize_id('_test_'))

# =============================================================================
# extract_domain
# =============================================================================
section("extract_domain")

test("extracts domain from URL", 'example', gen.extract_domain('https://example.com/feed'))
test("strips www prefix", 'example', gen.extract_domain('https://www.example.com'))
test("invalid URL returns feed fallback", 'feed', gen.extract_domain('not a url'))

# =============================================================================
# yaml_quote
# =============================================================================
section("yaml_quote")

test("nil returns empty quotes", '""', gen.yaml_quote(nil))
test("empty string returns empty quotes", '""', gen.yaml_quote(''))
test("simple string double-quoted", '"Hello"', gen.yaml_quote('Hello'))
test("string with double quotes uses single quotes", "'Jana \"Dezinfo\"'", gen.yaml_quote('Jana "Dezinfo"'))
test("string with special YAML chars quoted", true, gen.yaml_quote('key: value').start_with?('"'))

# =============================================================================
# extract_instance_domain
# =============================================================================
section("extract_instance_domain")

test("strips https://", 'mastodon.social', gen.extract_instance_domain('https://mastodon.social'))
test("strips http://", 'example.com', gen.extract_instance_domain('http://example.com'))
test("strips trailing path", 'mastodon.social', gen.extract_instance_domain('https://mastodon.social/api/v1'))
test("nil returns empty", '', gen.extract_instance_domain(nil))

# =============================================================================
# platform_label
# =============================================================================
section("platform_label")

test("twitter label", 'Twitter', gen.platform_label('twitter'))
test("bluesky label", 'Bluesky', gen.platform_label('bluesky'))
test("rss label", 'RSS', gen.platform_label('rss'))
test("youtube label", 'YouTube', gen.platform_label('youtube'))
test("unknown capitalizes", 'Mastodon', gen.platform_label('mastodon'))

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
