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

# Media deduplication (lazy loaded — guards against LoadError in unit tests)
begin
  require_relative 'media_dedup'
  MEDIA_DEDUP_AVAILABLE = true unless defined?(MEDIA_DEDUP_AVAILABLE)
rescue LoadError
  MEDIA_DEDUP_AVAILABLE = false unless defined?(MEDIA_DEDUP_AVAILABLE)
end

# HttpClient for video pre-download in dedup step (lazy loaded)
begin
  require_relative '../utils/http_client'
  HTTP_CLIENT_AVAILABLE = true unless defined?(HTTP_CLIENT_AVAILABLE)
rescue LoadError
  HTTP_CLIENT_AVAILABLE = false unless defined?(HTTP_CLIENT_AVAILABLE)
end

# Formatters (lazy loaded - expected to be required by caller)
# require_relative '../formatters/twitter_formatter'
# require_relative '../formatters/bluesky_formatter'
# require_relative '../formatters/rss_formatter'
# require_relative '../formatters/youtube_formatter'
# require_relative '../formatters/universal_formatter'

# Publishers (lazy loaded)
# require_relative '../publishers/mastodon_publisher'

# Edit detection (lazy loaded)
begin
  require_relative 'edit_detector'
  EDIT_DETECTOR_AVAILABLE = true
rescue LoadError
  EDIT_DETECTOR_AVAILABLE = false
end

TRANSPARENT_1X1_PNG_PATH = File.join(__dir__, '../../assets/transparent_1x1.png')

