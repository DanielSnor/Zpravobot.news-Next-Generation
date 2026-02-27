#!/usr/bin/env ruby
# frozen_string_literal: true

# Test AlertStateManager (Phase 10.3)
# Validates state persistence, analyze, update_state, day/night intervals
# Run: ruby test/test_alert_state_manager.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/health/check_result'
require_relative '../lib/health/alert_state_manager'
require 'tmpdir'
require 'json'
require 'time'
require 'fileutils'

puts "=" * 60
puts "AlertStateManager Tests"
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

# Helper: create temp state file path
def tmp_state_file
  File.join(Dir.tmpdir, "zbnw_test_alert_state_#{$$}_#{rand(100000)}.json")
end

# Helper: make CheckResult
def make_result(name:, level:, message: 'test', remediation: nil)
  CheckResult.new(name: name, level: level, message: message, remediation: remediation)
end

# =============================================================================
# Initialization
# =============================================================================
section("Initialization")

# Non-existent file -> empty state
path1 = tmp_state_file
mgr1 = AlertStateManager.new(path1)
test("non-existent file -> no previous problems", false, mgr1.has_previous_problems?)

# Existing valid JSON file -> loads state
path2 = tmp_state_file
state_data = {
  'problems' => { 'DB' => { 'first_seen_at' => Time.now.iso8601, 'last_alert_at' => Time.now.iso8601, 'level' => 'critical', 'message' => 'down' } },
  'pending_resolved' => {},
  'last_check_at' => Time.now.iso8601
}
File.write(path2, JSON.pretty_generate(state_data))
mgr2 = AlertStateManager.new(path2)
test("existing JSON file -> has previous problems", true, mgr2.has_previous_problems?)

# Corrupted JSON -> fallback to empty
path3 = tmp_state_file
File.write(path3, "not valid json {{{")
mgr3 = AlertStateManager.new(path3)
test("corrupted JSON -> fallback to empty state", false, mgr3.has_previous_problems?)

# Cleanup
[path1, path2, path3].each { |p| File.delete(p) rescue nil }

# =============================================================================
# extract_problems (private — tested via analyze)
# =============================================================================
section("extract_problems via analyze")

path4 = tmp_state_file
mgr4 = AlertStateManager.new(path4)

results_ok = [make_result(name: 'Server', level: :ok)]
analysis_ok = mgr4.analyze(results_ok)
test(":ok result not counted as problem", true, analysis_ok[:new].empty?)

results_warn = [make_result(name: 'Queue', level: :warning, message: 'slow')]
analysis_warn = mgr4.analyze(results_warn)
test(":warning result counted as new problem", 1, analysis_warn[:new].length)

path4b = tmp_state_file
mgr4b = AlertStateManager.new(path4b)
results_crit = [make_result(name: 'DB', level: :critical, message: 'down')]
analysis_crit = mgr4b.analyze(results_crit)
test(":critical result counted as new problem", 1, analysis_crit[:new].length)

[path4, path4b].each { |p| File.delete(p) rescue nil }

# =============================================================================
# analyze — new problems
# =============================================================================
section("analyze — new problems")

path5 = tmp_state_file
mgr5 = AlertStateManager.new(path5)

new_results = [
  make_result(name: 'DB', level: :critical, message: 'down'),
  make_result(name: 'Server', level: :ok, message: 'up')
]
analysis5 = mgr5.analyze(new_results)
test("new problem appears in analysis[:new]", true, analysis5[:new].any? { |p| p[:name] == 'DB' })
test("should_alert is true for new problem", true, analysis5[:should_alert])

# After update_state, no new problems on same results
mgr5.update_state(new_results, analysis5)
analysis5b = mgr5.analyze(new_results)
test("same problem not new after update_state", true, analysis5b[:new].empty?)

File.delete(path5) rescue nil

# =============================================================================
# analyze — persisting problems
# =============================================================================
section("analyze — persisting problems")

