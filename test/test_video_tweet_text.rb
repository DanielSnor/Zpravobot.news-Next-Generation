#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Video Tweet Text Extraction Regression Test
# ============================================================
# Tests that video tweets preserve their text content when parsed
# from Nitter HTML. Previously, the regex in parse_main_tweet_from_html
# used (.*?)</div> which stopped at the first nested </div>,
# truncating the HTML before tweet-content was reached.
#
# Bug: Video tweets published as "🎬 URL" without text.
# Fix: Position-based extraction via extract_main_tweet_section.
#
# Usage:
#   ruby test/test_video_tweet_text.rb
# ============================================================

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require_relative '../lib/adapters/twitter_adapter'
require_relative '../lib/models/post'
require_relative '../lib/models/author'
require_relative '../lib/models/media'

class VideoTweetTextTest
  PASS = '✅'
  FAIL = '❌'

  def initialize
    @adapter = Adapters::TwitterAdapter.new(
      handle: 'ct24zive',
      nitter_instance: 'http://xn.zpravobot.news:8080'
    )
    @passed = 0
    @failed = 0
    @errors = []
  end

  def run
    puts "=" * 70
    puts "Video Tweet Text Extraction Regression Test"
    puts "=" * 70
    puts

    test_video_tweet_text_preserved
    test_video_tweet_with_hashtag_links
    test_video_tweet_with_multiple_lines
    test_text_only_tweet_still_works
    test_image_tweet_still_works
    test_empty_tweet_content
    test_extract_main_tweet_section_with_after_tweet
    test_extract_main_tweet_section_without_after_tweet
    test_extract_main_tweet_section_fallback_to_tweet_body

    puts
    puts "=" * 70
    puts "Results: #{@passed} passed, #{@failed} failed"
    puts "=" * 70

    if @failed > 0
      puts "\nFailed tests:"
      @errors.each { |e| puts "  #{FAIL} #{e}" }
      exit 1
    end
  end

  private

  # Core regression test: video tweet HTML must preserve text
  def test_video_tweet_text_preserved
    html = build_video_tweet_html(
      text_content: "Americko-íránské jaderné rozhovory",
      post_id: "2019817819136053712",
      username: "ct24zive"
    )

    post = send_parse(html, "2019817819136053712", "ct24zive")

    assert("video tweet text preserved") do
      post && post.text && post.text.include?("Americko-íránské jaderné rozhovory")
    end
  end

  # Video tweet with hashtag links in tweet-content
  def test_video_tweet_with_hashtag_links
    html = build_video_tweet_html(
      text_content: 'Sledujte <a href="/search?q=%23ČT24">#ČT24</a>, čtvrtek odpoledne',
      post_id: "2019817819136053712",
      username: "ct24zive"
    )

    post = send_parse(html, "2019817819136053712", "ct24zive")

    assert("video tweet hashtag links resolved") do
      post && post.text && post.text.include?("#ČT24") && post.text.include?("čtvrtek odpoledne")
    end
  end

  # Video tweet with multiple lines of text (the actual bug case)
  def test_video_tweet_with_multiple_lines
    text_lines = [
      '🔵 Americko-íránské jaderné rozhovory<br>',
      '🔵 EK navrhla dvacátý balík sankcí proti Rusku<br>',
      '🔵 Stavebnictví i průmyslu se loni dařilo<br>',
      '<br>',
      'Sledujte <a href="/search?q=%23ČT24">#ČT24</a>, čtvrtek odpoledne, 6. 2. 2026'
    ].join("\n")

    html = build_video_tweet_html(
      text_content: text_lines,
      post_id: "2019817819136053712",
      username: "ct24zive"
    )

    post = send_parse(html, "2019817819136053712", "ct24zive")

    assert("video tweet multi-line text preserved") do
      post &&
        post.text.include?("Americko-íránské jaderné rozhovory") &&
        post.text.include?("EK navrhla") &&
        post.text.include?("Stavebnictví") &&
        post.text.include?("#ČT24")
    end
  end

  # Ensure text-only tweets still parse correctly
  def test_text_only_tweet_still_works
    html = build_text_only_tweet_html(
      text_content: "Jednoduchý textový tweet bez médií.",
      post_id: "1234567890",
      username: "testuser"
    )

    adapter = Adapters::TwitterAdapter.new(handle: 'testuser', nitter_instance: 'http://example.com')
    post = adapter.send(:parse_main_tweet_from_html, html, "1234567890", "testuser")

    assert("text-only tweet still works") do
      post && post.text && post.text.include?("Jednoduchý textový tweet")
    end
  end

  # Ensure image tweets still parse correctly
  def test_image_tweet_still_works
    html = build_image_tweet_html(
      text_content: "Tweet s obrázkem.",
      post_id: "1234567891",
      username: "testuser"
    )

    adapter = Adapters::TwitterAdapter.new(handle: 'testuser', nitter_instance: 'http://example.com')
    post = adapter.send(:parse_main_tweet_from_html, html, "1234567891", "testuser")

    assert("image tweet still works") do
      post && post.text && post.text.include?("Tweet s obrázkem")
    end
  end

  # Empty tweet-content returns empty text (deleted tweet)
  def test_empty_tweet_content
    html = build_video_tweet_html(
      text_content: "",
      post_id: "9999999999",
      username: "testuser"
    )

    adapter = Adapters::TwitterAdapter.new(handle: 'testuser', nitter_instance: 'http://example.com')
    post = adapter.send(:parse_main_tweet_from_html, html, "9999999999", "testuser")

    assert("empty tweet-content returns empty text") do
      post && (post.text.nil? || post.text.strip.empty?)
    end
  end

  # extract_main_tweet_section stops at after-tweet boundary
  def test_extract_main_tweet_section_with_after_tweet
    html = <<~HTML
      <div class="main-thread">
        <div id="m" class="main-tweet">
          <div class="timeline-item">
            <div class="tweet-body">
              <div class="tweet-content media-body">Main tweet text</div>
            </div>
          </div>
        </div>
        <div class="after-tweet">
          <div class="tweet-content media-body">Reply text that should NOT appear</div>
        </div>
      </div>
    HTML

    section = @adapter.send(:extract_main_tweet_section, html)

    assert("extract_main_tweet_section stops at after-tweet") do
      section &&
        section.include?("Main tweet text") &&
        !section.include?("Reply text that should NOT appear")
    end
  end

  # extract_main_tweet_section works without after-tweet boundary
  def test_extract_main_tweet_section_without_after_tweet
    html = <<~HTML
      <div class="main-thread">
        <div id="m" class="main-tweet">
          <div class="timeline-item">
            <div class="tweet-body">
              <div class="tweet-content media-body">Solo tweet text</div>
            </div>
          </div>
        </div>
      </div>
    HTML

    section = @adapter.send(:extract_main_tweet_section, html)

    assert("extract_main_tweet_section works without after-tweet") do
      section && section.include?("Solo tweet text")
    end
  end

  # Fallback to tweet-body when main-tweet class is missing
  def test_extract_main_tweet_section_fallback_to_tweet_body
    html = <<~HTML
      <div class="timeline-item">
        <div class="tweet-body">
          <div class="tweet-content media-body">Fallback text</div>
        </div>
      </div>
    HTML

    section = @adapter.send(:extract_main_tweet_section, html)

    assert("extract_main_tweet_section fallback to tweet-body") do
      section && section.include?("Fallback text")
    end
  end

  # ============================================
  # HTML Fixtures
  # ============================================

  def build_video_tweet_html(text_content:, post_id:, username:)
    <<~HTML
      <html>
      <head><title>#{username}: "tweet"</title></head>
      <body>
      <div class="main-thread">
        <div id="m" class="main-tweet">
          <div class="timeline-item">
            <div class="tweet-body">
              <a class="username" href="/#{username}">@#{username}</a>
              <div class="tweet-content media-body">#{text_content}</div>
              <span class="tweet-date"><a href="/#{username}/status/#{post_id}" title="Feb 6, 2026 · 2:30 PM UTC">Feb 6</a></span>
              <div class="attachments card">
                <div class="gallery-video">
                  <div class="attachment video-container">
                    <video poster="/pic/video_thumb%2Fexample.jpg">
                      <source src="/vid/example.mp4" type="video/mp4">
                    </video>
                  </div>
                </div>
              </div>
              <div class="tweet-stats">
                <span class="icon-comment">5</span>
                <span class="icon-retweet">10</span>
                <span class="icon-heart">25</span>
              </div>
            </div>
          </div>
        </div>
        <div class="after-tweet">
          <div class="timeline-item">
            <div class="tweet-content media-body">This is a reply and should not be captured</div>
          </div>
        </div>
      </div>
      </body>
      </html>
    HTML
  end

  def build_text_only_tweet_html(text_content:, post_id:, username:)
    <<~HTML
      <html>
      <head><title>#{username}: "tweet"</title></head>
      <body>
      <div class="main-thread">
        <div id="m" class="main-tweet">
          <div class="timeline-item">
            <div class="tweet-body">
              <div class="tweet-content media-body">#{text_content}</div>
              <span class="tweet-date"><a href="/#{username}/status/#{post_id}" title="Feb 6, 2026 · 2:30 PM UTC">Feb 6</a></span>
              <div class="tweet-stats">
                <span class="icon-comment">0</span>
              </div>
            </div>
          </div>
        </div>
      </div>
      </body>
      </html>
    HTML
  end

  def build_image_tweet_html(text_content:, post_id:, username:)
    <<~HTML
      <html>
      <head><title>#{username}: "tweet"</title></head>
      <body>
      <div class="main-thread">
        <div id="m" class="main-tweet">
          <div class="timeline-item">
            <div class="tweet-body">
              <div class="tweet-content media-body">#{text_content}</div>
              <span class="tweet-date"><a href="/#{username}/status/#{post_id}" title="Feb 6, 2026 · 2:30 PM UTC">Feb 6</a></span>
              <div class="attachments">
                <a class="still-image" href="/pic/media%2Fexample.jpg">
                  <img src="/pic/media%2Fexample.jpg" />
                </a>
              </div>
              <div class="tweet-stats">
                <span class="icon-comment">0</span>
              </div>
            </div>
          </div>
        </div>
      </div>
      </body>
      </html>
    HTML
  end

  # ============================================
  # Helpers
  # ============================================

  def send_parse(html, post_id, username)
    @adapter.send(:parse_main_tweet_from_html, html, post_id, username)
  end

  def assert(description)
    result = yield
    if result
      @passed += 1
      puts "  #{PASS} #{description}"
    else
      @failed += 1
      @errors << description
      puts "  #{FAIL} #{description}"
    end
  rescue => e
    @failed += 1
    @errors << "#{description} (#{e.class}: #{e.message})"
    puts "  #{FAIL} #{description} — #{e.class}: #{e.message}"
  end
end

if __FILE__ == $PROGRAM_NAME
  VideoTweetTextTest.new.run
end
