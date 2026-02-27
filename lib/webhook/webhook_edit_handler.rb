# frozen_string_literal: true

module Webhook
  # Handles edit detection and update/delete+republish for Twitter edited tweets
  #
  # Twitter allows editing tweets within 1 hour (creates new ID).
  # IFTTT captures both versions as separate triggers.
  # This handler detects edits and either:
  #   a) Updates existing Mastodon post (no media)
  #   b) Delete + Republish (with media — Mastodon can't change media on update)
  #   c) Skips older version
  class WebhookEditHandler
    include Support::Loggable

    # Result of edit handling
    EditResult = Struct.new(:action, :mastodon_id, keyword_init: true)

    # @param edit_detector [Processors::EditDetector]
    # @param thread_cache [Hash] Reference to parent's thread cache
    def initialize(edit_detector, thread_cache)
      @edit_detector = edit_detector
      @thread_cache = thread_cache
    end

    # Check for edit and handle if detected
    # @param parsed [WebhookPayloadParser::ParsedPayload] Parsed webhook
    # @param adapter [Adapters::TwitterNitterAdapter] Adapter for processing
    # @param payload [Hash] Raw payload for adapter
    # @param force_tier2 [Boolean]
    # @param publisher_getter [#call] Callable(bot_config) → publisher
    # @param formatter [#call] Callable(post, bot_config) → text
    # @param updater [#call] Callable(mastodon_id, text, bot_config) → result hash
    # @param state_manager [State::StateManager]
    # @param published_sources [Hash] Counter hash for source_id
    # @return [Symbol, nil] :skipped/:updated if handled, nil if should continue to normal flow
    def handle(parsed, adapter:, payload:, force_tier2:, publisher_getter:, formatter:, updater:, state_manager:, published_sources:)
      edit_result = @edit_detector.check_for_edit(
        parsed.source_id, parsed.post_id, parsed.username, parsed.text
      )

      case edit_result[:action]
      when :skip_older_version
        log "Skipping older version of edited tweet: #{parsed.post_id} (similar to #{edit_result[:original_post_id]}, #{(edit_result[:similarity] * 100).round(1)}% match)"
        return :skipped

      when :update_existing
        log "Edit detected: #{parsed.post_id} is newer version of #{edit_result[:original_post_id]} (#{(edit_result[:similarity] * 100).round(1)}% match)"
        return handle_edit(
          parsed, edit_result,
          adapter: adapter, payload: payload, force_tier2: force_tier2,
          publisher_getter: publisher_getter, formatter: formatter,
          updater: updater, state_manager: state_manager,
          published_sources: published_sources
        )

      when :publish_new
        if edit_result[:superseded_post_id]
          log "Publishing newer version #{parsed.post_id}, superseded: #{edit_result[:superseded_post_id]}"
        end
        nil # continue to normal flow
      end
    end

    private

    def handle_edit(parsed, edit_result, adapter:, payload:, force_tier2:, publisher_getter:, formatter:, updater:, state_manager:, published_sources:)
      post = adapter.process_webhook(payload, parsed.bot_config, force_tier2: force_tier2)
      unless post
        log "Adapter returned nil for #{parsed.post_id}, skipping"
        return :skipped
      end

      formatted_text = formatter.call(post, parsed.bot_config)
      has_media = post.respond_to?(:media) && post.media && !post.media.empty?

      if has_media
        result = try_delete_and_republish(
          parsed, edit_result, post, formatted_text,
          publisher_getter: publisher_getter,
          state_manager: state_manager,
          published_sources: published_sources
        )
        return result if result
        # Fallthrough to simple update on failure
      end

      # Simple text update (no media, or delete+republish failed)
      try_simple_update(
        parsed, edit_result, post, formatted_text,
        updater: updater,
        state_manager: state_manager,
        published_sources: published_sources
      )
    end

    def try_delete_and_republish(parsed, edit_result, post, formatted_text, publisher_getter:, state_manager:, published_sources:)
      log "Edit has media (#{post.media.count} items) → delete + republish"

      publisher = publisher_getter.call(parsed.bot_config)
      deleted_mastodon_id = edit_result[:mastodon_id]
      delete_succeeded = false
      media_ids = []

      # 1. Delete original
      publisher.delete_status(deleted_mastodon_id)
      delete_succeeded = true
      log "Deleted original status #{deleted_mastodon_id}"

      # 2. Upload media in parallel
      media_items = post.media.map do |m|
        url = m.respond_to?(:url) ? m.url : m.to_s
        alt = m.respond_to?(:alt_text) ? m.alt_text : ''
        { url: url, description: alt || '' }
      end
      media_ids = publisher.upload_media_parallel(media_items)

      # 3. Get thread context — exclude the just-deleted status
      in_reply_to_id = @thread_cache.dig(parsed.source_id, parsed.username.downcase)
      if in_reply_to_id == deleted_mastodon_id
        in_reply_to_id = nil
        log "Cleared in_reply_to (pointed to deleted status)"
      end

      # 4. Republish
      new_status = publisher.publish(
        formatted_text,
        media_ids: media_ids,
        in_reply_to_id: in_reply_to_id
      )

      new_mastodon_id = new_status['id']
      log "Republished as #{new_mastodon_id}", level: :success

      # 5. Update thread cache with new ID
      update_thread_cache_entry(parsed.source_id, parsed.username.downcase, new_mastodon_id)

      record_publish(parsed, post, new_mastodon_id, state_manager, published_sources)
      :updated

    rescue StandardError => e
      if delete_succeeded
        # DELETE succeeded but PUBLISH failed — must NOT fall through to simple update
        # (the original status is already deleted, UPDATE would fail too)
        log "Delete succeeded but republish failed: #{e.message}, publishing as new", level: :warn
        begin
          new_status = publisher.publish(formatted_text, media_ids: media_ids)
          new_mastodon_id = new_status['id']
          log "Published as new after failed republish: #{new_mastodon_id}", level: :success
          update_thread_cache_entry(parsed.source_id, parsed.username.downcase, new_mastodon_id)
          record_publish(parsed, post, new_mastodon_id, state_manager, published_sources)
          return :updated
        rescue StandardError => e2
          log "Emergency publish also failed: #{e2.message}", level: :error
        end
        nil
      else
        # DELETE failed — safe to fall through to simple update
        log "Delete+republish failed: #{e.message}, trying simple update", level: :warn
        nil
      end
    end

    def try_simple_update(parsed, edit_result, post, formatted_text, updater:, state_manager:, published_sources:)
      update_result = updater.call(edit_result[:mastodon_id], formatted_text, parsed.bot_config)

      if update_result[:success]
        log "Updated Mastodon status #{edit_result[:mastodon_id]}", level: :success
        @edit_detector.add_to_buffer(
          parsed.source_id, parsed.post_id, parsed.username, parsed.text,
          mastodon_id: edit_result[:mastodon_id]
        )
        state_manager.mark_updated(edit_result[:mastodon_id], parsed.post_id, new_post_url: post.url)
        published_sources[parsed.source_id] += 1
        :updated
      else
        log "Failed to update Mastodon: #{update_result[:error]}, publishing as new", level: :warn
        nil # fallthrough to normal publish
      end
    end

    def update_thread_cache_entry(source_id, username, new_mastodon_id)
      return unless @thread_cache && new_mastodon_id

      @thread_cache[source_id] ||= {}
      @thread_cache[source_id][username] = new_mastodon_id
    end

    def record_publish(parsed, post, mastodon_id, state_manager, published_sources)
      @edit_detector.add_to_buffer(
        parsed.source_id, parsed.post_id, parsed.username, parsed.text,
        mastodon_id: mastodon_id
      )
      state_manager.mark_published(
        parsed.source_id, parsed.post_id,
        post_url: post.url,
        mastodon_status_id: mastodon_id
      )
      published_sources[parsed.source_id] += 1
    end
  end
end
