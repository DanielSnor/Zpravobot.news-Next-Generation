#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Test Suite: Syncers::ImageCacheManager
# ============================================================
#
# Unit testy pro TTL-based image download cache. Žádná síť, žádná DB.
# `HttpClient.download` se stubuje přes `define_singleton_method`.
#
# Usage:
#   ruby test/test_image_cache_manager.rb
#
# ============================================================

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'tmpdir'
require 'fileutils'
require 'json'
require 'syncers/image_cache_manager'

$passed = 0
$failed = 0

def test(name)
  result = yield
  if result
    $passed += 1
    puts "  ✔ #{name}"
  else
    $failed += 1
    puts "  ✘ #{name}"
  end
rescue StandardError => e
  $failed += 1
  puts "  ✘ #{name} — #{e.class}: #{e.message}"
  puts "    #{e.backtrace.first(3).join("\n    ")}"
end

# ------------------------------------------------------------
# Fake Net::HTTPResponse for stubbing HttpClient.download
# ------------------------------------------------------------

class FakeSuccessResponse < Net::HTTPSuccess
  def initialize(body:, content_type: 'image/jpeg')
    super('1.1', '200', 'OK')
    @fake_body = body
    @fake_headers = { 'content-type' => content_type }
  end

  def body
    @fake_body
  end

  def [](key)
    @fake_headers[key.downcase]
  end
end

class FakeFailureResponse < Net::HTTPNotFound
  def initialize
    super('1.1', '404', 'Not Found')
  end

  def body
    ''
  end

  def [](_key)
    nil
  end
end

# Stub HttpClient.download with a controllable response per test
def stub_http(response_or_proc)
  HttpClient.singleton_class.send(:alias_method, :__orig_download, :download) unless HttpClient.singleton_class.method_defined?(:__orig_download)
  HttpClient.define_singleton_method(:download) do |_url, **_opts|
    response_or_proc.is_a?(Proc) ? response_or_proc.call : response_or_proc
  end
end

def restore_http
  return unless HttpClient.singleton_class.method_defined?(:__orig_download)

  HttpClient.singleton_class.send(:alias_method, :download, :__orig_download)
end

# ------------------------------------------------------------
# Tests
# ------------------------------------------------------------

