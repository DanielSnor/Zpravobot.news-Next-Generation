#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Test: yaml_quote helper from create_source.rb
# ============================================================
# Verifies that yaml_quote produces valid YAML for any input,
# including strings with quotes, YAML-special chars, and unicode.
#
# Each test checks:
# 1. yaml_quote returns expected quoted form
# 2. YAML roundtrip: YAML.safe_load("key: #{quoted}") == original
# ============================================================

require 'yaml'

# Extract SourceGenerator class to access yaml_quote
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'source_wizard/source_generator'

puts '=' * 60
puts '  yaml_quote — YAML Safe Quoting Test'
puts '=' * 60
puts

# Create an instance to access the private method
generator = SourceGenerator.new(config_dir: '/tmp')

test_cases = [
  {
    name: 'Simple string',
    input: 'simple',
    expected: '"simple"'
  },
  {
    name: 'String with double quotes (display name bug)',
    input: 'Jana "Dezinfo"',
    expected: "'Jana \"Dezinfo\"'"
  },
  {
    name: 'String with single quote only',
    input: "It's here",
    expected: "\"It's here\""
  },
  {
    name: 'String with both quote types',
    input: "She said \"it's fine\"",
    expected: "\"She said \\\"it's fine\\\"\""
  },
  {
    name: 'String with colon (YAML special)',
    input: 'Breaking: News',
    expected: '"Breaking: News"'
  },
  {
    name: 'String with hash (YAML comment)',
    input: '#resist',
    expected: '"#resist"'
  },
  {
    name: 'String with ampersand and exclamation',
    input: 'value with & and !',
    expected: '"value with & and !"'
  },
  {
    name: 'String with square brackets',
    input: '[important]',
    expected: '"[important]"'
  },
  {
    name: 'String with curly braces',
    input: '{key: value}',
    expected: '"{key: value}"'
  },
  {
    name: 'String with asterisk',
    input: '*bold*',
    expected: '"*bold*"'
  },
  {
    name: 'String with pipe (YAML literal block)',
    input: 'line1 | line2',
    expected: '"line1 | line2"'
  },
  {
    name: 'String with percent',
    input: '100% sure',
    expected: '"100% sure"'
  },
  {
    name: 'String with at sign',
    input: '@username',
    expected: '"@username"'
  },
  {
    name: 'String with leading dash (YAML list)',
    input: '- item',
    expected: '"- item"'
  },
  {
    name: 'String with leading space',
    input: ' padded',
    expected: '" padded"'
  },
  {
    name: 'String with trailing space',
    input: 'padded ',
    expected: '"padded "'
  },
  {
    name: 'Empty string',
    input: '',
    expected: '""'
  },
  {
    name: 'Nil input',
    input: nil,
    expected: '""'
  },
  {
    name: 'Unicode emoji',
    input: '🇨🇿 Česká republika',
    expected: '"🇨🇿 Česká republika"'
  },
  {
    name: 'Regex pattern (backslashes)',
    input: "^.+?\\s+(Posted|shared)$",
    expected: "\"^.+?\\\\s+(Posted|shared)$\""
  },
  {
    name: 'Simple domain (no special chars)',
    input: 'ct24zive',
    expected: '"ct24zive"'
  },
  {
    name: 'URL with colon',
    input: 'https://zpravobot.news',
    expected: '"https://zpravobot.news"'
  },
  {
    name: 'Backtick in string',
    input: 'code `here`',
    expected: '"code `here`"'
  }
]

passed = 0
failed = 0

test_cases.each_with_index do |test, i|
  puts "Test #{i + 1}: #{test[:name]}"

  result = generator.send(:yaml_quote, test[:input])

  errors = []

  # Check expected quoted form
  if result != test[:expected]
    errors << "  Expected: #{test[:expected].inspect}"
    errors << "  Got:      #{result.inspect}"
  end

  # Check YAML roundtrip (skip nil — roundtrip gives empty string)
  unless test[:input].nil? || test[:input].to_s.empty?
    begin
      yaml_str = "key: #{result}"
      parsed = YAML.safe_load(yaml_str)
      roundtrip_value = parsed['key'].to_s

      if roundtrip_value != test[:input]
        errors << "  Roundtrip FAILED!"
        errors << "  YAML input:  #{yaml_str.inspect}"
        errors << "  Parsed back: #{roundtrip_value.inspect}"
        errors << "  Original:    #{test[:input].inspect}"
      end
    rescue Psych::SyntaxError => e
      errors << "  YAML PARSE ERROR: #{e.message}"
      errors << "  YAML input: #{yaml_str.inspect}"
    end
  end

  if errors.empty?
    puts "  ✅ PASSED (#{result})"
    passed += 1
  else
    puts "  ❌ FAILED"
    errors.each { |e| puts e }
    failed += 1
  end
  puts
end

puts '=' * 60
puts "  #{passed}/#{passed + failed} tests passed"
puts '=' * 60

exit(failed > 0 ? 1 : 0)
