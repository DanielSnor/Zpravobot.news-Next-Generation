# frozen_string_literal: true

require_relative 'base_repository'

module State
  # Repository for media fingerprints (video deduplication)
  #
  # Stores SHA-256 hashes (unique key) + optional pHash integer (perceptual hash)
  # for video deduplication within a configurable time window.
  # Deduplication is per-source — different sources can share the same video.
  #
  # Two lookup strategies:
  #   find()             — exact SHA-256 match (URL-hash fallback for large videos)
  #   find_similar_phash() — Hamming scan on phash_int (small videos, re-encoding robust)
  #
  # Retention: records older than 96h are cleaned up by cleanup().
  class MediaFingerprintRepository < BaseRepository

    # Find existing fingerprint within the lookup window
    #
    # @param source_id [String] Source/bot identifier
    # @param sha256_hash [String] SHA-256 hex digest to look up
    # @param hours [Integer] Lookup window in hours
    # @return [Hash, nil] { post_id:, created_at: } or nil if not found
    def find(source_id, sha256_hash, hours:)
      result = @db.conn.exec_params(
        <<~SQL,
          SELECT post_id, created_at
          FROM media_fingerprints
          WHERE source_id = $1
            AND sha256_hash = $2
            AND created_at > NOW() - ($3 || ' hours')::INTERVAL
          ORDER BY created_at DESC
          LIMIT 1
        SQL
        [source_id, sha256_hash, hours.to_s]
      )
      return nil if result.ntuples.zero?

      { post_id: result[0]['post_id'], created_at: result[0]['created_at'] }
    rescue PG::Error => e
      log_error("[MediaFingerprintRepository] Failed to find fingerprint: #{e.message}")
      nil
    end

    # Find entries with similar perceptual hash (Hamming distance scan in Ruby)
    #
    # Fetches all phash_int-bearing entries for the source within the window,
    # then computes Hamming distance in Ruby. Dataset is small (≤ ~150 rows for
    # a 72h window at ~2 videos/hour), so full scan is fine.
    #
    # @param source_id [String] Source/bot identifier
    # @param phash_int [Integer] aHash 64-bit integer to compare against
    # @param hours [Integer] Lookup window in hours
    # @param threshold [Integer] Maximum Hamming distance for "same video" (default 10)
    # @return [Hash, nil] { post_id:, distance: } or nil if not found
    def find_similar_phash(source_id, phash_int, hours:, threshold: 10)
      result = @db.conn.exec_params(
        <<~SQL,
          SELECT post_id, phash_int
          FROM media_fingerprints
          WHERE source_id = $1
            AND phash_int IS NOT NULL
            AND created_at > NOW() - ($2 || ' hours')::INTERVAL
        SQL
        [source_id, hours.to_s]
      )
      result.each do |row|
        stored_hash = row['phash_int'].to_i
        distance = (phash_int ^ stored_hash).to_s(2).count('1')
        return { post_id: row['post_id'], distance: distance } if distance <= threshold
      end
      nil
    rescue PG::Error => e
      log_error("[MediaFingerprintRepository] find_similar_phash failed: #{e.message}")
      nil
    end

    # Store a new fingerprint (UPSERT — ignores conflicts on same source+hash)
    #
    # @param source_id [String] Source/bot identifier
    # @param sha256_hash [String] SHA-256 hex digest (unique key)
    # @param post_id [String, nil] Post ID for diagnostics
    # @param media_url [String, nil] Media URL for diagnostics
    # @param phash_int [Integer, nil] aHash 64-bit integer; nil for URL-hash entries
    def store(source_id:, sha256_hash:, post_id: nil, media_url: nil, phash_int: nil)
      # PostgreSQL bigint is signed 64-bit; convert unsigned aHash to signed if needed
      phash_int = phash_int - (1 << 64) if phash_int && phash_int > ((1 << 63) - 1)
      @db.conn.exec_params(
        <<~SQL,
          INSERT INTO media_fingerprints (source_id, sha256_hash, post_id, media_url, phash_int)
          VALUES ($1, $2, $3, $4, $5)
          ON CONFLICT (source_id, sha256_hash) DO NOTHING
        SQL
        [source_id, sha256_hash, post_id, media_url, phash_int]
      )
      true
    rescue PG::Error => e
      log_error("[MediaFingerprintRepository] Failed to store fingerprint: #{e.message}")
      false
    end

    # Delete fingerprints older than retention_hours
    #
    # @param retention_hours [Integer] Delete records older than N hours (default 96)
    # @return [Integer] Number of deleted rows
    def cleanup(retention_hours: 96)
      result = @db.conn.exec_params(
        'DELETE FROM media_fingerprints WHERE created_at < NOW() - ($1 || \' hours\')::INTERVAL',
        [retention_hours.to_s]
      )
      result.cmd_tuples
    rescue PG::Error => e
      log_error("[MediaFingerprintRepository] Failed to cleanup: #{e.message}")
      0
    end
  end
end
