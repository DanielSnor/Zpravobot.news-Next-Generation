#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Bluesky Thread Detection Test
# ============================================================
# Testuje:
# 1. Zda API vrací thread posty (self-replies) s různými filtry
# 2. Zda detect_self_reply správně identifikuje vlákna
# 3. Zda should_skip? propouští thread posty
#
# Použití:
#   ruby test_bluesky_threads.rb [handle]        # Live API test
#   ruby test_bluesky_threads.rb --offline       # Mock data test
#   ruby test_bluesky_threads.rb vladafoltan.bsky.social
#
# Pro integraci s ZBNW-NG:
#   cd /app/data/zbnw-ng
#   ruby test_bluesky_threads.rb vladafoltan.bsky.social
# ============================================================

require 'net/http'
require 'uri'
require 'json'
require 'time'

# Mock data pro offline testování
MOCK_FEED_DATA = {
  'feed' => [
    # Post 1: Normal post (no reply)
    {
      'post' => {
        'uri' => 'at://did:plc:abc123/app.bsky.feed.post/post1',
        'cid' => 'bafyrei1',
        'author' => {
          'did' => 'did:plc:abc123',
          'handle' => 'testuser.bsky.social',
          'displayName' => 'Test User'
        },
        'record' => {
          'text' => 'This is a normal post without any reply',
          'createdAt' => '2026-01-27T10:00:00Z'
        },
        'indexedAt' => '2026-01-27T10:00:01Z'
      }
    },
    # Post 2: Self-reply (THREAD POST) - should NOT be skipped
    {
      'post' => {
        'uri' => 'at://did:plc:abc123/app.bsky.feed.post/post2',
        'cid' => 'bafyrei2',
        'author' => {
          'did' => 'did:plc:abc123',
          'handle' => 'testuser.bsky.social',
          'displayName' => 'Test User'
        },
        'record' => {
          'text' => 'This is a thread continuation (self-reply)',
          'createdAt' => '2026-01-27T10:01:00Z',
          'reply' => {
            'parent' => {
              'uri' => 'at://did:plc:abc123/app.bsky.feed.post/post1',  # Same DID = self-reply
              'cid' => 'bafyrei1'
            },
            'root' => {
              'uri' => 'at://did:plc:abc123/app.bsky.feed.post/post1',
              'cid' => 'bafyrei1'
            }
          }
        },
        'indexedAt' => '2026-01-27T10:01:01Z'
      }
    },
    # Post 3: External reply - should be skipped when skip_replies=true
    {
      'post' => {
        'uri' => 'at://did:plc:abc123/app.bsky.feed.post/post3',
        'cid' => 'bafyrei3',
        'author' => {
          'did' => 'did:plc:abc123',
          'handle' => 'testuser.bsky.social',
          'displayName' => 'Test User'
        },
        'record' => {
          'text' => 'This is a reply to someone else',
          'createdAt' => '2026-01-27T10:02:00Z',
          'reply' => {
            'parent' => {
              'uri' => 'at://did:plc:xyz789/app.bsky.feed.post/other',  # Different DID = external reply
              'cid' => 'bafyrei_other'
            },
            'root' => {
              'uri' => 'at://did:plc:xyz789/app.bsky.feed.post/other',
              'cid' => 'bafyrei_other'
            }
          }
        },
        'indexedAt' => '2026-01-27T10:02:01Z'
      }
    },
    # Post 4: Another self-reply in the thread
    {
      'post' => {
        'uri' => 'at://did:plc:abc123/app.bsky.feed.post/post4',
        'cid' => 'bafyrei4',
        'author' => {
          'did' => 'did:plc:abc123',
          'handle' => 'testuser.bsky.social',
          'displayName' => 'Test User'
        },
        'record' => {
          'text' => 'Third post in my thread',
          'createdAt' => '2026-01-27T10:03:00Z',
          'reply' => {
            'parent' => {
              'uri' => 'at://did:plc:abc123/app.bsky.feed.post/post2',  # Same DID = self-reply
              'cid' => 'bafyrei2'
            },
            'root' => {
              'uri' => 'at://did:plc:abc123/app.bsky.feed.post/post1',
              'cid' => 'bafyrei1'
            }
          }
        },
        'indexedAt' => '2026-01-27T10:03:01Z'
      }
    }
  ]
}.freeze

