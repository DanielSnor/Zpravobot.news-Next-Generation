#!/usr/bin/env ruby
# frozen_string_literal: true

# Test CheckResult data class (Phase 10.2)
# Validates constructor, level checks, icon, to_h
# Run: ruby test/test_check_result.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/health/check_result'

puts "=" * 60
puts "CheckResult Tests"
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
# Constructor
# =============================================================================
section("Constructor")

r = CheckResult.new(name: 'Test', level: :ok, message: 'All good')
test("stores name", 'Test', r.name)
test("stores level", :ok, r.level)
test("stores message", 'All good', r.message)
test("details defaults to nil", nil, r.details)
test("remediation defaults to nil", nil, r.remediation)

r2 = CheckResult.new(name: 'DB', level: :critical, message: 'Down', details: { host: 'db1' }, remediation: 'Restart')
test("stores details when provided", { host: 'db1' }, r2.details)
test("stores remediation when provided", 'Restart', r2.remediation)

# =============================================================================
# Level checks
# =============================================================================
section("Level checks")

ok = CheckResult.new(name: 'A', level: :ok, message: 'ok')
warn = CheckResult.new(name: 'B', level: :warning, message: 'warn')
crit = CheckResult.new(name: 'C', level: :critical, message: 'crit')

test("ok? returns true for :ok", true, ok.ok?)
test("ok? returns false for :warning", false, warn.ok?)
test("warning? returns true for :warning", true, warn.warning?)
test("critical? returns true for :critical", true, crit.critical?)
test("critical? returns false for :ok", false, ok.critical?)

# =============================================================================
# Icon
# =============================================================================
section("Icon")

test(":ok icon is checkmark", "\u2705", ok.icon)
test(":warning icon is warning sign", "\u26a0\ufe0f", warn.icon)
test(":critical icon is cross", "\u274c", crit.icon)

# =============================================================================
# to_h
# =============================================================================
section("to_h")

h_simple = ok.to_h
test("to_h contains name", 'A', h_simple[:name])
test("to_h contains level", :ok, h_simple[:level])
test("to_h contains message", 'ok', h_simple[:message])
test("to_h omits nil details (compact)", false, h_simple.key?(:details))
test("to_h omits nil remediation (compact)", false, h_simple.key?(:remediation))

h_full = r2.to_h
test("to_h includes details when present", { host: 'db1' }, h_full[:details])
test("to_h includes remediation when present", 'Restart', h_full[:remediation])

# =============================================================================
# LEVELS constant
# =============================================================================
section("LEVELS constant")

test("LEVELS has :ok => 0", 0, CheckResult::LEVELS[:ok])
test("LEVELS has :warning => 1", 1, CheckResult::LEVELS[:warning])
test("LEVELS has :critical => 2", 2, CheckResult::LEVELS[:critical])

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
