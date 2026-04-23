# frozen_string_literal: true

# Post Processor - Unified Processing Pipeline
# ============================================
#
# Centralizovaná logika pro zpracování postů.
# Používá se z Orchestratoru (cron) i IftttQueueProcessor (webhook).
#
# Pipeline:
# 1. Dedupe check (already_published?)
# 1b. Edit detection (check for similar posts - update or skip)
# 2. Content filtering (should_skip?)
# 3. Format (UniversalFormatter)
# 4. Apply content replacements
# 5. Process content (trim, normalize)
# 6. Process URLs (cleanup, domain fixes)
# 7. Upload media
# 8. Publish to Mastodon (or update existing)
# 9. Mark as published + add to edit buffer

require 'digest'
require_relative '../support/loggable'
require_relative '../errors'
require_relative 'pipeline_steps'

require_relative 'media_dedup'
require_relative '../utils/http_client'
require_relative 'thumbnail_phash'
require_relative '../utils/ogp_fetcher'
require_relative 'edit_detector'

MENTION_BLOCKER_PNG_PATH = File.join(__dir__, '../../assets/white_strip_1280x1.png')

module Processors
  class PostProcessor
    include Support::Loggable

    # Platform/tracking domains to skip when looking for article URLs in post text.
    # Avoids fetching OGP from tweet URLs, Bluesky links, or our own domains.
    OGP_SKIP_DOMAINS = %w[
      twitter.com x.com t.co bsky.app bsky.social
      zpravobot.news nitter xcancel.com
    ].freeze

    # URL prefixes that indicate a prefix-style profile mention.
    # These cause Mastodon to render a profile card — trigger the profile card blocker.
    # Suffix mentions (@handle@twitter.com) do not generate profile cards and are excluded.
    PROFILE_URL_PREFIXES = %w[
      bsky.app/profile/
      x.com/
      twitter.com/
      facebook.com/
      instagram.com/
      youtube.com/
    ].freeze

    # Result value object for processing outcome (immutable)
    Result = Data.define(:status, :mastodon_id, :error, :skipped_reason) do
      def initialize(status:, mastodon_id: nil, error: nil, skipped_reason: nil)
        super
      end

      def published?    = status == :published
      def skipped?      = status == :skipped
      def failed?       = status == :failed
      def rate_limited? = status == :rate_limited
    end

    # Dependencies
    attr_reader :state_manager, :config_loader, :logger

    # Configuration
    attr_reader :dry_run, :verbose

    def initialize(
      state_manager:,
      config_loader:,
      logger: nil,
      dry_run: false,
      verbose: false
    )
      @state_manager = state_manager
      @config_loader = config_loader
      @logger = logger
      @dry_run = dry_run
      @verbose = verbose

      # Pipeline steps (extracted to reduce cyclomatic complexity)
      @dedup_step = DeduplicationStep.new(state_manager)
      @edit_step = EditDetectionStep.new(state_manager, true, logger: logger)
      @filter_step = ContentFilterStep.new
      @url_step = UrlProcessingStep.new(config_loader)

      # Lazy-loaded processors
      @content_filters = {}
      @publishers = {}
    end

    # Process a single post
    #
    # @param post [Post] Post object to process
    # @param source_config [Hash] Source configuration
    # @param options [Hash] Additional options
    # @option options [String] :in_reply_to_id Mastodon status ID for threading
    # @option options [Proc] :on_format Callback after formatting (for verbose logging)
    # @option options [Proc] :on_final Callback before publishing (for verbose logging)
    # @return [Result] Processing result
    def process(post, source_config, options = {})
      source_id = source_config[:id]
      post_id = post.id || post.url
      platform = source_config[:platform]

      # Step 1: Dedupe check
      ctx = ProcessingContext.new(
        post: post, source_config: source_config, options: options,
        source_id: source_id, post_id: post_id, platform: platform
      )
      dedup_result = @dedup_step.call(ctx)
      if dedup_result
        log_debug("[#{source_id}] Already published: #{post_id}")
        return dedup_result
      end

      # Step 1b: Edit detection (for Bluesky and Twitter where delete+repost happens)
      if @edit_step.enabled?(platform)
        username = extract_username(post, fallback: source_id.to_s.split('_').first)
        edit_result = @edit_step.check(ctx, username)

        case edit_result[:action]
        when :skip_older_version
          log_info("[#{source_id}] Skipping older version #{post_id} (#{(edit_result[:similarity] * 100).round}% similar to #{edit_result[:original_post_id]})")
          mark_skipped(source_id, post_id, 'older_version')
          return Result.new(status: :skipped, skipped_reason: 'older_version')

        when :update_existing
          log_info("[#{source_id}] Detected edit: #{post_id} updates #{edit_result[:original_post_id]} (#{(edit_result[:similarity] * 100).round}% similar)")
          return process_as_update(post, source_config, edit_result, options)
        end
        # :publish_new continues below
      end

      # Step 2: Content filtering
      skip_reason = @filter_step.call(post, source_config)
      if skip_reason
        log_debug("[#{source_id}] Skipping: #{skip_reason}")
        # Mark as processed to avoid re-checking
        mark_skipped(source_id, post_id, skip_reason)
        return Result.new(status: :skipped, skipped_reason: skip_reason)
      end

      # Step 3: Format post
      formatter = create_formatter(source_config)
      formatted_text = formatter.format(post)
      
      # Callback for verbose logging
      options[:on_format]&.call(formatted_text)

      # Step 4: Apply content replacements
      formatted_text = apply_content_replacements(formatted_text, source_config)

      # Step 5: Process content (trim, normalize)
      fallback_url_for_trim = build_trim_fallback_url(post, source_config)
      processed_text = process_content(formatted_text, source_config, fallback_url: fallback_url_for_trim)

      # Step 6: Process URLs
      processed_text = @url_step.call(processed_text, source_config)

      # Step 6.5: Re-trim if URL processing grew the text past the hard instance limit.
      # url_step applies apply_domain_fixes (prepends https:// to bare domains listed in
      # processing.url_domain_fixes), which can push the final text past truncation.max_length.
      # Re-running process_content is idempotent: already-trimmed text stays put, and any
      # trailing URL is preserved via the existing suffix-extraction regex.
      processed_text = enforce_hard_limit(processed_text, source_config, fallback_url: fallback_url_for_trim)

      # Callback for verbose logging
      options[:on_final]&.call(processed_text)

      # Step 6b: Video dedup check (opt-in per source, skipped in dry_run)
      video_dedup_hours = source_config.dig(:processing, :video_dedup_hours)
      video_data_cache = nil
      if !@dry_run && video_dedup_hours
        max_video_mb = source_config.dig(:processing, :max_video_size_mb)
        max_video_bytes = max_video_mb ? max_video_mb * 1024 * 1024 : nil
        video_data_cache = check_video_dedup(source_id, post_id, post, video_dedup_hours.to_i, max_video_bytes: max_video_bytes)
        if video_data_cache == :duplicate
          mark_skipped(source_id, post_id, 'duplicate_video')
          return Result.new(status: :skipped, skipped_reason: 'duplicate_video')
        end
      end

      # Step 6c: OGP fetch (opt-in, only when post has no media and feature is available)
      if !@dry_run &&
         source_config.dig(:processing, :ogp_fetch_link_card)
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

      # Step 6d: Link card thumbnail (opt-in, only when post has only link_card media)
      # Bluesky poskytuje thumbnail přímo v API odpovědi (external.thumb) — bez HTTP requestu.
      if source_config.dig(:processing, :ogp_fetch_link_card)
        if post.media.any? && post.media.all?(&:link_card?)
          thumb_url = post.media.find { |m| m.link_card? }&.thumbnail_url
          if thumb_url
            post.media << Media.new(type: 'image', url: thumb_url, alt_text: '')
            log_info("[#{source_id}] Link card thumbnail: Přidán obrázek #{thumb_url}")
          else
            log_debug("[#{source_id}] Link card thumbnail: přeskočen — thumbnail_url chybí")
          end
        end
      end

      # Step 7-8: Publish (or dry run)
      if @dry_run
        log_info("[#{source_id}] DRY RUN - would publish: #{processed_text[0..100]}...")
        return Result.new(status: :published, mastodon_id: nil)
      end

      publish_result = publish_post(
        processed_text,
        post,
        source_config,
        in_reply_to_id: options[:in_reply_to_id],
        video_data_cache: video_data_cache
      )

      unless publish_result[:success]
        if publish_result[:skipped]
          log_warn("[#{source_id}] Skipped: no text and no media")
          mark_skipped(source_id, post_id, 'empty_content')
          return Result.new(status: :skipped, skipped_reason: 'empty_content')
        end
        log_error("[#{source_id}] Publish failed: #{publish_result[:error]}")
        return Result.new(status: :failed, error: publish_result[:error])
      end

      # Step 9: Mark as published
      mastodon_id = publish_result[:mastodon_id]
      mark_published(source_id, post, mastodon_id)

      # Add to edit buffer for future edit detection
      if @edit_step.enabled?(platform) && mastodon_id
        begin
          @edit_step.add_to_buffer(source_id, post, mastodon_id)
        rescue StandardError => e
          log_warn("[EditBuffer] Failed to add: #{e.message}")
        end
      end

      # Step 9b: Store video fingerprint after successful publication.
      # Only stored when phash is available — records without phash can never trigger dedup.
      if video_data_cache.is_a?(Hash) && video_data_cache[:phash]
        begin
          media_dedup.store!(source_id, video_data_cache[:data],
                             post_id: post_id, media_url: video_data_cache[:url],
                             phash_int: video_data_cache[:phash])
        rescue StandardError => e
          log_warn("[MediaDedup] Failed to store fingerprint: #{e.message}")
        end
      end

      log_info("[#{source_id}] Published: #{mastodon_id}")
      Result.new(status: :published, mastodon_id: mastodon_id)

    rescue Zpravobot::AccountRateLimitedError => e
      account = source_config.dig(:target, :mastodon_account) || 'unknown'
      log_warn("[#{source_id}] Rate limited (account: #{account}, #{e.retry_after}s) — deferring post #{post_id}")
      Result.new(status: :rate_limited, error: e.message)
    rescue StandardError => e
      log_error("[#{source_id}] Error processing post: #{e.message}")
      log_error(e.backtrace.first(5).join("\n")) if @verbose
      Result.new(status: :failed, error: e.message)
    end

    # Public wrapper around process_content for use in edit paths that need
    # identical trimming behaviour as the normal publish pipeline (Step 5).
    def trim_text(text, source_config, fallback_url: nil)
      process_content(text, source_config, fallback_url: fallback_url)
    end

    # Safety net: re-run process_content if post-Step-6 URL processing grew the text
    # past the hard instance limit (truncation.max_length). Applies only when a hard
    # per-bot limit is configured AND the text actually exceeds it. Idempotent.
    def enforce_hard_limit(text, source_config, fallback_url: nil)
      truncation = source_config[:truncation] || {}
      hard_limit = truncation[:max_length]
      return text unless hard_limit && text.is_a?(String) && text.length > hard_limit

      source_id = source_config[:id]
      log_warn("[#{source_id}] Text grew past hard limit after URL processing (#{text.length}/#{hard_limit}) — re-trimming")
      process_content(text, source_config, fallback_url: fallback_url)
    end

    private

    # ============================================
    # Video Dedup helpers
    # ============================================

    def media_dedup
      @media_dedup ||= Processors::MediaDedup.new(@state_manager, logger: @logger || as_logger)
    end

    # Download video and check for duplicate.
    # Returns:
    #   :duplicate                     — video already published, skip post
    #   { url:, data: String, phash: } — new video, data + pHash cached for upload step
    #   nil                            — no video found or all downloads failed (proceed normally)
    def check_video_dedup(source_id, post_id, post, hours, max_video_bytes: nil)
      return nil unless post.respond_to?(:media)

      video_media = Array(post.media).find { |m| m.respond_to?(:type) && m.type == 'video' }
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

        # pHash path: perceptual hash via ImageMagick, robust against re-encoding.
        # If phash is nil (ImageMagick unavailable or frame extraction failed), skip dedup entirely.
        phash = Processors::ThumbnailPhash.compute(video_data)
        if phash && media_dedup.duplicate_by_phash?(source_id, phash, hours: hours)
          log_info("[#{source_id}] Video dedup (pHash): skipping duplicate for post #{post_id}")
          return :duplicate
        end

        { url: video_url, data: video_data, phash: phash }
      rescue StandardError => e
        log_warn("[#{source_id}] Video dedup check failed (proceeding): #{e.message}")
        nil
      end
    end

    # ============================================
    # Edit Detection helpers
    # ============================================

    def extract_username(post, fallback: 'unknown')
      if post.respond_to?(:author) && post.author
        return post.author.handle if post.author.respond_to?(:handle) && post.author.handle
        return post.author.username if post.author.respond_to?(:username) && post.author.username
      end
      fallback
    end

    # Process post as update to existing Mastodon status
    def process_as_update(post, source_config, edit_result, options)
      source_id = source_config[:id]
      post_id = post.id || post.url
      mastodon_id = edit_result[:mastodon_id]

      # Guard: if mastodon_id is missing, we can't update — publish as new instead
      unless mastodon_id
        log_warn("[#{source_id}] Edit detected but no mastodon_id available, publishing as new")
        return nil
      end

      # Format the new text
      formatter = create_formatter(source_config)
      formatted_text = formatter.format(post)
      options[:on_format]&.call(formatted_text)

      formatted_text = apply_content_replacements(formatted_text, source_config)
      fallback_url_for_trim = build_trim_fallback_url(post, source_config)
      processed_text = process_content(formatted_text, source_config, fallback_url: fallback_url_for_trim)
      processed_text = @url_step.call(processed_text, source_config)
      processed_text = enforce_hard_limit(processed_text, source_config, fallback_url: fallback_url_for_trim)
      options[:on_final]&.call(processed_text)

      if @dry_run
        log_info("[#{source_id}] DRY RUN - would update #{mastodon_id}: #{processed_text[0..100]}...")
        return Result.new(status: :published, mastodon_id: mastodon_id)
      end

      # Try to update existing Mastodon post
      update_result = update_mastodon_status(mastodon_id, processed_text, post, source_config)

      if update_result[:success]
        # UPDATE the existing record: replace original post_id with the edited post_id.
        # mark_published would INSERT a new row with the same mastodon_id → violates
        # uq_published_mastodon_status. mark_updated correctly changes post_id in-place.
        @state_manager.mark_updated(mastodon_id, post.id, new_post_url: post.url)
        @state_manager.log_publish(source_id, post_id: post.id, post_url: post.url, mastodon_status_id: mastodon_id)

        # Update edit buffer with new version
        begin
          @edit_step.add_to_buffer(source_id, post, mastodon_id)
        rescue StandardError => e
          log_warn("[EditBuffer] Failed to add: #{e.message}")
        end

        log_info("[#{source_id}] Updated: #{mastodon_id}")
        Result.new(status: :published, mastodon_id: mastodon_id)
      else
        # Update failed - fallback to publishing as new post
        log_warn("[#{source_id}] Update failed (#{update_result[:error]}), publishing as new")
        
        publish_result = publish_post(
          processed_text,
          post,
          source_config,
          in_reply_to_id: options[:in_reply_to_id]
        )

        if publish_result[:success]
          new_mastodon_id = publish_result[:mastodon_id]
          mark_published(source_id, post, new_mastodon_id)
          begin
            @edit_step.add_to_buffer(source_id, post, new_mastodon_id)
          rescue StandardError => e
            log_warn("[EditBuffer] Failed to add: #{e.message}")
          end
          log_info("[#{source_id}] Published (fallback): #{new_mastodon_id}")
          Result.new(status: :published, mastodon_id: new_mastodon_id)
        else
          Result.new(status: :failed, error: publish_result[:error])
        end
      end
    end

    def update_mastodon_status(mastodon_id, text, post, source_config)
      publisher = get_publisher(source_config)
      
      # Upload new media if any
      media_ids = upload_media(publisher, post)
      
      # Try update
      result = publisher.update_status(
        mastodon_id,
        text,
        media_ids: media_ids.empty? ? nil : media_ids
      )
      
      { success: true, mastodon_id: result['id'] }
      
    rescue Zpravobot::StatusNotFoundError
      { success: false, error: 'status_not_found' }
    rescue Zpravobot::EditNotAllowedError
      { success: false, error: 'edit_not_allowed' }
    rescue StandardError => e
      { success: false, error: e.message }
    end

    # ============================================
    # Step 3: Formatting
    # ============================================

    def create_formatter(source_config)
      platform = source_config[:platform]&.to_sym || :twitter
      formatting = source_config[:formatting] || {}
      content = source_config[:content] || {}
      processing = source_config[:processing] || {}

      # Build formatter config
      config = formatting.merge(
        platform: platform,
        source_name: formatting[:source_name],
        mentions: source_config[:mentions]
      )

      # Use platform-specific formatter (which delegates to UniversalFormatter)
      case platform
      when :twitter
        # Add thread handling options
        thread_config = source_config[:thread_handling] || {}
        config[:thread_handling] = {
          show_indicator: thread_config[:show_indicator] != false,
          indicator_position: thread_config[:indicator_position] || 'end'
        }
        Formatters::TwitterFormatter.new(config)

      when :bluesky
        # Add processing options (url_domain_fixes)
        config[:url_domain_fixes] = processing[:url_domain_fixes] || []
        Formatters::BlueskyFormatter.new(config)

      when :rss
        # Add content options and rss_source_type
        rss_config = config.merge(
          show_title_as_content: content[:show_title_as_content] || false,
          combine_title_and_content: content[:combine_title_and_content] || false,
          title_separator: content[:title_separator] || ' — ',
          rss_source_type: source_config[:rss_source_type] || 'rss'
        )
        Formatters::RssFormatter.new(rss_config)

      when :youtube
        # Add content options
        yt_config = config.merge(
          show_title_as_content: content[:show_title_as_content] || false,
          combine_title_and_content: content[:combine_title_and_content] || false,
          title_separator: content[:title_separator] || "\n\n",
          description_max_lines: content[:description_max_lines] || 3,
          include_views: content[:include_views] || content[:include_view_count] || false
        )
        Formatters::YouTubeFormatter.new(yt_config)
        
      else
        # Fallback to UniversalFormatter directly
        Formatters::UniversalFormatter.new(config)
      end
    end

    # ============================================
    # Step 4: Content Replacements
    # ============================================

    def apply_content_replacements(text, source_config)
      processing = source_config[:processing] || {}
      replacements = processing[:content_replacements] || []

      return text if replacements.empty?
      return text unless defined?(Processors::ContentFilter)

      # Extract trailing URL (same invariant as Step 5: URL is untouchable)
      url_suffix = nil
      text_for_processing = text
      if text =~ /([\r\n]+[^\n]*?https?:\/\/[^\s]+)\s*\z/
        url_suffix = $1
        text_for_processing = text.sub(/([\r\n]+[^\n]*?https?:\/\/[^\s]+)\s*\z/, '')
      end

      source_id = source_config[:id]
      filter = get_content_filter(source_id, replacements)
      result = filter.apply_replacements(text_for_processing)

      url_suffix ? "#{result}#{url_suffix}" : result
    end

    def get_content_filter(source_id, replacements)
      @content_filters[source_id] ||= Processors::ContentFilter.new(
        content_replacements: replacements
      )
    end

    # ============================================
    # Step 5: Content Processing (Trim)
    # ============================================

    # @param fallback_url [String, nil] URL to append when trimming occurs and no trailing URL is present.
    #   Used for platforms (Twitter, Bluesky) where the formatter does not add a URL for regular posts,
    #   and for cases where url_already_in_content? prevented appending the URL at formatting time.
    def process_content(text, source_config, fallback_url: nil)
      return text unless defined?(Processors::ContentProcessor)

      processing = source_config[:processing] || {}
      formatting = source_config[:formatting] || {}
      truncation = source_config[:truncation] || {}

      # Priority: truncation.max_length (instance-specific) > formatting.max_length > processing.max_length > 500
      # truncation.max_length is a hard per-bot limit matching the Mastodon instance character limit — trim exactly to it.
      # processing.max_length is a platform-level soft limit (e.g. 2400 for Twitter) — trim to 90% of it
      # to leave headroom for post-trim additions (URL rewriting, video fallback URLs, etc.).
      # Standard Mastodon limit (≤500) uses exact value — no headroom factor needed.
      soft_max = truncation[:max_length] || formatting[:max_length] || processing[:max_length] || 500
      max_length = if truncation[:max_length]
                     soft_max              # Hard per-bot limit: use exactly
                   elsif soft_max > 500
                     (soft_max * 0.9).to_i # High soft limit (e.g. Twitter 2400): apply 90% headroom
                   else
                     soft_max              # Standard Mastodon limit (≤500): use exactly
                   end
      strategy = (processing[:trim_strategy] || 'smart').to_sym
      tolerance = processing[:smart_tolerance_percent] || 12

      # Extract trailing URL (with optional prefix like 📺 🎬) to preserve through trimming
      url_suffix = nil
      text_for_processing = text
      if text =~ /([\r\n]+[^\n]*?https?:\/\/[^\s]+)\s*\z/
        url_suffix = $1
        text_for_processing = text.sub(/([\r\n]+[^\n]*?https?:\/\/[^\s]+)\s*\z/, '')
      end

      # If text will be trimmed but has no trailing URL, inject fallback_url as suffix.
      # This covers two scenarios:
      #   1. Twitter/Bluesky regular posts: formatter never adds URL (include_post_url_for_regular: false)
      #   2. RSS/other: url_already_in_content? prevented trailing URL; URL in body gets cut on trim
      if url_suffix.nil? && fallback_url && !fallback_url.to_s.empty? && text_for_processing.length > max_length
        read_more_prefix = formatting[:read_more_prefix] || "\n📖➡️ "
        # "\n" is the hardcoded separator that compose_output adds before url_prefix;
        # read_more_prefix itself starts with "\n", giving "\n\n📖➡️ url" (empty line before emoji).
        url_suffix = "\n#{read_more_prefix}#{fallback_url}"
      end

      # effective_max is the budget for the text body (before suffix is re-attached).
      # When max_length is a total-post limit (Mastodon instance limit ≥500 or explicit truncation.max_length),
      # subtract suffix_len so the full post (body + suffix) stays within the limit.
      # When max_length is a body-only limit (e.g. RSS platform max_length: 200), the suffix is appended
      # separately and does NOT count towards the body budget — do not subtract.
      suffix_len = url_suffix ? url_suffix.length : 0
      effective_max = if truncation[:max_length] || max_length >= 500
                        max_length - suffix_len  # Total-post limit: make room for suffix
                      else
                        max_length               # Body-only limit: suffix is appended on top
                      end

      # Process
      processor = Processors::ContentProcessor.new(
        max_length: effective_max,
        strategy: strategy,
        tolerance_percent: tolerance
      )
      processed = processor.process(text_for_processing)

      # Re-attach trailing URL with prefix
      if url_suffix
        processed = "#{processed.rstrip}#{url_suffix}"
      end

      processed
    end

    # Build a URL to use as fallback when trimming occurs and formatter did not add a trailing URL.
    # Rewrites the URL through platform-specific domain mapping (e.g. twitter.com → xcancel.com).
    # @param post [Post] Post object
    # @param source_config [Hash] Source configuration
    # @return [String, nil] Rewritten post URL or nil
    def build_trim_fallback_url(post, source_config)
      return nil unless post.respond_to?(:url) && !post.url.to_s.empty?

      url = post.url.dup
      formatting = source_config[:formatting] || {}
      url_domain = formatting[:url_domain]
      rewrite_domains = Array(formatting[:rewrite_domains])

      # Fall back to platform defaults (e.g. Twitter → xcancel.com)
      # when source config doesn't have explicit URL rewriting configured.
      if (url_domain.nil? || rewrite_domains.empty?) && defined?(Formatters::UniversalFormatter)
        platform = source_config[:platform]&.to_sym
        platform_defaults = Formatters::UniversalFormatter::PLATFORM_DEFAULTS[platform] || {}
        url_domain ||= platform_defaults[:url_domain]
        rewrite_domains = Array(platform_defaults[:rewrite_domains]) if rewrite_domains.empty?
      end

      if url_domain && rewrite_domains.any?
        rewrite_domains.each do |domain|
          url = url.gsub(%r{https?://(?:www\.)?#{Regexp.escape(domain)}/}i, "https://#{url_domain}/")
        end
      end

      url
    end

    # ============================================
    # Step 7-8: Publishing
    # ============================================

    def publish_post(text, post, source_config, in_reply_to_id: nil, video_data_cache: nil)
      publisher = get_publisher(source_config)
      visibility = source_config.dig(:target, :visibility) || 'public'

      max_video_mb = source_config.dig(:processing, :max_video_size_mb)
      max_size = max_video_mb ? max_video_mb * 1024 * 1024 : nil

      # Upload media (pass pre-downloaded video data if available to avoid double download)
      media_ids = upload_media(publisher, post, video_data_cache: video_data_cache, max_size: max_size)

      # Skip posts with no text and no media — nothing to publish, mark as skipped so runner doesn't retry.
      if (text.nil? || text.strip.empty?) && media_ids.empty?
        return { success: false, skipped: true, error: 'empty_content' }
      end

      # Video fallback: pokud měl post video (type: 'video' v media NEBO post.has_video) ale upload selhal,
      # zkus nejdřív nahrát thumbnail ze Syndication API jako náhradní obrázek;
      # pokud to nejde (nebo thumbnail není k dispozici), přidej odkaz na originál.
      # Poznámka: Nitter proxy thumbnail URL (video_thumbnail_url chybí v raw) záměrně ignorujeme.
      has_real_video = (
        post.respond_to?(:media) &&
        post.media.is_a?(Array) &&
        post.media.any? { |m| m.respond_to?(:type) && m.type == 'video' }
      ) || (post.respond_to?(:has_video) && post.has_video)
      if media_ids.empty? && has_real_video
        # Zkus thumbnail jako náhradní obrázek (pouze pbs.twimg.com URL ze Syndication API)
        thumbnail_url = post.respond_to?(:raw) && post.raw.is_a?(Hash) && post.raw[:video_thumbnail_url]
        if thumbnail_url
          begin
            thumbnail_id = publisher.upload_media_from_url(thumbnail_url, description: post.text.to_s.strip)
            media_ids = [thumbnail_id].compact if thumbnail_id
            log "Video upload failed, thumbnail uploaded as fallback image"
          rescue StandardError => e
            log "Thumbnail fallback upload also failed: #{e.message}", level: :warn
          end
        end

        # Přidej odkaz na originál (pokud ho formatter již nepřidal).
        # Použij rewritten URL (xcancel.com pro Twitter) — stejnou jakou formatter vložil
        # do textu — aby dedup check text.include?(url) správně fungoval.
        video_url_already_added = post.respond_to?(:raw) && post.raw.is_a?(Hash) && post.raw[:video_url_added]
        raw_url = post.respond_to?(:url) ? post.url.to_s : ''
        url     = build_trim_fallback_url(post, source_config) || raw_url
        unless video_url_already_added || url.empty? ||
               text.include?(url) || (!raw_url.empty? && raw_url != url && text.include?(raw_url))
          video_prefix = source_config.dig(:formatting, :prefix_video) || '🎬'
          text = "#{text}\n#{video_prefix} #{url}"
        end
      end
    
      # Thumbnail-only video post: Syndication returned only a thumbnail (no mp4 URL), which
      # was uploaded as type:'image' — so media_ids is NOT empty and the block above was skipped.
      # But the formatter (Tier 1.5/2 path) also did not add a URL to text, so we add it here.
      if post.respond_to?(:raw) && post.raw.is_a?(Hash) && post.raw[:video_thumbnail_only]
        video_url_already_added_th = post.raw[:video_url_added]
        raw_url_th = post.respond_to?(:url) ? post.url.to_s : ''
        url_th = build_trim_fallback_url(post, source_config) || raw_url_th
        unless video_url_already_added_th || url_th.empty? ||
               text.include?(url_th) || (!raw_url_th.empty? && raw_url_th != url_th && text.include?(raw_url_th))
          video_prefix = source_config.dig(:formatting, :prefix_video) || '🎬'
          text = "#{text}\n#{video_prefix} #{url_th}"
        end
      end

      # Profile card blocker: pokud text obsahuje mention ale nemáme žádná média,
      # přidáme průhledný 1×1px PNG aby Mastodon nezobrazil profile card prvního zmíněného profilu.
      if media_ids.empty? && contains_mention?(text)
        dummy_id = upload_dummy_transparent_image(publisher)
        media_ids = [dummy_id] if dummy_id
      end

      # Publish
      begin
        result = publisher.publish(
          text,
          media_ids: media_ids,
          visibility: visibility,
          in_reply_to_id: in_reply_to_id
        )
      rescue StandardError => e
        # Fallback: if parent post doesn't exist, retry as standalone
        if in_reply_to_id && e.message =~ /Record not found|neexistuje|does not appear to exist/i
          log_warn "Thread parent #{in_reply_to_id} not found, publishing as standalone"
          result = publisher.publish(
            text,
            media_ids: media_ids,
            visibility: visibility
          )
        else
          raise
        end
      end

      { success: true, mastodon_id: result['id'] }

    rescue Zpravobot::AccountRateLimitedError
      raise
    rescue StandardError => e
      { success: false, error: e.message }
    end

    def upload_media(publisher, post, video_data_cache: nil, max_size: nil)
      return [] unless post.respond_to?(:media) && post.media
      return [] if post.media.empty?

      # Filter out non-uploadable media types before upload
      uploadable = post.media.reject do |media|
        media.type == 'link_card' ||
          (media.type == 'video_thumbnail' && post.media.any? { |m| m.type == 'video' })
      end

      return [] if uploadable.empty?

      # Mastodon forbids mixing video and images in a single post.
      # When both are present, keep only the video (richer content).
      if uploadable.any? { |m| m.type == 'video' } && uploadable.any? { |m| m.type == 'image' }
        log "Mixed media (video + image) detected — dropping images, keeping video only"
        uploadable = uploadable.reject { |m| m.type == 'image' }
      end

      publisher_opts = max_size ? { max_size: max_size } : {}

      # If we have pre-downloaded video bytes, upload the cached video directly
      # to avoid downloading it a second time; upload other media items normally.
      # When data is nil (large video >10MB), skip cache and fall through to URL-based upload.
      if video_data_cache.is_a?(Hash) && !video_data_cache[:data].nil?
        cached_url = video_data_cache[:url]
        cached_data = video_data_cache[:data]
        media_ids = []
        uploadable.each do |media|
          if media.url == cached_url
            mid = publisher.upload_media_from_data(cached_data, url: cached_url, description: media.alt_text, **publisher_opts)
            media_ids << mid if mid
          else
            items = [{ url: media.url, description: media.alt_text, url_variants: media.url_variants }]
            media_ids.concat(publisher.upload_media_parallel(items, **publisher_opts))
          end
        end
        return media_ids
      end

      # Default: parallel URL-based upload (publisher handles MAX_MEDIA_COUNT limit)
      media_items = uploadable.map do |media|
        { url: media.url, description: media.alt_text, url_variants: media.url_variants }
      end

      publisher.upload_media_parallel(media_items, **publisher_opts)
    end

    def get_publisher(source_config)
      account_id = source_config.dig(:target, :mastodon_account)

      @publishers[account_id] ||= begin
        # Try direct token first (from Orchestrator)
        token = source_config[:_mastodon_token]

        # Fall back to config_loader (for IftttQueueProcessor)
        unless token
          account_creds = @config_loader.mastodon_credentials(account_id)
          token = account_creds[:token]
        end

        instance_url = source_config.dig(:target, :mastodon_instance) ||
                       source_config.dig(:mastodon, :instance) ||
                       @config_loader.load_global_config.dig(:mastodon, :instance)

        Publishers::MastodonPublisher.new(
          instance_url: instance_url,
          access_token: token
        )
      end
    end

    # ============================================
    # Step 9: State Management
    # ============================================

    def mark_published(source_id, post, mastodon_id)
      # For Bluesky, post.id is the AT URI (at://did:plc:.../app.bsky.feed.post/...)
      # Store it as platform_uri for thread linking
      platform_uri = post.bluesky? ? post.id : nil

      @state_manager.mark_published(
        source_id,
        post.id,
        post_url: post.url,
        mastodon_status_id: mastodon_id,
        platform_uri: platform_uri
      )

      @state_manager.log_publish(
        source_id,
        post_id: post.id,
        post_url: post.url,
        mastodon_status_id: mastodon_id
      )
    end

    def mark_skipped(source_id, post_id, reason)
      @state_manager.log_skip(source_id, post_id: post_id, reason: reason)
    end

    # ============================================
    # Profile Card Blocker (Dummy Image)
    # ============================================

    # Detects presence of a Mastodon-resolvable mention (@handle or @handle@domain)
    # or a Bluesky profile URL (bsky.app/profile/...) in formatted text.
    # Detects prefix-style profile mentions that cause Mastodon to render a profile card.
    # Suffix mentions (@handle@twitter.com) do not generate profile cards and are excluded.
    # @param text [String] Formatted Mastodon text
    # @return [Boolean]
    def contains_mention?(text)
      return false if text.nil? || text.empty?
      PROFILE_URL_PREFIXES.any? { |prefix| text.include?(prefix) }
    end

    # Upload transparent 1×1px PNG to prevent Mastodon profile card hijack.
    # Called when post has mentions but no other media attachments.
    # Non-fatal: returns nil on failure (post continues without dummy image).
    # @param publisher [Publishers::MastodonPublisher]
    # @return [String, nil] Media ID or nil on failure
    def upload_dummy_transparent_image(publisher)
      unless File.exist?(MENTION_BLOCKER_PNG_PATH)
        log_warn("Dummy transparent PNG not found: #{MENTION_BLOCKER_PNG_PATH}")
        return nil
      end

      data = File.binread(MENTION_BLOCKER_PNG_PATH)
      result = publisher.upload_media(
        data,
        filename: 'transparent.png',
        content_type: 'image/png',
        description: nil
      )
      log_info("  📎 Dummy 1×1px image uploaded (profile card blocker)") if result
      result
    rescue StandardError => e
      log_warn("  Dummy image upload failed: #{e.message}")
      nil
    end

    # ============================================
    # Step 6c: OGP Image Fetch
    # ============================================

    # Locate the article URL in the post and attempt to fetch its og:image.
    #
    # Tři fallback vrstvy pro URL:
    #   1. post.raw[:link_card_url] — uložena během build_syndication_post z expandovaného textu
    #      (spolehlivá i pokud se expand_tco_links zdaří; t.co URL se expanduje on-the-fly)
    #   2. První non-platform URL v processed_text (po formátování a URL rewriting)
    #   3. První non-platform URL v post.text (před formátováním — záloha)
    #
    # @param post [Post] Post object
    # @param processed_text [String] Post text after URL processing (t.co expanded)
    # @param source_id [String] Source identifier for logging
    # @return [String, nil] og:image URL or nil
    def fetch_ogp_image_for_post(post, processed_text, source_id = nil)
      # Priority 0: card image ze Syndication API (Twitter ji pre-fetchuje sám → pbs.twimg.com)
      # Nevyžaduje scraping cílového článku, obchází blokování třetích stran.
      if post.raw.is_a?(Hash)
        card_image = post.raw[:card_image]
        if card_image.to_s.start_with?('https://')
          log_info("[#{source_id}] OGP: card image ze Syndication API → #{card_image}") if source_id
          return card_image
        end
      end

      fetcher = Utils::OgpFetcher.new
      article_url = nil

      # Priority 1: post.raw[:link_card_url] — uložena v build_syndication_post
      raw_link = post.raw.is_a?(Hash) ? post.raw[:link_card_url].to_s : ''
      if raw_link.start_with?('http://', 'https://')
        # Pokud je stále t.co → expandovat on-the-fly přes HEAD request
        if raw_link.include?('t.co/')
          expanded = expand_tco_url(raw_link)
          article_url = expanded if expanded && !expanded.include?('t.co/')
          log_info("[#{source_id}] OGP: t.co expandováno → #{article_url || '(selhalo)'}") if source_id
        else
          article_url = raw_link
        end
        log_info("[#{source_id}] OGP: URL z post.raw → #{article_url}") if source_id && article_url
      end

      # Priority 2: první non-platform URL v processed_text
      unless article_url
        article_url = extract_article_url_from_text(processed_text)
        log_info("[#{source_id}] OGP: URL z processed_text → #{article_url}") if source_id && article_url
      end

      # Priority 3: první non-platform URL přímo v post.text (před formátováním)
      unless article_url
        article_url = extract_article_url_from_text(post.respond_to?(:text) ? post.text.to_s : '')
        log_info("[#{source_id}] OGP: URL z post.text → #{article_url}") if source_id && article_url
      end

      unless article_url
        log_info("[#{source_id}] OGP: žádná article URL nenalezena (t.co v textu? platforma bez URL?)") if source_id
        return nil
      end

      fetcher.fetch_og_image(article_url)
    rescue StandardError => e
      log_warn("[OGP] fetch_ogp_image_for_post failed: #{e.message}")
      nil
    end

    # Extract the first URL from text that is not a social/platform URL.
    # Strips trailing punctuation from matched URLs (., , ; : ! ? etc.)
    #
    # @param text [String] Post text
    # @return [String, nil] First article URL or nil
    def extract_article_url_from_text(text)
      return nil if text.nil? || text.empty?

      urls = text.scan(%r{https?://[^\s>)]+})
      urls.each do |raw_url|
        # Strip trailing punctuation that regex may have captured
        url = raw_url.sub(/[.,;:!?…]+$/, '')
        next if OGP_SKIP_DOMAINS.any? { |domain| url.include?(domain) }
        return url
      end
      nil
    end

    # Expand a single t.co URL via HTTP HEAD redirect.
    # Used as on-the-fly fallback when post.raw[:link_card_url] is still a t.co link.
    #
    # @param tco_url [String] t.co URL
    # @return [String, nil] Expanded URL or nil on failure
    def expand_tco_url(tco_url)
      response = HttpClient.head(tco_url, open_timeout: 3, read_timeout: 3)
      response['location'] if response.is_a?(Net::HTTPRedirection)
    rescue StandardError
      nil
    end

    # ============================================
    # Logging - delegates to injected logger or Loggable
    # ============================================

    def log_info(msg)
      @logger ? @logger.info(msg) : log(msg, level: :info)
    end

    def log_debug(msg)
      @logger ? @logger.debug(msg) : log(msg, level: :debug)
    end

    def log_warn(msg)
      @logger ? @logger.warn(msg) : log(msg, level: :warn)
    end

    def log_error(msg)
      @logger ? @logger.error(msg) : log(msg, level: :error)
    end
  end
end
