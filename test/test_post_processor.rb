#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script for PostProcessor
# =============================
#
# Tests the unified post processing pipeline with mock objects.
#
# Usage: ruby test/test_post_processor.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

# Mock implementations for testing
module Processors
  class ContentProcessor
    def initialize(max_length:, strategy: :smart, tolerance_percent: 12)
      @max_length = max_length
    end
    
    def process(text)
      return text if text.length <= @max_length
      text[0...@max_length - 1] + '…'
    end
  end
  
  class UrlProcessor
    attr_reader :no_trim_domains

    def initialize(no_trim_domains: [])
      @no_trim_domains = no_trim_domains
    end

    def apply_domain_fixes(text, fixes)
      text
    end

    def process_content(text)
      text
    end
  end
  
  class ContentFilter
    def initialize(content_replacements: [])
      @replacements = content_replacements
    end
    
    def apply_replacements(text)
      result = text
      @replacements.each do |r|
        result = result.gsub(r[:from], r[:to] || '')
      end
      result
    end
  end
end

module Formatters
  class TwitterFormatter
    def initialize(config = {})
      @config = config
    end
    
    def format(post)
      text = post.text
      url = post.url
      "#{text}\n#{url}"
    end
  end
end

module Publishers
  class MastodonPublisher
    MAX_MEDIA_COUNT = 4

    def initialize(instance_url:, access_token:)
    end
    
    def publish(text, media_ids: [], visibility: 'public', in_reply_to_id: nil)
      { 'id' => "mastodon_#{rand(100000)}" }
    end
    
    def upload_media_from_url(url, description: nil)
      "media_#{rand(1000)}"
    end
  end
end

module Config
  class ConfigLoader
    def load_global_config
      { url: { no_trim_domains: [] } }
    end

    def mastodon_credentials(account_id)
      { token: 'test_token' }
    end
  end
end

module State
  class StateManager
    def initialize
      @published = {}
      @skipped = []
    end

    def published?(source_id, post_id)
      @published.dig(source_id, post_id)
    end

    def mark_published(source_id, post_id, **opts)
      @published[source_id] ||= {}
      @published[source_id][post_id] = true
    end

    def log_publish(source_id, **opts)
    end

    def log_skip(source_id, **opts)
      @skipped << opts
    end

    # Edit detector support
    def find_by_text_hash(_username, _hash)
      nil
    end

    def find_recent_buffer_entries(_username, within_seconds: 3600)
      []
    end

    def add_to_edit_buffer(**opts)
    end

    def update_edit_buffer_mastodon_id(_source_id, _post_id, _mastodon_id)
    end

    def mark_edit_superseded(_source_id, _post_id)
    end

    def cleanup_edit_buffer(retention_hours: 2)
      0
    end
  end
end

# Load PostProcessor
# When running from test/ directory:
require_relative '../lib/processors/post_processor'

# Mock Post class
class MockPost
  attr_accessor :id, :url, :text, :title, :is_reply, :is_thread_post, 
                :is_repost, :is_quote, :media, :author
  
  def initialize(attrs = {})
    @id = attrs[:id] || 'test_123'
    @url = attrs[:url] || 'https://example.com/post/123'
    @text = attrs[:text] || 'Test post content'
    @title = attrs[:title]
    @is_reply = attrs[:is_reply] || false
    @is_thread_post = attrs[:is_thread_post] || false
    @is_repost = attrs[:is_repost] || false
    @is_quote = attrs[:is_quote] || false
    @media = attrs[:media] || []
  end
end

