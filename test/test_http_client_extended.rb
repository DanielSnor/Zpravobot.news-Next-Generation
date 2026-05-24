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
# 3. ConnectionPool — edge cases pro různé URI
# =============================================================================
section("ConnectionPool: Edge Cases")

HttpClient.reset_pools!

uri_no_port = URI('https://api.example.com/v1/statuses')
pool1 = HttpClient.pool_for(uri_no_port)
http = pool1.checkout(HttpClient::DEFAULT_OPEN_TIMEOUT,
                      HttpClient::DEFAULT_READ_TIMEOUT,
                      HttpClient::CHECKOUT_TIMEOUT)
test("HTTPS default port 443", 443, http.port)
test("HTTPS SSL enabled", true, http.use_ssl?)
pool1.checkin(http)

uri_custom = URI('http://localhost:3000/api')
pool2 = HttpClient.pool_for(uri_custom)
http2 = pool2.checkout(3, 5, HttpClient::CHECKOUT_TIMEOUT)
test("Custom open_timeout 3", 3, http2.open_timeout)
test("Custom read_timeout 5", 5, http2.read_timeout)
test("HTTP no SSL", false, http2.use_ssl?)
pool2.checkin(http2)

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
test_no_error("pool_for accepts URI object") do
  HttpClient.pool_for(URI('https://example.com'))
end

test_no_error("pool_for accepts URI with path") do
  HttpClient.pool_for(URI('https://example.com/api/v1/statuses'))
end

# =============================================================================
# 6. ConnectionPool — chování poolu (R2 fix)
# =============================================================================
# Pool drží až MAX_POOL_SIZE_PER_HOST connections per host:port:scheme.
# Vlákna si přes checkout vyzvedávají exkluzivní vlastnictví, po dokončení
# checkin vrátí. Pokud je pool plný a vše in_use, čekající vlákno blokuje
# do CHECKOUT_TIMEOUT, pak vyhodí PoolTimeoutError.
section("ConnectionPool: pool behavior")

HttpClient.reset_pools!
test_uri = URI('https://pool-test.example.com')
test_pool = HttpClient.pool_for(test_uri)

# Reuse: checkout → checkin → checkout vrátí stejnou instanci
http_a = test_pool.checkout(5, 10, 1)
test_pool.checkin(http_a)
http_b = test_pool.checkout(5, 10, 1)
test("checkin → další checkout vrátí TUTÉŽ Net::HTTP instanci (keep-alive)",
     true, http_a.equal?(http_b))
test_pool.checkin(http_b)

# Pool roste do MAX_POOL_SIZE_PER_HOST když více vláken drží connections
held = []
HttpClient::MAX_POOL_SIZE_PER_HOST.times do |i|
  held << test_pool.checkout(5, 10, 1)
end
test("pool má #{HttpClient::MAX_POOL_SIZE_PER_HOST} entries při plném využití",
     HttpClient::MAX_POOL_SIZE_PER_HOST, test_pool.size)
test("všechny checkouts vrátily různé Net::HTTP instance",
     HttpClient::MAX_POOL_SIZE_PER_HOST, held.uniq.size)

# Plný pool → další checkout timeoutne s PoolTimeoutError
begin
  start_t = Time.now
  test_pool.checkout(5, 10, 0.1)  # 100ms timeout
  puts "  \e[31m✗\e[0m vyčerpaný pool MĚL vyhodit PoolTimeoutError"
  $failed += 1
rescue HttpClient::PoolTimeoutError => e
  elapsed = Time.now - start_t
  if elapsed >= 0.1 && elapsed < 0.5
    puts "  \e[32m✓\e[0m vyčerpaný pool vyhodil PoolTimeoutError v ~#{(elapsed*1000).round}ms"
    $passed += 1
  else
    puts "  \e[31m✗\e[0m PoolTimeoutError přišel, ale timing #{elapsed}s mimo očekávané ~0.1s"
    $failed += 1
  end
end

# Po checkin se waiter probudí (signal v checkin)
held.each { |h| test_pool.checkin(h) }
test("po vrácení všech connections je pool stále velikosti #{HttpClient::MAX_POOL_SIZE_PER_HOST}",
     HttpClient::MAX_POOL_SIZE_PER_HOST, test_pool.size)

# Stale connection drop uvolní slot
http_drop = test_pool.checkout(5, 10, 1)
size_before_drop = test_pool.size
test_pool.drop(http_drop)
test("drop snižuje velikost poolu (uvolňuje slot)",
     size_before_drop - 1, test_pool.size)

# Multi-thread concurrent checkout/checkin nezamrzne
HttpClient.reset_pools!
mt_uri = URI('https://multithread.example.com')
mt_pool = HttpClient.pool_for(mt_uri)

threads = 8.times.map do |i|
  Thread.new do
    h = mt_pool.checkout(5, 10, 2)
    sleep(0.01)  # simulate work
    mt_pool.checkin(h)
  end
end
threads.each(&:join)
test("8 vláken sériálně checkout/checkin nezamrzlo (pool size #{HttpClient::MAX_POOL_SIZE_PER_HOST})",
     true, mt_pool.size <= HttpClient::MAX_POOL_SIZE_PER_HOST)

HttpClient.reset_pools!

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
