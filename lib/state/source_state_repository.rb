# frozen_string_literal: true

require_relative '../utils/hash_helpers'
require_relative '../support/loggable'

module State
  # Repository for source scheduling and error tracking
  class SourceStateRepository
    include Support::Loggable

    def initialize(db)
      @db = db
    end

    # Get source state
    # @param source_id [String] Source identifier
    # @return [Hash, nil]
    def get_source_state(source_id)
      result = @db.conn.exec_params(
        'SELECT * FROM source_state WHERE source_id = $1',
        [source_id]
      )
      result.ntuples > 0 ? HashHelpers.symbolize_keys(result[0]) : nil
    end

    # Update source state after successful check
    # @param source_id [String] Source identifier
    # @param posts_published [Integer] Number of posts published in this run
    def mark_check_success(source_id, posts_published: 0)
      @db.conn.exec_params(
        <<~SQL,
          INSERT INTO source_state (source_id, last_check, last_success, posts_today, last_reset, error_count)
          VALUES ($1, NOW(), NOW(), $2, CURRENT_DATE, 0)
          ON CONFLICT (source_id) DO UPDATE SET
          last_check = NOW(),
          last_success = NOW(),
          posts_today = CASE
            WHEN source_state.last_reset < CURRENT_DATE THEN $2
            ELSE source_state.posts_today + $2
          END,
          last_reset = CURRENT_DATE,
          error_count = 0,
          last_error = NULL
        SQL
        [source_id, posts_published]
      )
    end

    # Update source state after failed check
    # @param source_id [String] Source identifier
    # @param error_message [String] Error description
    def mark_check_error(source_id, error_message)
      @db.conn.exec_params(
        <<~SQL,
          INSERT INTO source_state (source_id, last_check, last_reset, error_count, last_error)
          VALUES ($1, NOW(), CURRENT_DATE, 1, $2)
          ON CONFLICT (source_id) DO UPDATE SET
          last_check = NOW(),
          error_count = source_state.error_count + 1,
          last_error = $2
        SQL
        [source_id, error_message]
      )
    end

    # Find sources due for checking
    # @param interval_minutes [Integer] Minimum minutes since last check
    # @param limit [Integer] Max sources to return
    # @return [Array<String>] Source IDs
    def sources_due_for_check(interval_minutes: 10, limit: 20)
      result = @db.conn.exec_params(
        <<~SQL,
          SELECT source_id FROM source_state
          WHERE last_check IS NULL
           OR last_check < NOW() - INTERVAL '1 minute' * $1
          ORDER BY last_check ASC NULLS FIRST
          LIMIT $2
        SQL
        [interval_minutes, limit]
      )
      result.map { |row| row['source_id'] }
    end

    # Reset daily counters
    def reset_daily_counters
      @db.conn.exec('UPDATE source_state SET posts_today = 0, last_reset = CURRENT_DATE')
      log_info('[SourceStateRepository] Daily counters reset')
    end

    # Get overall statistics
    # @return [Hash]
    def stats
      total_published = @db.conn.exec('SELECT COUNT(*) FROM published_posts')[0]['count'].to_i
      total_sources = @db.conn.exec('SELECT COUNT(*) FROM source_state')[0]['count'].to_i
      sources_with_errors = @db.conn.exec('SELECT COUNT(*) FROM source_state WHERE error_count > 0')[0]['count'].to_i

      posts_today = @db.conn.exec(
        'SELECT COALESCE(SUM(posts_today), 0) FROM source_state WHERE last_reset = CURRENT_DATE'
      )[0]['coalesce'].to_i

      {
        total_published: total_published,
        total_sources: total_sources,
        sources_with_errors: sources_with_errors,
        posts_today: posts_today
      }
    end

    # Get sources with consecutive errors
    # @param min_errors [Integer] Minimum error count
    # @return [Array<Hash>]
    def sources_with_errors(min_errors: 3)
      result = @db.conn.exec_params(
        <<~SQL,
          SELECT source_id, error_count, last_error, last_success
          FROM source_state
          WHERE error_count >= $1
          ORDER BY error_count DESC
        SQL
        [min_errors]
      )
      result.map { |row| HashHelpers.symbolize_keys(row) }
    end
  end
end
