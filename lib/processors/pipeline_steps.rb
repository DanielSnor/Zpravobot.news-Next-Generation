# frozen_string_literal: true

require_relative 'content_filter'

# Pipeline Step Objects for PostProcessor
# ========================================
# Extracted from PostProcessor#process to reduce cyclomatic complexity.
# Each step encapsulates one phase of the processing pipeline.
#
# Steps follow a common interface:
#   step.call(context) => context (mutated) or Result (early exit)
#
# ProcessingContext carries data between steps, avoiding long parameter lists.

module Processors
  # Shared context passed through pipeline steps
  ProcessingContext = Struct.new(
    :post, :source_config, :options,
    :source_id, :post_id, :platform,
    :formatted_text, :processed_text,
    :mastodon_id,
    keyword_init: true
  )

  # Step 1: Deduplication check
  class DeduplicationStep
    def initialize(state_manager)
      @state_manager = state_manager
    end

    # @return [nil] if post should continue, [Result] if already published
    def call(ctx)
      return nil unless @state_manager.published?(ctx.source_id, ctx.post_id)

      PostProcessor::Result.new(status: :skipped, skipped_reason: 'already_published')
    end
  end

  # Step 1b: Edit detection
  class EditDetectionStep
    EDIT_PLATFORMS = %w[bluesky twitter].freeze

    def initialize(state_manager, edit_detector_available, logger: nil)
      @state_manager = state_manager
      @edit_detector_available = edit_detector_available
      @logger = logger
      @edit_detector = nil
    end

    def enabled?(platform)
      @edit_detector_available && EDIT_PLATFORMS.include?(platform.to_s.downcase)
    end

    def get_detector
      @edit_detector ||= Processors::EditDetector.new(@state_manager, logger: @logger)
    end

    # @return [Hash] { action: :publish_new/:skip_older_version/:update_existing, ... }
    def check(ctx, username)
      detector = get_detector
      text = ctx.post.respond_to?(:text) ? ctx.post.text : ctx.post.to_s
      detector.check_for_edit(ctx.source_id, ctx.post_id, username, text)
    end

    def add_to_buffer(source_id, post, mastodon_id)
      return unless @edit_detector_available

      detector = get_detector
      username = extract_username(post)
      text = post.respond_to?(:text) ? post.text : post.to_s
      detector.add_to_buffer(source_id, post.id, username, text, mastodon_id: mastodon_id)
    end

    private

    def extract_username(post)
      if post.respond_to?(:author) && post.author
        return post.author.handle if post.author.respond_to?(:handle) && post.author.handle
        return post.author.username if post.author.respond_to?(:username) && post.author.username
      end
      'unknown'
    end
  end

  # Step 2: Content filtering (replies, reposts, banned phrases)
  class ContentFilterStep
    # @return [String, nil] skip reason or nil
    def call(post, source_config)
      filtering = source_config[:filtering] || {}

      # Reply handling
      if post.respond_to?(:is_reply) && post.is_reply
        is_self_reply = post.respond_to?(:is_thread_post) && post.is_thread_post
        if is_self_reply
          return 'is_self_reply_thread' if filtering[:skip_self_replies]
        else
          return 'is_external_reply' if filtering[:skip_replies]
        end
      end

      # Retweet/repost handling
      if post.respond_to?(:is_repost) && post.is_repost
        return 'is_retweet' if filtering[:skip_retweets]
      end

      # Quote handling
      if post.respond_to?(:is_quote) && post.is_quote
        return 'is_quote' if filtering[:skip_quotes]
      end

      # Content-based filtering
      check_content_filters(post, filtering)
    end

    private

    def check_content_filters(post, filtering)
      content_parts = []
      content_parts << post.text if post.respond_to?(:text) && post.text
      content_parts << post.title if post.respond_to?(:title) && post.title
      content_parts << post.url if post.respond_to?(:url) && post.url
      combined_content = content_parts.join(' ')

      return nil if combined_content.empty?

      banned = filtering[:banned_phrases] || []
      if banned.any? && matches_any?(combined_content, banned)
        return 'banned_phrase'
      end

      required = filtering[:required_keywords] || []
      if required.any? && !matches_all?(combined_content, required)
        return 'missing_required_keyword'
      end

      nil
    end

    def matches_any?(text, patterns)
      Processors::ContentFilter.new(banned_phrases: patterns).banned?(text)
    end

    def matches_all?(text, patterns)
      Processors::ContentFilter.new(required_keywords: patterns).has_required?(text)
    end
  end

  # Step 6: URL processing
  class UrlProcessingStep
    def initialize(config_loader)
      @config_loader = config_loader
      @url_processor = nil
    end

    def call(text, source_config)
      return text unless defined?(Processors::UrlProcessor)

      url_processor = get_url_processor
      processing = source_config[:processing] || {}

      source_fixes = processing[:url_domain_fixes] || []
      global_fixes = url_processor.no_trim_domains
      all_fixes = (source_fixes + global_fixes).uniq

      text = url_processor.apply_domain_fixes(text, all_fixes) if all_fixes.any?

      url_processor.process_content(text)
    end

    private

    def get_url_processor
      @url_processor ||= begin
        global_config = @config_loader.load_global_config rescue {}
        no_trim_domains = global_config.dig(:url, :no_trim_domains) || []
        Processors::UrlProcessor.new(no_trim_domains: no_trim_domains)
      end
    end
  end
end
