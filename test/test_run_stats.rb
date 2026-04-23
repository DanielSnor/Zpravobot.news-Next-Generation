#!/usr/bin/env ruby
# frozen_string_literal: true

# Test Stats::RunStats (REFACTOR-1)
# Run: ruby test/test_run_stats.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/stats/run_stats'

puts '=' * 60
puts 'Stats::RunStats Tests'
puts '=' * 60
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
# Initialization
# =============================================================================
section('Initialization')

stats = Stats::RunStats.new(processed: 0, published: 0, skipped: 0, errors: 0)
test('initialized key is 0', 0, stats[:processed])
test('initialized key :errors is 0', 0, stats[:errors])
test('uninitialized key auto-zero', 0, stats[:rate_limited])

stats2 = Stats::RunStats.new
test('empty init — unknown key auto-zero', 0, stats2[:anything])

# =============================================================================
# increment
# =============================================================================
section('increment')

s = Stats::RunStats.new(published: 0)
s.increment(:published)
test('increment pre-initialized key', 1, s[:published])

s.increment(:published).increment(:published)
test('increment chaining', 3, s[:published])

s.increment(:rate_limited)
test('increment uninitialized key', 1, s[:rate_limited])

s2 = Stats::RunStats.new
5.times { s2.increment(:processed) }
test('increment 5 times', 5, s2[:processed])

# =============================================================================
# fetch
# =============================================================================
section('fetch')

sf = Stats::RunStats.new(errors: 0)
test('fetch existing key', 0, sf.fetch(:errors, 99))
sf.increment(:errors)
test('fetch after increment', 1, sf.fetch(:errors, 99))
test('fetch unknown key returns default', 0, sf.fetch(:unknown, 0))
test('fetch unknown key custom default', 42, sf.fetch(:missing, 42))

# =============================================================================
# to_h
# =============================================================================
section('to_h')

sh = Stats::RunStats.new(processed: 0, published: 0)
sh.increment(:published)
h = sh.to_h
test('to_h returns Hash', true, h.is_a?(Hash))
test('to_h reflects state', 1, h[:published])
h[:published] = 99
test('to_h is a copy (mutation safe)', 1, sh[:published])

# =============================================================================
# inspect / to_s (no crash)
# =============================================================================
section('inspect / to_s')

si = Stats::RunStats.new(processed: 0)
si.increment(:processed)
test('inspect contains key', true, si.inspect.include?('processed'))
test('to_s does not crash', true, si.to_s.is_a?(String))

# =============================================================================
# Orchestrator usage pattern
# =============================================================================
section('Orchestrator pattern')

orch = Stats::RunStats.new(processed: 0, published: 0, skipped: 0, errors: 0)
orch.increment(:processed)
orch.increment(:published)
orch.increment(:processed)
orch.increment(:skipped)
orch.increment(:rate_limited)  # lazily added key
test('orchestrator: processed=2', 2, orch[:processed])
test('orchestrator: published=1', 1, orch[:published])
test('orchestrator: skipped=1', 1, orch[:skipped])
test('orchestrator: rate_limited=1', 1, orch[:rate_limited])
test('orchestrator: errors=0', 0, orch[:errors])
test('orchestrator: fetch(:errors, 0)', 0, orch.fetch(:errors, 0))

# =============================================================================
# IFTTT pattern (direct symbol increment)
# =============================================================================
section('IFTTT pattern')

ifttt = Stats::RunStats.new(processed: 0, published: 0, skipped: 0, failed: 0, updated: 0, rate_limited: 0)
[:published, :published, :skipped, :failed, :rate_limited, :updated].each do |result|
  ifttt.increment(result)
  ifttt.increment(:processed)
end
test('ifttt: processed=6', 6, ifttt[:processed])
test('ifttt: published=2', 2, ifttt[:published])
test('ifttt: skipped=1', 1, ifttt[:skipped])
test('ifttt: failed=1', 1, ifttt[:failed])
test('ifttt: updated=1', 1, ifttt[:updated])
test('ifttt: rate_limited=1', 1, ifttt[:rate_limited])

# =============================================================================
# Summary
# =============================================================================
puts
puts '=' * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts '=' * 60

exit($failed == 0 ? 0 : 1)