class BlueskyThreadTest
  PUBLIC_API = "https://public.api.bsky.app/xrpc"
  
  FEED_FILTERS = {
    all: 'posts_with_replies',
    no_replies: 'posts_no_replies',
    threads: 'posts_and_author_threads'
  }.freeze

  def initialize(handle, offline: false)
    @handle = handle.gsub(/^@/, '')
    @offline = offline
    @results = { pass: 0, fail: 0, warn: 0 }
  end

  def run_all_tests
    puts "=" * 70
    puts "🧪 BLUESKY THREAD DETECTION TEST"
    puts "=" * 70
    puts "Handle: @#{@handle}"
    puts "Mode: #{@offline ? '📴 OFFLINE (mock data)' : '🌐 LIVE API'}"
    puts "Time: #{Time.now}"
    puts "=" * 70
    puts

    if @offline
      # Offline tests with mock data
      test_thread_detection_offline
      test_should_skip_logic
    else
      # Live API tests
      test_api_connection
      test_filter_comparison
      test_thread_detection
      test_should_skip_logic
    end

    # Summary
    print_summary
  end

  private

  # ============================================
  # Test: Thread Detection with Mock Data
  # ============================================
  def test_thread_detection_offline
    section "TEST: Thread Detection (Mock Data)"
    
    feed = MOCK_FEED_DATA['feed']
    
    puts "  Analyzing #{feed.length} mock posts:"
    puts
    
    feed.each_with_index do |item, i|
      post = item['post']
      record = post['record']
      author = post['author']
      reply = record['reply']
      
      has_reply = !reply.nil?
      
      if has_reply
        author_did = author['did']
        parent_uri = reply.dig('parent', 'uri')
        parent_did = extract_did_from_uri(parent_uri)
        is_self = (parent_did == author_did)
        
        # Simulate detect_self_reply result
        is_thread_post = is_self
        
        # Simulate should_skip? with skip_replies=true
        should_skip = simulate_should_skip(true, is_thread_post, true)
        
        status = is_self ? "🧵 THREAD" : "↩️  REPLY"
        skip_status = should_skip ? "⛔ SKIP" : "✅ KEEP"
        
        puts "  #{i + 1}. #{status} #{skip_status}"
        puts "     Text: #{record['text'][0..50]}..."
        puts "     is_reply: true"
        puts "     is_thread_post: #{is_thread_post}"
        puts "     Author DID: #{author_did}"
        puts "     Parent DID: #{parent_did}"
        puts "     should_skip?: #{should_skip}"
        
        # Verify logic
        if is_self && should_skip
          fail "Thread post should NOT be skipped!"
        elsif !is_self && !should_skip
          fail "External reply should be skipped when skip_replies=true!"
        else
          pass "Correct filtering decision"
        end
        puts
      else
        puts "  #{i + 1}. 📝 NORMAL POST ✅ KEEP"
        puts "     Text: #{record['text'][0..50]}..."
        puts "     is_reply: false"
        puts "     should_skip?: false"
        pass "Normal post not skipped"
        puts
      end
    end
  end

  # ============================================
  # Test 1: API Connection
  # ============================================
  def test_api_connection
    section "TEST 1: API Connection"
    
    begin
      response = fetch_author_feed(filter: 'posts_no_replies', limit: 5)
      
      if response['feed']
        pass "API returned #{response['feed'].length} posts"
      else
        fail "API returned no feed data"
      end
    rescue => e
      fail "API connection failed: #{e.message}"
    end
  end

  # ============================================
  # Test 2: Filter Comparison
  # ============================================
  def test_filter_comparison
    section "TEST 2: Filter Comparison (Thread Posts in Different Filters)"
    
    results = {}
    
    FEED_FILTERS.each do |name, filter_value|
      begin
        response = fetch_author_feed(filter: filter_value, limit: 50)
        feed = response['feed'] || []
        
        total = feed.length
        replies = feed.count { |item| item.dig('post', 'record', 'reply') }
        self_replies = feed.count { |item| is_self_reply?(item) }
        
        results[name] = {
          total: total,
          replies: replies,
          self_replies: self_replies
        }
        
        puts "  #{name.to_s.ljust(12)} (#{filter_value}):"
        puts "    Total posts: #{total}"
        puts "    Replies: #{replies}"
        puts "    Self-replies (threads): #{self_replies}"
        puts
      rescue => e
        warn "Failed to fetch with filter #{name}: #{e.message}"
      end
    end
    
    # Analysis
    puts "  📊 Analysis:"
    
    if results[:no_replies] && results[:threads]
      no_replies_threads = results[:no_replies][:self_replies]
      threads_threads = results[:threads][:self_replies]
      
      if no_replies_threads > 0
        pass "Filter 'no_replies' DOES return self-replies (#{no_replies_threads} found)"
      elsif threads_threads > 0
        warn "Filter 'no_replies' does NOT return self-replies!"
        warn "Consider changing default filter to :threads"
        puts
        puts "  ⚠️  RECOMMENDATION: Change default filter in validate_config!:"
        puts "      @filter = config[:filter] || :threads"
      else
        warn "No self-replies found in any filter (user may not have threads)"
      end
    end
  end

  # ============================================
  # Test 3: Thread Detection Logic
  # ============================================
  def test_thread_detection
    section "TEST 3: detect_self_reply Logic"
    
    response = fetch_author_feed(filter: 'posts_with_replies', limit: 50)
    feed = response['feed'] || []
    
    replies = feed.select { |item| item.dig('post', 'record', 'reply') }
    
    if replies.empty?
      warn "No replies found to test thread detection"
      return
    end
    
    puts "  Found #{replies.length} replies to analyze:"
    puts
    
    self_reply_count = 0
    external_reply_count = 0
    
    replies.first(10).each_with_index do |item, i|
      post = item['post']
      record = post['record']
      author = post['author']
      reply = record['reply']
      
      # Extract DIDs
      author_did = author['did']
      parent_uri = reply.dig('parent', 'uri')
      parent_did = extract_did_from_uri(parent_uri)
      
      is_self = (parent_did == author_did)
      
      if is_self
        self_reply_count += 1
        status = "🧵 THREAD"
      else
        external_reply_count += 1
        status = "↩️  REPLY"
      end
      
      puts "  #{i + 1}. #{status}"
      puts "     Author DID: #{author_did[0..30]}..."
      puts "     Parent DID: #{parent_did ? "#{parent_did[0..30]}..." : 'N/A'}"
      puts "     Match: #{is_self}"
      puts "     Text: #{record['text'][0..50]}..." if record['text']
      puts
    end
    
    if self_reply_count > 0
      pass "Thread detection working: #{self_reply_count} self-replies detected"
    else
      warn "No self-replies found in test data"
    end
  end

  # ============================================
  # Test 4: should_skip? Logic
  # ============================================
  def test_should_skip_logic
    section "TEST 4: should_skip? Logic Simulation"
    
    # Simulate the should_skip? method
    test_cases = [
      { is_reply: false, is_thread_post: false, skip_replies: true, expected: false, desc: "Normal post" },
      { is_reply: true, is_thread_post: false, skip_replies: true, expected: true, desc: "External reply (skip_replies=true)" },
      { is_reply: true, is_thread_post: true, skip_replies: true, expected: false, desc: "Thread post (skip_replies=true)" },
      { is_reply: true, is_thread_post: false, skip_replies: false, expected: false, desc: "External reply (skip_replies=false)" },
      { is_reply: true, is_thread_post: true, skip_replies: false, expected: false, desc: "Thread post (skip_replies=false)" },
    ]
    
    test_cases.each do |tc|
      result = simulate_should_skip(tc[:is_reply], tc[:is_thread_post], tc[:skip_replies])
      
      if result == tc[:expected]
        pass "#{tc[:desc]} → skip=#{result}"
      else
        fail "#{tc[:desc]} → expected skip=#{tc[:expected]}, got skip=#{result}"
      end
    end
  end

  # ============================================
  # Helper Methods
  # ============================================
  
  def fetch_author_feed(filter:, limit: 50)
    uri = URI("#{PUBLIC_API}/app.bsky.feed.getAuthorFeed")
    uri.query = URI.encode_www_form(
      actor: @handle,
      limit: limit,
      filter: filter
    )
    
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 20
    
    request = Net::HTTP::Get.new(uri)
    request['User-Agent'] = 'ZpravobotTest/1.0'
    request['Accept'] = 'application/json'
    
    response = http.request(request)
    
    unless response.is_a?(Net::HTTPSuccess)
      raise "API error #{response.code}: #{response.body}"
    end
    
    JSON.parse(response.body)
  end

  def is_self_reply?(item)
    post = item['post']
    record = post['record']
    author = post['author']
    reply = record['reply']
    
    return false unless reply
    
    author_did = author['did']
    parent_uri = reply.dig('parent', 'uri')
    parent_did = extract_did_from_uri(parent_uri)
    
    parent_did == author_did
  end

  def extract_did_from_uri(uri)
    return nil unless uri
    
    if uri =~ %r{^at://(did:[^/]+)/}
      $1
    else
      nil
    end
  end

  def simulate_should_skip(is_reply, is_thread_post, skip_replies)
    # Simulates the patched should_skip? logic
    if skip_replies && is_reply
      return true unless is_thread_post
    end
    false
  end

  # ============================================
  # Output Helpers
  # ============================================

  def section(title)
    puts
    puts "-" * 70
    puts title
    puts "-" * 70
    puts
  end

  def pass(msg)
    @results[:pass] += 1
    puts "  ✅ PASS: #{msg}"
  end

  def fail(msg)
    @results[:fail] += 1
    puts "  ❌ FAIL: #{msg}"
  end

  def warn(msg)
    @results[:warn] += 1
    puts "  ⚠️  WARN: #{msg}"
  end

  def print_summary
    puts
    puts "=" * 70
    puts "SUMMARY"
    puts "=" * 70
    puts
    puts "  ✅ Passed: #{@results[:pass]}"
    puts "  ❌ Failed: #{@results[:fail]}"
    puts "  ⚠️  Warnings: #{@results[:warn]}"
    puts
    
    if @results[:fail] == 0
      puts "  🎉 All tests passed!"
    else
      puts "  ⚠️  Some tests failed - review output above"
    end
    puts
  end
end

# ============================================
# Main
# ============================================
if __FILE__ == $0
  offline = ARGV.include?('--offline')
  handle = (ARGV.reject { |a| a.start_with?('--') }.first) || 'vladafoltan.bsky.social'
  
  test = BlueskyThreadTest.new(handle, offline: offline)
  test.run_all_tests
end
