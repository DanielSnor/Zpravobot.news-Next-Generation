# frozen_string_literal: true

require 'digest'

module Processors
  # Media Deduplication via SHA-256 fingerprinting
  #
  # Detects duplicate media (zejména videa) based on SHA-256 hash of binary data.
  # Opt-in per source via config `processing.video_dedup_hours`.
  #
  # Pipeline integration:
  #   PostProcessor Step 6b: downloads video → checks hash → if duplicate → skip post
  #   PostProcessor Step 9b: after successful publish → stores fingerprint
  #
  # Usage:
  #   dedup = Processors::MediaDedup.new(state_manager, logger: @logger)
  #   if dedup.duplicate?(source_id, video_binary_data, hours: 72)
  #     # Skip - video already published
  #   else
  #     # Continue with upload
  #   end
  #
  #   # After successful publish:
  #   dedup.store!(source_id, video_binary_data, post_id: post_id)
  #
  class MediaDedup
    def initialize(state_manager, logger: nil)
      @state_manager = state_manager
      @logger = logger
    end

    # Check whether video with this hash was already published within the window
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
        log_info("[MediaDedup] Duplicate video for #{source_id}: hash=#{hash[0..15]}... (original post: #{existing[:post_id]})")
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
    # @param data [String] Binary video data
    # @param post_id [String, nil] Post ID for diagnostics
    # @param media_url [String, nil] Media URL for diagnostics
    def store!(source_id, data, post_id: nil, media_url: nil)
      return if data.nil? || data.empty?

      hash = compute_hash(data)
      @state_manager.store_media_fingerprint(
        source_id: source_id,
        sha256_hash: hash,
        post_id: post_id,
        media_url: media_url
      )
      log_debug("[MediaDedup] Stored fingerprint for #{source_id}/#{post_id}: hash=#{hash[0..15]}...")
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
