# frozen_string_literal: true

module Adapters
  module Twitter
    # Nitter fetch with exponential-backoff retry for Tier 2.
    # Returns a Post on success or nil on total failure.
    #
    # Included as instance methods in TwitterNitterAdapter.
    module NitterFetcher
      NITTER_MAX_RETRIES  = 3
      NITTER_RETRY_DELAYS = [1, 2, 4].freeze

      # Fetch a single tweet from Nitter with retry.
      # On success, enriches the post with IFTTT signals (video, quote, repost).
      #
      # @param ifttt_data [Hash] Parsed IFTTT data
      # @param bot_config [Hash] Bot configuration
      # @return [Post, nil] Enriched post, or nil if all attempts failed
      def fetch_tweet_from_nitter(ifttt_data, bot_config)
        return nil unless use_nitter_fallback && nitter_instance

        url_domain     = bot_config.dig(:url, :replace_to)
        nitter_handle  = ifttt_data[:source_handle] || ifttt_data[:username]
        twitter_adapter = get_twitter_adapter(nitter_handle, url_domain: url_domain)
        first_link     = ifttt_data[:first_link_url]

        NITTER_MAX_RETRIES.times do |attempt|
          begin
            post = twitter_adapter.fetch_single_post(ifttt_data[:post_id])

            if post
              enrich_tier2_post!(post, ifttt_data, first_link, attempt)
              return post
            end

            # Nitter returned nil — retry if attempts remain
            if attempt < NITTER_MAX_RETRIES - 1
              delay = NITTER_RETRY_DELAYS[attempt]
              log "Tier 2: Nitter returned nil, retrying in #{delay}s (attempt #{attempt + 1}/#{NITTER_MAX_RETRIES})"
              sleep delay
            end

          rescue StandardError => e
            log "Tier 2: Nitter fetch failed: #{e.message}", level: :error

            if attempt < NITTER_MAX_RETRIES - 1
              delay = NITTER_RETRY_DELAYS[attempt]
              log "Tier 2: Retrying in #{delay}s (attempt #{attempt + 1}/#{NITTER_MAX_RETRIES})"
              sleep delay
            end
          end
        end

        nil
      end

      private

      # Apply IFTTT-sourced corrections and enrichments to a Nitter-fetched post.
      #
      # 1. Video: trust IFTTT or Nitter (either signal wins)
      # 2. Quote: if Nitter missed it, use IFTTT's first_link_url
      # 3. Repost: always override author from IFTTT's "RT @" pattern (Nitter unreliable)
      # 4. Raw metadata: source = 'nitter', tier = 2
      def enrich_tier2_post!(post, ifttt_data, first_link, attempt)
        # --- Video detection ---
        ifttt_says_video = first_link && first_link.match?(%r{/video/\d*$})
        nitter_says_video = post.has_video
        is_video = ifttt_says_video || nitter_says_video

        if is_video && !ifttt_says_video
          log "Tier 2: Video detected by Nitter (IFTTT first_link was: #{first_link})"
        end
        post.has_video = is_video

        # --- Quote detection fallback ---
        if post.quoted_post.nil? && first_link&.match?(%r{(?:twitter\.com|x\.com)/\w+/status/\d+$})
          post.is_quote   = true
          post.quoted_post = build_quoted_post(first_link)
          log "Tier 2: Set quoted_post from IFTTT first_link_url: #{first_link}"
        end

        # --- Repost author correction ---
        # IFTTT text "RT @original_author: ..." is authoritative.
        # Nitter may return the wrong author (retweeter or someone from the RT chain).
        ifttt_post_type = detect_post_type(ifttt_data[:text], ifttt_data[:first_link_url])
        if ifttt_post_type[:is_repost]
          rt_original_author = ifttt_post_type[:rt_original_author]
          post.is_repost  = true
          post.reposted_by = ifttt_data[:source_handle] || ifttt_data[:username]

          if rt_original_author && post.author&.username&.downcase != rt_original_author.downcase
            log "Tier 2: Corrected author from @#{post.author&.username} to @#{rt_original_author} (IFTTT RT signal)"
            post.author = Author.new(
              username:     rt_original_author,
              display_name: rt_original_author,
              url:          "https://x.com/#{rt_original_author}"
            )
          end

          log "Tier 2: Repost by @#{ifttt_data[:username]}, original author: @#{rt_original_author}"
        end

        # --- Raw metadata ---
        post.raw = {} unless post.raw.is_a?(Hash)
        post.raw.merge!(
          source:        'nitter',
          tier:          2,
          ifttt_trigger: true,
          has_video:     is_video
        )
        post.raw[:retry_attempt] = attempt if attempt > 0

        if post.text.nil? || post.text.strip.empty?
          log "Tier 2: ⚠️ Nitter returned HTTP 200 but tweet content is empty for #{ifttt_data[:post_id]} (tweet likely deleted)", level: :warn
        else
          log "Tier 2: Successfully fetched from Nitter#{attempt > 0 ? " (attempt #{attempt + 1})" : ""}", level: :success
        end
      end
    end
  end
end
