#!/usr/bin/env ruby
# frozen_string_literal: true

# Test Zpravobot Error Hierarchy (Phase 8 — #11)
# Validates inheritance, attributes, and rescue patterns
# Run: ruby test/test_errors.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/errors'

puts "=" * 60
puts "Zpravobot Error Hierarchy Tests"
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

def test_no_error(name, &block)
  begin
    block.call
    puts "  \e[32m\u2713\e[0m #{name}"
    $passed += 1
  rescue => e
    puts "  \e[31m\u2717\e[0m #{name}"
    puts "    Unexpected error: #{e.class}: #{e.message}"
    $failed += 1
  end
end

def test_raises(name, exception_class, &block)
  begin
    block.call
    puts "  \e[31m\u2717\e[0m #{name} (no exception raised)"
    $failed += 1
  rescue exception_class
    puts "  \e[32m\u2713\e[0m #{name}"
    $passed += 1
  rescue => e
    puts "  \e[31m\u2717\e[0m #{name}"
    puts "    Expected: #{exception_class}"
    puts "    Got:      #{e.class}: #{e.message}"
    $failed += 1
  end
end

def section(title)
  puts
  puts "--- #{title} ---"
end

# =============================================================================
# 1. Inheritance Chain
# =============================================================================
section("Inheritance Chain")

test("Error < StandardError", true, Zpravobot::Error < StandardError)
test("NetworkError < Error", true, Zpravobot::NetworkError < Zpravobot::Error)
test("RateLimitError < NetworkError", true, Zpravobot::RateLimitError < Zpravobot::NetworkError)
test("ServerError < NetworkError", true, Zpravobot::ServerError < Zpravobot::NetworkError)
test("ConfigError < Error", true, Zpravobot::ConfigError < Zpravobot::Error)
test("PublishError < Error", true, Zpravobot::PublishError < Zpravobot::Error)
test("AdapterError < Error", true, Zpravobot::AdapterError < Zpravobot::Error)
test("StateError < Error", true, Zpravobot::StateError < Zpravobot::Error)
test("StatusNotFoundError < PublishError", true, Zpravobot::StatusNotFoundError < Zpravobot::PublishError)
test("EditNotAllowedError < PublishError", true, Zpravobot::EditNotAllowedError < Zpravobot::PublishError)
test("ValidationError < PublishError", true, Zpravobot::ValidationError < Zpravobot::PublishError)

# =============================================================================
# 2. RateLimitError attributes
# =============================================================================
section("RateLimitError")

e = Zpravobot::RateLimitError.new
test("Default message", "Rate limited", e.message)
test("Default retry_after", 5, e.retry_after)

e2 = Zpravobot::RateLimitError.new("Custom rate limit", retry_after: 30)
test("Custom message", "Custom rate limit", e2.message)
test("Custom retry_after", 30, e2.retry_after)

# =============================================================================
# 3. ServerError attributes
# =============================================================================
section("ServerError")

e3 = Zpravobot::ServerError.new
test("Default message includes 500", true, e3.message.include?('500'))
test("Default status_code", 500, e3.status_code)

e4 = Zpravobot::ServerError.new("Bad gateway", status_code: 502)
test("Custom message", "Bad gateway", e4.message)
test("Custom status_code", 502, e4.status_code)

e5 = Zpravobot::ServerError.new(status_code: 503)
test("Auto-generated message includes status", true, e5.message.include?('503'))

# =============================================================================
# 4. Rescue patterns — catch-all
# =============================================================================
section("Rescue Patterns: catch-all")

caught_by_base = false
begin
  raise Zpravobot::RateLimitError.new(retry_after: 10)
rescue Zpravobot::Error
  caught_by_base = true
end
test("RateLimitError caught by Zpravobot::Error", true, caught_by_base)

caught_by_network = false
begin
  raise Zpravobot::ServerError.new(status_code: 503)
rescue Zpravobot::NetworkError
  caught_by_network = true
end
test("ServerError caught by NetworkError", true, caught_by_network)

caught_by_publish = false
begin
  raise Zpravobot::StatusNotFoundError, "Not found"
rescue Zpravobot::PublishError
  caught_by_publish = true
end
test("StatusNotFoundError caught by PublishError", true, caught_by_publish)

caught_by_standard = false
begin
  raise Zpravobot::ConfigError, "Missing key"
rescue StandardError
  caught_by_standard = true
end
test("ConfigError caught by StandardError", true, caught_by_standard)

# =============================================================================
# 5. Simple errors — message only
# =============================================================================
section("Simple Errors: message")

test("ConfigError message", "Missing token", Zpravobot::ConfigError.new("Missing token").message)
test("PublishError message", "API failed", Zpravobot::PublishError.new("API failed").message)
test("AdapterError message", "Fetch failed", Zpravobot::AdapterError.new("Fetch failed").message)
test("StateError message", "DB error", Zpravobot::StateError.new("DB error").message)
test("StatusNotFoundError message", "404", Zpravobot::StatusNotFoundError.new("404").message)
test("EditNotAllowedError message", "403", Zpravobot::EditNotAllowedError.new("403").message)
test("ValidationError message", "422", Zpravobot::ValidationError.new("422").message)

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
