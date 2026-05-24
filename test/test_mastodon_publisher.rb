#!/usr/bin/env ruby
# frozen_string_literal: true

# Test MastodonPublisher — constants, validation, parsing (Phase 10.4)
# Tests ONLY methods that don't require HTTP calls.
# Run: ruby test/test_mastodon_publisher.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/publishers/mastodon_publisher'

puts "=" * 60
puts "MastodonPublisher Tests (offline)"
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
# Constants
# =============================================================================
section("Constants")

test("MAX_STATUS_LENGTH is 2500", 2500, Publishers::MastodonPublisher::MAX_STATUS_LENGTH)
test("MAX_MEDIA_SIZE is 10MB", 10 * 1024 * 1024, Publishers::MastodonPublisher::MAX_MEDIA_SIZE)
test("MAX_MEDIA_COUNT is 4", 4, Publishers::MastodonPublisher::MAX_MEDIA_COUNT)

# =============================================================================
# initialize + validate_credentials!
# =============================================================================
section("initialize + validate_credentials!")

pub = Publishers::MastodonPublisher.new(instance_url: 'https://mastodon.social/', access_token: 'tok123')
test("stores instance_url (strips trailing /)", 'https://mastodon.social', pub.instance_url)
test("stores access_token", 'tok123', pub.access_token)

test_raises("raises ConfigError for empty instance_url", Zpravobot::ConfigError) do
  Publishers::MastodonPublisher.new(instance_url: '', access_token: 'tok')
end

test_raises("raises NoMethodError for nil instance_url (chomp before validation)", NoMethodError) do
  Publishers::MastodonPublisher.new(instance_url: nil, access_token: 'tok')
end

test_raises("raises ConfigError for empty access_token", Zpravobot::ConfigError) do
  Publishers::MastodonPublisher.new(instance_url: 'https://example.com', access_token: '')
end

test_raises("raises ConfigError for nil access_token", Zpravobot::ConfigError) do
  Publishers::MastodonPublisher.new(instance_url: 'https://example.com', access_token: nil)
end

# =============================================================================
# publish — input validation (raises BEFORE HTTP)
# =============================================================================
section("publish — input validation")

pub2 = Publishers::MastodonPublisher.new(instance_url: 'https://example.com', access_token: 'tok')

test_raises("raises ArgumentError for empty text without media", ArgumentError) do
  pub2.publish('')
end

test_raises("raises ArgumentError for nil text without media", ArgumentError) do
  pub2.publish(nil)
end

long_text = 'x' * 2501
test_raises("raises ArgumentError for text > MAX_STATUS_LENGTH", ArgumentError) do
  pub2.publish(long_text)
end

# Tyto cesty by drive vedly na HTTP a overovali jsme jen ze NEpadne ArgumentError -
# delaly ale skutecne volani na example.com (log noise, sum v reportu). Misto toho
# stubujeme api_post; test prochazi pokud publish projde validacnim guardem bez raise.
MockHttpResponse = Struct.new(:code, :body) unless defined?(MockHttpResponse)
def make_stub_publisher(instance_url:, access_token:)
  pub = Publishers::MastodonPublisher.new(instance_url: instance_url, access_token: access_token)
  pub.define_singleton_method(:api_post) do |_path, _params|
    MockHttpResponse.new('200', '{"id":"123","url":"https://example.com/123"}')
  end
  pub
end

stub_pub = make_stub_publisher(instance_url: 'https://example.com', access_token: 'tok')

test_no_error("empty text with media projde validaci (api_post stubovan)") do
  stub_pub.publish('', media_ids: ['123'])
end

test_no_error("text na hranici 2500 znaku projde validaci (api_post stubovan)") do
  stub_pub.publish('x' * 2500)
end

# =============================================================================
# parse_error (private)
# =============================================================================
section("parse_error (private)")

pub3 = Publishers::MastodonPublisher.new(instance_url: 'https://example.com', access_token: 'tok')

# Mock response objects
MockResponse = Struct.new(:body, :code, keyword_init: true)

resp_json = MockResponse.new(body: '{"error": "Rate limited"}', code: '429')
test("parses JSON error field", 'Rate limited', pub3.send(:parse_error, resp_json))

