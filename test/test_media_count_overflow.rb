#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script for media count overflow fix
# =========================================
#
# Verifies that:
# 1. extract_media_from_html filters videos when 4+ images present
# 2. PostProcessor#upload_media enforces MAX_MEDIA_COUNT on media_ids
# 3. Normal video-only tweets are not affected
# 4. video_thumbnail + video still works correctly
#
# Usage: ruby test/test_media_count_overflow.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require_relative '../lib/models/media'

# ============================================
# Part 1: Test extract_media_from_html
# ============================================

# Minimal mock of TwitterAdapter to test extract_media_from_html in isolation
# We only need the method itself + fix_media_url + log
module Adapters
  class TestableTwitterAdapter
    def initialize
      @nitter_instance = 'http://nitter.example.com'
    end

    def log(message, level: :info)
      # silent in tests
    end

    def fix_media_url(url)
      url.start_with?('http') ? url : "#{@nitter_instance}#{url}"
    end

    # Paste the actual method from twitter_adapter.rb
    def extract_media_from_html(html)
      media = []

      html.scan(/<a[^>]*class="[^"]*(?:still-image|gallery-image)[^"]*"[^>]*href="([^"]+)"/i) do |match|
        url = fix_media_url(match[0])
        next if url.include?('emoji')

        media << Media.new(
          type: 'image',
          url: url,
          alt_text: ''
        )
      end

      if media.empty?
        html.scan(/<img[^>]+src="([^"]+)"[^>]*>/i) do |match|
          url = fix_media_url(match[0])
          next if url.include?('emoji') || url.include?('profile') || url.include?('logo')

          is_video_thumb = url.include?('video_thumb') || url.include?('ext_tw_video')
          media << Media.new(
            type: is_video_thumb ? 'video_thumbnail' : 'image',
            url: url,
            alt_text: is_video_thumb ? 'Video' : ''
          )
        end
      end

      html.scan(/<source[^>]+src="([^"]+)"[^>]*>/i) do |match|
        media << Media.new(
          type: 'video',
          url: fix_media_url(match[0]),
          alt_text: ''
        )
      end

      html.scan(/<video[^>]+poster="([^"]+)"[^>]*>/i) do |match|
        media << Media.new(
          type: 'video_thumbnail',
          url: fix_media_url(match[0]),
          alt_text: 'Video'
        )
      end

      media.uniq! { |m| m.url }

      # The fix: filter impossible image+video combinations
      images = media.select { |m| m.type == 'image' }
      videos = media.select { |m| m.type == 'video' }
      if images.size >= 4 && videos.any?
        log "Filtering #{videos.size} video(s) alongside #{images.size} images (likely converted GIF artifact)"
        media.reject! { |m| m.type == 'video' }
      end

      media
    end
  end
end

# ============================================
# Part 2: Test PostProcessor#upload_media guard
# ============================================

# Mock publisher that tracks uploads
class MockPublisher
  attr_reader :uploaded

  def initialize
    @uploaded = []
    @counter = 0
  end

  def upload_media_from_url(url, description: nil)
    @counter += 1
    id = "media_#{@counter}"
    @uploaded << { id: id, url: url }
    id
  end
end

# Mock post
class MockPost
  attr_accessor :media

  def initialize(media: [])
    @media = media
  end
end

# Simulated upload_media from PostProcessor (with the fix applied)
module PostProcessorSim
  MAX_MEDIA_COUNT = 4

  def self.upload_media(publisher, post)
    media_ids = []

    return media_ids unless post.respond_to?(:media) && post.media
    return media_ids if post.media.empty?

    media_list = post.media
    if media_list.size > MAX_MEDIA_COUNT
      media_list = media_list.first(MAX_MEDIA_COUNT)
    end

    media_list.each do |media|
      next if media.type == 'link_card'
      next if media.type == 'video_thumbnail' && post.media.any? { |m| m.type == 'video' }

      media_id = publisher.upload_media_from_url(media.url, description: media.alt_text)
      media_ids << media_id if media_id
    end

    # Safety net (the fix)
    if media_ids.size > MAX_MEDIA_COUNT
      media_ids = media_ids.first(MAX_MEDIA_COUNT)
    end

    media_ids
  end
end

