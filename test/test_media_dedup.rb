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
  HAMMING_THRESHOLD = 10

  def initialize
    @fingerprints = {}  # "source_id:hash" => { post_id:, media_url:, phash_int:, created_at: }
  end

  def find_media_fingerprint(source_id, sha256_hash, hours:)
    key = "#{source_id}:#{sha256_hash}"
    entry = @fingerprints[key]
    return nil unless entry
    return nil if (Time.now - entry[:created_at]) > hours * 3600

    entry
  end

  def find_similar_media_phash(source_id, phash_int, hours:, threshold: HAMMING_THRESHOLD)
    cutoff = Time.now - (hours * 3600)
    @fingerprints.each do |key, entry|
      next unless key.start_with?("#{source_id}:")
      next if entry[:created_at] < cutoff
      next if entry[:phash_int].nil?

      distance = (phash_int ^ entry[:phash_int]).to_s(2).count('1')
      return { post_id: entry[:post_id], distance: distance } if distance <= threshold
    end
    nil
  end

  def store_media_fingerprint(source_id:, sha256_hash:, post_id: nil, media_url: nil, phash_int: nil)
    key = "#{source_id}:#{sha256_hash}"
    @fingerprints[key] ||= { post_id: post_id, media_url: media_url, phash_int: phash_int, created_at: Time.now }
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
      phash_int: nil,
      created_at: Time.now - (age_hours * 3600)
    }
  end

  # Test helper — inject a fingerprint with specific phash_int value
  def inject_phash_fingerprint(source_id, sha256_hash, phash_int, age_hours: 0)
    key = "#{source_id}:#{sha256_hash}"
    @fingerprints[key] = {
      post_id: 'phash_post',
      media_url: nil,
      phash_int: phash_int,
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
    # pHash path (perceptual dedup)
    test_phash_duplicate_false_when_no_fingerprint
    test_phash_duplicate_true_when_similar_hash
    test_phash_duplicate_false_when_exceeds_threshold
    test_phash_duplicate_false_for_nil_phash
    test_phash_store_saves_phash_int
    test_phash_store_nil_phash_stores_without_phash
    test_phash_full_lifecycle

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
  # pHash path tests (perceptual dedup)
  # ============================================================

  def test_phash_duplicate_false_when_no_fingerprint
    test('duplicate_by_phash?: returns false when no phash fingerprint in DB') do
      state = MockStateManagerDedup.new
      dedup = Processors::MediaDedup.new(state)
      result = dedup.duplicate_by_phash?('source_a', 0x40636f0f8f38310f, hours: 72)
      assert_equal false, result
    end
  end

  def test_phash_duplicate_true_when_similar_hash
    test('duplicate_by_phash?: returns true when Hamming distance ≤ threshold') do
      state = MockStateManagerDedup.new
      dedup = Processors::MediaDedup.new(state)
      base_hash = 0x40636f0f8f38310f

      # Inject a stored fingerprint with exact same hash (Hamming: 0)
      state.inject_phash_fingerprint('source_a', 'sha_for_test', base_hash)

      result = dedup.duplicate_by_phash?('source_a', base_hash, hours: 72)
      assert_equal true, result
    end
  end

  def test_phash_duplicate_false_when_exceeds_threshold
    test('duplicate_by_phash?: returns false when Hamming distance > threshold (10)') do
      state = MockStateManagerDedup.new
      dedup = Processors::MediaDedup.new(state)
      base_hash = 0x0000000000000000

      # 11 bits different = Hamming 11 > threshold 10
      different_hash = (1 << 11) - 1  # 0b11111111111

      state.inject_phash_fingerprint('source_a', 'sha_for_test', base_hash)

      result = dedup.duplicate_by_phash?('source_a', different_hash, hours: 72)
      assert_equal false, result
    end
  end

  def test_phash_duplicate_false_for_nil_phash
    test('duplicate_by_phash?: returns false for nil phash_int (guard)') do
      state = MockStateManagerDedup.new
      state.inject_phash_fingerprint('source_a', 'sha_for_test', 0xFFFF)
      dedup = Processors::MediaDedup.new(state)

      result = dedup.duplicate_by_phash?('source_a', nil, hours: 72)
      assert_equal false, result
    end
  end

  def test_phash_store_saves_phash_int
    test('store!: saves phash_int alongside sha256') do
      state = MockStateManagerDedup.new
      dedup = Processors::MediaDedup.new(state)
      data = 'video binary content'
      phash = 0x40636f0f8f38310f

      dedup.store!('source_a', data, post_id: 'tweet_001', phash_int: phash)
      assert_equal 1, state.size

      # Find it and verify phash_int was stored
      hash = Digest::SHA256.hexdigest(data)
      found = state.find_media_fingerprint('source_a', hash, hours: 72)
      assert found, 'Expected fingerprint to be found'
      assert_equal phash, found[:phash_int]
    end
  end

  def test_phash_store_nil_phash_stores_without_phash
    test('store!: stores with phash_int=nil (URL-hash path)') do
      state = MockStateManagerDedup.new
      dedup = Processors::MediaDedup.new(state)
      url = 'https://video.twimg.com/ext_tw_video/123/pu/vid/large.mp4'

      # URL-hash path: phash_int not provided (defaults to nil)
      dedup.store!('source_a', url, post_id: 'tweet_large')
      assert_equal 1, state.size

      hash = Digest::SHA256.hexdigest(url)
      found = state.find_media_fingerprint('source_a', hash, hours: 72)
      assert found, 'Expected URL-hash fingerprint to be found'
      assert_equal nil, found[:phash_int]
    end
  end

  def test_phash_full_lifecycle
    test('pHash full lifecycle: store with phash → detect duplicate → different source skipped') do
      state = MockStateManagerDedup.new
      dedup = Processors::MediaDedup.new(state)
      source_id = 'rainmaker1973_twitter'
      video_data = 'binary mp4 content of weather video'
      phash = 0x40636f0f8f38310f  # pretend this was computed from the video

      # First occurrence — not a duplicate
      is_dup = dedup.duplicate_by_phash?(source_id, phash, hours: 72)
      assert_equal false, is_dup, 'First occurrence should NOT be duplicate'

      # Store fingerprint
      dedup.store!(source_id, video_data, post_id: 'tweet_001', phash_int: phash)
      assert_equal 1, state.size

      # Same video (exact same hash) — should be duplicate
      is_dup2 = dedup.duplicate_by_phash?(source_id, phash, hours: 72)
      assert_equal true, is_dup2, 'Second occurrence (exact hash) should be duplicate'

      # Nearly identical video (Hamming 3 = within threshold 10) — also duplicate
      near_hash = phash ^ 0b111  # flip 3 bits
      is_dup3 = dedup.duplicate_by_phash?(source_id, near_hash, hours: 72)
      assert_equal true, is_dup3, 'Nearly identical hash (Hamming 3) should be duplicate'

      # Clearly different video (Hamming 20 > threshold) — NOT duplicate
      far_hash = phash ^ 0xFFFFF  # flip 20 bits
      is_dup4 = dedup.duplicate_by_phash?(source_id, far_hash, hours: 72)
      assert_equal false, is_dup4, 'Very different hash (Hamming 20) should NOT be duplicate'

      # Different source — NOT duplicate (per-source dedup)
      is_dup5 = dedup.duplicate_by_phash?('other_source', phash, hours: 72)
      assert_equal false, is_dup5, 'Different source should NOT be duplicate'
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