path6 = tmp_state_file
# Create state with a problem from 65 minutes ago (exceeds both DAY_INTERVAL=30 and NIGHT_INTERVAL=60)
now = Time.now
old_time = (now - 65 * 60).iso8601 # 65 min ago
state6 = {
  'problems' => {
    'DB' => {
      'first_seen_at' => old_time,
      'last_alert_at' => old_time,
      'level' => 'critical',
      'message' => 'down'
    }
  },
  'pending_resolved' => {},
  'last_check_at' => old_time
}
File.write(path6, JSON.pretty_generate(state6))
mgr6 = AlertStateManager.new(path6)

persist_results = [make_result(name: 'DB', level: :critical, message: 'still down')]
analysis6 = mgr6.analyze(persist_results)
test("problem older than DAY_INTERVAL appears in persisting", true, analysis6[:persisting].any? { |p| p[:name] == 'DB' })

# Problem younger than interval — no persisting
path6b = tmp_state_file
recent_time = (now - 10 * 60).iso8601 # 10 min ago
state6b = {
  'problems' => {
    'DB' => {
      'first_seen_at' => recent_time,
      'last_alert_at' => recent_time,
      'level' => 'critical',
      'message' => 'down'
    }
  },
  'pending_resolved' => {},
  'last_check_at' => recent_time
}
File.write(path6b, JSON.pretty_generate(state6b))
mgr6b = AlertStateManager.new(path6b)

analysis6b = mgr6b.analyze(persist_results)
test("problem younger than interval not in persisting", true, analysis6b[:persisting].empty?)

[path6, path6b].each { |p| File.delete(p) rescue nil }

# =============================================================================
# analyze — resolved problems
# =============================================================================
section("analyze — resolved problems")

path7 = tmp_state_file
now = Time.now
disappeared_time = (now - 25 * 60).iso8601 # 25 min ago (> RESOLVED_STABILIZATION of 20)
state7 = {
  'problems' => {},
  'pending_resolved' => {
    'DB' => {
      'first_seen_at' => (now - 60 * 60).iso8601,
      'last_alert_at' => (now - 40 * 60).iso8601,
      'disappeared_at' => disappeared_time,
      'level' => 'critical',
      'message' => 'down'
    }
  },
  'last_check_at' => (now - 10 * 60).iso8601
}
File.write(path7, JSON.pretty_generate(state7))
mgr7 = AlertStateManager.new(path7)

resolved_results = [make_result(name: 'Server', level: :ok, message: 'up')]
analysis7 = mgr7.analyze(resolved_results)
test("resolved after stabilization appears in resolved", true, analysis7[:resolved].any? { |p| p[:name] == 'DB' })
test("should_alert true for resolved problem", true, analysis7[:should_alert])

# Not yet stabilized
path7b = tmp_state_file
disappeared_recent = (now - 5 * 60).iso8601 # 5 min ago (< 20 min)
state7b = {
  'problems' => {},
  'pending_resolved' => {
    'DB' => {
      'first_seen_at' => (now - 60 * 60).iso8601,
      'last_alert_at' => (now - 40 * 60).iso8601,
      'disappeared_at' => disappeared_recent,
      'level' => 'critical',
      'message' => 'down'
    }
  },
  'last_check_at' => (now - 5 * 60).iso8601
}
File.write(path7b, JSON.pretty_generate(state7b))
mgr7b = AlertStateManager.new(path7b)

analysis7b = mgr7b.analyze(resolved_results)
test("not yet stabilized -> not in resolved", true, analysis7b[:resolved].empty?)

# Problem returned from pending_resolved — not counted as new
path7c = tmp_state_file
state7c = {
  'problems' => {},
  'pending_resolved' => {
    'DB' => {
      'first_seen_at' => (now - 60 * 60).iso8601,
      'last_alert_at' => (now - 5 * 60).iso8601,
      'disappeared_at' => (now - 3 * 60).iso8601,
      'level' => 'critical',
      'message' => 'down'
    }
  },
  'last_check_at' => (now - 5 * 60).iso8601
}
File.write(path7c, JSON.pretty_generate(state7c))
mgr7c = AlertStateManager.new(path7c)

