# frozen_string_literal: true

require 'date'
require_relative '../support/loggable'

module Stats
  # Manages account_stats_snapshot table for ZpravobotStats weekly reporting.
  #
  # Stores weekly snapshots of Mastodon account stats (followers, statuses, posts_week)
  # so we can compute the "skokan týdne" (biggest mover) across weeks.
  #
  # Usage:
  #   db = State::DatabaseConnection.new
  #   db.connect
  #   store = Stats::SnapshotStore.new(db)
  #   store.save_snapshot(Date.today, account_data, posts_per_account)
  #   prev = store.previous_snapshot(Date.today, weeks_back: 1)
  #   store.cleanup_old_snapshots(keep_weeks: 52)
  #
  class SnapshotStore
    include Support::Loggable

    def initialize(db)
      @db = db
    end

    # Upsert snapshots for all accounts
    # @param date [Date] snapshot date (typically Sunday)
    # @param account_data [Hash] { account_id => { followers:, statuses:, display_name:, username: } }
    # @param posts_per_account [Hash] { account_id => Integer } posts published this week
    # @return [Integer] number of accounts saved
    def save_snapshot(date, account_data, posts_per_account)
      saved = 0
      account_data.each do |account_id, stats|
        posts = posts_per_account[account_id.to_s] ||
                posts_per_account[account_id.to_sym] || 0
        @db.conn.exec_params(
          <<~SQL,
            INSERT INTO account_stats_snapshot (account_id, snapshot_date, followers, statuses, posts_week)
            VALUES ($1, $2, $3, $4, $5)
            ON CONFLICT (account_id, snapshot_date) DO UPDATE
              SET followers  = EXCLUDED.followers,
                  statuses   = EXCLUDED.statuses,
                  posts_week = EXCLUDED.posts_week
          SQL
          [account_id.to_s, date.to_s, stats[:followers], stats[:statuses], posts]
        )
        saved += 1
      rescue PG::Error => e
        log_warn("[SnapshotStore] Failed to save snapshot for #{account_id}: #{e.message}")
      end
      log_info("[SnapshotStore] Saved #{saved} account snapshots for #{date}")
      saved
    end

    # Load snapshot from N weeks ago (±3 days window for flexibility)
    # @param date [Date] current date (reference point)
    # @param weeks_back [Integer] how many weeks back to look
    # @return [Hash, nil] { account_id => { followers:, statuses:, posts_week:, snapshot_date: } }
    #                     nil if no snapshot found in the window
    def previous_snapshot(date, weeks_back: 1)
      target_date = date - (weeks_back * 7)
      window_from = (target_date - 3).to_s
      window_to   = (target_date + 3).to_s

      result = @db.conn.exec_params(
        <<~SQL,
          SELECT account_id, followers, statuses, posts_week, snapshot_date
          FROM account_stats_snapshot
          WHERE snapshot_date BETWEEN $1 AND $2
          ORDER BY snapshot_date DESC
        SQL
        [window_from, window_to]
      )
      return nil if result.ntuples.zero?

      # Keep the newest snapshot within the window per account
      snapshot = {}
      result.each do |row|
        account_id = row['account_id']
        next if snapshot.key?(account_id)
        snapshot[account_id] = {
          followers:     row['followers']&.to_i,
          statuses:      row['statuses']&.to_i,
          posts_week:    row['posts_week']&.to_i,
          snapshot_date: row['snapshot_date']
        }
      end
      snapshot.empty? ? nil : snapshot
    rescue PG::Error => e
      log_warn("[SnapshotStore] Failed to load previous snapshot: #{e.message}")
      nil
    end

    # Remove snapshots older than the retention window
    # @param keep_weeks [Integer] how many weeks to retain (default: 52 = 1 year)
    # @return [Integer] number of deleted rows
    def cleanup_old_snapshots(keep_weeks: 52)
      cutoff = (Date.today - (keep_weeks * 7)).to_s
      result = @db.conn.exec_params(
        'DELETE FROM account_stats_snapshot WHERE snapshot_date < $1',
        [cutoff]
      )
      count = result.cmd_tuples
      log_info("[SnapshotStore] Cleaned up #{count} old snapshots (cutoff: #{cutoff})") if count > 0
      count
    rescue PG::Error => e
      log_warn("[SnapshotStore] Failed to cleanup snapshots: #{e.message}")
      0
    end
  end
end
