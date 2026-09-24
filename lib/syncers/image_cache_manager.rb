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

    # 14 dní: Twitter se synchronizuje po skupinách jednou týdně, takže TTL 7 dní
    # vypršelo přesně v okamžiku dalšího běhu a cache nikdy nezabrala.
    IMAGE_CACHE_TTL = 86_400 * 14 # 14 days in seconds
    DEFAULT_CACHE_DIR = (ENV['ZBNW_DIR'] ? "#{ENV['ZBNW_DIR']}/cache/profiles" : 'cache/profiles').freeze

    # Cache soubory zapsané před zavedením záznamů o uploadu byly starým kódem
    # vždy i nahrány — chybějící záznam u nich neznamená selhání uploadu.
    # Nasazeno 24. 9. 2026 večer; poslední běh starého kódu zapsal cache ráno.
    # Po 2026-10-08 (14denní TTL) už žádný takový soubor v cache není a větev
    # v `unchanged_since_upload?` lze odstranit.
    UPLOAD_RECORDS_SINCE = Time.utc(2026, 9, 24, 12)

    # @param upload_scope [String, nil] rozliší záznamy o uploadu pro stejný handle
    #   na různých platformách (typicky platform_key syncera)
    def initialize(source_handle:, cache_dir:, use_cache:, download_options: {}, validate_content_type: false,
                   upload_scope: nil)
      @source_handle = source_handle
      @cache_dir = cache_dir
      @use_cache = use_cache
      @download_options = download_options
      @validate_content_type = validate_content_type
      @upload_scope = upload_scope

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
    # Záznam o naposledy nahraném obrázku
    # ============================================
    #
    # Mastodon při každém uploadu avataru/banneru vytvoří nový soubor a starý
    # smaže, i když jsou bajty totožné. Aby URL avatarů zůstávaly stabilní
    # (katalog, sdílecí stuby), nahrává se obrázek jen když se změnil jeho
    # SHA256 proti poslednímu úspěšnému uploadu. Záznam žije vedle cache
    # v souboru <type>_<handle>[.<scope>].uploaded, nezávisle na URL obrázku.

    # @param type [String] 'avatar' nebo 'banner'
    # @param data [String] binární obsah obrázku
    # @param cached_at [Time, nil] mtime cache souboru, ze kterého data pocházejí
    # @return [Boolean] true, když byl přesně tento obsah už úspěšně nahrán
    def unchanged_since_upload?(type, data, cached_at: nil)
      return false unless @use_cache

      recorded = uploaded_digest(type)
      if recorded.nil? && cached_at && cached_at < UPLOAD_RECORDS_SINCE
        # Přechodné pravidlo, viz UPLOAD_RECORDS_SINCE.
        record_upload(type, data)
        return true
      end

      !recorded.nil? && recorded == self.class.digest(data)
    end

    # Zapíše digest po úspěšném uploadu.
    def record_upload(type, data)
      return unless @use_cache

      Utils::AtomicFile.write(uploaded_digest_path(type), self.class.digest(data))
    rescue StandardError => e
      log "  ⚠️ Upload record write error: #{e.message}", level: :warn
    end

    # @return [String, nil] digest posledního uploadu, nil když záznam chybí
    def uploaded_digest(type)
      path = uploaded_digest_path(type)
      return nil unless File.exist?(path)

      value = File.read(path).strip
      value.empty? ? nil : value
    rescue StandardError
      nil
    end

    def self.digest(data)
      Digest::SHA256.hexdigest(data.to_s)
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

        # Záznamy o posledním uploadu — po vyčištění cache se obrázek nahraje znovu.
        %w[avatar banner].each do |type|
          Dir.glob(File.join(cache_dir, "#{type}_#{handle_key}{,.*}.uploaded")).each do |f|
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

        files = Dir.glob(File.join(cache_dir, '*')).reject { |f| f.end_with?('.meta', '.uploaded') }
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

    def uploaded_digest_path(type)
      handle_key = @source_handle.gsub(/[^a-zA-Z0-9]/, '_')
      scope = @upload_scope.to_s.gsub(/[^a-zA-Z0-9]/, '_')
      name = scope.empty? ? "#{type}_#{handle_key}.uploaded" : "#{type}_#{handle_key}.#{scope}.uploaded"
      File.join(@cache_dir, name)
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
