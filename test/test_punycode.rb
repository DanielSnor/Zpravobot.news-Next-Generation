#!/usr/bin/env ruby
# frozen_string_literal: true

# Test PunycodeDecoder module
# Validates punycode domain decoding (IDN → Unicode)
# Run: ruby test/test_punycode.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/utils/punycode'

puts "=" * 60
puts "PunycodeDecoder Tests"
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
# punycode?
# =============================================================================
section("punycode?: Detection")

test("IDN domain detected", true, PunycodeDecoder.punycode?("xn--aktuln-sta08b.cz"))
test("Subdomain with IDN detected", true, PunycodeDecoder.punycode?("www.xn--aktuln-sta08b.cz"))
test("ASCII domain not detected", false, PunycodeDecoder.punycode?("example.com"))
test("nil returns false", false, PunycodeDecoder.punycode?(nil))
test("Empty string returns false", false, PunycodeDecoder.punycode?(""))
test("Case insensitive (XN--)", true, PunycodeDecoder.punycode?("XN--aktuln-sta08b.cz"))

# =============================================================================
# decode_domain
# =============================================================================
section("decode_domain: Basic")

test("Czech IDN: aktuálně.cz",
     "aktuálně.cz",
     PunycodeDecoder.decode_domain("xn--aktuln-sta08b.cz"))

test("With subdomain: www.aktuálně.cz",
     "www.aktuálně.cz",
     PunycodeDecoder.decode_domain("www.xn--aktuln-sta08b.cz"))

test("German IDN: münchen.de",
     "münchen.de",
     PunycodeDecoder.decode_domain("xn--mnchen-3ya.de"))

section("decode_domain: Passthrough")

test("ASCII domain unchanged", "example.com", PunycodeDecoder.decode_domain("example.com"))
test("nil returns nil", nil, PunycodeDecoder.decode_domain(nil))
test("Empty string returns empty", "", PunycodeDecoder.decode_domain(""))

# =============================================================================
# decode_url
# =============================================================================
section("decode_url: Basic")

test("URL with IDN domain",
     "https://aktuálně.cz/article",
     PunycodeDecoder.decode_url("https://xn--aktuln-sta08b.cz/article"))

test("URL with IDN domain and path",
     "https://aktuálně.cz/zpravy/domaci/clanek-12345",
     PunycodeDecoder.decode_url("https://xn--aktuln-sta08b.cz/zpravy/domaci/clanek-12345"))

test("URL with IDN domain and query",
     "https://aktuálně.cz/search?q=test",
     PunycodeDecoder.decode_url("https://xn--aktuln-sta08b.cz/search?q=test"))

test("URL with subdomain",
     "https://www.aktuálně.cz/article",
     PunycodeDecoder.decode_url("https://www.xn--aktuln-sta08b.cz/article"))

section("decode_url: Passthrough")

test("ASCII URL unchanged", "https://example.com/page", PunycodeDecoder.decode_url("https://example.com/page"))
test("nil returns nil", nil, PunycodeDecoder.decode_url(nil))
test("Empty string returns empty", "", PunycodeDecoder.decode_url(""))

section("decode_url: Edge cases")

test("URL with port",
     "https://aktuálně.cz:8080/path",
     PunycodeDecoder.decode_url("https://xn--aktuln-sta08b.cz:8080/path"))

test("HTTP (not HTTPS)",
     "http://aktuálně.cz/article",
     PunycodeDecoder.decode_url("http://xn--aktuln-sta08b.cz/article"))

test("Non-URL string returns unchanged", "not a url", PunycodeDecoder.decode_url("not a url"))

puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
