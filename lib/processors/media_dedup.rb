# frozen_string_literal: true

require 'digest'

module Processors
  # Media Deduplication via perceptual hashing (pHash / aHash)
  #
  # Detects visually identical videos even after re-encoding or CDN URL changes.
  # Opt-in per source via config `processing.video_dedup_hours`.
  #
  # Pipeline integration:
  #   PostProcessor Step 6b: downloads video → compute pHash via ImageMagick → check → skip or cache
  #   PostProcessor Step 9b: after successful publish → stores fingerprint (sha256 key + phash_int)
  #   If ImageMagick unavailable or pHash computation fails, dedup is silently skipped.
  #
  # Usage:
  #   dedup = Processors::MediaDedup.new(state_manager, logger: @logger)
  #   phash = ThumbnailPhash.compute(video_data)
  #   if phash && dedup.duplicate_by_phash?(source_id, phash, hours: 72)
  #     # Skip - visually identical video already published
  #   end
  #
  #   # After successful publish:
  #   dedup.store!(source_id, video_data, post_id: post_id, phash_int: phash)
  #
  class MediaDedup
    def initialize(state_manager, logger: nil)
      @state_manager = state_manager
      @logger = logger
    end

    # Check whether a visually similar video was already published (pHash Hamming scan)
    #
    # Preferred dedup method — robust against re-encoding and CDN URL changes.
    # Returns false if phash_int is nil (graceful no-op).
    #
    # @param source_id [String] Source/bot identifier
    # @param phash_int [Integer, nil] aHash 64-bit integer from ThumbnailPhash.compute
    # @param hours [Integer] Lookup window in hours
    # @return [Boolean] true if similar video already published
    def duplicate_by_phash?(source_id, phash_int, hours:)
      return false if phash_int.nil?

      existing = @state_manager.find_similar_media_phash(source_id, phash_int, hours: hours)
      if existing
        log_info("[MediaDedup] Duplicate video (pHash d=#{existing[:distance]}) for #{source_id} (original post: #{existing[:post_id]})")
        true
      else
        false
      end
    rescue StandardError => e
      log_warn("[MediaDedup] duplicate_by_phash? check failed for #{source_id}: #{e.message}")
      false
    end

    # Check whether video with this exact SHA-256 hash was already published
    #
    # Not used by the main pipeline (which uses duplicate_by_phash? instead).
    # Kept for potential diagnostics or manual tooling.
    #
    # @param source_id [String] Source/bot identifier
    # @param data [String] Binary video data
    # @param hours [Integer] Lookup window in hours
    # @return [Boolean] true if duplicate
    def duplicate?(source_id, data, hours:)
      return false if data.nil? || data.empty?

      hash = compute_hash(data)
      existing = @state_manager.find_media_fingerprint(source_id, hash, hours: hours)

      if existing
        log_info("[MediaDedup] Duplicate video (SHA-256) for #{source_id}: hash=#{hash[0..15]}... (original post: #{existing[:post_id]})")
        true
      else
        false
      end
    rescue StandardError => e
      log_warn("[MediaDedup] duplicate? check failed for #{source_id}: #{e.message}")
      false
    end

    # Store fingerprint after successful publication
    #
    # @param source_id [String] Source/bot identifier
    # @param data [String] Binary video data (sha256 used as unique key)
    # @param post_id [String, nil] Post ID for diagnostics
    # @param media_url [String, nil] Media URL for diagnostics
    # @param phash_int [Integer, nil] aHash 64-bit integer from ThumbnailPhash.compute
    def store!(source_id, data, post_id: nil, media_url: nil, phash_int: nil)
      return if data.nil? || data.empty?

      hash = compute_hash(data)
      @state_manager.store_media_fingerprint(
        source_id: source_id,
        sha256_hash: hash,
        post_id: post_id,
        media_url: media_url,
        phash_int: phash_int
      )
      log_debug("[MediaDedup] Stored fingerprint for #{source_id}/#{post_id}: hash=#{hash[0..15]}..." \
                "#{phash_int ? " phash=#{phash_int.to_s(16)}" : ' (URL-hash, no pHash)'}")
    rescue StandardError => e
      log_warn("[MediaDedup] Failed to store fingerprint for #{source_id}: #{e.message}")
    end

    # Delete fingerprints older than retention_hours
    #
    # @param retention_hours [Integer] Delete records older than N hours (default 96)
    # @return [Integer] Number of deleted records
    def cleanup(retention_hours: 96)
      @state_manager.cleanup_media_fingerprints(retention_hours: retention_hours)
    rescue StandardError => e
      log_warn("[MediaDedup] Cleanup failed: #{e.message}")
      0
    end

    private

    def compute_hash(data)
      Digest::SHA256.hexdigest(data)
    end

    def log_debug(msg)
      @logger ? @logger.debug(msg) : nil
    end

    def log_info(msg)
      @logger ? @logger.info(msg) : nil
    end

    def log_warn(msg)
      @logger ? @logger.warn(msg) : nil
    end
  end
end
