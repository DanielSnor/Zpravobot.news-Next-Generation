# frozen_string_literal: true

# Twitter Nitter Adapter for Zpravobot Next Generation
#
# Hybridní architektura kombinující spolehlivost IFTTT s kvalitou Nitter dat:
#
# TIER 1: Přímá publikace z IFTTT dat
#   - Tweet NENÍ zkrácený (má plný text)
#   - Includes: regular posts, RT, reply, quote (všechny s plným textem)
#
# TIER 1.5: IFTTT + Syndication API
#   - Pro zdroje s nitter_processing: false
#   - Plný text + média z Twitter Syndication API
#   - Rychlejší než Nitter (JSON, ne HTML parsing)
#
# TIER 2: IFTTT trigger + Nitter fetch
#   - Tweet JE zkrácený (potřebujeme plný text z Nitteru)
#
# TIER 3.5: Syndication fallback
#   - Nitter selhal → zkusíme Syndication API
#   - Média + potenciálně zkrácený text (lepší než Tier 3)
#
# TIER 3: Final fallback
#   - Nitter i Syndication selhaly → publikuj IFTTT data (lepší než nic)
#   - Aplikuje IFTTT-style ellipsis logiku pro správné ukončení textu

require 'json'
require 'time'
require 'uri'
require_relative 'base_adapter'
require_relative 'twitter_adapter'
require_relative '../models/post'
require_relative '../models/author'
require_relative '../models/media'
require_relative '../services/syndication_media_fetcher'
require_relative '../utils/format_helpers'
require_relative '../utils/html_cleaner'
require_relative '../utils/http_client'
require_relative '../utils/punycode'

