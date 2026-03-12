#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Test Script: MediaDedup (Video SHA-256 Deduplikace)
# ============================================================
#
# Testuje Processors::MediaDedup s mock StateManagerem.
# Nevyžaduje DB ani síť.
#
# Použití:
#   ruby test/test_media_dedup.rb
#   ruby test/test_media_dedup.rb --verbose
#
# ============================================================

require_relative '../lib/processors/media_dedup'

# Mock StateManager — in-memory fingerprint store
class MockStateManagerDedup
  def initialize
    @fingerprints = {}  # "source_id:hash" => { post_id:, created_at: }
  end

  def find_media_fingerprint(source_id, sha256_hash, hours:)
    key = "#{source_id}:#{sha256_hash}"
    entry = @fingerprints[key]
    return nil unless entry
    return nil if (Time.now - entry[:created_at]) > hours * 3600

    entry
  end

  def store_media_fingerprint(source_id:, sha256_hash:, post_id: nil, media_url: nil)
    key = "#{source_id}:#{sha256_hash}"
    @fingerprints[key] ||= { post_id: post_id, media_url: media_url, created_at: Time.now }
    true
  end

  def cleanup_media_fingerprints(retention_hours: 96)
    cutoff = Time.now - (retention_hours * 3600)
    before = @fingerprints.size
    @fingerprints.reject! { |_, e| e[:created_at] < cutoff }
    before - @fingerprints.size
  end

  # Test helper — insert an old record for cleanup tests
  def inject_old_fingerprint(source_id, sha256_hash, age_hours)
    key = "#{source_id}:#{sha256_hash}"
    @fingerprints[key] = {
      post_id: 'old_post',
      media_url: nil,
      created_at: Time.now - (age_hours * 3600)
    }
  end

  def size
    @fingerprints.size
  end
end

# Mock Logger
class MockLoggerDedup
  attr_reader :messages

  def initialize
    @messages = []
  end

  def debug(msg);  @messages << [:debug, msg]; end
  def info(msg);   @messages << [:info,  msg]; puts "  ℹ️  #{msg}" if $verbose; end
  def warn(msg);   @messages << [:warn,  msg]; puts "  ⚠️  #{msg}" if $verbose; end
end

# ============================================================
# Test suite
# ============================================================

