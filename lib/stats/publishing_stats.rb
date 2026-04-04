# frozen_string_literal: true

require 'set'
require_relative '../support/loggable'

module Stats
  # Fetches publishing statistics from DB for ZpravobotStats weekly reporting.
  #
  # Usage:
  #   db = State::DatabaseConnection.new
  #   db.connect
  #   ps = Stats::PublishingStats.new(db)
  #   ps.weekly_comparison(days: 7)    # => [{ source_id:, this_week:, last_week: }, ...]
  #   ps.totals(days: 7)               # => { this_week:, last_week: }
  #   ps.error_stats(days: 7)          # => { published:, skipped:, errors:, reliability: }
  #
  class PublishingStats
    include Support::Loggable

    def initialize(db)
      @db = db
    end

    # Posts per source this week vs last week
    # @param days [Integer] window size (default: 7)
    # @return [Array<Hash>] [{ source_id:, this_week:, last_week: }, ...] ordered by this_week DESC
    def weekly_comparison(days: 7)
      result = @db.conn.exec_params(
        <<~SQL,
          SELECT
            source_id,
            COUNT(*) FILTER (WHERE published_at >= NOW() - ($1 * INTERVAL '1 day'))          AS this_week,
            COUNT(*) FILTER (
              WHERE published_at >= NOW() - ($2 * INTERVAL '1 day')
                AND published_at <  NOW() - ($1 * INTERVAL '1 day')
            ) AS last_week
          FROM published_posts
          WHERE published_at >= NOW() - ($2 * INTERVAL '1 day')
          GROUP BY source_id
          ORDER BY this_week DESC
        SQL
        [days, days * 2]
      )
      result.map do |row|
        {
          source_id: row['source_id'],
          this_week: row['this_week'].to_i,
          last_week: row['last_week'].to_i
        }
      end
    rescue PG::Error => e
      log_warn("[PublishingStats] weekly_comparison failed: #{e.message}")
      []
    end

    # Total post counts this week and last week
    # @param days [Integer] window size (default: 7)
    # @return [Hash] { this_week: Integer, last_week: Integer }
    def totals(days: 7)
      result = @db.conn.exec_params(
        <<~SQL,
          SELECT
            COUNT(*) FILTER (WHERE published_at >= NOW() - ($1 * INTERVAL '1 day'))          AS this_week,
            COUNT(*) FILTER (
              WHERE published_at >= NOW() - ($2 * INTERVAL '1 day')
                AND published_at <  NOW() - ($1 * INTERVAL '1 day')
            ) AS last_week
          FROM published_posts
          WHERE published_at >= NOW() - ($2 * INTERVAL '1 day')
        SQL
        [days, days * 2]
      )
      row = result.ntuples > 0 ? result[0] : {}
      {
        this_week: row['this_week'].to_i,
        last_week: row['last_week'].to_i
      }
    rescue PG::Error => e
      log_warn("[PublishingStats] totals failed: #{e.message}")
      { this_week: 0, last_week: 0 }
    end

    # Publish/skip/error counts and reliability from activity_log
    # @param days [Integer] window size (default: 7)
    # @return [Hash] { published:, skipped:, errors:, reliability: }
    def error_stats(days: 7)
      result = @db.conn.exec_params(
        <<~SQL,
          SELECT action, COUNT(*) AS cnt
          FROM activity_log
          WHERE created_at >= NOW() - ($1 * INTERVAL '1 day')
            AND action IN ('publish', 'skip', 'error')
          GROUP BY action
        SQL
        [days]
      )
      counts = { 'publish' => 0, 'skip' => 0, 'error' => 0 }
      result.each { |row| counts[row['action']] = row['cnt'].to_i }

      published = counts['publish']
      errors    = counts['error']
      total     = published + errors
      reliability = total > 0 ? ((published.to_f / total) * 100).round(1) : 100.0

      {
        published:   published,
        skipped:     counts['skip'],
        errors:      errors,
        reliability: reliability
      }
    rescue PG::Error => e
      log_warn("[PublishingStats] error_stats failed: #{e.message}")
      { published: 0, skipped: 0, errors: 0, reliability: 100.0 }
    end

    # Posts per Mastodon account this week (sources aggregated by account)
    # @param source_account_map [Hash] { source_id => account_id }
    # @param days [Integer] window size (default: 7)
    # @return [Hash] { account_id => { this_week: Integer, last_week: Integer } }
    def posts_per_account(source_account_map, days: 7)
      weekly = weekly_comparison(days: days)
      result = Hash.new { |h, k| h[k] = { this_week: 0, last_week: 0 } }

      weekly.each do |row|
        account_id = source_account_map[row[:source_id].to_s]
        next unless account_id

        result[account_id][:this_week] += row[:this_week]
        result[account_id][:last_week] += row[:last_week]
      end

      result
    rescue => e
      log_warn("[PublishingStats] posts_per_account failed: #{e.message}")
      {}
    end

    # Posts per category this week, grouped by account categories
    # @param account_categories [Hash] { account_id => [String] } from mastodon_accounts.yml
    # @param source_account_map [Hash] { source_id => account_id }
    # @param days [Integer] window size (default: 7)
    # @return [Array<Hash>] [{ category:, posts:, accounts: }, ...] ordered by posts DESC
    def category_stats(account_categories, source_account_map, days: 7)
      weekly = weekly_comparison(days: days)
      category_posts    = Hash.new(0)
      category_accounts = Hash.new { |h, k| h[k] = Set.new }

      weekly.each do |row|
        next if row[:this_week].zero?

        account_id = source_account_map[row[:source_id].to_s]
        next unless account_id

        categories = account_categories[account_id.to_s] ||
                     account_categories[account_id.to_sym] || []
        categories.each do |cat|
          category_posts[cat.to_s]    += row[:this_week]
          category_accounts[cat.to_s].add(account_id)
        end
      end

      category_posts.map do |cat, posts|
        { category: cat, posts: posts, accounts: category_accounts[cat].size }
      end.sort_by { |r| -r[:posts] }
    rescue => e
      log_warn("[PublishingStats] category_stats failed: #{e.message}")
      []
    end
  end
end
