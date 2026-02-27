#!/usr/bin/env ruby
# frozen_string_literal: true

# Test ověření opravy MASTODON_MAX_CHARS
# Ověří, že formátovače respektují max_length z konfigurace

require_relative '../lib/formatters/bluesky_formatter'
require_relative '../lib/formatters/twitter_formatter'

def test(name)
  print "Testing: #{name}... "
  result = yield
  if result
    puts "✅"
    true
  else
    puts "❌"
    false
  end
rescue => e
  puts "❌ #{e.message}"
  false
end

def separator
  puts "=" * 60
end

puts
separator
puts "  ZBNW-NG: Test opravy max_length"
separator
puts

all_passed = true

# Test 1: BlueskyFormatter s defaultním limitem (500)
all_passed &= test("BlueskyFormatter - default max_length (500)") do
  formatter = Formatters::BlueskyFormatter.new({})
  # After UniversalFormatter refactor, config is stored in @options hash
  formatter.instance_variable_get(:@options)[:max_length] == 500
end

# Test 2: BlueskyFormatter s custom limitem (2400)
all_passed &= test("BlueskyFormatter - custom max_length (2400)") do
  formatter = Formatters::BlueskyFormatter.new({ max_length: 2400 })
  formatter.instance_variable_get(:@options)[:max_length] == 2400
end

# Test 3: TwitterFormatter s defaultním limitem (500)
all_passed &= test("TwitterFormatter - default max_length (500)") do
  formatter = Formatters::TwitterFormatter.new({})
  formatter.instance_variable_get(:@options)[:max_length] == 500
end

# Test 4: TwitterFormatter s custom limitem (2400)
all_passed &= test("TwitterFormatter - custom max_length (2400)") do
  formatter = Formatters::TwitterFormatter.new({ max_length: 2400 })
  formatter.instance_variable_get(:@options)[:max_length] == 2400
end

# Test 5: Ověření, že MASTODON_MAX_CHARS konstanta neexistuje
all_passed &= test("MASTODON_MAX_CHARS konstanta neexistuje") do
  !Formatters::BlueskyFormatter.const_defined?(:MASTODON_MAX_CHARS) &&
  !Formatters::TwitterFormatter.const_defined?(:MASTODON_MAX_CHARS)
end

puts
separator

if all_passed
  puts "✅ Všechny testy prošly!"
  puts
  puts "Oprava je správně aplikována."
  puts "Formátovače nyní respektují max_length z konfigurace."
  exit 0
else
  puts "❌ Některé testy selhaly!"
  puts
  puts "Zkontroluj, že byly všechny změny správně aplikovány."
  exit 1
end