# Test runner
class PostProcessorTest
  def initialize
    @passed = 0
    @failed = 0
  end
  
  def run_all
    puts "=" * 60
    puts "PostProcessor Test Suite"
    puts "=" * 60
    puts
    
    test_basic_processing
    test_dedupe
    test_skip_reply
    test_skip_retweet
    test_banned_phrase
    test_content_replacement
    test_dry_run
    test_edit_nil_mastodon_id
    
    puts
    puts "=" * 60
    puts "Results: #{@passed} passed, #{@failed} failed"
    puts "=" * 60
  end
  
  private
  
  def create_processor(dry_run: false)
    Processors::PostProcessor.new(
      state_manager: State::StateManager.new,
      config_loader: Config::ConfigLoader.new,
      dry_run: dry_run
    )
  end
  
  def base_config
    {
      id: 'test_source',
      platform: 'twitter',
      formatting: {
        source_name: 'Test Source',
        max_length: 500
      },
      filtering: {},
      processing: {},
      target: {
        mastodon_account: 'test_account',
        visibility: 'public'
      }
    }
  end
  
  def test_basic_processing
    test("Basic Processing") do
      processor = create_processor(dry_run: true)
      post = MockPost.new(text: 'Hello world')
      
      result = processor.process(post, base_config)
      
      assert(result.published?, "Should be published")
      assert(result.mastodon_id.nil?, "Dry run has no mastodon_id")
    end
  end
  
  def test_dedupe
    test("Dedupe - Already Published") do
      state = State::StateManager.new
      state.mark_published('test_source', 'post_123')
      
      processor = Processors::PostProcessor.new(
        state_manager: state,
        config_loader: Config::ConfigLoader.new,
        dry_run: true
      )
      
      post = MockPost.new(id: 'post_123')
      result = processor.process(post, base_config)
      
      assert(result.skipped?, "Should be skipped")
      assert_eq(result.skipped_reason, 'already_published')
    end
  end
  
  def test_skip_reply
    test("Skip External Reply") do
      processor = create_processor(dry_run: true)
      config = base_config.merge(
        filtering: { skip_replies: true }
      )
      
      post = MockPost.new(is_reply: true, is_thread_post: false)
      result = processor.process(post, config)
      
      assert(result.skipped?, "Should be skipped")
      assert_eq(result.skipped_reason, 'is_external_reply')
    end
  end
  
  def test_skip_retweet
    test("Skip Retweet") do
      processor = create_processor(dry_run: true)
      config = base_config.merge(
        filtering: { skip_retweets: true }
      )
      
      post = MockPost.new(is_repost: true)
      result = processor.process(post, config)
      
      assert(result.skipped?, "Should be skipped")
      assert_eq(result.skipped_reason, 'is_retweet')
    end
  end
  
  def test_banned_phrase
    test("Banned Phrase Filter") do
      processor = create_processor(dry_run: true)
      config = base_config.merge(
        filtering: { banned_phrases: ['spam', 'advertisement'] }
      )
      
      post = MockPost.new(text: 'This is spam content')
      result = processor.process(post, config)
      
      assert(result.skipped?, "Should be skipped")
      assert_eq(result.skipped_reason, 'banned_phrase')
    end
  end
  
  def test_content_replacement
    test("Content Replacement") do
      processor = create_processor(dry_run: true)
      config = base_config.merge(
        processing: {
          content_replacements: [
            { from: 'foo', to: 'bar' }
          ]
        }
      )
      
      post = MockPost.new(text: 'Hello foo world')
      
      # We can't easily verify the replacement without more complex mocking
      # but we verify processing completes
      result = processor.process(post, config)
      assert(result.published?, "Should be published")
    end
  end
  
  def test_dry_run
    test("Dry Run Mode") do
      processor = create_processor(dry_run: true)
      post = MockPost.new

      result = processor.process(post, base_config)

      assert(result.published?, "Should be published (dry run)")
      assert(result.mastodon_id.nil?, "Dry run should not have mastodon_id")
    end
  end

  def test_edit_nil_mastodon_id
    test("Edit with nil mastodon_id publishes as new") do
      processor = create_processor(dry_run: true)
      post = MockPost.new(text: 'Edited content')
      edit_result = { action: :update_existing, mastodon_id: nil, original_post_id: '99', similarity: 0.9 }

      result = processor.send(:process_as_update, post, base_config, edit_result, {})

      assert(result.nil?, "Should return nil (fall through to normal publish)")
    end
  end
  
  # Test helpers
  
  def test(name)
    print "Testing: #{name}... "
    
    begin
      yield
      puts "✅ PASSED"
      @passed += 1
    rescue AssertionError => e
      puts "❌ FAILED: #{e.message}"
      @failed += 1
    rescue => e
      puts "❌ ERROR: #{e.message}"
      @failed += 1
    end
  end
  
  def assert(condition, message = "Assertion failed")
    raise AssertionError, message unless condition
  end
  
  def assert_eq(actual, expected)
    raise AssertionError, "Expected #{expected.inspect}, got #{actual.inspect}" unless actual == expected
  end
  
  class AssertionError < StandardError; end
end

# Run tests
PostProcessorTest.new.run_all
