#!/usr/bin/env ruby
# frozen_string_literal: true

# Test Processors::TwitterThreadProcessor — HTML parsing (Phase 10.5)
# Tests has_thread_chain? and extract_thread_chain (no HTTP/DB)
# Run: ruby test/test_twitter_thread_processor.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/processors/twitter_thread_processor'

puts "=" * 60
puts "TwitterThreadProcessor Tests (offline)"
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
# Create a minimal processor instance (mocks for deps we don't use)
# =============================================================================
MockSM = Struct.new(:x)
MockTA = Struct.new(:x)
MockPub = Struct.new(:x)

proc = Processors::TwitterThreadProcessor.new(
  state_manager: MockSM.new,
  twitter_adapter: MockTA.new,
  publisher: MockPub.new,
  nitter_instance: 'https://nitter.example.com'
)

# =============================================================================
# Constants
# =============================================================================
section("Constants")

test("MAX_CHAIN_DEPTH is 10", 10, Processors::TwitterThreadProcessor::MAX_CHAIN_DEPTH)
test("RETRY_ATTEMPTS is 3", 3, Processors::TwitterThreadProcessor::RETRY_ATTEMPTS)

# =============================================================================
# has_thread_chain?
# =============================================================================
section("has_thread_chain?")

test("nil returns false", false, proc.has_thread_chain?(nil))
test("empty string returns false", false, proc.has_thread_chain?(''))
test("HTML without before-tweet returns false", false, proc.has_thread_chain?('<div>hello</div>'))

thread_html = <<~HTML
  <div class="before-tweet thread-line">
    <div class="timeline-item " data-username="alice">
      <a class="tweet-link" href="/alice/status/123#m"></a>
      <div class="tweet-content media-body" dir="auto">First tweet</div>
    </div>
  </div>
  <div id="m" class="main-tweet">Main tweet</div>
HTML
test("HTML with before-tweet + timeline-item returns true", true, proc.has_thread_chain?(thread_html))

no_timeline_html = <<~HTML
  <div class="before-tweet thread-line">
    <div>no timeline-item class</div>
  </div>
  <div class="main-tweet">Main</div>
HTML
test("before-tweet without timeline-item returns false", false, proc.has_thread_chain?(no_timeline_html))

# =============================================================================
# extract_thread_chain
# =============================================================================
section("extract_thread_chain")

# Single tweet in chain
single_chain_html = <<~HTML
  <div class="before-tweet thread-line">
    <div class="timeline-item " data-username="Alice">
      <a class="tweet-link" href="/Alice/status/111#m"></a>
      <div class="tweet-content media-body" dir="auto">Hello world</div>
    </div>
  </div>
  <div id="m" class="main-tweet">Main tweet here</div>
HTML

chain = proc.extract_thread_chain(single_chain_html)
test("extracts 1 tweet from single chain", 1, chain.length)
test("extracts tweet ID", '111', chain[0][:id])
test("extracts username (downcased)", 'alice', chain[0][:username])
test("extracts text preview", true, chain[0][:text_preview].include?('Hello world'))

# Empty before-tweet -> empty array
empty_before_html = <<~HTML
  <div class="before-tweet thread-line">
  </div>
  <div id="m" class="main-tweet">Main</div>
HTML
test("empty before-tweet returns empty array", [], proc.extract_thread_chain(empty_before_html))

# Multiple tweets in chain -> correct order (oldest first)
multi_chain_html = <<~HTML
  <div class="before-tweet thread-line">
    <div class="timeline-item " data-username="bob">
      <a class="tweet-link" href="/bob/status/100#m"></a>
      <div class="tweet-content media-body" dir="auto">First tweet</div>
    </div>
    <div class="timeline-item " data-username="bob">
      <a class="tweet-link" href="/bob/status/200#m"></a>
      <div class="tweet-content media-body" dir="auto">Second tweet</div>
    </div>
    <div class="timeline-item " data-username="bob">
      <a class="tweet-link" href="/bob/status/300#m"></a>
      <div class="tweet-content media-body" dir="auto">Third tweet</div>
    </div>
  </div>
  <div id="m" class="main-tweet">Main</div>
