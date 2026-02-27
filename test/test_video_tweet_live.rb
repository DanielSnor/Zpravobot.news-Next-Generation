#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Live Video Tweet Fetch Test
# ============================================================
# Tests that fetch_single_post correctly extracts text and
# detects video from 5 live Nitter URLs. Validates the fix
# for video tweets that previously lost their text content
# due to the nested-div regex bug in parse_main_tweet_from_html.
#
# Usage:
#   ruby test/test_video_tweet_live.rb
# ============================================================

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require_relative '../lib/adapters/twitter_adapter'

class VideoTweetLiveTest
  PASS = 'PASS'
  FAIL = 'FAIL'

  NITTER_INSTANCE = 'http://xn.zpravobot.news:8080'

  # Each entry: [full_url, username, post_id]
  TEST_URLS = [
    ['http://xn.zpravobot.news:8080/ct24zive/status/2019817819136053712',       'ct24zive',       '2019817819136053712'],
    ['http://xn.zpravobot.news:8080/MichalKubal/status/2016191911380357232',    'MichalKubal',    '2016191911380357232'],
    ['http://xn.zpravobot.news:8080/OMGzine/status/2016203442851622990',        'OMGzine',        '2016203442851622990'],
    ['http://xn.zpravobot.news:8080/nezvany_host/status/2016128372649214013',   'nezvany_host',   '2016128372649214013'],
    ['http://xn.zpravobot.news:8080/Posledniskaut/status/2016144880108490761',  'Posledniskaut',  '2016144880108490761'],
  ].freeze

  def initialize
    @passed = 0
    @failed = 0
    @results = []
  end

  def run
    puts '=' * 70
    puts 'Live Video Tweet Fetch Test'
    puts '=' * 70
    puts "Nitter instance: #{NITTER_INSTANCE}"
    puts "Time: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
    puts "Testing #{TEST_URLS.size} URLs..."
    puts

    TEST_URLS.each_with_index do |(url, username, post_id), idx|
      puts '-' * 70
      puts "#{idx + 1}/#{TEST_URLS.size}  @#{username}  post_id=#{post_id}"
      puts "  URL: #{url}"
      puts

      test_single_post(username, post_id)
      puts
    end

    print_summary
  end

  private

  def test_single_post(username, post_id)
    adapter = Adapters::TwitterAdapter.new(
      handle: username,
      nitter_instance: NITTER_INSTANCE
    )

    post = adapter.fetch_single_post(post_id)

    if post.nil?
      record_result(username, post_id, false, 'fetch_single_post returned nil')
      puts "  Result: #{FAIL} -- fetch_single_post returned nil (network error or parse failure)"
      return
    end

    text = post.text || ''
    has_text = !text.strip.empty?
    has_video = post.has_video?

    text_preview = text.strip.gsub(/\n/, ' ')[0, 100]
    text_preview += '...' if text.strip.length > 100

    puts "  Text extracted: #{has_text ? 'YES' : 'NO'}"
    puts "  Text preview:   #{has_text ? text_preview : '(empty)'}"
    puts "  Video detected: #{has_video ? 'YES' : 'NO'}"

    # A post passes if we got non-empty text from Nitter
    passed = has_text
    record_result(username, post_id, passed, has_text ? nil : 'text is empty')

    puts "  Result: #{passed ? PASS : FAIL}"
  end

  def record_result(username, post_id, passed, reason)
    if passed
      @passed += 1
    else
      @failed += 1
    end
    @results << { username: username, post_id: post_id, passed: passed, reason: reason }
  end

  def print_summary
    puts '=' * 70
    puts 'SUMMARY'
    puts '=' * 70
    puts

    @results.each do |r|
      status = r[:passed] ? PASS : FAIL
      detail = r[:reason] ? " (#{r[:reason]})" : ''
      puts "  #{status}  @#{r[:username]}  #{r[:post_id]}#{detail}"
    end

    puts
    puts "Total: #{@passed} passed, #{@failed} failed out of #{@results.size}"
    puts '=' * 70

    exit 1 if @failed > 0
  end
end

if __FILE__ == $PROGRAM_NAME
  VideoTweetLiveTest.new.run
end
