#!/usr/bin/env ruby
# frozen_string_literal: true

# Test Support::ThreadingSupport module (Phase 10.1)
# Validates thread detection, cache, DB fallback, author extraction
# Run: ruby test/test_threading_support.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/support/threading_support'

puts "=" * 60
puts "ThreadingSupport Tests"
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
# Stubs / Mocks
# =============================================================================

# Mock state_manager with configurable return value
class MockStateManager
  attr_accessor :thread_parent_id

  def initialize(thread_parent_id: nil)
    @thread_parent_id = thread_parent_id
  end

  def find_recent_thread_parent(_source_id)
    @thread_parent_id
  end
end

# Mock Post with is_thread_post and author
MockAuthor = Struct.new(:username, keyword_init: true)

MockPost = Struct.new(:is_thread_post, :author, keyword_init: true)

# Stub class that includes ThreadingSupport
class ThreadingHost
  include Support::ThreadingSupport

  attr_accessor :state_manager, :thread_cache

  def initialize(state_manager: MockStateManager.new)
    @state_manager = state_manager
    @thread_cache = {}
  end
end

# =============================================================================
# thread_post?
# =============================================================================
section("thread_post?")

host = ThreadingHost.new

post_thread = MockPost.new(is_thread_post: true, author: MockAuthor.new(username: 'alice'))
test("returns true when is_thread_post == true", true, host.thread_post?(post_thread))

post_not_thread = MockPost.new(is_thread_post: false, author: MockAuthor.new(username: 'alice'))
test("returns false when is_thread_post == false", false, host.thread_post?(post_not_thread))

# Object without is_thread_post method
plain_obj = Struct.new(:text).new('hello')
test("returns false when post has no is_thread_post", false, host.thread_post?(plain_obj))

# =============================================================================
# extract_author_handle (private — test via send)
# =============================================================================
section("extract_author_handle")

host = ThreadingHost.new

post_with_author = MockPost.new(is_thread_post: true, author: MockAuthor.new(username: 'Alice'))
test("extracts username from Author object", 'alice', host.send(:extract_author_handle, post_with_author))

hash_author_post = MockPost.new(is_thread_post: true, author: { 'username' => 'Bob' })
test("extracts username from Hash author", 'bob', host.send(:extract_author_handle, hash_author_post))

no_author_post = MockPost.new(is_thread_post: true, author: nil)
test("returns nil when post has no author", nil, host.send(:extract_author_handle, no_author_post))

upper_post = MockPost.new(is_thread_post: true, author: MockAuthor.new(username: 'FooBar'))
test("downcases handle", 'foobar', host.send(:extract_author_handle, upper_post))

# =============================================================================
# update_thread_cache + thread_cache_lookup
# =============================================================================
section("update_thread_cache + thread_cache_lookup")

host = ThreadingHost.new
post_alice = MockPost.new(is_thread_post: true, author: MockAuthor.new(username: 'alice'))

host.update_thread_cache('source_a', post_alice, '12345')
test("update_thread_cache stores mastodon_id", '12345', host.thread_cache.dig('source_a', 'alice'))

# resolve_thread_parent should find cached ID
cached_id = host.resolve_thread_parent('source_a', post_alice)
test("resolve_thread_parent finds cached ID", '12345', cached_id)

# Cache is per-source
post_alice2 = MockPost.new(is_thread_post: true, author: MockAuthor.new(username: 'alice'))
cached_other = host.send(:thread_cache_lookup, 'source_b', post_alice2)
test("cache is per-source (source_b returns nil)", nil, cached_other)

# Cache is per-author
post_bob = MockPost.new(is_thread_post: true, author: MockAuthor.new(username: 'bob'))
cached_bob = host.send(:thread_cache_lookup, 'source_a', post_bob)
test("cache is per-author (bob returns nil)", nil, cached_bob)

# update_thread_cache with nil mastodon_id does nothing
host2 = ThreadingHost.new
post_nil = MockPost.new(is_thread_post: true, author: MockAuthor.new(username: 'carol'))
host2.update_thread_cache('src', post_nil, nil)
test("update_thread_cache with nil mastodon_id stores nothing", {}, host2.thread_cache)

# clear_thread_cache
host.clear_thread_cache
test("clear_thread_cache empties cache", {}, host.thread_cache)

# =============================================================================
# resolve_thread_parent
# =============================================================================
section("resolve_thread_parent")

# Non-thread post returns nil
host3 = ThreadingHost.new
post_non_thread = MockPost.new(is_thread_post: false, author: MockAuthor.new(username: 'alice'))
test("returns nil for non-thread post", nil, host3.resolve_thread_parent('src', post_non_thread))

# Cache has priority over DB
sm_with_db = MockStateManager.new(thread_parent_id: 'db_999')
host4 = ThreadingHost.new(state_manager: sm_with_db)
post_t = MockPost.new(is_thread_post: true, author: MockAuthor.new(username: 'alice'))
host4.update_thread_cache('src', post_t, 'cache_111')
result = host4.resolve_thread_parent('src', post_t)
test("cache has priority over DB", 'cache_111', result)

# DB fallback when cache empty
sm_db = MockStateManager.new(thread_parent_id: 'db_555')
host5 = ThreadingHost.new(state_manager: sm_db)
post_t2 = MockPost.new(is_thread_post: true, author: MockAuthor.new(username: 'dave'))
result_db = host5.resolve_thread_parent('src', post_t2)
test("returns DB parent when cache empty", 'db_555', result_db)

# Both empty -> nil
sm_nil = MockStateManager.new(thread_parent_id: nil)
host6 = ThreadingHost.new(state_manager: sm_nil)
post_t3 = MockPost.new(is_thread_post: true, author: MockAuthor.new(username: 'eve'))
result_nil = host6.resolve_thread_parent('src', post_t3)
test("returns nil when both cache and DB empty", nil, result_nil)

# =============================================================================
# log_threading — no crash
# =============================================================================
section("log_threading")

test_no_error("log_threading does not crash without log_info/log") do
  host7 = ThreadingHost.new
  host7.send(:log_threading, "test message", "src")
end

# Host with log_info available
class ThreadingHostWithLog
  include Support::ThreadingSupport
  attr_accessor :state_manager, :thread_cache, :logged_messages

  def initialize
    @state_manager = MockStateManager.new
    @thread_cache = {}
    @logged_messages = []
  end

  def log_info(msg)
    @logged_messages << msg
  end
end

host8 = ThreadingHostWithLog.new
host8.send(:log_threading, "hello", "src")
test("log_threading calls log_info when available", true, host8.logged_messages.any? { |m| m.include?("hello") })

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
