# frozen_string_literal: true

module Adapters
  module Twitter
    # Tier decision logic for TwitterNitterAdapter.
    # Determines whether a tweet should be processed via Tier 1 (direct IFTTT)
    # or Tier 2 (Nitter fetch), based on text length, post type, and media signals.
    #
    # Included as instance methods in TwitterNitterAdapter.
    module TierDecision
      # Twitter's practical character limit where IFTTT starts truncating
      TRUNCATION_THRESHOLD = 257

      # Patterns for detecting truncated content
      TRUNCATION_PATTERNS = {
        ellipsis_text: /…|\.{3}/,
        ellipsis_url:  /https?:\/\/[^\s]*…/,
        truncated_tco: /https?:\/\/t\.co\/\w*…/
      }.freeze

      # Determine which processing tier to use.
      # @param ifttt_data [Hash] Parsed IFTTT data
      # @return [Integer] 1 or 2
      def determine_tier(ifttt_data)
        text      = ifttt_data[:text]
        first_link = ifttt_data[:first_link_url]
        embed_code = ifttt_data[:embed_code]
        # Use source_handle (from bot_config) if available; fall back to payload username.
        # This ensures correct self-reply detection when IFTTT uses a brand name (e.g. "drozd")
        # instead of the real Twitter handle (e.g. "mzvcr").
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

        # Heuristic: Multiple t.co URLs with non-media first_link → likely has image.
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

        # Poll heuristic: text ending with ? and no media → likely poll → Tier 2
        # Nitter HTML will contain div.poll if it's a poll tweet.
        # False positives (normal questions without media) get Nitter treatment —
        # harmless, they just get full-text enrichment as a bonus.
        if text&.strip&.end_with?('?') && first_link.to_s.empty?
          log "Text ends with '?' and no media → Tier 2 (possible poll)"
          return 2
        end

        # Tier 1: Full text available from IFTTT
        1
      end

      # Check if embed_code contains Twitter media images.
      # IFTTT's embed_code includes the tweet HTML which contains image URLs
      # even when first_link_url points to a text link instead of /photo/.
      #
      # @param embed_code [String] IFTTT TweetEmbedCode field
      # @return [Boolean] true if images detected
      def has_image_in_embed?(embed_code)
        if embed_code.nil? || embed_code.empty?
          log "embed_code is empty or nil"
          return false
        end

        has_pbs        = embed_code.include?('pbs.twimg.com/media')
        has_pic        = embed_code.match?(/pic\.twitter\.com/i)
        has_video_thumb = embed_code.include?('pbs.twimg.com/ext_tw_video_thumb') ||
                          embed_code.include?('video.twimg.com')

        log "embed_code check: length=#{embed_code.length}, pbs.twimg=#{has_pbs}, pic.twitter=#{has_pic}, video_thumb=#{has_video_thumb}"

        has_pbs || has_pic || has_video_thumb
      end

      # Detect self-reply (thread continuation).
      # @param text [String] Tweet text
      # @param username [String] Author's username
      # @return [Boolean] true if tweet is a reply to own tweet
      def is_self_reply?(text, username)
        return false if text.nil? || username.nil?

        normalized = username.to_s.gsub(/^@/, '').downcase
        text.match?(/^@#{Regexp.escape(normalized)}\b/i)
      end

      # Detect if tweet text is likely truncated by IFTTT.
      # Based on IFTTT filter logic from example-ifttt-filter-x-xcancel-4_0_0.ts
      #
      # @param text [String] Tweet text from IFTTT
      # @return [Boolean] true if likely truncated
      def likely_truncated?(text)
        return false if text.nil? || text.empty?

        # 1. Explicit ellipsis in text (definitive truncation)
        return true if text.match?(TRUNCATION_PATTERNS[:ellipsis_text])

        # 2. Truncated URL
        return true if text.match?(TRUNCATION_PATTERNS[:ellipsis_url])
        return true if text.match?(TRUNCATION_PATTERNS[:truncated_tco])

        # 3. Heuristic: >= 257 chars without natural terminator
        if text.length >= TRUNCATION_THRESHOLD
          # Remove trailing t.co link before checking terminator
          text_for_check = text.gsub(/\s*https?:\/\/t\.co\/\S+\s*\z/, '').rstrip

          ends_with_punctuation = text_for_check.match?(/[.!?。！？]\s*\z/)
          ends_with_emoji       = text_for_check.match?(/\p{Emoji}\s*\z/)
          ends_with_hashtag     = text_for_check.match?(/#\w+\s*\z/)

          # Digit ending (no punctuation) → truncated mid-sentence
          ends_with_bare_digit = text_for_check.match?(/\d\s*\z/) && !ends_with_punctuation

          # Czech preposition/conjunction at end → definitely truncated
          ends_with_preposition = text_for_check.match?(/\s(a|i|k|o|s|u|v|z|na|do|od|po|za|ze|ke|ve|se|proti|pro|při|pod|nad|před|přes|mezi|mimo|bez|kvůli|podle|vůči|během|ani|aby|ale|než|jen|jak|což|nebo|jako|tedy|když|že)\s*\z/i)

          has_terminator = ends_with_punctuation || ends_with_emoji || ends_with_hashtag

          return true if ends_with_bare_digit
          return true if ends_with_preposition
          return true unless has_terminator
        end

        false
      end
    end
  end
end
