# frozen_string_literal: true

require_relative 'database_connection'
require_relative 'published_posts_repository'
require_relative 'source_state_repository'
require_relative 'activity_logger'
require_relative 'edit_buffer_manager'

module State
  # Facade for all state management operations
  # Delegates to specialized repository classes while preserving the original API
  #
  # Usage:
  #   manager = State::StateManager.new(schema: 'zpravobot')
  #   manager.connect
  #   manager.published?('ct24_twitter', 'tweet_123456')
  #   manager.disconnect
  #
  class StateManager
    attr_reader :schema

    def initialize(url: nil, host: nil, port: 5432, dbname: nil, user: nil, password: nil, schema: nil)
      @db = DatabaseConnection.new(
        url: url, host: host, port: port, dbname: dbname,
        user: user, password: password, schema: schema
      )
      @schema = @db.schema
      @posts = PublishedPostsRepository.new(@db)
      @source_state = SourceStateRepository.new(@db)
      @activity = ActivityLogger.new(@db)
      @edit_buffer = EditBufferManager.new(@db)
    end

    # ============================================================
    # Connection Management — delegate to DatabaseConnection
    # ============================================================

    def connect
      @db.connect
    end

    def disconnect
      @db.disconnect
    end

    def connected?
      @db.connected?
    end

    def ensure_connection
      @db.ensure_connection
    end

    # ============================================================
    # Published Posts — delegate to PublishedPostsRepository
    # ============================================================

    def published?(source_id, post_id)
      @posts.published?(source_id, post_id)
    end

    def find_by_platform_uri(source_id, platform_uri)
      @posts.find_by_platform_uri(source_id, platform_uri)
    end

    def find_by_post_id(source_id, post_id)
      @posts.find_by_post_id(source_id, post_id)
    end

    def find_recent_thread_parent(source_id)
      @posts.find_recent_thread_parent(source_id)
    end

    def mark_published(source_id, post_id, post_url: nil, mastodon_status_id: nil, platform_uri: nil)
      @posts.mark_published(source_id, post_id,
        post_url: post_url, mastodon_status_id: mastodon_status_id, platform_uri: platform_uri)
    end

    def mark_updated(mastodon_status_id, new_post_id, new_post_url: nil)
      @posts.mark_updated(mastodon_status_id, new_post_id, new_post_url: new_post_url)
    end

    def find_mastodon_id_by_platform_uri(platform_uri)
      @posts.find_mastodon_id_by_platform_uri(platform_uri)
    end

    def find_mastodon_id_by_post_id(source_id, post_id)
      @posts.find_mastodon_id_by_post_id(source_id, post_id)
    end

    def recent_published(source_id, limit: 10)
      @posts.recent_published(source_id, limit: limit)
    end

    # ============================================================
    # Source State — delegate to SourceStateRepository
    # ============================================================

    def get_source_state(source_id)
      @source_state.get_source_state(source_id)
    end

    def mark_check_success(source_id, posts_published: 0)
      @source_state.mark_check_success(source_id, posts_published: posts_published)
    end

    def mark_check_error(source_id, error_message)
      @source_state.mark_check_error(source_id, error_message)
    end

    def sources_due_for_check(interval_minutes: 10, limit: 20)
      @source_state.sources_due_for_check(interval_minutes: interval_minutes, limit: limit)
    end

    def reset_daily_counters
      @source_state.reset_daily_counters
    end

    def stats
      @source_state.stats
    end

    def sources_with_errors(min_errors: 3)
      @source_state.sources_with_errors(min_errors: min_errors)
    end

    # ============================================================
    # Activity Log — delegate to ActivityLogger
    # ============================================================

    def log_activity(source_id, action, details = nil)
      @activity.log_activity(source_id, action, details)
    end

    def log_fetch(source_id, posts_found:)
      @activity.log_fetch(source_id, posts_found: posts_found)
    end

    def log_publish(source_id, post_id:, post_url: nil, mastodon_status_id: nil)
      @activity.log_publish(source_id, post_id: post_id,
        post_url: post_url, mastodon_status_id: mastodon_status_id)
    end

    def log_skip(source_id, post_id:, reason:)
      @activity.log_skip(source_id, post_id: post_id, reason: reason)
    end

    def log_error_activity(source_id, message:, details: nil)
      @activity.log_error_activity(source_id, message: message, details: details)
    end

    def log_transient_error(source_id, message:)
      @activity.log_transient_error(source_id, message: message)
    end

    def recent_activity(source_id, limit: 50)
      @activity.recent_activity(source_id, limit: limit)
    end

    # ============================================================
    # Edit Detection Buffer — delegate to EditBufferManager
    # ============================================================

    def add_to_edit_buffer(source_id:, post_id:, username:, text_normalized:, text_hash: nil, mastodon_id: nil)
      @edit_buffer.add_to_edit_buffer(
        source_id: source_id, post_id: post_id, username: username,
        text_normalized: text_normalized, text_hash: text_hash, mastodon_id: mastodon_id
      )
    end

    def update_edit_buffer_mastodon_id(source_id, post_id, mastodon_id)
      @edit_buffer.update_edit_buffer_mastodon_id(source_id, post_id, mastodon_id)
    end

    def find_by_text_hash(username, text_hash)
      @edit_buffer.find_by_text_hash(username, text_hash)
    end

    def find_recent_buffer_entries(username, within_seconds: 3600)
      @edit_buffer.find_recent_buffer_entries(username, within_seconds: within_seconds)
    end

    def mark_edit_superseded(source_id, post_id)
      @edit_buffer.mark_edit_superseded(source_id, post_id)
    end

    def cleanup_edit_buffer(retention_hours: 2)
      @edit_buffer.cleanup_edit_buffer(retention_hours: retention_hours)
    end

    def edit_buffer_stats
      @edit_buffer.edit_buffer_stats
    end

    def in_edit_buffer?(source_id, post_id)
      @edit_buffer.in_edit_buffer?(source_id, post_id)
    end
  end
end