HTML

multi = proc.extract_thread_chain(multi_chain_html)
test("extracts 3 tweets from multi chain", 3, multi.length)
test("first tweet ID is 100 (oldest first)", '100', multi[0][:id])
test("last tweet ID is 300", '300', multi[2][:id])

# Chain longer than MAX_CHAIN_DEPTH -> trimmed to last 10
items = (1..15).map do |i|
  <<~ITEM
    <div class="timeline-item " data-username="carol">
      <a class="tweet-link" href="/carol/status/#{i}#m"></a>
      <div class="tweet-content media-body" dir="auto">Tweet #{i}</div>
    </div>
  ITEM
end

long_html = <<~HTML
  <div class="before-tweet thread-line">
    #{items.join}
  </div>
  <div id="m" class="main-tweet">Main</div>
HTML

long_chain = proc.extract_thread_chain(long_html)
test("chain trimmed to MAX_CHAIN_DEPTH (10)", 10, long_chain.length)
test("keeps most recent (last) tweets", '15', long_chain.last[:id])
test("oldest kept is #6", '6', long_chain.first[:id])

# UTF-8 characters in text
utf8_html = <<~HTML
  <div class="before-tweet thread-line">
    <div class="timeline-item " data-username="dan">
      <a class="tweet-link" href="/dan/status/999#m"></a>
      <div class="tweet-content media-body" dir="auto">Příliš žluťoučký 🇨🇿</div>
    </div>
  </div>
  <div id="m" class="main-tweet">Main</div>
HTML

utf8_chain = proc.extract_thread_chain(utf8_html)
test("UTF-8 chars in text are preserved", true, utf8_chain[0][:text_preview].include?('Příliš'))

# HTML tags in tweet content are stripped
html_in_content = <<~HTML
  <div class="before-tweet thread-line">
    <div class="timeline-item " data-username="eve">
      <a class="tweet-link" href="/eve/status/555#m"></a>
      <div class="tweet-content media-body" dir="auto">Hello <b>bold</b> and <a href="#">link</a></div>
    </div>
  </div>
  <div id="m" class="main-tweet">Main</div>
HTML

html_chain = proc.extract_thread_chain(html_in_content)
test("HTML tags stripped from content", false, html_chain[0][:text_preview].include?('<b>'))
test("text content preserved after stripping", true, html_chain[0][:text_preview].include?('bold'))

# No before-tweet section at all -> empty
test("no before-tweet section returns empty", [], proc.extract_thread_chain('<div class="main-tweet">Main</div>'))

# =============================================================================
# Standalone tweet (no thread)
# =============================================================================
section("Standalone tweet")

standalone_html = <<~HTML
  <div class="main-thread">
    <div id="m" class="main-tweet">
      <div class="tweet-content">Just a regular tweet</div>
    </div>
  </div>
HTML

test("standalone tweet has no thread chain", false, proc.has_thread_chain?(standalone_html))

# =============================================================================
# sanitize_encoding (private, test via send)
# =============================================================================
section("sanitize_encoding")

test("nil returns empty string", '', proc.send(:sanitize_encoding, nil))
test("valid UTF-8 passes through", 'Hello', proc.send(:sanitize_encoding, 'Hello'))
test("Czech chars pass through", 'Příliš žluťoučký', proc.send(:sanitize_encoding, 'Příliš žluťoučký'))

# Simulate ASCII-8BIT string (like Nitter response)
binary_str = "Hello \x80\xFF world".dup.force_encoding('ASCII-8BIT')
sanitized = proc.send(:sanitize_encoding, binary_str)
test("binary string sanitized to UTF-8", Encoding::UTF_8, sanitized.encoding)
test("invalid bytes replaced with ?", true, sanitized.include?('?'))
test("valid ASCII part preserved", true, sanitized.include?('Hello'))

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
