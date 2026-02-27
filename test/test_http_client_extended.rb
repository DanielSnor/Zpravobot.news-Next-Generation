#!/usr/bin/env ruby
# frozen_string_literal: true

# Test HttpClient Extended Methods (Phase 8 — #5)
# Validates POST, PUT, DELETE, download, retry logic (offline — no actual HTTP)
# Run: ruby test/test_http_client_extended.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/utils/http_client'
require_relative '../lib/errors'

puts "=" * 60
puts "HttpClient Extended Methods Tests (Offline)"
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

def section(title)
  puts
  puts "--- #{title} ---"
end

# =============================================================================
# 1. Module methods exist
# =============================================================================
section("Extended Module Interface")

test("post_json is a method", true, HttpClient.respond_to?(:post_json))
test("post_raw is a method", true, HttpClient.respond_to?(:post_raw))
test("put_json is a method", true, HttpClient.respond_to?(:put_json))
test("patch_raw is a method", true, HttpClient.respond_to?(:patch_raw))
test("delete is a method", true, HttpClient.respond_to?(:delete))
test("download is a method", true, HttpClient.respond_to?(:download))
test("request_with_retry is a method", true, HttpClient.respond_to?(:request_with_retry))
test("get_with_retry is a method", true, HttpClient.respond_to?(:get_with_retry))

# =============================================================================
# 2. Constants
# =============================================================================
section("Extended Constants")

test("RETRIABLE_ERRORS is an Array", true, HttpClient::RETRIABLE_ERRORS.is_a?(Array))
test("RETRIABLE_ERRORS includes Net::OpenTimeout", true,
     HttpClient::RETRIABLE_ERRORS.include?(Net::OpenTimeout))
test("RETRIABLE_ERRORS includes Net::ReadTimeout", true,
     HttpClient::RETRIABLE_ERRORS.include?(Net::ReadTimeout))
test("RETRIABLE_ERRORS includes Errno::ECONNREFUSED", true,
     HttpClient::RETRIABLE_ERRORS.include?(Errno::ECONNREFUSED))
test("RETRIABLE_ERRORS includes Zpravobot::NetworkError", true,
     HttpClient::RETRIABLE_ERRORS.include?(Zpravobot::NetworkError))

# =============================================================================
# 3. build_http for various URIs
# =============================================================================
section("build_http: Edge Cases")

uri_no_port = URI('https://api.example.com/v1/statuses')
http = HttpClient.build_http(uri_no_port)
test("HTTPS default port 443", 443, http.port)
test("HTTPS SSL enabled", true, http.use_ssl?)

uri_custom = URI('http://localhost:3000/api')
http2 = HttpClient.build_http(uri_custom, open_timeout: 3, read_timeout: 5)
test("Custom open_timeout 3", 3, http2.open_timeout)
test("Custom read_timeout 5", 5, http2.read_timeout)
test("HTTP no SSL", false, http2.use_ssl?)

# =============================================================================
# 4. Error hierarchy used in RETRIABLE_ERRORS
# =============================================================================
section("Error Hierarchy in Retry Logic")

# Verify Zpravobot::NetworkError subclasses are catchable via RETRIABLE_ERRORS
network_err = Zpravobot::NetworkError.new("test")
test("NetworkError is-a StandardError", true, network_err.is_a?(StandardError))

rate_err = Zpravobot::RateLimitError.new(retry_after: 10)
test("RateLimitError is-a NetworkError", true, rate_err.is_a?(Zpravobot::NetworkError))
test("RateLimitError retry_after", 10, rate_err.retry_after)

server_err = Zpravobot::ServerError.new(status_code: 502)
test("ServerError is-a NetworkError", true, server_err.is_a?(Zpravobot::NetworkError))
test("ServerError status_code", 502, server_err.status_code)

# =============================================================================
# 5. URI parsing in methods (string vs URI object)
# =============================================================================
section("URI Handling")

# Verify methods accept both String and URI
test_no_error("build_http accepts URI object") do
  HttpClient.build_http(URI('https://example.com'))
end

test_no_error("build_http accepts URI with path") do
  HttpClient.build_http(URI('https://example.com/api/v1/statuses'))
end

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