module Adapters
  class TwitterNitterAdapter < BaseAdapter
    # Twitter's practical character limit where IFTTT starts truncating
    TRUNCATION_THRESHOLD = 257

    # Patterns for detecting natural terminators (tweet probably NOT truncated)
    # Identical to IFTTT filter's hasTerminator check
    TERMINATOR_PATTERNS = {
      punctuation: /[.!?。！？…]\s*\z/,
      emoji: /\p{Emoji}\s*\z/,
      url: /https?:\/\/\S+\s*\z/,
      hashtag: /#\w+\s*\z/,
      mention: /@\w+\s*\z/
    }.freeze

    # Patterns for detecting truncated content
    TRUNCATION_PATTERNS = {
      ellipsis_text: /…|\.{3}/,
      ellipsis_url: /https?:\/\/[^\s]*…/,
      truncated_tco: /https?:\/\/t\.co\/\w*…/
    }.freeze

    attr_reader :nitter_instance, :use_nitter_fallback

    def initialize(nitter_instance: nil, use_nitter_fallback: true)
      @nitter_instance = nitter_instance || ENV['NITTER_INSTANCE']
      @use_nitter_fallback = use_nitter_fallback
    end

    # ===========================================
    # Main Entry Point - Process IFTTT Webhook
    # ===========================================

    # Process incoming IFTTT webhook payload
    # @param payload [Hash] IFTTT webhook data
    # @param bot_config [Hash] Bot configuration from YAML
    # @param force_tier2 [Boolean] Force Tier 2 processing (for thread detection in batch)
    # @return [Post, nil] Processed post or nil if skipped
    def process_webhook(payload, bot_config, force_tier2: false)
      ifttt_data = parse_ifttt_payload(payload)
      return nil unless ifttt_data

      # Inject source_handle from bot_config (used for Nitter URL and self-reply detection)
      # Allows IFTTT applets to use a hardcoded/brand username (e.g. "drozd", "vystrahy")
      # while still correctly fetching from Nitter using the real Twitter handle.
      if (source_handle = bot_config.dig(:source, :handle))
        ifttt_data[:source_handle] = source_handle
      end

      # Check if Nitter processing is disabled for this source
      # When disabled, use Syndication API (Tier 1.5) instead of Nitter
      nitter_enabled = bot_config.dig(:nitter_processing, :enabled) != false

      # Determine processing tier
      tier = if !nitter_enabled
               log "Nitter processing disabled → Tier 1.5 (Syndication)"
               1.5
             elsif force_tier2
               log "Forced Tier 2 (batch thread detection)"
               2
             else
               determine_tier(ifttt_data)
             end

      log "Processing tweet #{ifttt_data[:post_id]} via Tier #{tier}"

      case tier
      when 1
        process_tier1(ifttt_data, bot_config)
      when 1.5
        process_tier1_5(ifttt_data, bot_config)
      when 2
        process_tier2(ifttt_data, bot_config)
      else
        log "Unknown tier: #{tier}", level: :error
        nil
      end
    end

    # ===========================================
    # IFTTT Payload Parsing
    # ===========================================

    # Parse and normalize IFTTT webhook payload
    # @param payload [Hash] Raw webhook payload
    # @return [Hash, nil] Normalized data or nil if invalid
    def parse_ifttt_payload(payload)
      return nil unless payload.is_a?(Hash)

      # Extract post_id from LinkToTweet
      link_to_tweet = payload['link_to_tweet'] || payload['LinkToTweet'] || ''
      post_id = extract_post_id(link_to_tweet)
      return nil unless post_id

      text = payload['text'] || payload['Text'] || ''
      embed_code = payload['embed_code'] || payload['TweetEmbedCode'] || ''

      # IFTTT sends text/embed_code URL-encoded and may contain HTML entities
      text = decode_ifttt_field(text)
      embed_code = decode_ifttt_field(embed_code)

      {
        post_id: post_id,
        text: text,
        embed_code: embed_code,
        link_to_tweet: link_to_tweet,
        first_link_url: payload['first_link_url'] || payload['FirstLinkUrl'] || '',
        username: payload['username'] || payload['UserName'] || '',
        bot_id: payload['bot_id'] || payload['bot'] || nil,
        received_at: Time.now
      }
    end

    # Extract post ID from Twitter/X URL
    # @param url [String] Tweet URL
    # @return [String, nil] Post ID or nil
    def extract_post_id(url)
      return nil unless url.is_a?(String)

      # Match: https://twitter.com/user/status/1234567890
      # Match: https://x.com/user/status/1234567890
      match = url.match(%r{(?:twitter\.com|x\.com)/\w+/status/(\d+)})
      match ? match[1] : nil
    end

    # Extract author username from Twitter/X URL
    # @param url [String] URL like https://twitter.com/GibisVB/status/123
    # @return [String] Username or "unknown"
    def extract_author_from_url(url)
      return "unknown" unless url
      match = url.match(%r{(?:twitter\.com|x\.com)/(\w+)/status/})
      match ? match[1] : "unknown"
    end
    
    # Build quoted_post hash with author extracted from URL
    # @param url [String] Quote tweet URL
    # @return [Hash] { url:, author: }
    def build_quoted_post(url)
      return nil unless url
      { url: url, author: extract_author_from_url(url) }
    end

    # ===========================================
    # Tier Decision Logic
    # ===========================================

    # Determine which processing tier to use
    # @param ifttt_data [Hash] Parsed IFTTT data
    # @return [Integer] Tier number (1, 2)
    def determine_tier(ifttt_data)
      text = ifttt_data[:text]
      first_link = ifttt_data[:first_link_url]
      embed_code = ifttt_data[:embed_code]
      # Use source_handle (from bot_config) if available; fall back to payload username
      # This ensures correct self-reply detection when IFTTT uses a brand name (e.g. "drozd")
      # instead of the real Twitter handle (e.g. "mzvcr")
      username = ifttt_data[:source_handle] || ifttt_data[:username]

      # Retweet → Tier 2 (IFTTT always truncates RTs)
      if text&.match?(/^RT\s+@\w+:/i)
        log "Retweet detected → Tier 2 (IFTTT truncates RTs)"
        return 2
      end

      # Self-reply (thread) → Tier 2 (need Nitter for thread context)
      if is_self_reply?(text, username)
        log "Self-reply detected (thread) → Tier 2"
        return 2
      end

      # Photo detected via first_link_url → Tier 2 (need Nitter to get all images)
      if first_link && first_link.match?(%r{/photo/\d*$})
        log "Photo detected in first_link_url → Tier 2"
        return 2
      end

      # Video detected → Tier 2 (need Nitter for video thumbnail)
      if first_link && first_link.match?(%r{/video/\d*$})
        log "Video detected → Tier 2 (need thumbnail from Nitter)"
        return 2
      end

      # Quote tweet detected via first_link_url → Tier 2
      # FirstLinkUrl pointing to another tweet status (not media) = quote
      if first_link && first_link.match?(%r{(?:twitter\.com|x\.com)/\w+/status/\d+$})
        log "Quote detected in first_link_url (status URL) → Tier 2"
        return 2
      end

      # Photo detected via embed_code → Tier 2
      # (catches cases where first_link_url is a text URL, not media URL)
      if has_image_in_embed?(embed_code)
        log "Image detected in embed_code (pbs.twimg.com) → Tier 2"
        return 2
      end

      # Heuristic: Multiple t.co URLs with non-media first_link → likely has image
      # When tweet has image + text link:
      #   - FirstLinkUrl = text link (not /photo/)
      #   - Text contains 2+ t.co links (one is link, one is image)
      if first_link && !first_link.match?(%r{/(?:photo|video)/\d*$}) && !first_link.match?(%r{/status/\d+$})
        tco_count = text&.scan(%r{https?://t\.co/\S+})&.count || 0
        if tco_count >= 2
          log "Multiple t.co URLs (#{tco_count}) with non-media first_link → Tier 2 (likely has image)"
          return 2
        end
      end

      # Tier 2: Tweet is truncated, need Nitter for full text
      return 2 if likely_truncated?(text)

      # Tier 1: Full text available from IFTTT
      1
    end

    # Check if embed_code contains Twitter media images
    # IFTTT's embed_code includes the tweet HTML which contains image URLs
    # even when first_link_url points to a text link instead of /photo/
    #
    # @param embed_code [String] IFTTT TweetEmbedCode field
    # @return [Boolean] true if images detected
    def has_image_in_embed?(embed_code)
      if embed_code.nil? || embed_code.empty?
        log "embed_code is empty or nil"
        return false
      end

      # Debug: log embed_code length and presence of media patterns
      has_pbs = embed_code.include?('pbs.twimg.com/media')
      has_pic = embed_code.match?(/pic\.twitter\.com/i)
      has_video_thumb = embed_code.include?('pbs.twimg.com/ext_tw_video_thumb') ||
                        embed_code.include?('video.twimg.com')
      log "embed_code check: length=#{embed_code.length}, pbs.twimg=#{has_pbs}, pic.twitter=#{has_pic}, video_thumb=#{has_video_thumb}"

      # Twitter embeds include pbs.twimg.com/media for images
      # pic.twitter.com is the shortened form that redirects to media
      # ext_tw_video_thumb and video.twimg.com indicate video content
      has_pbs || has_pic || has_video_thumb
    end

    # Detect self-reply (thread continuation)
    # @param text [String] Tweet text
    # @param username [String] Author's username
    # @return [Boolean] true if tweet is a reply to own tweet
    def is_self_reply?(text, username)
      return false if text.nil? || username.nil?

      # Check if starts with @own_username (case insensitive)
      normalized_username = username.to_s.gsub(/^@/, '').downcase
      text.match?(/^@#{Regexp.escape(normalized_username)}\b/i)
    end

    # Detect if tweet text is likely truncated by IFTTT
    # Based on IFTTT filter logic from example-ifttt-filter-x-xcancel-4_0_0.ts
    #
    # @param text [String] Tweet text from IFTTT
    # @return [Boolean] true if likely truncated
    def likely_truncated?(text)
      return false if text.nil? || text.empty?

      # 1. Explicit ellipsis in text (definitive truncation)
      return true if text.match?(TRUNCATION_PATTERNS[:ellipsis_text])

      # 2. Truncated URL (IFTTT sometimes truncates URLs too)
      return true if text.match?(TRUNCATION_PATTERNS[:ellipsis_url])
      return true if text.match?(TRUNCATION_PATTERNS[:truncated_tco])

      # 3. Heuristic: >= 257 chars without natural terminator
      if text.length >= TRUNCATION_THRESHOLD
        # Remove trailing t.co link before checking terminator
        # IFTTT often truncates text but leaves t.co at the end
        text_for_check = text.gsub(/\s*https?:\/\/t\.co\/\S+\s*\z/, '').rstrip

        # Natural terminators that indicate complete content
        ends_with_punctuation = text_for_check.match?(/[.!?。！？]\s*\z/)
        ends_with_emoji = text_for_check.match?(/\p{Emoji}\s*\z/)
        ends_with_hashtag = text_for_check.match?(/#\w+\s*\z/)

        # If ends with digit (and no punctuation), likely truncated mid-sentence
        # e.g., "- 4 190 raket s plochou dráhou letu (+0) - 28" (cut off mid-list)
        ends_with_bare_digit = text_for_check.match?(/\d\s*\z/) && !ends_with_punctuation

        # Text ending with Czech preposition/conjunction is definitely truncated
        # No sentence naturally ends with these words
        ends_with_preposition = text_for_check.match?(/\s(a|i|k|o|s|u|v|z|na|do|od|po|za|ze|ke|ve|se|proti|pro|při|pod|nad|před|přes|mezi|mimo|bez|kvůli|podle|vůči|během|ani|aby|ale|než|jen|jak|což|nebo|jako|tedy|když|že)\s*\z/i)

        # Truncated if: no natural terminator OR ends with bare digit OR ends with preposition
        has_terminator = ends_with_punctuation || ends_with_emoji || ends_with_hashtag

        return true if ends_with_bare_digit
        return true if ends_with_preposition
        return true unless has_terminator
      end

      false
    end

    # ===========================================
    # Tier 1: Direct IFTTT Processing
    # ===========================================

    # Process tweet directly from IFTTT data (full text available)
    # @param ifttt_data [Hash] Parsed IFTTT data
    # @param bot_config [Hash] Bot configuration
    # @return [Post] Processed post
    def process_tier1(ifttt_data, bot_config)
      log "Tier 1: Direct processing for #{ifttt_data[:post_id]}"

      text = ifttt_data[:text]
      # Use source_handle (real Twitter handle) for author attribution
      username = ifttt_data[:source_handle] || ifttt_data[:username]
      first_link = ifttt_data[:first_link_url]

      # Expand t.co links to actual URLs
      expanded_text = expand_tco_links(text)

      # Detect post type
      post_type = detect_post_type(text, first_link)

      # Detect video
      has_video = first_link && first_link.match?(%r{/video/\d*$})

      # If video detected, remove video URL from text
      if has_video && first_link
        # Remove video URL from text (expanded t.co link)
        expanded_text = expanded_text.gsub(first_link, '').strip
        # Also try x.com variant
        expanded_text = expanded_text.gsub(first_link.gsub('twitter.com', 'x.com'), '').strip
        expanded_text = expanded_text.gsub(first_link.gsub('x.com', 'twitter.com'), '').strip
      end

      # For retweets: author = original author from RT @match, reposted_by = IFTTT account (retweeter)
      author_username = if post_type[:is_repost] && post_type[:rt_original_author]
        post_type[:rt_original_author]
      else
        username
      end

      # Build Post object
      Post.new(
        id: ifttt_data[:post_id],
        platform: 'twitter',
        url: ifttt_data[:link_to_tweet],
        text: clean_text(expanded_text),
        author: build_author(author_username),
        published_at: Time.now,
        media: [],  # No media for Tier 1 (photos go to Tier 2)
        is_repost: post_type[:is_repost],
        is_reply: post_type[:is_reply],
        is_quote: post_type[:is_quote],
        reposted_by: post_type[:is_repost] ? username : nil,
        quoted_post: build_quoted_post(post_type[:quoted_url]),
        has_video: has_video,
        raw: {
          source: 'ifttt',
          tier: 1,
          original_username: username,
          tco_expanded: (expanded_text != text),
          has_video: has_video
        }
      )
    end

    # ===========================================
    # Tier 1.5: IFTTT + Syndication API
    # ===========================================
    #
    # Enhanced Tier 1 using Twitter Syndication API for media.
    # Falls back to Tier 1 (no media) if Syndication fails.
    #
    # Benefits:
    #   - Full text (not truncated by IFTTT)
    #   - Photos (up to 4)
    #   - Video thumbnail
    #   - Display name
    #   - Faster than Nitter (JSON, no HTML parsing)
    #
    # @param ifttt_data [Hash] Parsed IFTTT data
    # @param bot_config [Hash] Bot configuration
    # @return [Post] Processed post
    # Shared logic for syndication-based tiers (1.5 and 3.5)
    #
    # @param ifttt_data [Hash] Parsed IFTTT data
    # @param bot_config [Hash] Bot configuration
    # @param tier [Float] Tier number for logging
    # @param fallback_method [Symbol] Method to call on failure
    # @param raw_extra [Hash] Extra data for Post#raw
    # @return [Post] Processed post
    def process_syndication_tier(ifttt_data, bot_config, tier:, fallback_method:, raw_extra:)
      log "Tier #{tier}: Syndication fetch for #{ifttt_data[:post_id]}"

      syndication = Services::SyndicationMediaFetcher.fetch(ifttt_data[:post_id])

      unless syndication[:success]
        log "Tier #{tier} failed (#{syndication[:error]}) → fallback", level: :warn
        return send(fallback_method, ifttt_data, bot_config)
      end

      log "Tier #{tier} success: #{syndication[:photos].count} photos, video: #{syndication[:video_thumbnail] ? 'yes' : 'no'}"
      build_syndication_post(ifttt_data, syndication, tier: tier, raw_extra: raw_extra)
    end

    def process_tier1_5(ifttt_data, bot_config)
      process_syndication_tier(ifttt_data, bot_config,
        tier: 1.5, fallback_method: :process_tier1,
        raw_extra: { source: 'syndication', tier: 1.5, ifttt_trigger: true })
    end

    # ===========================================
    # Tier 2: IFTTT Trigger + Nitter Fetch
    # ===========================================

    # Process tweet by fetching full data from Nitter
    # Falls back to Tier 3 (IFTTT data) if Nitter fails
    #
    # @param ifttt_data [Hash] Parsed IFTTT data
    # @param bot_config [Hash] Bot configuration
    # @return [Post] Processed post
    def process_tier2(ifttt_data, bot_config)
      log "Tier 2: Nitter fetch for #{ifttt_data[:post_id]}"

      return process_tier3_fallback(ifttt_data, bot_config) unless use_nitter_fallback && nitter_instance

      # Exponential backoff: 3 pokusy s delay 1s, 2s, 4s
      max_retries = 3
      retry_delays = [1, 2, 4]

      max_retries.times do |attempt|
        begin
          # Use existing TwitterAdapter to fetch from Nitter
          # Use source_handle (real Twitter handle) for correct Nitter URL construction
          url_domain = bot_config.dig(:url, :replace_to)
          nitter_handle = ifttt_data[:source_handle] || ifttt_data[:username]
          twitter_adapter = get_twitter_adapter(nitter_handle, url_domain: url_domain)

          # Fetch single tweet by ID
          post = twitter_adapter.fetch_single_post(ifttt_data[:post_id])

          if post
            # Video detection: combine IFTTT and Nitter signals
            # IFTTT may have text link as first_link_url even when video exists
            # So we trust either source detecting video
            first_link = ifttt_data[:first_link_url]
            ifttt_says_video = first_link && first_link.match?(%r{/video/\d*$})
            nitter_says_video = post.has_video  # From detect_video_from_html
            is_video = ifttt_says_video || nitter_says_video

            if is_video && !ifttt_says_video
              log "Tier 2: Video detected by Nitter (IFTTT first_link was: #{first_link})"
            end

            post.has_video = is_video

            # If Nitter didn't extract quoted_post, use IFTTT's FirstLinkUrl
            # IFTTT reliably provides quote URL in first_link_url
            if post.quoted_post.nil? && first_link && first_link.match?(%r{(?:twitter\.com|x\.com)/\w+/status/\d+$})
              post.is_quote = true
              post.quoted_post = build_quoted_post(first_link)
              log "Tier 2: Set quoted_post from IFTTT first_link_url: #{first_link}"
            end

            # Repost: IFTTT text "RT @original_author: ..." je autoritativní zdroj
            # Nitter může vrátit špatného autora (retweetera, nebo jiného uživatele
            # z RT chainu), proto vždy opravíme autora podle IFTTT dat.
            ifttt_post_type = detect_post_type(ifttt_data[:text], ifttt_data[:first_link_url])
            if ifttt_post_type[:is_repost]
              rt_original_author = ifttt_post_type[:rt_original_author]
              post.is_repost = true
              post.reposted_by = ifttt_data[:source_handle] || ifttt_data[:username]  # Retweeter (kdo retweetnul)

              # Vždy opravit autora na originálního autora z RT @match
              # (Nitter může vrátit kohokoliv z RT chainu jako .username element)
              if rt_original_author && post.author&.username&.downcase != rt_original_author.downcase
                log "Tier 2: Corrected author from @#{post.author&.username} to @#{rt_original_author} (IFTTT RT signal)"
                post.author = Author.new(
                  username: rt_original_author,
                  display_name: rt_original_author,
                  url: "https://x.com/#{rt_original_author}"
                )
              end

              log "Tier 2: Repost by @#{ifttt_data[:username]}, original author: @#{rt_original_author}"
            end

            # Update raw metadata for tier 2
            post.raw = {} unless post.raw.is_a?(Hash)
            if post.raw.is_a?(Hash)
              post.raw[:source] = 'nitter'
              post.raw[:tier] = 2
              post.raw[:ifttt_trigger] = true
              post.raw[:has_video] = is_video
              post.raw[:retry_attempt] = attempt if attempt > 0
            end
            if post.text.nil? || post.text.strip.empty?
              log "Tier 2: ⚠️ Nitter returned HTTP 200 but tweet content is empty for #{ifttt_data[:post_id]} (tweet likely deleted)", level: :warn
            else
              log "Tier 2: Successfully fetched from Nitter#{attempt > 0 ? " (attempt #{attempt + 1})" : ""}", level: :success
            end
            return post
          end

          # Post je nil - Nitter nevrátil data, zkusíme retry
          if attempt < max_retries - 1
            delay = retry_delays[attempt]
            log "Tier 2: Nitter returned nil, retrying in #{delay}s (attempt #{attempt + 1}/#{max_retries})"
            sleep delay
          end

        rescue StandardError => e
          log "Tier 2: Nitter fetch failed: #{e.message}", level: :error

          # Při chybě také zkusíme retry
          if attempt < max_retries - 1
            delay = retry_delays[attempt]
            log "Tier 2: Retrying in #{delay}s (attempt #{attempt + 1}/#{max_retries})"
            sleep delay
          end
        end
      end

      # Po všech pokusech - fallback na Tier 3.5 (Syndication)
      log "Tier 2: All #{max_retries} attempts failed, falling back to Tier 3.5 (Syndication)", level: :warn
      process_tier3_5_fallback(ifttt_data, bot_config)
    end

    # ===========================================
    # Tier 3.5: Syndication Fallback from Tier 2
    # ===========================================
    #
    # When Nitter fails, try Syndication API before falling back to IFTTT.
    # Provides media + potentially truncated text (better than Tier 3).
    #
    # @param ifttt_data [Hash] Parsed IFTTT data
    # @param bot_config [Hash] Bot configuration
    # @return [Post] Processed post
    def process_tier3_5_fallback(ifttt_data, bot_config)
      log "Tier 3.5: Trying Syndication as Nitter fallback for #{ifttt_data[:post_id]}"
      process_syndication_tier(ifttt_data, bot_config,
        tier: 3.5, fallback_method: :process_tier3_fallback,
        raw_extra: { source: 'syndication_fallback', tier: 3.5, nitter_failed: true })
    end

    # ===========================================
    # Tier 3: Final Fallback to IFTTT Data
    # ===========================================

    # Final fallback when both Nitter and Syndication fail.
    # Uses IFTTT data (truncated, no media).
    # Better than nothing - at least we publish something.
    #
    # Applies IFTTT-style ellipsis logic (identical to IFTTT filter):
    # - If text is >= 257 chars (IFTTT truncation threshold)
    # - AND has no natural terminator (.!?…, emoji, URL, hashtag, @mention)
    # - → Add ellipsis to indicate truncation
    #
    # @param ifttt_data [Hash] Parsed IFTTT data
    # @param bot_config [Hash] Bot configuration
    # @return [Post] Processed post with truncation indicator
    def process_tier3_fallback(ifttt_data, bot_config)
      log "Tier 3: Final fallback to IFTTT data for #{ifttt_data[:post_id]}", level: :warn

      # Text is already URL-decoded + HTML entity decoded in WebhookPayloadParser#parse
      post = process_tier1(ifttt_data, bot_config)

      # Remove /photo/X and /video/X URLs from text (they don't work standalone)
      # These are Twitter media URLs that IFTTT includes but are useless in Tier 3
      text = post.text
      text = text.gsub(%r{https?://[^\s]+/(?:photo|video)/\d+}, '').strip
      # Clean up any double spaces left after URL removal
      text = text.gsub(/\s{2,}/, ' ').strip
      post.text = text

      # Apply IFTTT-style ellipsis logic (identical to IFTTT filter)
      # If text is "suspiciously long" and has no natural terminator → add ellipsis
      ellipsis_added = false

      if needs_ellipsis_for_ifttt_fallback?(text)
        log "Tier 3: Adding ellipsis (text >= #{TRUNCATION_THRESHOLD} chars, no natural terminator)"
        post.text = text.rstrip + '…'
        ellipsis_added = true
      end

      # Try to extract media from IFTTT embed_code (best-effort)
      embed_code = ifttt_data[:embed_code]
      if post.media.empty? && embed_code && !embed_code.empty?
        images = embed_code.scan(/src="(https?:\/\/pbs\.twimg\.com\/[^"]+)"/).flatten
        images.each do |img_url|
          post.media << Media.new(type: 'image', url: img_url, alt_text: '')
        end
        log "Tier 3: Extracted #{images.count} images from embed_code" if images.any?
      end

      # Update raw metadata for tier 3
      if post.raw.is_a?(Hash)
        post.raw[:source] = 'ifttt_fallback'
        post.raw[:tier] = 3
        post.raw[:truncated] = true
        post.raw[:force_read_more] = true  # Force 📖➡️ link for degraded data
        post.raw[:ellipsis_added] = ellipsis_added
      end

      post
    end

    # ===========================================
    # Post Type Detection
    # ===========================================

    # Detect post type from IFTTT data
    # @param text [String] Tweet text
    # @param first_link_url [String] First media/link URL
    # @return [Hash] Post type flags
    def detect_post_type(text, first_link_url)
      result = {
        is_repost: false,
        is_reply: false,
        is_quote: false,
        reposted_by: nil,          # Zachováno pro zpětnou kompatibilitu (= rt_original_author)
        rt_original_author: nil,   # Explicitní: originální autor z RT @match
        quoted_url: nil
      }

      # Retweet detection: "RT @username: ..."
      if (rt_match = text.match(/^RT\s+(?:by\s+)?@(\w+):\s*/i))
        result[:is_repost] = true
        result[:reposted_by] = rt_match[1]
        result[:rt_original_author] = rt_match[1]
      end

      # Reply detection: starts with @username or "R to @username:"
      if text.match?(/^@\w+\s/) || text.match?(/^R to @\w+:/i)
        result[:is_reply] = true
      end

      # Quote detection: first_link_url is a Twitter status URL (not /photo/ or /video/)
      if first_link_url && first_link_url.match?(%r{^https?://(?:twitter\.com|x\.com)/\w+/status/\d+$})
        result[:is_quote] = true
        result[:quoted_url] = first_link_url
      end

      result
    end

    # ===========================================
    # Shared Syndication Post Builder (Tier 1.5 / 3.5)
    # ===========================================

    # Build a Post from Syndication API data combined with IFTTT metadata.
    # Shared between Tier 1.5 (primary syndication) and Tier 3.5 (fallback).
    #
    # Processing pipeline:
    # 1. Use syndication text (with IFTTT fallback)
    # 2. Expand t.co links
    # 3. Strip media/nitter URLs from text
    # 4. Detect post type from IFTTT signals
    # 5. Build media array from syndication photos/video
    # 6. Detect truncation + add ellipsis if needed
    # 7. Build Post object with tier-specific raw metadata
    #
    # @param ifttt_data [Hash] Parsed IFTTT data
    # @param syndication [Hash] Syndication API response (success: true)
    # @param tier [Float] Tier number for logging (1.5 or 3.5)
    # @param raw_extra [Hash] Tier-specific raw metadata fields
    # @return [Post] Processed post
    def build_syndication_post(ifttt_data, syndication, tier:, raw_extra:)
      text = syndication[:text] || ifttt_data[:text]
      # Use source_handle (real Twitter handle) for author attribution
      username = ifttt_data[:source_handle] || ifttt_data[:username]
      first_link = ifttt_data[:first_link_url]

      # Expand t.co links
      expanded_text = expand_tco_links(text)

      # Remove expanded media URLs from text (they're attached as images)
      expanded_text = expanded_text.gsub(%r{https?://[^\s]+/(?:photo|video)/\d+}, '')
      expanded_text = expanded_text.gsub(%r{https?://nitter\.[^\s]+/status/\d+}, '')

      # Detect post type from IFTTT data
      post_type = detect_post_type(ifttt_data[:text], first_link)

      # Detect video
      has_video = syndication[:video_thumbnail] ||
                  (first_link && first_link.match?(%r{/video/\d*$}))

      # Build media array
      media = []
      syndication[:photos].each do |photo_url|
        media << Media.new(type: 'image', url: photo_url, alt_text: '')
      end

      if syndication[:video_thumbnail] && media.empty?
        media << Media.new(type: 'image', url: syndication[:video_thumbnail], alt_text: 'Video thumbnail')
      end

      # Remove video URL from text
      if has_video && first_link
        [first_link,
         first_link.gsub('twitter.com', 'x.com'),
         first_link.gsub('x.com', 'twitter.com')].each do |url|
          expanded_text = expanded_text.gsub(url, '').strip
        end
      end

      # Clean text
      final_text = clean_text(expanded_text)

      # Detect truncated text from Syndication API
      # Syndication truncates long tweets (Twitter Blue) at ~280 chars
      truncated = false
      ellipsis_added = false

      if final_text.length >= 270
        ends_with_tco = final_text.match?(/https:\/\/t\.co\/\S+\s*$/)
        has_terminator = has_natural_terminator?(final_text)

        if ends_with_tco || !has_terminator
          truncated = true
          unless has_terminator || final_text.match?(/…\s*$/)
            final_text = final_text.rstrip + '…'
            ellipsis_added = true
            log "Tier #{tier}: Text truncated, adding ellipsis (#{final_text.length} chars)"
          end
        end
      end

      # For retweets: author = original author from RT @match, reposted_by = IFTTT account (retweeter)
      author_username = if post_type[:is_repost] && post_type[:rt_original_author]
        post_type[:rt_original_author]
      else
        username
      end

      # Display name from Syndication API only applies to non-retweet posts
      author_display = if post_type[:is_repost]
        author_username  # No display name available for RT original author
      else
        syndication[:display_name] || username
      end

      # Build Post object
      Post.new(
        id: ifttt_data[:post_id],
        platform: 'twitter',
        url: ifttt_data[:link_to_tweet],
        text: final_text,
        author: Author.new(
          username: author_username,
          display_name: author_display,
          url: "https://x.com/#{author_username}"
        ),
        published_at: syndication[:created_at] ? Time.parse(syndication[:created_at]) : Time.now,
        media: media,
        is_repost: post_type[:is_repost],
        is_reply: post_type[:is_reply],
        is_quote: post_type[:is_quote],
        reposted_by: post_type[:is_repost] ? username : nil,
        quoted_post: build_quoted_post(post_type[:quoted_url]),
        has_video: has_video,
        raw: raw_extra.merge(
          syndication_success: true,
          ifttt_trigger: true,
          photo_count: syndication[:photos].count,
          has_video_thumbnail: !!syndication[:video_thumbnail],
          truncated: truncated,
          force_read_more: truncated,
          ellipsis_added: ellipsis_added
        )
      )
    end

    # ===========================================
    # Helper Methods
    # ===========================================

    # Get or create TwitterAdapter for Nitter fetching
    def get_twitter_adapter(handle, url_domain: nil)
      TwitterAdapter.new(
        handle: handle,
        nitter_instance: nitter_instance,
        url_domain: url_domain
      )
    end

    # Build Author object from username
    def build_author(username)
      Author.new(
        username: username,
        display_name: username, # IFTTT doesn't provide display name
        url: "https://x.com/#{username}"
      )
    end

    # Extract media from IFTTT data
    def extract_media(ifttt_data)
      media = []

      first_url = ifttt_data[:first_link_url]
      if first_url && first_url.match?(%r{/photo/|/video/|pbs\.twimg\.com|video\.twimg\.com})
        media << Media.new(
          type: first_url.include?('video') ? 'video' : 'image',
          url: first_url,
          alt_text: ''
        )
      end

      media
    end

    def clean_text(text)
      FormatHelpers.clean_text(text)
    end

    # Decode IFTTT URL-encoded field + HTML entities
    # @param text [String] Raw IFTTT field (URL-encoded, may contain HTML entities)
    # @return [String] Decoded plain text
    def decode_ifttt_field(text)
      return '' if text.nil? || text.empty?

      text = URI.decode_www_form_component(text)
      HtmlCleaner.decode_html_entities(text)
    end

    # ===========================================
    # t.co URL Expansion
    # ===========================================

    # Expand all t.co links in text to their actual URLs
    # @param text [String] Text containing t.co links
    # @return [String] Text with expanded URLs
    def expand_tco_links(text)
      return text unless text

      text.gsub(%r{https?://t\.co/\S+}) do |tco_url|
        expanded = expand_tco(tco_url)
        expanded || tco_url
      end
    end

    # Expand single t.co URL to actual destination
    # @param tco_url [String] t.co shortened URL
    # @return [String, nil] Expanded URL or nil if failed
    def expand_tco(tco_url)
      return nil unless tco_url&.match?(%r{https?://t\.co/})

      response = HttpClient.head(tco_url, open_timeout: 3, read_timeout: 3)

      case response
      when Net::HTTPRedirection
        PunycodeDecoder.decode_url(response['location'])
      else
        nil
      end
    rescue StandardError => e
      log "t.co expansion failed for #{tco_url}: #{e.message}", level: :warn
      nil
    end

    # ===========================================
    # IFTTT Ellipsis Logic (Tier 3)
    # ===========================================

    # Check if text needs ellipsis added for IFTTT fallback
    # Identical logic to IFTTT filter's Twitter-specific ellipsis handling
    #
    # Logic (from IFTTT filter lines 731-748):
    # - threshold = min(257, POST_LENGTH - 30) ≈ 257
    # - If text.length >= threshold AND text.length <= POST_LENGTH
    # - AND !hasTerminator (no .!?…, emoji, URL, hashtag, @mention)
    # - → Add ellipsis
    #
    # @param text [String] Tweet text
    # @return [Boolean] true if ellipsis should be added
    def needs_ellipsis_for_ifttt_fallback?(text)
      return false if text.nil? || text.empty?

      # Only apply to "suspiciously long" text (near IFTTT truncation limit)
      return false if text.length < TRUNCATION_THRESHOLD

      # If text already has ellipsis, don't add another
      return false if text.match?(/…\s*$/)

      # Check for natural terminators
      !has_natural_terminator?(text)
    end

    # Check if text ends with a natural terminator
    # Identical patterns to IFTTT filter's hasTerminator check:
    # - URL_TERMINATOR: URL, #hashtag, @mention
    # - EMOJI check
    # - TERMINATOR_CHECK: .!?…
    #
    # @param text [String] Text to check
    # @return [Boolean] true if text has natural ending
    def has_natural_terminator?(text)
      return false if text.nil? || text.empty?

      # Remove trailing t.co placeholder if present (same as IFTTT filter)
      # This ensures we check the actual content, not a trailing link
      text_for_check = text.gsub(/\s*https?:\/\/t\.co\/\S+\s*\z/, '').rstrip

      TERMINATOR_PATTERNS.any? { |_type, pattern| text_for_check.match?(pattern) }
    end

  end
end