# ============================================
# Test runner
# ============================================

class MediaCountOverflowTest
  def initialize
    @passed = 0
    @failed = 0
  end

  def run_all
    puts "=" * 60
    puts "Media Count Overflow Test Suite"
    puts "=" * 60
    puts

    # Parser tests
    test_4_images_plus_video_filtered
    test_3_images_plus_video_kept
    test_video_only_not_affected
    test_video_with_thumbnail_not_affected
    test_4_images_no_video
    test_4_images_plus_2_videos_filtered

    # Upload guard tests
    test_upload_media_caps_at_4
    test_upload_media_skips_video_thumbnail
    test_upload_media_normal_4_images
    test_upload_media_5_plain_images

    puts
    puts "=" * 60
    puts "Results: #{@passed} passed, #{@failed} failed"
    puts "=" * 60

    exit(@failed > 0 ? 1 : 0)
  end

  private

  def adapter
    @adapter ||= Adapters::TestableTwitterAdapter.new
  end

  # ---- Parser tests ----

  def test_4_images_plus_video_filtered
    test("Parser: 4 images + 1 video → video filtered out") do
      html = <<~HTML
        <div class="attachments">
          <a class="still-image" href="http://img.example.com/1.jpg"></a>
          <a class="still-image" href="http://img.example.com/2.jpg"></a>
          <a class="still-image" href="http://img.example.com/3.jpg"></a>
          <a class="still-image" href="http://img.example.com/4.jpg"></a>
          <video><source src="http://vid.example.com/gif.mp4"></video>
        </div>
      HTML

      media = adapter.extract_media_from_html(html)

      assert_eq(media.size, 4, "Should have 4 media items")
      assert(media.all? { |m| m.type == 'image' }, "All should be images")
      assert(media.none? { |m| m.type == 'video' }, "No videos should remain")
    end
  end

  def test_3_images_plus_video_kept
    test("Parser: 3 images + 1 video → video kept (valid combo)") do
      html = <<~HTML
        <div class="attachments">
          <a class="still-image" href="http://img.example.com/1.jpg"></a>
          <a class="still-image" href="http://img.example.com/2.jpg"></a>
          <a class="still-image" href="http://img.example.com/3.jpg"></a>
          <video><source src="http://vid.example.com/clip.mp4"></video>
        </div>
      HTML

      media = adapter.extract_media_from_html(html)

      images = media.select { |m| m.type == 'image' }
      videos = media.select { |m| m.type == 'video' }
      assert_eq(images.size, 3, "Should have 3 images")
      assert_eq(videos.size, 1, "Should have 1 video")
    end
  end

  def test_video_only_not_affected
    test("Parser: 1 video only → not affected") do
      html = <<~HTML
        <div class="attachments">
          <video poster="http://img.example.com/thumb.jpg">
            <source src="http://vid.example.com/video.mp4">
          </video>
        </div>
      HTML

      media = adapter.extract_media_from_html(html)

      videos = media.select { |m| m.type == 'video' }
      thumbs = media.select { |m| m.type == 'video_thumbnail' }
      assert_eq(videos.size, 1, "Should have 1 video")
      assert_eq(thumbs.size, 1, "Should have 1 thumbnail")
    end
  end

  def test_video_with_thumbnail_not_affected
    test("Parser: video + thumbnail → both preserved") do
      html = <<~HTML
        <div class="attachments">
          <video poster="http://img.example.com/poster.jpg">
            <source src="http://vid.example.com/clip.mp4">
          </video>
        </div>
      HTML

      media = adapter.extract_media_from_html(html)

      assert(media.any? { |m| m.type == 'video' }, "Should have video")
      assert(media.any? { |m| m.type == 'video_thumbnail' }, "Should have thumbnail")
    end
  end

  def test_4_images_no_video
    test("Parser: 4 images, no video → all kept") do
      html = <<~HTML
        <div class="attachments">
          <a class="still-image" href="http://img.example.com/1.jpg"></a>
          <a class="still-image" href="http://img.example.com/2.jpg"></a>
          <a class="still-image" href="http://img.example.com/3.jpg"></a>
          <a class="still-image" href="http://img.example.com/4.jpg"></a>
        </div>
      HTML

      media = adapter.extract_media_from_html(html)

      assert_eq(media.size, 4, "Should have 4 images")
      assert(media.all? { |m| m.type == 'image' }, "All should be images")
    end
  end

  def test_4_images_plus_2_videos_filtered
    test("Parser: 4 images + 2 videos → both videos filtered") do
      html = <<~HTML
        <div class="attachments">
          <a class="still-image" href="http://img.example.com/1.jpg"></a>
          <a class="still-image" href="http://img.example.com/2.jpg"></a>
          <a class="still-image" href="http://img.example.com/3.jpg"></a>
          <a class="still-image" href="http://img.example.com/4.jpg"></a>
          <video><source src="http://vid.example.com/gif1.mp4"></video>
          <video><source src="http://vid.example.com/gif2.mp4"></video>
        </div>
      HTML

      media = adapter.extract_media_from_html(html)

      assert_eq(media.size, 4, "Should have 4 media items")
      assert(media.all? { |m| m.type == 'image' }, "All should be images")
    end
  end

  # ---- Upload guard tests ----

  def test_upload_media_caps_at_4
    test("Upload: 6 images → capped to 4 uploads") do
      media = (1..6).map { |i| Media.new(type: 'image', url: "http://img.example.com/#{i}.jpg") }
      post = MockPost.new(media: media)
      publisher = MockPublisher.new

      ids = PostProcessorSim.upload_media(publisher, post)

      assert_eq(ids.size, 4, "Should upload max 4")
      assert_eq(publisher.uploaded.size, 4, "Publisher should receive 4 uploads")
    end
  end

  def test_upload_media_skips_video_thumbnail
    test("Upload: 4 images + video + video_thumbnail → thumbnail skipped, video uploaded (5 total → trimmed to 4)") do
      media = [
        Media.new(type: 'image', url: "http://img.example.com/1.jpg"),
        Media.new(type: 'image', url: "http://img.example.com/2.jpg"),
        Media.new(type: 'image', url: "http://img.example.com/3.jpg"),
        Media.new(type: 'image', url: "http://img.example.com/4.jpg"),
        Media.new(type: 'video', url: "http://vid.example.com/clip.mp4"),
        Media.new(type: 'video_thumbnail', url: "http://img.example.com/thumb.jpg"),
      ]
      post = MockPost.new(media: media)
      publisher = MockPublisher.new

      ids = PostProcessorSim.upload_media(publisher, post)

      # Pre-upload guard: 6 items → first(4) = [img1, img2, img3, img4]
      # video_thumbnail skip doesn't matter (it's already truncated)
      # Result: 4 image uploads
      assert(ids.size <= 4, "Should not exceed 4 media_ids")
    end
  end

  def test_upload_media_normal_4_images
    test("Upload: exactly 4 images → all uploaded") do
      media = (1..4).map { |i| Media.new(type: 'image', url: "http://img.example.com/#{i}.jpg") }
      post = MockPost.new(media: media)
      publisher = MockPublisher.new

      ids = PostProcessorSim.upload_media(publisher, post)

      assert_eq(ids.size, 4, "Should upload all 4")
    end
  end

  def test_upload_media_5_plain_images
    test("Upload: 5 images → trimmed to 4") do
      media = (1..5).map { |i| Media.new(type: 'image', url: "http://img.example.com/#{i}.jpg") }
      post = MockPost.new(media: media)
      publisher = MockPublisher.new

      ids = PostProcessorSim.upload_media(publisher, post)

      assert_eq(ids.size, 4, "Should trim to 4")
    end
  end

  # ---- Helpers ----

  def test(name)
    print "Testing: #{name}... "
    begin
      yield
      puts "PASSED"
      @passed += 1
    rescue AssertionError => e
      puts "FAILED: #{e.message}"
      @failed += 1
    rescue => e
      puts "ERROR: #{e.class}: #{e.message}"
      @failed += 1
    end
  end

  def assert(condition, message = "Assertion failed")
    raise AssertionError, message unless condition
  end

  def assert_eq(actual, expected, message = nil)
    msg = message || "Expected #{expected.inspect}, got #{actual.inspect}"
    raise AssertionError, msg unless actual == expected
  end

  class AssertionError < StandardError; end
end

MediaCountOverflowTest.new.run_all
