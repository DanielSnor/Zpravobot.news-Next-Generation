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

require_relative '../support/loggable'
require_relative '../errors'
require_relative 'pipeline_steps'

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
      processed_text = process_content(formatted_text, source_config)

      # Step 6: Process URLs
      processed_text = @url_step.call(processed_text, source_config)
      
      # Callback for verbose logging
      options[:on_final]&.call(processed_text)

      # Step 7-8: Publish (or dry run)
      if @dry_run
        log_info("[#{source_id}] DRY RUN - would publish: #{processed_text[0..100]}...")
        return Result.new(status: :published, mastodon_id: nil)
      end

      publish_result = publish_post(
        processed_text,
        post,
        source_config,
        in_reply_to_id: options[:in_reply_to_id]
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
      
      log_info("[#{source_id}] Published: #{mastodon_id}")
      Result.new(status: :published, mastodon_id: mastodon_id)

    rescue StandardError => e
      log_error("[#{source_id}] Error processing post: #{e.message}")
      log_error(e.backtrace.first(5).join("\n")) if @verbose
      Result.new(status: :failed, error: e.message)
    end

    private

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
      processed_text = process_content(formatted_text, source_config)
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
        @state_manager.mark_updated(mastodon_id, post.id, post_url: post.url)
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

    def process_content(text, source_config)
      return text unless defined?(Processors::ContentProcessor)

      processing = source_config[:processing] || {}
      formatting = source_config[:formatting] || {}
      truncation = source_config[:truncation] || {}

      # Priority: truncation.max_length (instance-specific) > formatting.max_length > processing.max_length > 500
      # truncation.max_length is set per-bot to match the Mastodon instance character limit.
      # processing.max_length is a platform-level fallback (e.g. 2400 for Twitter) and must
      # not override the bot-specific instance limit.
      max_length = truncation[:max_length] || formatting[:max_length] || processing[:max_length] || 500
      strategy = (processing[:trim_strategy] || 'smart').to_sym
      tolerance = processing[:smart_tolerance_percent] || 12

      # Extract trailing URL (with optional prefix like 📺 🎬) to preserve through trimming
      url_suffix = nil
      text_for_processing = text
      if text =~ /([\r\n]+[^\n]*?https?:\/\/[^\s]+)\s*\z/
        url_suffix = $1
        text_for_processing = text.sub(/([\r\n]+[^\n]*?https?:\/\/[^\s]+)\s*\z/, '')
      end

      # Account for url_suffix length in the budget so the re-attached URL
      # does not push the final text over max_length.
      suffix_len = url_suffix ? url_suffix.length : 0
      effective_max = [max_length - suffix_len, 1].max

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

    # ============================================
    # Step 7-8: Publishing
    # ============================================

    def publish_post(text, post, source_config, in_reply_to_id: nil)
      publisher = get_publisher(source_config)
      visibility = source_config.dig(:target, :visibility) || 'public'
    
      # Upload media
      media_ids = upload_media(publisher, post)
    
      # Video fallback: pokud má post video ale žádná média se nenahrála,
      # přidej odkaz na originál (pokud ho formatter už nepřidal)
      if media_ids.empty? && post.respond_to?(:has_video?) && post.has_video?
        video_url_already_added = post.respond_to?(:raw) && post.raw.is_a?(Hash) && post.raw[:video_url_added]
        unless video_url_already_added || text.include?(post.url)
          video_prefix = source_config.dig(:formatting, :prefix_video) || '🎬'
          text = "#{text}\n#{video_prefix} #{post.url}"
        end
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
        if in_reply_to_id && e.message =~ /Record not found|neexistuje/i
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

    def upload_media(publisher, post)
      return [] unless post.respond_to?(:media) && post.media
      return [] if post.media.empty?

      # Filter out non-uploadable media types before parallel upload
      uploadable = post.media.reject do |media|
        media.type == 'link_card' ||
          (media.type == 'video_thumbnail' && post.media.any? { |m| m.type == 'video' })
      end

      return [] if uploadable.empty?

      # Build items for parallel upload (publisher handles MAX_MEDIA_COUNT limit)
      media_items = uploadable.map do |media|
        { url: media.url, description: media.alt_text }
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