resp_plain = MockResponse.new(body: 'Something went wrong', code: '500')
test("non-JSON returns body text", 'Something went wrong', pub3.send(:parse_error, resp_plain))

resp_empty = MockResponse.new(body: '', code: '500')
test("empty body returns empty string", '', pub3.send(:parse_error, resp_empty))

# Pozn.: Pokrytí detect_content_type_from_bytes (magic byte detekce) bylo
# po R5 extrakci MimeDetectoru přesunuto do test/test_mime_detector.rb —
# publisher tu metodu už nemá (volá MimeDetector.from_bytes interně).
# Zde se testují jen delegáty detect_content_type / detect_content_type_from_path /
# correct_filename_extension, které publisher i nadále veřejně vystavuje.

# Sdílené fixtures + publisher instance pro testy delegátů níž
pub4 = Publishers::MastodonPublisher.new(instance_url: 'https://example.com', access_token: 'tok')
jpeg_magic  = "\xFF\xD8\xFF\xE0" + ('x' * 20)
png_magic   = "\x89PNG\r\n\x1A\n" + ('x' * 20)
gif89_magic = "GIF89a" + ('x' * 20)
webp_magic  = "RIFF\x00\x00\x00\x00WEBP" + ('x' * 20)
mp4_magic   = "\x00\x00\x00\x20ftypisom" + ('x' * 20)

# =============================================================================
# detect_content_type (private) — content-first, extension fallback
# =============================================================================
section("detect_content_type (private)")

dummy_data = 'x' * 20  # no valid magic bytes -> falls through to extension

# Extension fallback (when magic bytes don't match)
test(".jpg ext fallback -> image/jpeg", 'image/jpeg', pub4.send(:detect_content_type, 'https://example.com/pic.jpg', dummy_data))
test(".jpeg ext fallback -> image/jpeg", 'image/jpeg', pub4.send(:detect_content_type, 'https://example.com/pic.jpeg', dummy_data))
test(".png ext fallback -> image/png", 'image/png', pub4.send(:detect_content_type, 'https://example.com/pic.png', dummy_data))
test(".gif ext fallback -> image/gif", 'image/gif', pub4.send(:detect_content_type, 'https://example.com/pic.gif', dummy_data))
test(".webp ext fallback -> image/webp", 'image/webp', pub4.send(:detect_content_type, 'https://example.com/pic.webp', dummy_data))
test(".mp4 ext fallback -> video/mp4", 'video/mp4', pub4.send(:detect_content_type, 'https://example.com/vid.mp4', dummy_data))

# Magic bytes with no extension
test("JPEG bytes + no ext -> image/jpeg", 'image/jpeg',
     pub4.send(:detect_content_type, 'https://example.com/noext', jpeg_magic))
test("PNG bytes + no ext -> image/png", 'image/png',
     pub4.send(:detect_content_type, 'https://example.com/noext', png_magic))

# CRITICAL: Magic bytes override wrong extension (the actual bug fix)
test("PNG bytes + .jpg ext -> image/png (content wins)", 'image/png',
     pub4.send(:detect_content_type, 'https://example.com/pic.jpg', png_magic))
test("JPEG bytes + .png ext -> image/jpeg (content wins)", 'image/jpeg',
     pub4.send(:detect_content_type, 'https://example.com/pic.png', jpeg_magic))
test("WebP bytes + .jpg ext -> image/webp (content wins)", 'image/webp',
     pub4.send(:detect_content_type, 'https://example.com/pic.jpg', webp_magic))
test("GIF bytes + .jpg ext -> image/gif (content wins)", 'image/gif',
     pub4.send(:detect_content_type, 'https://example.com/pic.jpg', gif89_magic))
test("MP4 bytes + .jpg ext -> video/mp4 (content wins)", 'video/mp4',
     pub4.send(:detect_content_type, 'https://example.com/pic.jpg', mp4_magic))

# Unknown bytes + unknown extension -> application/octet-stream
test("unknown bytes + unknown ext -> application/octet-stream", 'application/octet-stream',
     pub4.send(:detect_content_type, 'https://example.com/file.xyz', dummy_data))