returned_results = [make_result(name: 'DB', level: :critical, message: 'back')]
analysis7c = mgr7c.analyze(returned_results)
test("problem returned from pending_resolved not counted as new", true, analysis7c[:new].empty?)

[path7, path7b, path7c].each { |p| File.delete(p) rescue nil }

# =============================================================================
# analyze — resolved + persisting (interval not expired)
# =============================================================================
section("analyze — resolved with unexpired persisting")

path7d = tmp_state_file
now = Time.now
# Problem A: active, last alerted 10 min ago (interval not expired)
# Problem B: in pending_resolved, disappeared 25 min ago (stabilized)
state7d = {
  'problems' => {
    'DB' => {
      'first_seen_at' => (now - 60 * 60).iso8601,
      'last_alert_at' => (now - 10 * 60).iso8601,
      'level' => 'critical',
      'message' => 'down'
    }
  },
  'pending_resolved' => {
    'Queue' => {
      'first_seen_at' => (now - 90 * 60).iso8601,
      'last_alert_at' => (now - 40 * 60).iso8601,
      'disappeared_at' => (now - 25 * 60).iso8601,
      'level' => 'warning',
      'message' => 'slow'
    }
  },
  'last_check_at' => (now - 10 * 60).iso8601
}
File.write(path7d, JSON.pretty_generate(state7d))
mgr7d = AlertStateManager.new(path7d)

# Current: DB still critical, Queue gone (resolved)
results7d = [
  make_result(name: 'DB', level: :critical, message: 'still down'),
  make_result(name: 'Server', level: :ok, message: 'up')
]
analysis7d = mgr7d.analyze(results7d)

test("resolved Queue in analysis[:resolved]", true, analysis7d[:resolved].any? { |p| p[:name] == 'Queue' })
test("should_alert true (resolved triggers it)", true, analysis7d[:should_alert])
test("no new problems", true, analysis7d[:new].empty?)
test("no persisting problems (interval not expired for DB)", true, analysis7d[:persisting].empty?)

File.delete(path7d) rescue nil

# =============================================================================
# in_day_hours? (private — tested via analyze with known state)
# =============================================================================
section("in_day_hours? (via constants)")

test("DAY_INTERVAL is 30", 30, AlertStateManager::DAY_INTERVAL)
test("NIGHT_INTERVAL is 60", 60, AlertStateManager::NIGHT_INTERVAL)
test("DAY_START is 7", 7, AlertStateManager::DAY_START)
test("DAY_END is 23", 23, AlertStateManager::DAY_END)
test("RESOLVED_STABILIZATION is 20", 20, AlertStateManager::RESOLVED_STABILIZATION)

# =============================================================================
# update_state
# =============================================================================
section("update_state")

path8 = tmp_state_file
mgr8 = AlertStateManager.new(path8)

# New problem gets first_seen_at and last_alert_at
new_res = [make_result(name: 'DB', level: :critical, message: 'down')]
a8 = mgr8.analyze(new_res)
mgr8.update_state(new_res, a8)

# Read saved state
saved = JSON.parse(File.read(path8))
test("new problem saved with first_seen_at", true, saved['problems']['DB'].key?('first_seen_at'))
test("new problem saved with last_alert_at", true, saved['problems']['DB'].key?('last_alert_at'))

# Problem disappears -> moves to pending_resolved
ok_res = [make_result(name: 'Server', level: :ok, message: 'ok')]
a8b = mgr8.analyze(ok_res)
mgr8.update_state(ok_res, a8b)

saved2 = JSON.parse(File.read(path8))
test("disappeared problem in pending_resolved", true, saved2['pending_resolved'].key?('DB'))
test("disappeared problem has disappeared_at", true, saved2['pending_resolved']['DB'].key?('disappeared_at'))

File.delete(path8) rescue nil

# =============================================================================
# has_previous_problems?
# =============================================================================
section("has_previous_problems?")

