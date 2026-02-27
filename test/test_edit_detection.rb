#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Test Script: Edit Detection
# ============================================================
#
# Testuje EditDetector a související komponenty.
#
# Použití:
#   ruby test/test_edit_detection.rb
#   ruby test/test_edit_detection.rb --verbose
#
# ============================================================

require_relative '../lib/processors/edit_detector'
# require_relative '../lib/state/state_manager'  # Not needed - using MockStateManager

# Mock StateManager pro testování bez DB
class MockStateManager
  def initialize
    @buffer = {}  # { "source_id:post_id" => entry }
  end

  def add_to_edit_buffer(source_id:, post_id:, username:, text_normalized:, text_hash: nil, mastodon_id: nil)
    key = "#{source_id}:#{post_id}"
    @buffer[key] = {
      source_id: source_id,
      post_id: post_id,
      username: username,
      text_normalized: text_normalized,
      text_hash: text_hash,
      mastodon_id: mastodon_id,
      created_at: Time.now
    }
    true
  end

  def update_edit_buffer_mastodon_id(source_id, post_id, mastodon_id)
    key = "#{source_id}:#{post_id}"
    return false unless @buffer[key]
    @buffer[key][:mastodon_id] = mastodon_id
    true
  end

  def find_by_text_hash(username, text_hash)
    entry = @buffer.values.find do |e|
      e[:username] == username && 
      e[:text_hash] == text_hash &&
      (Time.now - e[:created_at]) < 3600
    end
    return nil unless entry
    { post_id: entry[:post_id], mastodon_id: entry[:mastodon_id] }
  end

  def find_recent_buffer_entries(username, within_seconds: 3600)
    @buffer.values.select do |e|
      e[:username] == username &&
      (Time.now - e[:created_at]) < within_seconds
    end.sort_by { |e| -e[:created_at].to_i }
  end

  def mark_edit_superseded(source_id, post_id)
    key = "#{source_id}:#{post_id}"
    !!@buffer.delete(key)
  end

  def cleanup_edit_buffer(retention_hours: 2)
    cutoff = Time.now - (retention_hours * 3600)
    before = @buffer.size
    @buffer.reject! { |_, e| e[:created_at] < cutoff }
    before - @buffer.size
  end

  def buffer_contents
    @buffer
  end
end

# Mock Logger
class MockLogger
  attr_reader :messages

  def initialize
    @messages = []
  end

  def debug(msg)
    @messages << [:debug, msg]
  end

  def info(msg)
    @messages << [:info, msg]
    puts "  ℹ️  #{msg}" if $verbose
  end

  def warn(msg)
    @messages << [:warn, msg]
    puts "  ⚠️  #{msg}" if $verbose
  end
end

