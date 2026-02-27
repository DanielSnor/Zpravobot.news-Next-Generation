# frozen_string_literal: true

module Webhook
  # Handles tweet processing for webhook posts via TwitterTweetProcessor
  #
  # Builds IFTTT fallback_post from TwitterNitterAdapter Tier 1 data,
  # then delegates the full pipeline (Nitter fetch, Syndication fallback,
  # threading, PostProcessor) to TwitterTweetProcessor.
  #
  # Previous role (pre-TASK-10):
  #   Two modes: advanced (TwitterThreadProcessor) + basic (ThreadingSupport)
  #   Fetched post via @adapter.process_webhook, returned ThreadResult.
  #   → Replaced by TwitterTweetProcessor which handles both modes internally.
  class WebhookThreadHandler
    include Support::Loggable

    # @param adapter [Adapters::TwitterNitterAdapter]  For IFTTT payload parsing + fallback_post
    # @param tweet_processor [Processors::TwitterTweetProcessor]  Unified tweet processor
    def initialize(adapter, tweet_processor:)
      @adapter = adapter
      @tweet_processor = tweet_processor
    end

    # Process tweet via unified TwitterTweetProcessor
    #
    # @param parsed [WebhookPayloadParser::ParsedPayload]
    # @param payload [Hash] Raw IFTTT payload (string keys)
    # @param force_tier2 [Boolean]  Deprecated: no longer used after TASK-10 refactor.
    #                               TwitterTweetProcessor always fetches from Nitter when
    #                               nitter_processing.enabled: true — force_tier2 is implicit.
    # @return [Symbol] :published, :skipped, or :failed
    def handle(parsed, payload:, force_tier2: false)
      bot_config = parsed.bot_config

      # Build Tier 1 fallback_post from IFTTT data.
      # Used as Tier 3 final fallback if both Nitter and Syndication fail.
      fallback_post = build_ifttt_fallback_post(payload, bot_config)

      # Use source_handle from config when available — overrides IFTTT username,
      # which may be a brand name (e.g. "drozd") instead of the real handle ("mzvcr").
      username = bot_config.dig(:source, :handle) || parsed.username

      @tweet_processor.process(
        post_id:       parsed.post_id,
        username:      username,
        source_config: bot_config,
        fallback_post: fallback_post
      )
    end

    private

    # Build a Tier 1 Post from IFTTT payload data
    #
    # Tier 1 = direct IFTTT data (may be truncated, no media).
    # Used as Tier 3 fallback — at least we publish something rather than nothing.
    # Tier 1/3 logic stays in TwitterNitterAdapter; TwitterTweetProcessor calls it
    # only indirectly via fallback_post.
    #
    # @return [Post, nil]
    def build_ifttt_fallback_post(payload, bot_config)
      ifttt_data = @adapter.parse_ifttt_payload(payload)
      return nil unless ifttt_data

      # Inject source_handle for correct author attribution inside TwitterNitterAdapter
      if (source_handle = bot_config.dig(:source, :handle))
        ifttt_data[:source_handle] = source_handle
      end

      @adapter.process_tier1(ifttt_data, bot_config)
    rescue StandardError => e
      log "Failed to build IFTTT fallback_post: #{e.message}", level: :warn
      nil
    end
  end
end