Dir.mktmpdir('image_cache_test_') do |tmpdir|
  puts "Testing Syncers::ImageCacheManager in #{tmpdir}"
  puts

  puts '--- Constructor & directory setup ---'

  test('creates cache dir when use_cache: true') do
    dir = File.join(tmpdir, 'new_cache_dir')
    Syncers::ImageCacheManager.new(source_handle: 'x', cache_dir: dir, use_cache: true)
    Dir.exist?(dir)
  end

  test('does NOT create cache dir when use_cache: false') do
    dir = File.join(tmpdir, 'skip_cache_dir')
    Syncers::ImageCacheManager.new(source_handle: 'x', cache_dir: dir, use_cache: false)
    !Dir.exist?(dir)
  end

  puts
  puts '--- download_image_cached — happy path ---'

  cache_dir = File.join(tmpdir, 'cache')
  FileUtils.mkdir_p(cache_dir)

  test('downloads and returns image data on cache miss') do
    stub_http(FakeSuccessResponse.new(body: 'IMGDATA'))
    mgr = Syncers::ImageCacheManager.new(source_handle: 'user1', cache_dir: cache_dir, use_cache: true)

    result = mgr.download_image_cached('https://example.com/img.jpg', 'avatar')
    restore_http

    result && result[:data] == 'IMGDATA' && result[:from_cache] == false && result[:content_type] == 'image/jpeg'
  end

  test('second call returns cached data (from_cache: true)') do
    stub_http(FakeSuccessResponse.new(body: 'CACHED'))
    mgr = Syncers::ImageCacheManager.new(source_handle: 'user2', cache_dir: cache_dir, use_cache: true)

    mgr.download_image_cached('https://example.com/cached.jpg', 'avatar')

    # Stub different response — if cache works, we still get CACHED
    stub_http(FakeSuccessResponse.new(body: 'SHOULD_NOT_BE_USED'))
    result = mgr.download_image_cached('https://example.com/cached.jpg', 'avatar')
    restore_http

    result && result[:data] == 'CACHED' && result[:from_cache] == true
  end

  test('force: true bypasses cache') do
    stub_http(FakeSuccessResponse.new(body: 'ORIGINAL'))
    mgr = Syncers::ImageCacheManager.new(source_handle: 'user3', cache_dir: cache_dir, use_cache: true)

    mgr.download_image_cached('https://example.com/force.jpg', 'avatar')

    stub_http(FakeSuccessResponse.new(body: 'REFRESHED'))
    result = mgr.download_image_cached('https://example.com/force.jpg', 'avatar', force: true)
    restore_http

    result && result[:data] == 'REFRESHED' && result[:from_cache] == false
  end

  test('use_cache: false always downloads') do
    call_count = 0
    stub_http(-> {
      call_count += 1
      FakeSuccessResponse.new(body: "CALL_#{call_count}")
    })

    mgr = Syncers::ImageCacheManager.new(source_handle: 'user4', cache_dir: cache_dir, use_cache: false)
    mgr.download_image_cached('https://example.com/nocache.jpg', 'avatar')
    mgr.download_image_cached('https://example.com/nocache.jpg', 'avatar')
    restore_http

    call_count == 2
  end

  puts
  puts '--- download_image_cached — failure paths ---'

  test('returns nil on download failure (404)') do
    stub_http(FakeFailureResponse.new)
    mgr = Syncers::ImageCacheManager.new(source_handle: 'user5', cache_dir: cache_dir, use_cache: true)

    result = mgr.download_image_cached('https://example.com/404.jpg', 'avatar')
    restore_http

    result.nil?
  end

  test('returns nil on nil response (network error)') do
    stub_http(nil)
    mgr = Syncers::ImageCacheManager.new(source_handle: 'user6', cache_dir: cache_dir, use_cache: true)

    result = mgr.download_image_cached('https://example.com/err.jpg', 'avatar')
    restore_http

    result.nil?
  end

  test('rejects non-image content-type when validate_content_type: true') do
    stub_http(FakeSuccessResponse.new(body: '<html>', content_type: 'text/html'))
    mgr = Syncers::ImageCacheManager.new(
      source_handle: 'user7', cache_dir: cache_dir, use_cache: true,
      validate_content_type: true
    )

    result = mgr.download_image_cached('https://example.com/page', 'avatar')
    restore_http

    result.nil?
  end

  test('accepts non-image content-type when validate_content_type: false (default)') do
    stub_http(FakeSuccessResponse.new(body: 'DATA', content_type: 'application/octet-stream'))
    mgr = Syncers::ImageCacheManager.new(source_handle: 'user8', cache_dir: cache_dir, use_cache: true)

    result = mgr.download_image_cached('https://example.com/octet', 'avatar')
    restore_http

    !result.nil? && result[:data] == 'DATA'
  end

  puts
  puts '--- Content-type → filename extension ---'

  [
    ['image/jpeg', 'profile.jpg'],
    ['image/png',  'profile.png'],
    ['image/gif',  'profile.gif'],
    ['image/webp', 'profile.webp'],
    ['image/bmp',  'profile.jpg']  # fallback
  ].each do |ct, expected_filename|
    test("filename extension for #{ct} → #{expected_filename}") do
      stub_http(FakeSuccessResponse.new(body: 'X', content_type: ct))
      mgr = Syncers::ImageCacheManager.new(
        source_handle: "ct_#{ct.gsub(/\W/, '_')}", cache_dir: cache_dir, use_cache: true
      )

      result = mgr.download_image_cached("https://example.com/#{ct}", 'avatar')
      restore_http

      result && result[:filename] == expected_filename
    end
  end

  puts
  puts '--- TTL expiry ---'

  test('expired cache entry is re-downloaded') do
    stub_http(FakeSuccessResponse.new(body: 'OLD'))
    mgr = Syncers::ImageCacheManager.new(source_handle: 'ttl1', cache_dir: cache_dir, use_cache: true)
    mgr.download_image_cached('https://example.com/ttl.jpg', 'avatar')

    # Simulate expired by backdating mtime on all cache files
    Dir.glob(File.join(cache_dir, 'avatar_ttl1_*')).each do |f|
      old_time = Time.now - (Syncers::ImageCacheManager::IMAGE_CACHE_TTL + 10)
      File.utime(old_time, old_time, f)
    end

    stub_http(FakeSuccessResponse.new(body: 'FRESH'))
    result = mgr.download_image_cached('https://example.com/ttl.jpg', 'avatar')
    restore_http

    result && result[:data] == 'FRESH' && result[:from_cache] == false
  end

  puts
  puts '--- Cache key stability ---'

  test('same URL → same cache key (hit across instances)') do
    stub_http(FakeSuccessResponse.new(body: 'SHARED'))
    mgr1 = Syncers::ImageCacheManager.new(source_handle: 'shared', cache_dir: cache_dir, use_cache: true)
    mgr1.download_image_cached('https://example.com/shared.jpg', 'avatar')

    stub_http(FakeSuccessResponse.new(body: 'DIFFERENT_RESPONSE'))
    mgr2 = Syncers::ImageCacheManager.new(source_handle: 'shared', cache_dir: cache_dir, use_cache: true)
    result = mgr2.download_image_cached('https://example.com/shared.jpg', 'avatar')
    restore_http

    result && result[:data] == 'SHARED' && result[:from_cache] == true
  end

  test('different URL → different cache key') do
    stub_http(FakeSuccessResponse.new(body: 'A'))
    mgr = Syncers::ImageCacheManager.new(source_handle: 'diffkey', cache_dir: cache_dir, use_cache: true)
    mgr.download_image_cached('https://example.com/a.jpg', 'avatar')

    stub_http(FakeSuccessResponse.new(body: 'B'))
    result = mgr.download_image_cached('https://example.com/b.jpg', 'avatar')
    restore_http

    result && result[:data] == 'B' && result[:from_cache] == false
  end

  test('non-alphanumeric characters in handle are sanitized') do
    stub_http(FakeSuccessResponse.new(body: 'X'))
    mgr = Syncers::ImageCacheManager.new(source_handle: 'weird@user.name', cache_dir: cache_dir, use_cache: true)
    mgr.download_image_cached('https://example.com/sanitize.jpg', 'avatar')
    restore_http

    # File name must not contain @ or .
    files = Dir.glob(File.join(cache_dir, 'avatar_weird*'))
    files.any? && files.none? { |f| File.basename(f).match?(/[@.]/) && !f.end_with?('.meta') }
  end

  puts
  puts '--- Class-level API: clear_cache ---'

  test('clear_cache deletes files + meta for a handle') do
    clr_dir = File.join(tmpdir, 'clear_test')
    FileUtils.mkdir_p(clr_dir)
    stub_http(FakeSuccessResponse.new(body: 'X'))

    mgr = Syncers::ImageCacheManager.new(source_handle: 'clrme', cache_dir: clr_dir, use_cache: true)
    mgr.download_image_cached('https://example.com/a.jpg', 'avatar')
    mgr.download_image_cached('https://example.com/b.jpg', 'banner')
    restore_http

    before = Dir.glob(File.join(clr_dir, '*')).count
    deleted = Syncers::ImageCacheManager.clear_cache('clrme', cache_dir: clr_dir)
    after = Dir.glob(File.join(clr_dir, '*')).count

    # Sanity: we had at least 4 files (avatar+banner, each main+meta),
    # after clear nothing should remain, and clear_cache should report >= 2
    before >= 4 && deleted >= 2 && after.zero?
  end

  test('clear_cache is no-op when no matching files') do
    empty_dir = File.join(tmpdir, 'empty_clr')
    deleted = Syncers::ImageCacheManager.clear_cache('nobody', cache_dir: empty_dir)
    deleted.zero?
  end

  puts
  puts '--- Class-level API: cache_stats ---'

  test('cache_stats returns counts and size') do
    stats_dir = File.join(tmpdir, 'stats_test')
    FileUtils.mkdir_p(stats_dir)
    stub_http(FakeSuccessResponse.new(body: 'A' * 1000))

    mgr = Syncers::ImageCacheManager.new(source_handle: 'statme', cache_dir: stats_dir, use_cache: true)
    mgr.download_image_cached('https://example.com/stats.jpg', 'avatar')
    restore_http

    stats = Syncers::ImageCacheManager.cache_stats(cache_dir: stats_dir)
    stats[:total_files] == 1 && stats[:total_size_bytes] == 1000 && stats[:cache_dir] == stats_dir
  end

  puts
  puts '--- Cache read resilience ---'

  test('corrupted meta file → cache miss → re-download') do
    corrupt_dir = File.join(tmpdir, 'corrupt')
    FileUtils.mkdir_p(corrupt_dir)
    stub_http(FakeSuccessResponse.new(body: 'FIRST'))

    mgr = Syncers::ImageCacheManager.new(source_handle: 'corrupt_user', cache_dir: corrupt_dir, use_cache: true)
    mgr.download_image_cached('https://example.com/c.jpg', 'avatar')

    # Corrupt the meta file
    meta_file = Dir.glob(File.join(corrupt_dir, '*.meta')).first
    File.write(meta_file, 'NOT_JSON')

    stub_http(FakeSuccessResponse.new(body: 'SECOND'))
    result = mgr.download_image_cached('https://example.com/c.jpg', 'avatar')
    restore_http

    result && result[:data] == 'SECOND' && result[:from_cache] == false
  end
end

puts
puts '=' * 50
puts "Passed: #{$passed}"
puts "Failed: #{$failed}"
exit($failed.zero? ? 0 : 1)
