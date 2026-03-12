# frozen_string_literal: true

require_relative '../support/loggable'

module State
  # Repository for media SHA-256 fingerprints (video deduplication)
  #
  # Stores SHA-256 hashes of video binary data to detect duplicate uploads
  # within a configurable time window. Deduplication is per-source — different
  # sources can legitimately share the same video.
  #
  # Retention: records older than 96h are cleaned up by cleanup().
  class MediaFingerprintRepository
    include Support::Loggable

    def initialize(db)
      @db = db
    end

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

    # Store a new fingerprint (UPSERT — ignores conflicts on same source+hash)
    #
    # @param source_id [String] Source/bot identifier
    # @param sha256_hash [String] SHA-256 hex digest
    # @param post_id [String, nil] Post ID for diagnostics
    # @param media_url [String, nil] Media URL for diagnostics
    def store(source_id:, sha256_hash:, post_id: nil, media_url: nil)
      @db.conn.exec_params(
        <<~SQL,
          INSERT INTO media_fingerprints (source_id, sha256_hash, post_id, media_url)
          VALUES ($1, $2, $3, $4)
          ON CONFLICT (source_id, sha256_hash) DO NOTHING
        SQL
        [source_id, sha256_hash, post_id, media_url]
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
