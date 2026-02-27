#!/usr/bin/env ruby
# frozen_string_literal: true

# Test BaseAdapter contract (#10)
# Validates abstract interface, config handling, subclass behavior
# Run: ruby test/test_base_adapter.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/adapters/base_adapter'

puts "=" * 60
puts "BaseAdapter Contract Tests"
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
  rescue exception_class => e
    puts "  \e[32m\u2713\e[0m #{name}"
    $passed += 1
  rescue => e
    puts "  \e[31m\u2717\e[0m #{name}"
    puts "    Expected: #{exception_class}"
    puts "    Got:      #{e.class}: #{e.message}"
    $failed += 1
  end
end

def section(title)
  puts
  puts "--- #{title} ---"
end

# =============================================================================
# 1. Abstract interface
# =============================================================================
section("Abstract Interface")

adapter = Adapters::BaseAdapter.new

test_raises("#platform raises NotImplementedError", NotImplementedError) do
  adapter.platform
end

test_raises("#fetch_posts raises NotImplementedError", NotImplementedError) do
  adapter.fetch_posts
end

test_raises("#fetch_posts with args raises NotImplementedError", NotImplementedError) do
  adapter.fetch_posts(since: Time.now, limit: 10)
end

# =============================================================================
# 2. Configuration
# =============================================================================
section("Configuration")

adapter1 = Adapters::BaseAdapter.new
test("Default config is empty hash", {}, adapter1.config)

config = { handle: 'test', url: 'http://example.com' }
adapter2 = Adapters::BaseAdapter.new(config)
test("Config is stored", config, adapter2.config)
test("Config is accessible via reader", 'test', adapter2.config[:handle])

# =============================================================================
# 3. Subclass behavior
# =============================================================================
section("Subclass Behavior")

# Define a test subclass
class TestAdapter < Adapters::BaseAdapter
  def platform
    'test'
  end

  def fetch_posts(since: nil, limit: 50)
    [{ id: 1, text: 'hello' }]
  end

  protected

  def validate_config!
    raise ArgumentError, "handle required" unless config[:handle]
  end
end

# Subclass with valid config
adapter3 = TestAdapter.new(handle: 'myhandle')
test("Subclass #platform returns value", 'test', adapter3.platform)
test("Subclass #fetch_posts returns data", [{ id: 1, text: 'hello' }], adapter3.fetch_posts)
test("Subclass #fetch_posts with args", [{ id: 1, text: 'hello' }], adapter3.fetch_posts(since: Time.now, limit: 5))

# Subclass with invalid config
test_raises("Subclass validate_config! raises on missing handle", ArgumentError) do
  TestAdapter.new({})
end

test_raises("Subclass validate_config! raises on nil config", ArgumentError) do
  TestAdapter.new
end

# =============================================================================
# 4. Subclass inherits BaseAdapter
# =============================================================================
section("Inheritance")

adapter4 = TestAdapter.new(handle: 'test')
test("Subclass is_a? BaseAdapter", true, adapter4.is_a?(Adapters::BaseAdapter))
test("Subclass responds to #config", true, adapter4.respond_to?(:config))
test("Subclass responds to #platform", true, adapter4.respond_to?(:platform))
test("Subclass responds to #fetch_posts", true, adapter4.respond_to?(:fetch_posts))

# =============================================================================
# 5. Log method (protected, accessible from subclass)
# =============================================================================
section("Logging")

class LogTestAdapter < Adapters::BaseAdapter
  attr_reader :log_output

  def platform; 'logtest'; end
  def fetch_posts(since: nil, limit: 50); []; end

  def test_log
    # Capture stdout
    old_stdout = $stdout
    $stdout = StringIO.new
    log("test message", level: :info)
    log("error message", level: :error)
    log("success message", level: :success)
    output = $stdout.string
    $stdout = old_stdout
    output
  end
end

require 'stringio'
log_adapter = LogTestAdapter.new
output = log_adapter.test_log
test("Log includes class name", true, output.include?('[LogTestAdapter]'))
test("Log includes message", true, output.include?('test message'))
test("Log includes error message", true, output.include?('error message'))

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
