# frozen_string_literal: true

require_relative 'content_filter'
require_relative '../logging'

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
    :video_data_cache,  # { url: String, data: String, phash: Integer|nil } — pre-downloaded video bytes + pHash for dedup + upload
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
      text = ctx.post.text
      detector.check_for_edit(ctx.source_id, ctx.post_id, username, text)
    end

    def add_to_buffer(source_id, post, mastodon_id)
      return unless @edit_detector_available

      detector = get_detector
      username = extract_username(post)
      text = post.text
      detector.add_to_buffer(source_id, post.id, username, text, mastodon_id: mastodon_id)
    end

    private

    def extract_username(post)
      post.author&.handle || 'unknown'
    end
  end

  # Step 2: Content filtering (replies, reposts, banned phrases)
  class ContentFilterStep
    # @return [String, nil] skip reason or nil
    def call(post, source_config)
      filtering = source_config[:filtering] || {}

      # Reply handling
      if post.is_reply
        is_self_reply = post.is_thread_post
        if is_self_reply
          return 'is_self_reply_thread' if filtering[:skip_self_replies]
        else
          return 'is_external_reply' if filtering[:skip_replies]
        end
      end

      # Retweet/repost handling
      if post.is_repost
        return 'is_retweet' if filtering[:skip_retweets]
      end

      # Quote handling
      if post.is_quote
        return 'is_quote' if filtering[:skip_quotes]
      end

      # Content-based filtering
      check_content_filters(post, filtering)
    end

    private

    def check_content_filters(post, filtering)
      content_parts = []
      content_parts << post.text if post.text
      content_parts << post.title if post.title
      content_parts << post.url if post.url
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

  # Steps 6b-6d: Media enrichment (video dedup, OGP fetch, link card thumbnail)
  class MediaEnrichmentStep
    # Platform/tracking domains skipped when looking for article URLs in post text.
    OGP_SKIP_DOMAINS = %w[
      twitter.com x.com t.co bsky.app bsky.social
      zpravobot.news nitter xcancel.com
    ].freeze

    def initialize(state_manager, dry_run:, logger: nil)
      @state_manager = state_manager
      @dry_run = dry_run
      @logger = logger
    end

    # @param post          [Post]   Post object (media may be mutated in place)
    # @param source_id     [String]
    # @param post_id       [String]
    # @param processed_text [String] Text after URL processing (used for OGP URL detection)
    # @param source_config  [Hash]
    # @return [Hash] { action: :continue, video_data_cache: nil|Hash }
    #              | { action: :skip, reason: String }
    def call(post, source_id, post_id, processed_text, source_config)
      video_data_cache = enrich_video(post, source_id, post_id, source_config)
      return { action: :skip, reason: 'duplicate_video' } if video_data_cache == :duplicate

      enrich_ogp(post, source_id, processed_text, source_config)
      enrich_link_card(post, source_id, source_config)

      { action: :continue, video_data_cache: video_data_cache }
    end

    private

    def enrich_video(post, source_id, post_id, source_config)
      return nil if @dry_run

      video_dedup_hours = source_config.dig(:processing, :video_dedup_hours)
      return nil unless video_dedup_hours

      max_video_mb    = source_config.dig(:processing, :max_video_size_mb)
      max_video_bytes = max_video_mb ? max_video_mb * 1024 * 1024 : nil
      check_video_dedup(source_id, post_id, post, video_dedup_hours.to_i, max_video_bytes: max_video_bytes)
    end

    def enrich_ogp(post, source_id, processed_text, source_config)
      return unless !@dry_run && source_config.dig(:processing, :ogp_fetch_link_card)

      if post.media.empty?
        ogp_url = fetch_ogp_image_for_post(post, processed_text, source_id)
        if ogp_url
          post.media << Media.new(type: 'image', url: ogp_url, alt_text: '')
          log_info("[#{source_id}] OGP: Přidán obrázek #{ogp_url}")
        else
          log_info("[#{source_id}] OGP: og:image nenalezen nebo fetch selhal")
        end
      else
        log_debug("[#{source_id}] OGP: přeskočen — post již má #{post.media.size} médium/médií")
      end
    end

    def enrich_link_card(post, source_id, source_config)
      return unless source_config.dig(:processing, :ogp_fetch_link_card)
      return unless post.media.any? && post.media.all?(&:link_card?)

      thumb_url = post.media.find { |m| m.link_card? }&.thumbnail_url
      if thumb_url
        post.media << Media.new(type: 'image', url: thumb_url, alt_text: '')
        log_info("[#{source_id}] Link card thumbnail: Přidán obrázek #{thumb_url}")
      else
        log_debug("[#{source_id}] Link card thumbnail: přeskočen — thumbnail_url chybí")
      end
    end

    def check_video_dedup(source_id, post_id, post, hours, max_video_bytes: nil)
      return nil unless post.media.any?

      video_media = post.media.find { |m| m.type == 'video' }
      return nil unless video_media&.url

      download_limit = max_video_bytes || (10 * 1024 * 1024)
      begin
        urls_to_try = ([video_media.url] + Array(video_media.url_variants).reject { |u| u == video_media.url }).compact

        video_url = nil
        video_data = nil
        urls_to_try.each do |url|
          response = HttpClient.download(url, max_size: download_limit)
          next if response.nil? || response == :too_large || response.body.nil? || response.body.empty?
          video_url = url
          video_data = response.body
          break
        end
        return nil unless video_data

        phash = Processors::ThumbnailPhash.compute(video_data)
        if phash && dedup_store.duplicate_by_phash?(source_id, phash, hours: hours)
          log_info("[#{source_id}] Video dedup (pHash): skipping duplicate for post #{post_id}")
          return :duplicate
        end

        { url: video_url, data: video_data, phash: phash }
      rescue StandardError => e
        log_warn("[#{source_id}] Video dedup check failed (proceeding): #{e.message}")
        nil
      end
    end

    def fetch_ogp_image_for_post(post, processed_text, source_id = nil)
      if post.raw.is_a?(Hash)
        card_image = post.raw[:card_image]
        if card_image.to_s.start_with?('https://')
          log_info("[#{source_id}] OGP: card image ze Syndication API → #{card_image}") if source_id
          return card_image
        end
      end

      article_url = nil
      raw_link = post.raw.is_a?(Hash) ? post.raw[:link_card_url].to_s : ''
      if raw_link.start_with?('http://', 'https://')
        if raw_link.include?('t.co/')
          expanded = expand_tco_url(raw_link)
          article_url = expanded if expanded && !expanded.include?('t.co/')
          log_info("[#{source_id}] OGP: t.co expandováno → #{article_url || '(selhalo)'}") if source_id
        else
          article_url = raw_link
        end
        log_info("[#{source_id}] OGP: URL z post.raw → #{article_url}") if source_id && article_url
      end

      unless article_url
        article_url = extract_article_url_from_text(processed_text)
        log_info("[#{source_id}] OGP: URL z processed_text → #{article_url}") if source_id && article_url
      end

      unless article_url
        article_url = extract_article_url_from_text(post.text.to_s)
        log_info("[#{source_id}] OGP: URL z post.text → #{article_url}") if source_id && article_url
      end

      unless article_url
        log_info("[#{source_id}] OGP: žádná article URL nenalezena (t.co v textu? platforma bez URL?)") if source_id
        return nil
      end

      Utils::OgpFetcher.new.fetch_og_image(article_url)
    rescue StandardError => e
      log_warn("[OGP] fetch_ogp_image_for_post failed: #{e.message}")
      nil
    end

    def extract_article_url_from_text(text)
      return nil if text.nil? || text.empty?

      text.scan(%r{https?://[^\s>)]+}).each do |raw_url|
        url = raw_url.sub(/[.,;:!?…]+$/, '')
        return url unless OGP_SKIP_DOMAINS.any? { |domain| url.include?(domain) }
      end
      nil
    end

    def expand_tco_url(tco_url)
      response = HttpClient.head(tco_url, open_timeout: 3, read_timeout: 3)
      response['location'] if response.is_a?(Net::HTTPRedirection)
    rescue StandardError
      nil
    end

    def dedup_store
      @dedup_store ||= Processors::MediaDedup.new(@state_manager, logger: @logger)
    end

    def log_info(msg)
      @logger ? @logger.info(msg) : Logging.info(msg)
    end

    def log_debug(msg)
      @logger ? @logger.debug(msg) : Logging.debug(msg)
    end

    def log_warn(msg)
      @logger ? @logger.warn(msg) : Logging.warn(msg)
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
        domain_rewrites = global_config.dig(:url, :domain_rewrites) || []
        Processors::UrlProcessor.new(no_trim_domains: no_trim_domains, domain_rewrites: domain_rewrites)
      end
    end
  end
end
