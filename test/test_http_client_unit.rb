#!/usr/bin/env ruby
# frozen_string_literal: true

# Test HttpClient module (offline — no actual HTTP calls)
# Validates configuration, URL parsing, HTTP object building
# Run: ruby test/test_http_client_unit.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/utils/http_client'

puts "=" * 60
puts "HttpClient Unit Tests (Offline)"
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
# 1. Constants
# =============================================================================
section("Constants")

test("DEFAULT_UA defined", true, HttpClient::DEFAULT_UA.is_a?(String))
test("DEFAULT_UA contains Zpravobot", true, HttpClient::DEFAULT_UA.include?('Zpravobot'))
test("GOOGLEBOT_UA defined", true, HttpClient::GOOGLEBOT_UA.is_a?(String))
test("GOOGLEBOT_UA contains Googlebot", true, HttpClient::GOOGLEBOT_UA.include?('Googlebot'))

test("DEFAULT_OPEN_TIMEOUT is 10", 10, HttpClient::DEFAULT_OPEN_TIMEOUT)
test("DEFAULT_READ_TIMEOUT is 30", 30, HttpClient::DEFAULT_READ_TIMEOUT)
test("DEFAULT_MAX_RETRIES is 3", 3, HttpClient::DEFAULT_MAX_RETRIES)
test("DEFAULT_RETRY_DELAYS frozen", true, HttpClient::DEFAULT_RETRY_DELAYS.frozen?)
test("DEFAULT_RETRY_DELAYS values", [1, 2, 4], HttpClient::DEFAULT_RETRY_DELAYS)

# =============================================================================
# 2. ConnectionPool — HTTPS configuration
# =============================================================================
# Po refaktoru (R2) sahá execute na pool přes pool_for(uri); build_http už
# není veřejné API. Testy ověřují, že pool vyrobí správně nakonfigurované
# Net::HTTP instance pro různé URI a timeouty.
section("ConnectionPool: HTTPS")

HttpClient.reset_pools!  # čistý start

uri_https = URI('https://example.com/path')
pool_https = HttpClient.pool_for(uri_https)
http_https = pool_https.checkout(HttpClient::DEFAULT_OPEN_TIMEOUT,
                                  HttpClient::DEFAULT_READ_TIMEOUT,
                                  HttpClient::CHECKOUT_TIMEOUT)

test("HTTPS: returns Net::HTTP", true, http_https.is_a?(Net::HTTP))
test("HTTPS: use_ssl is true", true, http_https.use_ssl?)
test("HTTPS: host is correct", 'example.com', http_https.address)
test("HTTPS: port is 443", 443, http_https.port)
test("HTTPS: open_timeout default", 10, http_https.open_timeout)
test("HTTPS: read_timeout default", 30, http_https.read_timeout)

pool_https.checkin(http_https)

# =============================================================================
# 3. ConnectionPool — HTTP
# =============================================================================
section("ConnectionPool: HTTP")

uri_http = URI('http://localhost:8080/rss')
pool_http = HttpClient.pool_for(uri_http)
http_plain = pool_http.checkout(HttpClient::DEFAULT_OPEN_TIMEOUT,
                                 HttpClient::DEFAULT_READ_TIMEOUT,
                                 HttpClient::CHECKOUT_TIMEOUT)

test("HTTP: use_ssl is false", false, http_plain.use_ssl?)
test("HTTP: host is correct", 'localhost', http_plain.address)
test("HTTP: port is 8080", 8080, http_plain.port)

pool_http.checkin(http_plain)

# =============================================================================
# 4. ConnectionPool — Custom timeouts
# =============================================================================
section("ConnectionPool: Custom Timeouts")

http_custom = pool_https.checkout(5, 15, HttpClient::CHECKOUT_TIMEOUT)
test("Custom open_timeout", 5, http_custom.open_timeout)
test("Custom read_timeout", 15, http_custom.read_timeout)
pool_https.checkin(http_custom)

# =============================================================================
# 5. Module functions are accessible
# =============================================================================
section("Module Interface")

test("get is a method", true, HttpClient.respond_to?(:get))
test("head is a method", true, HttpClient.respond_to?(:head))
test("get_with_retry is a method", true, HttpClient.respond_to?(:get_with_retry))
test("execute is a method", true, HttpClient.respond_to?(:execute))
test("pool_for is a method", true, HttpClient.respond_to?(:pool_for))
test("ConnectionPool is a class", true, HttpClient::ConnectionPool.is_a?(Class))

HttpClient.reset_pools!  # cleanup po testech

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