# =============================================================================
# Error aliases
# =============================================================================
section("Error aliases")

test("StatusNotFoundError alias", Zpravobot::StatusNotFoundError, Publishers::MastodonPublisher::StatusNotFoundError)
test("EditNotAllowedError alias", Zpravobot::EditNotAllowedError, Publishers::MastodonPublisher::EditNotAllowedError)
test("ValidationError alias", Zpravobot::ValidationError, Publishers::MastodonPublisher::ValidationError)

# =============================================================================
section("upload_media_from_file — input validation")

pub5 = Publishers::MastodonPublisher.new(instance_url: 'https://example.com', access_token: 'tok')

test_raises("raises ArgumentError for nonexistent file", ArgumentError) do
  pub5.upload_media_from_file('/nonexistent/file.png')
end

# =============================================================================
section("detect_content_type_from_path (private)")

pub6 = Publishers::MastodonPublisher.new(instance_url: 'https://example.com', access_token: 'tok')
dummy = 'x' * 20

# Extension fallback (when magic bytes don't match)
test("/path/image.jpg -> image/jpeg", 'image/jpeg',
     pub6.send(:detect_content_type_from_path, '/path/image.jpg', dummy))
test("/path/image.jpeg -> image/jpeg", 'image/jpeg',
     pub6.send(:detect_content_type_from_path, '/path/image.jpeg', dummy))
test("/path/image.png -> image/png", 'image/png',
     pub6.send(:detect_content_type_from_path, '/path/image.png', dummy))
test("/path/image.gif -> image/gif", 'image/gif',
     pub6.send(:detect_content_type_from_path, '/path/image.gif', dummy))
test("/path/image.webp -> image/webp", 'image/webp',
     pub6.send(:detect_content_type_from_path, '/path/image.webp', dummy))

# Content overrides extension (the actual bug fix)
png_bytes = "\x89PNG\r\n\x1A\n" + ('x' * 20)
test("path .jpg but PNG content -> image/png", 'image/png',
     pub6.send(:detect_content_type_from_path, '/path/image.jpg', png_bytes))

jpeg_bytes = "\xFF\xD8\xFF\xE0" + ('x' * 20)
test("path .png but JPEG content -> image/jpeg", 'image/jpeg',
     pub6.send(:detect_content_type_from_path, '/path/image.png', jpeg_bytes))

# =============================================================================
section("correct_filename_extension (private)")

pub7 = Publishers::MastodonPublisher.new(instance_url: 'https://example.com', access_token: 'tok')

# Extension matches content type — no change
test("image.jpg + image/jpeg -> image.jpg", 'image.jpg',
     pub7.send(:correct_filename_extension, 'image.jpg', 'image/jpeg'))
test("image.jpeg + image/jpeg -> image.jpeg", 'image.jpeg',
     pub7.send(:correct_filename_extension, 'image.jpeg', 'image/jpeg'))
test("photo.png + image/png -> photo.png", 'photo.png',
     pub7.send(:correct_filename_extension, 'photo.png', 'image/png'))

# Extension doesn't match content — correction
test("image.jpg + image/png -> image.png", 'image.png',
     pub7.send(:correct_filename_extension, 'image.jpg', 'image/png'))
test("photo.jpg + image/webp -> photo.webp", 'photo.webp',
     pub7.send(:correct_filename_extension, 'photo.jpg', 'image/webp'))
test("video.jpg + video/mp4 -> video.mp4", 'video.mp4',
     pub7.send(:correct_filename_extension, 'video.jpg', 'video/mp4'))

# No extension — add correct one
test("media + image/jpeg -> media.jpg", 'media.jpg',
     pub7.send(:correct_filename_extension, 'media', 'image/jpeg'))
test("file + image/png -> file.png", 'file.png',
     pub7.send(:correct_filename_extension, 'file', 'image/png'))

# Unknown content type — no change
test("image.jpg + text/html -> image.jpg (unknown)", 'image.jpg',
     pub7.send(:correct_filename_extension, 'image.jpg', 'text/html'))

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
