# frozen_string_literal: true

require_relative '../support/loggable'

module State
  # Repository for edit detection buffer management
  class EditBufferManager
    include Support::Loggable

    def initialize(db)
      @db = db
    end

    # Add post to edit detection buffer
    #
    # @param source_id [String] Source/bot identifier
    # @param post_id [String] Original post ID
    # @param username [String] Twitter handle (lowercase)
    # @param text_normalized [String] Normalized text for comparison
    # @param text_hash [String] SHA-256 hash of normalized text
    # @param mastodon_id [String, nil] Mastodon status ID if already published
    # @return [Boolean]
    def add_to_edit_buffer(source_id:, post_id:, username:, text_normalized:, text_hash: nil, mastodon_id: nil)
      @db.conn.exec_params(
        <<~SQL,
          INSERT INTO edit_detection_buffer
          (source_id, post_id, username, text_normalized, text_hash, mastodon_id)
          VALUES ($1, $2, $3, $4, $5, $6)
          ON CONFLICT (source_id, post_id) DO UPDATE SET
          text_normalized = EXCLUDED.text_normalized,
          text_hash = EXCLUDED.text_hash,
          mastodon_id = COALESCE(EXCLUDED.mastodon_id, edit_detection_buffer.mastodon_id)
        SQL
        [source_id, post_id, username, text_normalized, text_hash, mastodon_id]
      )
      true
    rescue PG::Error => e
      log_error("[EditBufferManager] Failed to add to edit buffer: #{e.message}")
      false
    end

    # Update Mastodon ID in buffer (after successful publish)
    #
    # @param source_id [String] Source/bot identifier
    # @param post_id [String] Original post ID
    # @param mastodon_id [String] Mastodon status ID
    # @return [Boolean]
    def update_edit_buffer_mastodon_id(source_id, post_id, mastodon_id)
      result = @db.conn.exec_params(
        <<~SQL,
          UPDATE edit_detection_buffer
          SET mastodon_id = $3
          WHERE source_id = $1 AND post_id = $2
        SQL
        [source_id, post_id, mastodon_id]
      )
      result.cmd_tuples > 0
    rescue PG::Error => e
      log_error("[EditBufferManager] Failed to update mastodon_id: #{e.message}")
      false
    end

    # Find record by text hash (fast exact match)
    #
    # @param username [String] Twitter handle (lowercase)
    # @param text_hash [String] SHA-256 hash
    # @return [Hash, nil]
    def find_by_text_hash(username, text_hash)
      result = @db.conn.exec_params(
        <<~SQL,
          SELECT post_id, mastodon_id
          FROM edit_detection_buffer
          WHERE username = $1
          AND text_hash = $2
          AND created_at > NOW() - INTERVAL '1 hour'
          ORDER BY created_at DESC
          LIMIT 1
        SQL
        [username, text_hash]
      )

      return nil if result.ntuples.zero?

      row = result[0]
      {
        post_id: row['post_id'],
        mastodon_id: row['mastodon_id']
      }
    rescue PG::Error => e
      log_error("[EditBufferManager] Failed to find by text hash: #{e.message}")
      nil
    end

    # Find recent entries for a user (for similarity search)
    #
    # @param username [String] Twitter handle (lowercase)
    # @param within_seconds [Integer] Time window in seconds (default 3600 = 1h)
    # @return [Array<Hash>]
    def find_recent_buffer_entries(username, within_seconds: 3600)
      result = @db.conn.exec_params(
        <<~SQL,
          SELECT post_id, text_normalized, mastodon_id, created_at
          FROM edit_detection_buffer
          WHERE username = $1
          AND created_at > NOW() - ($2 || ' seconds')::INTERVAL
          ORDER BY created_at DESC
          LIMIT 10
        SQL
        [username, within_seconds.to_s]
      )

      result.map do |row|
        {
          post_id: row['post_id'],
          text_normalized: row['text_normalized'],
          mastodon_id: row['mastodon_id'],
          created_at: row['created_at']
        }
      end
    rescue PG::Error => e
      log_error("[EditBufferManager] Failed to find recent buffer entries: #{e.message}")
      []
    end

    # Mark post as superseded (delete from buffer)
    #
    # @param source_id [String] Source/bot identifier
    # @param post_id [String] Original post ID
    # @return [Boolean]
    def mark_edit_superseded(source_id, post_id)
      result = @db.conn.exec_params(
        'DELETE FROM edit_detection_buffer WHERE source_id = $1 AND post_id = $2',
        [source_id, post_id]
      )
      result.cmd_tuples > 0
    rescue PG::Error => e
      log_error("[EditBufferManager] Failed to mark superseded: #{e.message}")
      false
    end

    # Cleanup old entries from buffer
    #
    # @param retention_hours [Integer] Retention in hours (default 2)
    # @return [Integer] Number of deleted entries
    def cleanup_edit_buffer(retention_hours: 2)
      result = @db.conn.exec_params(
        'DELETE FROM edit_detection_buffer WHERE created_at < NOW() - ($1 || \' hours\')::INTERVAL',
        [retention_hours.to_s]
      )
      result.cmd_tuples
    rescue PG::Error => e
      log_error("[EditBufferManager] Failed to cleanup edit buffer: #{e.message}")
      0
    end

    # Get buffer statistics (for monitoring)
    #
    # @return [Hash]
    def edit_buffer_stats
      result = @db.conn.exec(
        <<~SQL
          SELECT
          COUNT(*) as total,
          COUNT(*) FILTER (WHERE created_at > NOW() - INTERVAL '1 hour') as last_hour,
          COUNT(DISTINCT username) as unique_users
          FROM edit_detection_buffer
        SQL
      )

      row = result[0]
      {
        total_entries: row['total'].to_i,
        entries_last_hour: row['last_hour'].to_i,
        unique_users: row['unique_users'].to_i
      }
    rescue PG::Error => e
      log_error("[EditBufferManager] Failed to get buffer stats: #{e.message}")
      { total_entries: 0, entries_last_hour: 0, unique_users: 0 }
    end

    # Check if post exists in buffer
    #
    # @param source_id [String] Source/bot identifier
    # @param post_id [String] Original post ID
    # @return [Boolean]
    def in_edit_buffer?(source_id, post_id)
      result = @db.conn.exec_params(
        'SELECT 1 FROM edit_detection_buffer WHERE source_id = $1 AND post_id = $2 LIMIT 1',
        [source_id, post_id]
      )
      result.ntuples > 0
    rescue PG::Error => e
      log_error("[EditBufferManager] Failed to check edit buffer: #{e.message}")
      false
    end
  end
end