# Test runner
class EditDetectionTest
  def initialize
    @state_manager = MockStateManager.new
    @logger = MockLogger.new
    @detector = Processors::EditDetector.new(@state_manager, logger: @logger)
    @passed = 0
    @failed = 0
  end

  def run_all
    puts
    puts "=" * 60
    puts "  Edit Detection Tests"
    puts "=" * 60
    puts

    test_no_similar_post
    test_exact_match
    test_similar_text_detection
    test_newer_version_update
    test_older_version_skip
    test_batch_scenario
    test_normalization
    test_url_encoded_text

    puts
    puts "=" * 60
    puts "  Results: #{@passed} passed, #{@failed} failed"
    puts "=" * 60
    puts

    @failed == 0
  end

  private

  def test_no_similar_post
    test("No similar post - should publish new") do
      result = @detector.check_for_edit(
        "test_bot", "1001", "testuser",
        "This is a completely new tweet"
      )

      assert_equal :publish_new, result[:action]
      assert_nil result[:original_post_id]
    end
  end

  def test_exact_match
    test("Exact match - same text, different ID") do
      # Add original to buffer
      @detector.add_to_buffer(
        "test_bot", "2001", "exactuser",
        "Tento tweet je testovací zpráva",
        mastodon_id: "masto_2001"
      )

      # Check for edit with same text, different (newer) ID
      result = @detector.check_for_edit(
        "test_bot", "2002", "exactuser",
        "Tento tweet je testovací zpráva"
      )

      assert_equal :update_existing, result[:action]
      assert_equal "2001", result[:original_post_id]
      assert_equal "masto_2001", result[:mastodon_id]
      assert_equal 1.0, result[:similarity]
    end
  end

  def test_similar_text_detection
    test("Similar text detection - minor edits") do
      # Add original
      @detector.add_to_buffer(
        "test_bot", "3001", "simuser",
        "Prosím, zabývejme se mnohem více faktickým děním v naší zemi",
        mastodon_id: "masto_3001"
      )

      # Check with slightly different text (typo fix)
      result = @detector.check_for_edit(
        "test_bot", "3002", "simuser",
        "Prosím, zabývejme se mnohem a mnohem více faktickým děním v naší zemi"
      )

      assert_equal :update_existing, result[:action]
      assert result[:similarity] >= 0.80, "Similarity should be >= 0.80, got #{result[:similarity]}"
    end
  end

  def test_newer_version_update
    test("Newer version should trigger update") do
      # Add original with lower ID (older)
      @detector.add_to_buffer(
        "test_bot", "4001", "neweruser",
        "Original tweet text here",
        mastodon_id: "masto_4001"
      )

      # Check with higher ID (newer) - this is the edited version
      result = @detector.check_for_edit(
        "test_bot", "4002", "neweruser",
        "Original tweet text here with small edit"
      )

      # Should trigger update because 4002 > 4001
      assert_equal :update_existing, result[:action]
    end
  end

  def test_older_version_skip
    test("Older version should be skipped") do
      # Add newer version first (higher ID)
      @detector.add_to_buffer(
        "test_bot", "5002", "olderuser",
        "Final edited tweet text",
        mastodon_id: "masto_5002"
      )

      # Check with lower ID (older) - this is the original arriving late
      result = @detector.check_for_edit(
        "test_bot", "5001", "olderuser",
        "Final edited tweet text"
      )

      # Should skip because 5001 < 5002
      assert_equal :skip_older_version, result[:action]
      assert_equal "5002", result[:original_post_id]
    end
  end

  def test_batch_scenario
    test("Batch scenario - both versions unpublished") do
      # Simulate: original arrives, goes to buffer (not yet published)
      @detector.add_to_buffer(
        "test_bot", "6001", "batchuser",
        "Tweet that will be edited"
        # Note: no mastodon_id - not published yet
      )

      # Edit arrives immediately after
      result = @detector.check_for_edit(
        "test_bot", "6002", "batchuser",
        "Tweet that will be edited, now improved"
      )

      # Should publish the newer one and mark older as superseded
      assert_equal :publish_new, result[:action]
      assert_equal "6001", result[:superseded_post_id]
    end
  end

  def test_normalization
    test("Text normalization - URLs and mentions removed") do
      # Add original with URL
      @detector.add_to_buffer(
        "test_bot", "7001", "normuser",
        "Check this out https://t.co/abc123 @someone"
      )

      # Check with different URL but same base text
      result = @detector.check_for_edit(
        "test_bot", "7002", "normuser",
        "Check this out https://t.co/xyz789 @someone"
      )

      # Should match because URLs are normalized out
      assert [:update_existing, :publish_new].include?(result[:action])
      assert result[:similarity] >= 0.80 || result[:action] == :publish_new
    end
  end

  def test_url_encoded_text
    test("Already-decoded text - IFTTT similarity detection (text decoded by parser)") do
      # Text is now decoded by WebhookPayloadParser before reaching EditDetector
      # Simulate: original tweet added to buffer with already-decoded text
      @detector.add_to_buffer(
        "test_bot", "8001", "ct24zive",
        "administrativa donalda trumpa podle ap ukon\u010d\u00ed z\u00e1sah \u00da\u0159adu pro imigraci a cla (ice) v minnesot\u011b. operace vedla k masov\u00e9mu zadr\u017eov\u00e1n\u00ed, protest\u016fm a smrti dvou lid\u00ed. https://t.co/ps5syahl3k",
        mastodon_id: "masto_8001"
      )

      # Edited version arrives with slightly different decoded text
      result = @detector.check_for_edit(
        "test_bot", "8002", "ct24zive",
        "administrativa americk\u00e9ho prezidenta donalda trumpa podle ap ukon\u010d\u00ed z\u00e1sah \u00da\u0159adu pro imigraci a cla (ice) v minnesot\u011b. operace vedla k masov\u00e9mu zadr\u017eov\u00e1n\u00ed, protest\u016fm a smrti dvou lid\u00ed. https://t.co/pz8rz8how2"
      )

      # Should detect as edit (update_existing), not publish as new
      assert_equal :update_existing, result[:action]
      assert_equal "8001", result[:original_post_id]
      assert_equal "masto_8001", result[:mastodon_id]
      assert result[:similarity] >= 0.80, "Similarity should be >= 0.80, got #{result[:similarity]}"
    end
  end

  # Test helpers
  def test(name)
    print "  #{name}... "
    begin
      yield
      puts "✅"
      @passed += 1
    rescue AssertionError => e
      puts "❌"
      puts "    #{e.message}"
      @failed += 1
    rescue StandardError => e
      puts "💥"
      puts "    #{e.class}: #{e.message}"
      @failed += 1
    end
  end

  def assert(condition, message = "Assertion failed")
    raise AssertionError, message unless condition
  end

  def assert_equal(expected, actual)
    unless expected == actual
      raise AssertionError, "Expected #{expected.inspect}, got #{actual.inspect}"
    end
  end

  def assert_nil(value)
    raise AssertionError, "Expected nil, got #{value.inspect}" unless value.nil?
  end

  class AssertionError < StandardError; end
end

# Run tests
$verbose = ARGV.include?('--verbose') || ARGV.include?('-v')
success = EditDetectionTest.new.run_all
exit(success ? 0 : 1)
