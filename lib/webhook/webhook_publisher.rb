# frozen_string_literal: true

module Webhook
  # Handles the final publishing step for webhook-processed posts
  #
  # Delegates to PostProcessor for unified processing pipeline,
  # then records the result in edit buffer and thread cache
  class WebhookPublisher
    include Support::Loggable

    # @param post_processor [Processors::PostProcessor]
    # @param edit_detector [Processors::EditDetector]
    # @param thread_cache_updater [#call] Callable(source_id, post, mastodon_id)
    def initialize(post_processor, edit_detector, thread_cache_updater:)
      @post_processor = post_processor
      @edit_detector = edit_detector
      @thread_cache_updater = thread_cache_updater
    end

    # Publish post via PostProcessor and record result
    # @param parsed [WebhookPayloadParser::ParsedPayload]
    # @param post [Post] Processed post object
    # @param in_reply_to_id [String, nil] Thread parent mastodon ID
    # @param published_sources [Hash] Counter hash for source_id
    # @return [Symbol] :published, :skipped, or :failed
    def publish(parsed, post, in_reply_to_id:, published_sources:)
      result = @post_processor.process(post, parsed.bot_config, { in_reply_to_id: in_reply_to_id })

      case result.status
      when :published
        @edit_detector.add_to_buffer(
          parsed.source_id, parsed.post_id, parsed.username, parsed.text,
          mastodon_id: result.mastodon_id
        )
        @thread_cache_updater.call(parsed.source_id, post, result.mastodon_id)
        published_sources[parsed.source_id] += 1
        log "Published: #{parsed.post_id} → #{result.mastodon_id}", level: :success
        :published

      when :skipped
        log "Skipped: #{result.skipped_reason}"
        :skipped

      when :failed
        log "Failed: #{result.error}", level: :error
        :failed
      end
    end
  end
end
