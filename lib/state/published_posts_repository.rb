# frozen_string_literal: true

require_relative '../utils/hash_helpers'
require_relative '../support/loggable'

module State
  # Repository for published posts deduplication and thread tracking
  class PublishedPostsRepository
    include Support::Loggable

    def initialize(db)
      @db = db
    end

    # Check if post was already published
    # @param source_id [String] Source identifier
    # @param post_id [String] Original post ID from platform
    # @return [Boolean]
    def published?(source_id, post_id)
      result = @db.conn.exec_params(
        'SELECT 1 FROM published_posts WHERE source_id = $1 AND post_id = $2 LIMIT 1',
        [source_id, post_id]
      )
      result.ntuples > 0
    end

    # Find a published post by platform URI (for threading)
    # @param source_id [String] Source identifier
    # @param platform_uri [String] Platform-specific URI
    # @return [Hash, nil] Published post record or nil
    def find_by_platform_uri(source_id, platform_uri)
      return nil if platform_uri.nil? || platform_uri.empty?

      result = @db.conn.exec_params(
        "SELECT mastodon_status_id, post_id, post_url
         FROM #{@db.schema}.published_posts
         WHERE source_id = $1 AND platform_uri = $2
         LIMIT 1",
        [source_id, platform_uri]
      )

      return nil if result.ntuples.zero?

      row = result[0]
      {
        mastodon_status_id: row['mastodon_status_id'],
        post_id: row['post_id'],
        post_url: row['post_url']
      }
    end

    # Find published post by post_id
    # @param source_id [String] Source identifier
    # @param post_id [String] Original platform post ID
    # @return [Hash, nil]
    def find_by_post_id(source_id, post_id)
      return nil if post_id.nil? || post_id.to_s.empty?

      result = @db.conn.exec_params(
        <<~SQL,
          SELECT mastodon_status_id, post_id, post_url, published_at
          FROM #{@db.schema}.published_posts
          WHERE source_id = $1 AND post_id = $2
          LIMIT 1
        SQL
        [source_id, post_id.to_s]
      )

      return nil if result.ntuples.zero?

      row = result[0]
      {
        mastodon_status_id: row['mastodon_status_id'],
        post_id: row['post_id'],
        post_url: row['post_url'],
        published_at: row['published_at']
      }
    rescue PG::Error => e
      log_error("[PublishedPostsRepository] find_by_post_id failed: #{e.message}")
      nil
    end

    # Find recent thread parent from database
    # @param source_id [String] Source identifier
    # @return [String, nil] Mastodon status ID of most recent published post
    def find_recent_thread_parent(source_id)
      result = @db.conn.exec_params(
        <<~SQL,
          SELECT mastodon_status_id
          FROM published_posts
          WHERE source_id = $1
          AND published_at > NOW() - INTERVAL '24 hours'
          AND mastodon_status_id IS NOT NULL
          ORDER BY published_at DESC
          LIMIT 1
        SQL
        [source_id]
      )

      return nil if result.ntuples == 0
      result[0]['mastodon_status_id']
    rescue PG::Error => e
      log_error("[PublishedPostsRepository] find_recent_thread_parent failed: #{e.message}")
      nil
    end

    # Mark post as published
    # @param source_id [String] Source identifier
    # @param post_id [String] Original post ID
    # @param post_url [String, nil] URL to original post
    # @param mastodon_status_id [String, nil] Mastodon status ID
    # @param platform_uri [String, nil] Platform-specific URI for thread tracking
    # @return [Boolean]
    def mark_published(source_id, post_id, post_url: nil, mastodon_status_id: nil, platform_uri: nil)
      @db.conn.exec_params(
        <<~SQL,
          INSERT INTO published_posts (source_id, post_id, post_url, mastodon_status_id, platform_uri)
          VALUES ($1, $2, $3, $4, $5)
          ON CONFLICT (source_id, post_id) DO UPDATE SET
          mastodon_status_id = COALESCE(EXCLUDED.mastodon_status_id, published_posts.mastodon_status_id),
          platform_uri = COALESCE(EXCLUDED.platform_uri, published_posts.platform_uri)
        SQL
        [source_id, post_id, post_url, mastodon_status_id, platform_uri]
      )
      true
    rescue PG::Error => e
      log_error("[PublishedPostsRepository] Failed to mark published: #{e.message}")
      false
    end

    # Update post_id on an existing record identified by mastodon_status_id.
    # Used after edit detection: the Mastodon status stays the same but the
    # source post_id changes (edited tweet gets a new ID).
    # @param mastodon_status_id [String] Existing Mastodon status ID
    # @param new_post_id [String] New source post ID
    # @param new_post_url [String, nil] New source post URL
    # @return [Boolean]
    def mark_updated(mastodon_status_id, new_post_id, new_post_url: nil)
      @db.conn.exec_params(
        <<~SQL,
          UPDATE published_posts
          SET post_id = $2, post_url = COALESCE($3, post_url)
          WHERE mastodon_status_id = $1
        SQL
        [mastodon_status_id, new_post_id, new_post_url]
      )
      true
    rescue PG::Error => e
      log_error("[PublishedPostsRepository] Failed to mark updated: #{e.message}")
      false
    end

    # Find Mastodon status ID by platform URI
    # @param platform_uri [String] Platform-specific URI
    # @return [String, nil] Mastodon status ID or nil
    def find_mastodon_id_by_platform_uri(platform_uri)
      return nil if platform_uri.nil? || platform_uri.empty?

      result = @db.conn.exec_params(
        <<~SQL,
          SELECT mastodon_status_id
          FROM published_posts
          WHERE platform_uri = $1
          AND mastodon_status_id IS NOT NULL
          LIMIT 1
        SQL
        [platform_uri]
      )

      result.ntuples > 0 ? result[0]['mastodon_status_id'] : nil
    rescue PG::Error => e
      log_error("[PublishedPostsRepository] Failed to find by platform_uri: #{e.message}")
      nil
    end

    # Find Mastodon status ID by post_id
    # @param source_id [String] Source identifier
    # @param post_id [String] Original post ID
    # @return [String, nil] Mastodon status ID or nil
    def find_mastodon_id_by_post_id(source_id, post_id)
      result = @db.conn.exec_params(
        <<~SQL,
          SELECT mastodon_status_id
          FROM published_posts
          WHERE source_id = $1
          AND post_id = $2
          AND mastodon_status_id IS NOT NULL
          LIMIT 1
        SQL
        [source_id, post_id]
      )

      result.ntuples > 0 ? result[0]['mastodon_status_id'] : nil
    rescue PG::Error => e
      log_error("[PublishedPostsRepository] Failed to find by post_id: #{e.message}")
      nil
    end

    # Get recently published posts for a source
    # @param source_id [String] Source identifier
    # @param limit [Integer] Max posts to return
    # @return [Array<Hash>]
    def recent_published(source_id, limit: 10)
      result = @db.conn.exec_params(
        <<~SQL,
          SELECT post_id, post_url, mastodon_status_id, platform_uri, published_at
          FROM published_posts
          WHERE source_id = $1
          ORDER BY published_at DESC
          LIMIT $2
        SQL
        [source_id, limit]
      )
      result.map { |row| HashHelpers.symbolize_keys(row) }
    end
  end
end
