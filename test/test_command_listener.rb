#!/usr/bin/env ruby
# frozen_string_literal: true

# Test Monitoring::CommandListener (Phase 15.1)
# Validates parse_command, authorization, rate limiting, split_response (no HTTP)
# Run: ruby test/test_command_listener.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/monitoring/command_listener'

puts "=" * 60
puts "CommandListener Tests"
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

# Create listener with minimal config
config = {
  mastodon_instance: 'https://example.com',
  alert_bot_token: 'test_token',
  command_listener: {
    bot_account: 'udrzbot',
    allowed_accounts: ['admin@example.com', 'operator@test.cz'],
    rate_limit_per_cycle: 3,
    response_visibility: 'direct',
    poll_limit: 30
  }
}
listener = Monitoring::CommandListener.new(config)

# =============================================================================
# Constants
# =============================================================================
section("Constants")

test("POLL_LIMIT is 30", 30, Monitoring::CommandListener::POLL_LIMIT)
test("MAX_RESPONSE_LENGTH is 2400", 2400, Monitoring::CommandListener::MAX_RESPONSE_LENGTH)
test("STATE_FILENAME is 'command_listener_state.json'",
     'command_listener_state.json',
     Monitoring::CommandListener::STATE_FILENAME)

# =============================================================================
# parse_command
# =============================================================================
section("parse_command")

# Simple command via HtmlCleaner
test("simple command: '@udrzbot status'",
     { command: 'status', args: '' },
     listener.send(:parse_command, '<p><span class="h-card"><a href="https://zpravobot.news/@udrzbot">@<span>udrzbot</span></a></span> status</p>'))

# Command with arguments
test("command with args: '@udrzbot check server'",
     'check',
     listener.send(:parse_command, '<p><span class="h-card"><a href="https://zpravobot.news/@udrzbot">@<span>udrzbot</span></a></span> check server</p>')[:command])

test("args extracted: 'check server'",
     'server',
     listener.send(:parse_command, '<p><span class="h-card"><a href="https://zpravobot.news/@udrzbot">@<span>udrzbot</span></a></span> check server</p>')[:args])

# Empty command -> help
test("empty mention defaults to 'help'",
     'help',
     listener.send(:parse_command, '<p><span class="h-card"><a href="https://zpravobot.news/@udrzbot">@<span>udrzbot</span></a></span></p>')[:command])

# Case insensitive
test("command is lowercased",
     'status',
     listener.send(:parse_command, '<p><span class="h-card"><a href="https://zpravobot.news/@udrzbot">@<span>udrzbot</span></a></span> STATUS</p>')[:command])

# Plain text (no HTML wrapping)
test("plain text parse: '@udrzbot heartbeat'",
     'heartbeat',
     listener.send(:parse_command, '@udrzbot heartbeat')[:command])

# Fully qualified mention
test("fully qualified mention '@udrzbot@zpravobot.news'",
     'sources',
     listener.send(:parse_command, '@udrzbot@zpravobot.news sources')[:command])

# =============================================================================
# authorized?
# =============================================================================
section("authorized?")

test("allowed account returns true",
     true,
     listener.send(:authorized?, 'admin@example.com'))

test("disallowed account returns false",
     false,
     listener.send(:authorized?, 'hacker@evil.com'))

test("case-insensitive matching",
     true,
     listener.send(:authorized?, 'Admin@Example.COM'))

test("second allowed account works",
     true,
     listener.send(:authorized?, 'operator@test.cz'))

# Listener with empty allowed_accounts
empty_config = {
  mastodon_instance: 'https://example.com',
  alert_bot_token: 'test_token',
  command_listener: { allowed_accounts: [] }
}
empty_listener = Monitoring::CommandListener.new(empty_config)

test("empty allowed_accounts returns false",
     false,
     empty_listener.send(:authorized?, 'anyone@example.com'))

# Listener with nil allowed_accounts
nil_config = {
  mastodon_instance: 'https://example.com',
  alert_bot_token: 'test_token',
  command_listener: {}
}
nil_listener = Monitoring::CommandListener.new(nil_config)

test("nil allowed_accounts returns false",
     false,
     nil_listener.send(:authorized?, 'anyone@example.com'))

# =============================================================================
# rate_limited? / record_command
# =============================================================================
section("rate_limited? / record_command")

# Fresh listener — no commands recorded yet
fresh_listener = Monitoring::CommandListener.new(config)

test("first command is not rate limited",
     false,
     fresh_listener.send(:rate_limited?, 'admin@example.com'))

# Record 3 commands (rate_limit_per_cycle is 3)
fresh_listener.send(:record_command, 'admin@example.com')
fresh_listener.send(:record_command, 'admin@example.com')
fresh_listener.send(:record_command, 'admin@example.com')

test("after 3 commands, rate_limited returns true",
     true,
     fresh_listener.send(:rate_limited?, 'admin@example.com'))

test("different account is not rate limited",
     false,
     fresh_listener.send(:rate_limited?, 'operator@test.cz'))

test("record_command increments counter",
     3,
     fresh_listener.instance_variable_get(:@command_counts)['admin@example.com'])

# =============================================================================
# split_response
# =============================================================================
section("split_response")

test("short text returns single-element array",
     1,
     listener.send(:split_response, 'Short text').length)

test("short text content preserved",
     'Short text',
     listener.send(:split_response, 'Short text').first)

# Long text that exceeds MAX_RESPONSE_LENGTH
long_text = "A" * 3000
chunks = listener.send(:split_response, long_text)
test("long text is split into multiple chunks",
     true,
     chunks.length > 1)

test("all chunks except last have continuation marker",
     true,
     chunks[0..-2].all? { |c| c.include?('[...pokračování]') })

test("last chunk has no continuation marker",
     false,
     chunks.last.include?('[...pokračování]'))

# Text with paragraph breaks — split prefers \n\n
paragraph_text = (["Odstavec číslo #{_n = 1}. " * 20] * 10).join("\n\n")
para_chunks = listener.send(:split_response, paragraph_text)
test("paragraph text splits at boundaries",
     true,
     para_chunks.length > 1)

# =============================================================================
# self_mention?
# =============================================================================
section("self_mention?")

test("detects HTML self-mention",
     true,
     listener.send(:self_mention?, '<p><span class="h-card"><a href="https://zpravobot.news/@udrzbot">@<span>udrzbot</span></a></span> status</p>', 'udrzbot'))

test("detects plain text self-mention",
     true,
     listener.send(:self_mention?, '@udrzbot status', 'udrzbot'))

test("no mention returns false",
     false,
     listener.send(:self_mention?, '<p>just a regular post</p>', 'udrzbot'))

test("nil content returns false",
     false,
     listener.send(:self_mention?, nil, 'udrzbot'))

test("case insensitive self-mention",
     true,
     listener.send(:self_mention?, '@UDRZBOT status', 'udrzbot'))

test("different bot account detected",
     true,
     listener.send(:self_mention?, '@tlambot hello', 'tlambot'))

test("wrong bot account returns false",
     false,
     listener.send(:self_mention?, '@tlambot hello', 'udrzbot'))

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