module Processors
  class PostProcessor
    include Support::Loggable

    # Result struct for processing outcome
    Result = Struct.new(:status, :mastodon_id, :error, :skipped_reason, keyword_init: true) do
      def published?
        status == :published
      end
      
      def skipped?
        status == :skipped
      end
      
      def failed?
        status == :failed
      end
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
      @edit_step = EditDetectionStep.new(state_manager, EDIT_DETECTOR_AVAILABLE, logger: logger)
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
      processed_text = process_content(formatted_text, source_config, fallback_url: build_trim_fallback_url(post, source_config))

      # Step 6: Process URLs
      processed_text = @url_step.call(processed_text, source_config)

      # Callback for verbose logging
      options[:on_final]&.call(processed_text)

      # Step 6b: Video dedup check (opt-in per source, skipped in dry_run)
      video_dedup_hours = source_config.dig(:processing, :video_dedup_hours)
      video_data_cache = nil
      if !@dry_run && video_dedup_hours && MEDIA_DEDUP_AVAILABLE && HTTP_CLIENT_AVAILABLE
        video_data_cache = check_video_dedup(source_id, post_id, post, video_dedup_hours.to_i)
        if video_data_cache == :duplicate
          mark_skipped(source_id, post_id, 'duplicate_video')
          return Result.new(status: :skipped, skipped_reason: 'duplicate_video')
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
      # For large videos (data: nil), fingerprint by URL string; for small videos, by content.
      if video_data_cache.is_a?(Hash) && MEDIA_DEDUP_AVAILABLE
        begin
          fingerprint_data = video_data_cache[:data] || video_data_cache[:url]
          media_dedup.store!(source_id, fingerprint_data,
                             post_id: post_id, media_url: video_data_cache[:url])
        rescue StandardError => e
          log_warn("[MediaDedup] Failed to store fingerprint: #{e.message}")
        end
      end

      log_info("[#{source_id}] Published: #{mastodon_id}")
      Result.new(status: :published, mastodon_id: mastodon_id)

    rescue StandardError => e
      log_error("[#{source_id}] Error processing post: #{e.message}")
      log_error(e.backtrace.first(5).join("\n")) if @verbose
      Result.new(status: :failed, error: e.message)
    end

    private

    # ============================================
    # Video Dedup helpers
    # ============================================

    def media_dedup
      @media_dedup ||= Processors::MediaDedup.new(@state_manager, logger: @logger || as_logger)
    end

    # Download video and check for duplicate hash.
    # Returns:
    #   :duplicate               — video already published, skip post
    #   { url:, data: String }   — new small video (≤10MB), data cached for upload step
    #   { url:, data: nil }      — new large video (>10MB), URL-hash fingerprint stored, upload uses URL
    #   nil                      — no video found or download failed (proceed normally)
    def check_video_dedup(source_id, post_id, post, hours)
      return nil unless post.respond_to?(:media)

      video_media = Array(post.media).find { |m| m.respond_to?(:type) && m.type == 'video' }
      return nil unless video_media&.url

      begin
        urls_to_try = ([video_media.url] + Array(video_media.url_variants).reject { |u| u == video_media.url }).compact

        video_url = nil
        video_data = nil
        fallback_url = nil  # first URL that returned :too_large (for URL-hash fallback)

        urls_to_try.each do |url|
          response = HttpClient.download(url, max_size: 10 * 1024 * 1024)
          if response == :too_large
            fallback_url ||= url
            next
          end
          next if response.nil? || response.body.nil? || response.body.empty?

          video_url = url
          video_data = response.body
          break
        end

        if video_data
          # Content-hash path: small video — hash binary data
          if media_dedup.duplicate?(source_id, video_data, hours: hours)
            log_info("[#{source_id}] Video dedup: skipping duplicate for post #{post_id}")
            return :duplicate
          end
          return { url: video_url, data: video_data }
        elsif fallback_url
          # URL-hash path: large video (>10MB) — hash the URL string as proxy fingerprint.
          # Syndication API URLs are stable per tweet, so same tweet → same URL → same hash.
          if media_dedup.duplicate?(source_id, fallback_url, hours: hours)
            log_info("[#{source_id}] Video dedup (URL-hash): skipping duplicate for post #{post_id}")
            return :duplicate
          end
          return { url: fallback_url, data: nil }  # nil = too large, upload falls back to URL path
        end

        nil  # no video or all downloads failed (non-too_large errors)
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
      processed_text = process_content(formatted_text, source_config, fallback_url: build_trim_fallback_url(post, source_config))
      processed_text = @url_step.call(processed_text, source_config)
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
      soft_max = truncation[:max_length] || formatting[:max_length] || processing[:max_length] || 500
      max_length = truncation[:max_length] ? soft_max : (soft_max * 0.9).to_i
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

      # max_length is the limit for the full post (body + suffix).
      # Reduce effective body budget by the suffix length so the total stays within max_length.
      suffix_len = url_suffix ? url_suffix.length : 0
      effective_max = max_length - suffix_len

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

      # Upload media (pass pre-downloaded video data if available to avoid double download)
      media_ids = upload_media(publisher, post, video_data_cache: video_data_cache)
    
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

    rescue StandardError => e
      { success: false, error: e.message }
    end

    def upload_media(publisher, post, video_data_cache: nil)
      return [] unless post.respond_to?(:media) && post.media
      return [] if post.media.empty?

      # Filter out non-uploadable media types before upload
      uploadable = post.media.reject do |media|
        media.type == 'link_card' ||
          (media.type == 'video_thumbnail' && post.media.any? { |m| m.type == 'video' })
      end

      return [] if uploadable.empty?

      # If we have pre-downloaded video bytes, upload the cached video directly
      # to avoid downloading it a second time; upload other media items normally.
      # When data is nil (large video >10MB), skip cache and fall through to URL-based upload.
      if video_data_cache.is_a?(Hash) && !video_data_cache[:data].nil?
        cached_url = video_data_cache[:url]
        cached_data = video_data_cache[:data]
        media_ids = []
        uploadable.each do |media|
          if media.url == cached_url
            mid = publisher.upload_media_from_data(cached_data, url: cached_url, description: media.alt_text)
            media_ids << mid if mid
          else
            items = [{ url: media.url, description: media.alt_text, url_variants: media.url_variants }]
            media_ids.concat(publisher.upload_media_parallel(items))
          end
        end
        return media_ids
      end

      # Default: parallel URL-based upload (publisher handles MAX_MEDIA_COUNT limit)
      media_items = uploadable.map do |media|
        { url: media.url, description: media.alt_text, url_variants: media.url_variants }
      end

      publisher.upload_media_parallel(media_items)
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
    # in formatted text. Uses same negative lookbehind as format_mentions regex
    # to avoid false positives on email addresses (user@domain.com).
    # @param text [String] Formatted Mastodon text
    # @return [Boolean]
    def contains_mention?(text)
      return false if text.nil? || text.empty?
      text.match?(/(?<![.\w\/])@\w+/)
    end

    # Upload transparent 1×1px PNG to prevent Mastodon profile card hijack.
    # Called when post has mentions but no other media attachments.
    # Non-fatal: returns nil on failure (post continues without dummy image).
    # @param publisher [Publishers::MastodonPublisher]
    # @return [String, nil] Media ID or nil on failure
    def upload_dummy_transparent_image(publisher)
      unless File.exist?(TRANSPARENT_1X1_PNG_PATH)
        log_warn("Dummy transparent PNG not found: #{TRANSPARENT_1X1_PNG_PATH}")
        return nil
      end

      data = File.binread(TRANSPARENT_1X1_PNG_PATH)
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
