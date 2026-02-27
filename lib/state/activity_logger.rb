# frozen_string_literal: true

require 'json'
require_relative '../support/loggable'

module State
  # Repository for activity logging (diagnostics)
  class ActivityLogger
    include Support::Loggable

    def initialize(db)
      @db = db
    end

    # Log an activity
    # @param source_id [String, nil] Source identifier (nil for system logs)
    # @param action [String] Action type: fetch, publish, skip, error, profile_sync, media_upload, transient_error
    # @param details [Hash, nil] Additional details as JSON
    def log_activity(source_id, action, details = nil)
      @db.conn.exec_params(
        <<~SQL,
          INSERT INTO activity_log (source_id, action, details)
          VALUES ($1, $2, $3)
        SQL
        [source_id, action, details&.to_json]
      )
    rescue PG::Error => e
      log_error("[ActivityLogger] Failed to log activity: #{e.message}")
    end

    # Convenience methods for common log actions
    def log_fetch(source_id, posts_found:)
      log_activity(source_id, 'fetch', { posts_found: posts_found })
    end

    def log_publish(source_id, post_id:, post_url: nil, mastodon_status_id: nil)
      log_activity(source_id, 'publish', {
        post_id: post_id,
        post_url: post_url,
        mastodon_status_id: mastodon_status_id
      }.compact)
    end

    def log_skip(source_id, post_id:, reason:)
      log_activity(source_id, 'skip', { post_id: post_id, reason: reason })
    end

    def log_error_activity(source_id, message:, details: nil)
      log_activity(source_id, 'error', { message: message, details: details }.compact)
    end

    def log_transient_error(source_id, message:)
      log_activity(source_id, 'transient_error', { message: message })
    end

    # Get recent activity for a source
    # @param source_id [String] Source identifier
    # @param limit [Integer] Max entries to return
    # @return [Array<Hash>]
    def recent_activity(source_id, limit: 50)
      result = @db.conn.exec_params(
        <<~SQL,
          SELECT action, details, created_at
          FROM activity_log
          WHERE source_id = $1
          ORDER BY created_at DESC
          LIMIT $2
        SQL
        [source_id, limit]
      )
      result.map do |row|
        {
          action: row['action'],
          details: row['details'] ? JSON.parse(row['details'], symbolize_names: true) : nil,
          created_at: row['created_at']
        }
      end
    end
  end
end