path9 = tmp_state_file
mgr9 = AlertStateManager.new(path9)
test("false for fresh state", false, mgr9.has_previous_problems?)

# Add a problem
r9 = [make_result(name: 'X', level: :warning, message: 'w')]
a9 = mgr9.analyze(r9)
mgr9.update_state(r9, a9)
test("true after adding problem", true, mgr9.has_previous_problems?)

File.delete(path9) rescue nil

# has_previous_problems? true if only pending_resolved
path9b = tmp_state_file
state9b = {
  'problems' => {},
  'pending_resolved' => { 'Y' => { 'first_seen_at' => Time.now.iso8601, 'last_alert_at' => Time.now.iso8601, 'disappeared_at' => Time.now.iso8601, 'level' => 'warning', 'message' => 'w' } },
  'last_check_at' => Time.now.iso8601
}
File.write(path9b, JSON.pretty_generate(state9b))
mgr9b = AlertStateManager.new(path9b)
test("true if problem only in pending_resolved", true, mgr9b.has_previous_problems?)

File.delete(path9b) rescue nil

# =============================================================================
# Full CRITICAL -> OK -> resolved flow (bug fix: update_state on :ok)
# =============================================================================
section("Full CRITICAL -> OK -> resolved flow")

path_flow = tmp_state_file
mgr_flow = AlertStateManager.new(path_flow)
now = Time.now

# Step 1: CRITICAL problem detected and alerted
crit_results = [
  make_result(name: 'Swap', level: :critical, message: 'Swap I/O 1708/s'),
  make_result(name: 'Server', level: :ok, message: 'ok')
]
analysis_flow1 = mgr_flow.analyze(crit_results)
test("flow: new Swap problem detected", true, analysis_flow1[:new].any? { |p| p[:name] == 'Swap' })
test("flow: should_alert for new problem", true, analysis_flow1[:should_alert])
mgr_flow.update_state(crit_results, analysis_flow1)
test("flow: Swap in problems after alert", true, mgr_flow.has_previous_problems?)

# Step 2: Problem disappears (status :ok), update_state must be called
ok_results = [
  make_result(name: 'Swap', level: :ok, message: 'Swap OK'),
  make_result(name: 'Server', level: :ok, message: 'ok')
]
analysis_flow2 = mgr_flow.analyze(ok_results)
test("flow: no should_alert yet (stabilization pending)", false, analysis_flow2[:should_alert])

# KEY: update_state must be called even when status is :ok (this is the bug fix)
mgr_flow.update_state(ok_results, analysis_flow2)
saved_flow = JSON.parse(File.read(path_flow))
test("flow: Swap moved to pending_resolved", true, saved_flow['pending_resolved'].key?('Swap'))
test("flow: Swap has disappeared_at", true, saved_flow['pending_resolved']['Swap'].key?('disappeared_at'))
test("flow: problems is empty", true, saved_flow['problems'].empty?)

# Step 3: Simulate time passing (>20 min) by rewriting disappeared_at
saved_flow['pending_resolved']['Swap']['disappeared_at'] = (now - 25 * 60).iso8601
File.write(path_flow, JSON.pretty_generate(saved_flow))
mgr_flow_after = AlertStateManager.new(path_flow)

analysis_flow3 = mgr_flow_after.analyze(ok_results)
test("flow: resolved Swap after stabilization", true, analysis_flow3[:resolved].any? { |p| p[:name] == 'Swap' })
test("flow: should_alert true for resolved", true, analysis_flow3[:should_alert])

File.delete(path_flow) rescue nil

# =============================================================================
# clear_state
# =============================================================================
section("clear_state")

path10 = tmp_state_file
mgr10 = AlertStateManager.new(path10)
r10 = [make_result(name: 'Z', level: :critical, message: 'fail')]
a10 = mgr10.analyze(r10)
mgr10.update_state(r10, a10)
test("has problems before clear", true, mgr10.has_previous_problems?)

mgr10.clear_state
test("no problems after clear_state", false, mgr10.has_previous_problems?)

File.delete(path10) rescue nil

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
