# frozen_string_literal: true

# ============================================================
# ImageCacheManager — TTL-based image download cache
# ============================================================
#
# Handles downloading profile images (avatar, banner) with a
# local file-system cache. Cache entries expire after IMAGE_CACHE_TTL.
#
# Used by BaseProfileSyncer; can also be used standalone.
#
# Usage:
#   cache = Syncers::ImageCacheManager.new(
#     source_handle: 'elonmusk',
#     cache_dir: 'cache/profiles',
#     use_cache: true,
#     download_options: { headers: { 'Cookie' => '...' } },
#     validate_content_type: true
#   )
#   result = cache.download_image_cached('https://...', 'avatar')
#   # => { data: <binary>, content_type: 'image/jpeg', filename: 'profile.jpg', from_cache: false }
#
# Class-level cache management:
#   ImageCacheManager.clear_cache('elonmusk')
#   ImageCacheManager.cache_stats
#
# ============================================================

require 'digest'
require 'fileutils'
require 'json'
require 'net/http'
require_relative '../utils/atomic_file'
require_relative '../utils/http_client'
require_relative '../utils/format_helpers'
require_relative '../support/loggable'

module Syncers
  class ImageCacheManager
    include Support::Loggable

    IMAGE_CACHE_TTL = 86_400 * 7 # 7 days in seconds
    DEFAULT_CACHE_DIR = (ENV['ZBNW_DIR'] ? "#{ENV['ZBNW_DIR']}/cache/profiles" : 'cache/profiles').freeze

    def initialize(source_handle:, cache_dir:, use_cache:, download_options: {}, validate_content_type: false)
      @source_handle = source_handle
      @cache_dir = cache_dir
      @use_cache = use_cache
      @download_options = download_options
      @validate_content_type = validate_content_type

      ensure_cache_dir if use_cache
    end

    # Download an image, returning cached copy if available (and not forcing refresh).
    # @param url [String] Image URL
    # @param type [String] Cache prefix, e.g. 'avatar' or 'banner'
    # @param force [Boolean] Bypass cache and re-download
    # @return [Hash, nil] { data:, content_type:, filename:, from_cache: } or nil on failure
    def download_image_cached(url, type, force: false)
      cache_key = cache_key_for_url(url, type)

      unless force
        cached = read_image_cache(cache_key)
        return cached if cached
      end

      image_data = download_image(url)
      return nil unless image_data

      write_image_cache(cache_key, image_data[:data], image_data[:content_type], image_data[:filename])
      image_data.merge(from_cache: false)
    end

    # ============================================
    # Class-level cache management
    # ============================================

    class << self
      # Clear all cached images for a handle
      # @param handle [String] Platform handle
      # @param cache_dir [String] Cache directory (defaults to DEFAULT_CACHE_DIR)
      # @return [Integer] Number of deleted files
      def clear_cache(handle, cache_dir: DEFAULT_CACHE_DIR)
        FileUtils.mkdir_p(cache_dir) unless Dir.exist?(cache_dir)

        handle_key = handle.gsub(/[^a-zA-Z0-9]/, '_')
        patterns = ["avatar_#{handle_key}_*", "banner_#{handle_key}_*"]

        deleted = 0
        patterns.each do |pattern|
          Dir.glob(File.join(cache_dir, pattern)).each do |f|
            File.delete(f) rescue nil
            deleted += 1
          end
          Dir.glob(File.join(cache_dir, "#{pattern}.meta")).each do |f|
            File.delete(f) rescue nil
          end
        end

        deleted
      end

      # Get cache statistics
      # @param cache_dir [String] Cache directory (defaults to DEFAULT_CACHE_DIR)
      # @return [Hash] Cache statistics
      def cache_stats(cache_dir: DEFAULT_CACHE_DIR)
        FileUtils.mkdir_p(cache_dir) unless Dir.exist?(cache_dir)

        files = Dir.glob(File.join(cache_dir, '*')).reject { |f| f.end_with?('.meta') }
        total_size = files.sum { |f| File.size(f) rescue 0 }

        {
          total_files: files.count,
          total_size_bytes: total_size,
          total_size_human: FormatHelpers.format_bytes(total_size),
          cache_dir: cache_dir
        }
      end
    end

    private

    def ensure_cache_dir
      FileUtils.mkdir_p(@cache_dir) unless Dir.exist?(@cache_dir)
    end

    def cache_key_for_url(url, prefix)
      hash = Digest::SHA256.hexdigest(url)[0, 16]
      handle_key = @source_handle.gsub(/[^a-zA-Z0-9]/, '_')
      "#{prefix}_#{handle_key}_#{hash}"
    end

    def cache_path(key)
      File.join(@cache_dir, key)
    end

    def read_image_cache(key)
      return nil unless @use_cache

      path = cache_path(key)
      meta_path = "#{path}.meta"

      return nil unless File.exist?(path) && File.exist?(meta_path)

      if (Time.now - File.mtime(path)) > IMAGE_CACHE_TTL
        File.delete(path) rescue nil
        File.delete(meta_path) rescue nil
        return nil
      end

      meta = JSON.parse(File.read(meta_path), symbolize_names: true)
      data = File.binread(path)

      {
        data: data,
        content_type: meta[:content_type],
        filename: meta[:filename],
        from_cache: true,
        cached_at: File.mtime(path)
      }
    rescue StandardError => e
      log "  ⚠️ Cache read error: #{e.message}", level: :warn
      nil
    end

    def write_image_cache(key, data, content_type, filename)
      return unless @use_cache

      path = cache_path(key)
      meta_path = "#{path}.meta"

      File.binwrite(path, data)
      Utils::AtomicFile.write(meta_path, { content_type: content_type, filename: filename }.to_json)
    rescue StandardError => e
      log "  ⚠️ Cache write error: #{e.message}", level: :warn
    end

    def download_image(url)
      response = HttpClient.download(url, **@download_options)

      return nil unless response&.is_a?(Net::HTTPSuccess)

      content_type = response['content-type']&.split(';')&.first || 'image/jpeg'

      if @validate_content_type
        unless content_type.start_with?('image/')
          log "  Invalid content type: #{content_type}", level: :warn
          return nil
        end
      end

      ext = case content_type
            when 'image/jpeg' then 'jpg'
            when 'image/png'  then 'png'
            when 'image/gif'  then 'gif'
            when 'image/webp' then 'webp'
            else 'jpg'
            end

      {
        data: response.body,
        content_type: content_type,
        filename: "profile.#{ext}"
      }
    rescue StandardError => e
      log "  Failed to download image: #{e.message}", level: :warn
      nil
    end
  end
end
