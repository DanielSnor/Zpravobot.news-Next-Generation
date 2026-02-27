#!/usr/bin/env ruby
# frozen_string_literal: true

# Test Monitoring::CommandHandlers (Phase 10.7)
# Validates dispatch, help, constants, check validation (no DB/monitor)
# Run: ruby test/test_command_handlers.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/monitoring/command_handlers'

puts "=" * 60
puts "CommandHandlers Tests"
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
# Constants
# =============================================================================
section("Constants — COMMANDS")

commands = Monitoring::CommandHandlers::COMMANDS
test("COMMANDS contains 'help'", true, commands.key?('help'))
test("COMMANDS contains 'status'", true, commands.key?('status'))
test("COMMANDS contains 'detail'", true, commands.key?('detail'))
test("COMMANDS contains 'heartbeat'", true, commands.key?('heartbeat'))
test("COMMANDS contains 'sources'", true, commands.key?('sources'))
test("COMMANDS contains 'check'", true, commands.key?('check'))
test("COMMANDS contains 'details' (alias)", true, commands.key?('details'))

section("Constants — CHECK_ALIASES")

aliases = Monitoring::CommandHandlers::CHECK_ALIASES
test("CHECK_ALIASES has 'server'", 'Server', aliases['server'])
test("CHECK_ALIASES has 'webhook'", 'Webhook Server', aliases['webhook'])
test("CHECK_ALIASES has 'nitter'", 'Nitter Instance', aliases['nitter'])
test("CHECK_ALIASES has 'mastodon'", 'Mastodon API', aliases['mastodon'])

# All COMMANDS values are valid method names on the class
section("COMMANDS values are valid methods")

handler = Monitoring::CommandHandlers.new({})
commands.each_value do |method_name|
  has_method = handler.respond_to?(method_name, true)
  test("#{method_name} is a valid method", true, has_method)
end

# =============================================================================
# dispatch
# =============================================================================
section("dispatch")

# Unknown command -> error message, no exception
result_unknown = handler.dispatch('nonexistent', '')
test("unknown command returns error string", true, result_unknown.is_a?(String))
test("unknown command mentions the command", true, result_unknown.include?('nonexistent'))

# 'help' -> returns help text
result_help = handler.dispatch('help', '')
test("'help' returns a string", true, result_help.is_a?(String))

# 'details' is alias for 'detail' (both map to :handle_detail)
test("'details' maps to same method as 'detail'", commands['detail'], commands['details'])

# =============================================================================
# handle_help
# =============================================================================
section("handle_help")

help_text = handler.dispatch('help', '')
test("help contains 'Údržbot'", true, help_text.include?('Údržbot'))
test("help contains 'help'", true, help_text.include?('help'))
test("help lists status command", true, help_text.include?('status'))
test("help lists detail command", true, help_text.include?('detail'))
test("help lists check command", true, help_text.include?('check'))
test("help lists available check aliases", true, help_text.include?('server'))

# =============================================================================
# handle_check — validation (no monitor needed for input validation)
# =============================================================================
section("handle_check — validation")

# Empty argument -> help text
check_empty = handler.dispatch('check', '')
test("empty check arg returns help", true, check_empty.include?('Zadejte'))
test("empty check arg lists available aliases", true, check_empty.include?('server'))

# Unknown check name
check_unknown = handler.dispatch('check', 'nonexistent')
test("unknown check returns error", true, check_unknown.include?('Neznámý'))

# =============================================================================
# known_command?
# =============================================================================
section("known_command?")

test("'help' is known", true, handler.known_command?('help'))
test("'status' is known", true, handler.known_command?('status'))
test("'foo' is not known", false, handler.known_command?('foo'))

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