class MediaDedupTest
  def initialize
    @state_manager = MockStateManagerDedup.new
    @logger = MockLoggerDedup.new
    @dedup = Processors::MediaDedup.new(@state_manager, logger: @logger)
    @passed = 0
    @failed = 0
  end

  def run_all
    puts
    puts '=' * 60
    puts '  MediaDedup Tests'
    puts '=' * 60
    puts

    test_compute_hash_stable
    test_compute_hash_correct_sha256
    test_duplicate_returns_false_when_no_fingerprint
    test_duplicate_returns_true_when_fingerprint_exists
    test_duplicate_returns_false_after_window_expires
    test_duplicate_false_for_different_sources
    test_duplicate_false_for_nil_data
    test_duplicate_false_for_empty_data
    test_store_saves_fingerprint
    test_store_noop_for_nil_data
    test_store_noop_for_empty_data
    test_store_does_not_overwrite_existing
    test_cleanup_removes_old_entries
    test_cleanup_keeps_recent_entries
    test_cleanup_returns_deleted_count
    test_full_lifecycle

    puts
    puts '=' * 60
    puts "  Results: #{@passed} passed, #{@failed} failed"
    puts '=' * 60
    puts

    @failed == 0
  end

  private

  # ============================================================
  # Tests
  # ============================================================

  def test_compute_hash_stable
    test('compute_hash: same data → same hash') do
      data = 'hello video'
      hash1 = Digest::SHA256.hexdigest(data)
      hash2 = Digest::SHA256.hexdigest(data)
      assert_equal hash1, hash2
    end
  end

  def test_compute_hash_correct_sha256
    test('compute_hash: matches known SHA-256') do
      data = 'test'
      expected = '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08'
      actual = Digest::SHA256.hexdigest(data)
      assert_equal expected, actual
    end
  end

  def test_duplicate_returns_false_when_no_fingerprint
    test('duplicate?: returns false when no fingerprint in DB') do
      state = MockStateManagerDedup.new
      dedup = Processors::MediaDedup.new(state)
      result = dedup.duplicate?('source_a', 'some video bytes', hours: 72)
      assert_equal false, result
    end
  end

  def test_duplicate_returns_true_when_fingerprint_exists
    test('duplicate?: returns true when fingerprint found within window') do
      state = MockStateManagerDedup.new
      dedup = Processors::MediaDedup.new(state)
      data = 'video content bytes'

      # Store it first
      dedup.store!('source_a', data, post_id: 'post_001')

      # Now check — should be duplicate
      result = dedup.duplicate?('source_a', data, hours: 72)
      assert_equal true, result
    end
  end

  def test_duplicate_returns_false_after_window_expires
    test('duplicate?: returns false when fingerprint is outside window') do
      state = MockStateManagerDedup.new
      dedup = Processors::MediaDedup.new(state)
      data = 'video data for window test'

      hash = Digest::SHA256.hexdigest(data)
      # Inject an old record (100h old, outside 72h window)
      state.inject_old_fingerprint('source_b', hash, 100)

      result = dedup.duplicate?('source_b', data, hours: 72)
      assert_equal false, result
    end
  end

  def test_duplicate_false_for_different_sources
    test('duplicate?: returns false for same hash but different source') do
      state = MockStateManagerDedup.new
      dedup = Processors::MediaDedup.new(state)
      data = 'shared viral video'

      # Store for source_a
      dedup.store!('source_a', data, post_id: 'post_100')

      # Same video, but source_b — should NOT be a duplicate
      result = dedup.duplicate?('source_b', data, hours: 72)
      assert_equal false, result
    end
  end

  def test_duplicate_false_for_nil_data
    test('duplicate?: returns false for nil data (guard)') do
      result = @dedup.duplicate?('source_a', nil, hours: 72)
      assert_equal false, result
    end
  end

  def test_duplicate_false_for_empty_data
    test('duplicate?: returns false for empty data (guard)') do
      result = @dedup.duplicate?('source_a', '', hours: 72)
      assert_equal false, result
    end
  end

  def test_store_saves_fingerprint
    test('store!: saves fingerprint to state manager') do
      state = MockStateManagerDedup.new
      dedup = Processors::MediaDedup.new(state)
      data = 'new video to store'

      assert_equal 0, state.size
      dedup.store!('my_source', data, post_id: 'post_xyz', media_url: 'https://example.com/video.mp4')
      assert_equal 1, state.size

      # Verify it can be found
      hash = Digest::SHA256.hexdigest(data)
      found = state.find_media_fingerprint('my_source', hash, hours: 72)
      assert found, 'Expected fingerprint to be found'
      assert_equal 'post_xyz', found[:post_id]
    end
  end

  def test_store_noop_for_nil_data
    test('store!: no-op for nil data') do
      state = MockStateManagerDedup.new
      dedup = Processors::MediaDedup.new(state)
      dedup.store!('source_a', nil, post_id: 'post_nil')
      assert_equal 0, state.size
    end
  end

  def test_store_noop_for_empty_data
    test('store!: no-op for empty data') do
      state = MockStateManagerDedup.new
      dedup = Processors::MediaDedup.new(state)
      dedup.store!('source_a', '', post_id: 'post_empty')
      assert_equal 0, state.size
    end
  end

  def test_store_does_not_overwrite_existing
    test('store!: UPSERT — does not overwrite existing fingerprint (ON CONFLICT DO NOTHING)') do
      state = MockStateManagerDedup.new
      dedup = Processors::MediaDedup.new(state)
      data = 'duplicate video data'

      dedup.store!('source_a', data, post_id: 'first_post')
      dedup.store!('source_a', data, post_id: 'second_post')

      # Should still have only 1 entry
      assert_equal 1, state.size

      hash = Digest::SHA256.hexdigest(data)
      found = state.find_media_fingerprint('source_a', hash, hours: 72)
      # First post should win
      assert_equal 'first_post', found[:post_id]
    end
  end

  def test_cleanup_removes_old_entries
    test('cleanup: removes entries older than retention_hours') do
      state = MockStateManagerDedup.new
      dedup = Processors::MediaDedup.new(state)

      state.inject_old_fingerprint('source_a', 'hash_old_1', 100)  # 100h old
      state.inject_old_fingerprint('source_a', 'hash_old_2', 200)  # 200h old
      assert_equal 2, state.size

      deleted = dedup.cleanup(retention_hours: 96)
      assert_equal 2, deleted
      assert_equal 0, state.size
    end
  end

  def test_cleanup_keeps_recent_entries
    test('cleanup: keeps entries within retention window') do
      state = MockStateManagerDedup.new
      dedup = Processors::MediaDedup.new(state)

      dedup.store!('source_a', 'recent video data', post_id: 'recent_post')
      state.inject_old_fingerprint('source_a', 'old_hash', 100)  # too old
      assert_equal 2, state.size

      deleted = dedup.cleanup(retention_hours: 96)
      assert_equal 1, deleted
      assert_equal 1, state.size
    end
  end

  def test_cleanup_returns_deleted_count
    test('cleanup: returns integer count of deleted records') do
      state = MockStateManagerDedup.new
      dedup = Processors::MediaDedup.new(state)

      # Nothing to cleanup
      result = dedup.cleanup(retention_hours: 96)
      assert result.is_a?(Integer), "Expected Integer, got #{result.class}"
      assert_equal 0, result
    end
  end

  def test_full_lifecycle
    test('full lifecycle: first publish stored, second publish skipped') do
      state = MockStateManagerDedup.new
      dedup = Processors::MediaDedup.new(state)
      source_id = 'rainmaker1973_twitter'
      video_data = 'binary mp4 content of a viral weather video'

      # First occurrence — not a duplicate
      is_dup = dedup.duplicate?(source_id, video_data, hours: 72)
      assert_equal false, is_dup, 'First occurrence should NOT be duplicate'

      # Publish succeeds → store fingerprint
      dedup.store!(source_id, video_data, post_id: 'tweet_001')

      # Second occurrence 10 minutes later — should be detected as duplicate
      is_dup2 = dedup.duplicate?(source_id, video_data, hours: 72)
      assert_equal true, is_dup2, 'Second occurrence should be duplicate'

      # Different source — should NOT be duplicate
      is_dup_other = dedup.duplicate?('other_source', video_data, hours: 72)
      assert_equal false, is_dup_other, 'Different source should NOT be duplicate'
    end
  end

  # ============================================================
  # Test helpers
  # ============================================================

  def test(name)
    print "  #{name}... "
    begin
      yield
      puts '✅'
      @passed += 1
    rescue AssertionError => e
      puts '❌'
      puts "    #{e.message}"
      @failed += 1
    rescue StandardError => e
      puts '💥'
      puts "    #{e.class}: #{e.message}"
      puts e.backtrace.first(3).map { |l| "      #{l}" }.join("\n") if $verbose
      @failed += 1
    end
  end

  def assert(condition, message = 'Assertion failed')
    raise AssertionError, message unless condition
  end

  def assert_equal(expected, actual, message = nil)
    return if expected == actual

    raise AssertionError, message || "Expected #{expected.inspect}, got #{actual.inspect}"
  end

  class AssertionError < StandardError; end
end

# Run tests
$verbose = ARGV.include?('--verbose') || ARGV.include?('-v')
success = MediaDedupTest.new.run_all
exit(success ? 0 : 1)
