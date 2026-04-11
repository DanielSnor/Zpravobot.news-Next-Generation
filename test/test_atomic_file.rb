#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Test Suite: Utils::AtomicFile
# ============================================================
#
# Sanity tests for atomic write helper. No network, no DB.
#
# Usage:
#   ruby test/test_atomic_file.rb
#
# ============================================================

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'tmpdir'
require 'fileutils'
require 'json'
require 'utils/atomic_file'

$passed = 0
$failed = 0

def test(name)
  result = yield
  if result
    $passed += 1
    puts "  ✔ #{name}"
  else
    $failed += 1
    puts "  ✘ #{name}"
  end
rescue StandardError => e
  $failed += 1
  puts "  ✘ #{name} — #{e.class}: #{e.message}"
  puts "    #{e.backtrace.first(3).join("\n    ")}"
end

Dir.mktmpdir('atomic_file_test_') do |tmpdir|
  puts "Testing Utils::AtomicFile in #{tmpdir}"
  puts

  # ---- Happy path ----
  test('writes content to new file') do
    path = File.join(tmpdir, 'new.json')
    Utils::AtomicFile.write(path, '{"a":1}')
    File.exist?(path) && File.read(path) == '{"a":1}'
  end

  test('overwrites existing file') do
    path = File.join(tmpdir, 'existing.json')
    File.write(path, 'OLD')
    Utils::AtomicFile.write(path, 'NEW')
    File.read(path) == 'NEW'
  end

  test('returns bytes written') do
    path = File.join(tmpdir, 'bytes.txt')
    n = Utils::AtomicFile.write(path, 'hello')
    n == 5
  end

  test('creates parent directory if missing') do
    path = File.join(tmpdir, 'nested/dir/file.json')
    Utils::AtomicFile.write(path, 'x')
    File.exist?(path)
  end

  test('handles unicode with UTF-8 encoding') do
    path = File.join(tmpdir, 'utf8.json')
    content = '{"msg":"Příliš žluťoučký kůň"}'
    Utils::AtomicFile.write(path, content, encoding: 'UTF-8')
    File.read(path, encoding: 'UTF-8') == content
  end

  # ---- Atomicity — no .tmp leftover ----
  test('cleans up .tmp file on success') do
    path = File.join(tmpdir, 'cleanup.json')
    Utils::AtomicFile.write(path, 'data')
    leftover = Dir.glob("#{path}.tmp.*")
    leftover.empty?
  end

  test('leaves original file intact if tmp write fails') do
    path = File.join(tmpdir, 'preserve.json')
    File.write(path, 'ORIGINAL')

    # Make parent dir read-only to force tmp write failure
    parent = File.join(tmpdir, 'readonly_parent')
    FileUtils.mkdir_p(parent)
    target = File.join(parent, 'target.json')
    File.write(target, 'ORIGINAL')
    File.chmod(0o555, parent)

    original_preserved = false
    begin
      Utils::AtomicFile.write(target, 'NEW')
    rescue StandardError
      # Expected — readonly dir prevents tmp creation
      original_preserved = File.read(target) == 'ORIGINAL'
    ensure
      File.chmod(0o755, parent)
    end
    original_preserved
  end

  test('cleans up .tmp file on rename failure') do
    path = File.join(tmpdir, 'fail.json')
    Utils::AtomicFile.write(path, 'initial')

    # Simulate rename failure by stubbing File.rename to raise
    original_rename = File.method(:rename)
    File.define_singleton_method(:rename) { |_, _| raise 'simulated failure' }

    tmp_before = Dir.glob("#{path}.tmp.*")

    begin
      Utils::AtomicFile.write(path, 'new_content')
    rescue StandardError
      # Expected
    ensure
      File.define_singleton_method(:rename, original_rename)
    end

    tmp_after = Dir.glob("#{path}.tmp.*")
    # Should have cleaned up any tmp files it created
    tmp_after.size <= tmp_before.size
  end

  # ---- JSON round-trip (real use case) ----
  test('round-trip with JSON.pretty_generate') do
    path = File.join(tmpdir, 'state.json')
    state = { 'cycle' => 3, 'promoted' => %w[a b c], 'remaining' => [] }
    Utils::AtomicFile.write(path, JSON.pretty_generate(state))
    parsed = JSON.parse(File.read(path))
    parsed == state
  end
end

puts
puts "=" * 50
puts "Passed: #{$passed}"
puts "Failed: #{$failed}"
exit($failed.zero? ? 0 : 1)
