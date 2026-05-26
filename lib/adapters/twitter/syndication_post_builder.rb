# frozen_string_literal: true

module Adapters
  module Twitter
    # Builds Post objects from Syndication API responses (Tiers 1.5 and 3.5).
    # Also contains shared post helpers: detect_post_type, build_author, etc.
    #
    # Included as instance methods in TwitterNitterAdapter.
    #
    # Truncation indication (appending `…` for cut-off bodies) is handled downstream
    # by PostProcessor#mark_source_truncation — see lib/utils/truncation_detector.rb.
    module SyndicationPostBuilder
      # Build a Post from Syndication API data combined with IFTTT metadata.
      # Shared between Tier 1.5 (primary syndication) and Tier 3.5 (fallback).
      #
      # @param ifttt_data [Hash] Parsed IFTTT data
      # @param syndication [Hash] Syndication API response (success: true)
      # @param tier [Float] Tier number for logging (1.5 or 3.5)
      # @param raw_extra [Hash] Tier-specific raw metadata fields
      # @return [Post] Processed post
      def build_syndication_post(ifttt_data, syndication, tier:, raw_extra:)
        text       = syndication[:text] || ifttt_data[:text]
        username   = ifttt_data[:source_handle] || ifttt_data[:username]
        first_link = ifttt_data[:first_link_url]

        # Expand t.co links
        expanded_text = expand_tco_links(text)

        # Remove expanded media URLs from text (they're attached as media objects)
        expanded_text = expanded_text.gsub(%r{https?://[^\s]+/(?:photo|video)/\d+}, '')
        expanded_text = expanded_text.gsub(%r{https?://[^\s]+/status/\d+[^\s]*}, '')

        post_type = detect_post_type(ifttt_data[:text], first_link)

        has_video = syndication[:video_url] || syndication[:video_thumbnail] ||
                    (first_link && first_link.match?(%r{/video/\d*$}))

        # Build media array
        media = []
        syndication[:photos].each { |url| media << Media.new(type: 'image', url: url, alt_text: '') }

        if syndication[:video_url]
          alt = (syndication[:text] || ifttt_data[:text]).to_s.strip
          media << Media.new(type: 'video', url: syndication[:video_url], alt_text: alt)
        elsif syndication[:video_thumbnail] && media.empty?
          alt = (syndication[:text] || ifttt_data[:text]).to_s.strip
          media << Media.new(type: 'image', url: syndication[:video_thumbnail], alt_text: alt)
        end

        # Remove video URL from text
        if has_video && first_link
          [first_link,
           first_link.gsub('twitter.com', 'x.com'),
           first_link.gsub('x.com', 'twitter.com')].each do |url|
            expanded_text = expanded_text.gsub(url, '').strip
          end
        end

        final_text = clean_text(expanded_text)

        # Truncation detection + `…` are applied downstream in
        # PostProcessor#mark_source_truncation so all tiers share one heuristic.

        # For retweets: author = original author from RT @match
        author_username = if post_type[:is_repost] && post_type[:rt_original_author]
                            post_type[:rt_original_author]
                          else
                            username
                          end

        # Display name from Syndication API only applies to non-retweet posts
        author_display = if post_type[:is_repost]
                           author_username
                         else
                           syndication[:display_name] || username
                         end

        Post.new(
          id:           ifttt_data[:post_id],
          platform:     'twitter',
          url:          ifttt_data[:link_to_tweet],
          text:         final_text,
          author:       Author.new(
            username:     author_username,
            display_name: author_display,
            url:          "https://x.com/#{author_username}"
          ),
          published_at: syndication[:created_at] ? Time.parse(syndication[:created_at]) : Time.now,
          media:        media,
          is_repost:    post_type[:is_repost],
          is_reply:     post_type[:is_reply],
          is_quote:     post_type[:is_quote],
          reposted_by:  post_type[:is_repost] ? username : nil,
          quoted_post:  build_quoted_post(post_type[:quoted_url]),
          has_video:    has_video,
          poll_data:    syndication[:poll_data],
          raw:          raw_extra.merge(
            syndication_success:   true,
            ifttt_trigger:         true,
            photo_count:           syndication[:photos].count,
            has_video_thumbnail:   !!syndication[:video_thumbnail],
            video_thumbnail_url:   syndication[:video_thumbnail]
          )
        )
      end

      # Detect post type from IFTTT data.
      # @param text [String] Tweet text
      # @param first_link_url [String] First media/link URL
      # @return [Hash] Post type flags
      def detect_post_type(text, first_link_url)
        result = {
          is_repost:          false,
          is_reply:           false,
          is_quote:           false,
          reposted_by:        nil,
          rt_original_author: nil,
          quoted_url:         nil
        }

        # Retweet detection: "RT @username: ..."
        if (rt_match = text.match(/^RT\s+(?:by\s+)?@(\w+):\s*/i))
          result[:is_repost]          = true
          result[:reposted_by]        = rt_match[1]
          result[:rt_original_author] = rt_match[1]
        end

        # Reply detection: starts with @username or "R to @username:"
        result[:is_reply] = true if text.match?(/^@\w+\s/) || text.match?(/^R to @\w+:/i)

        # Quote detection: first_link_url is a Twitter status URL (not /photo/ or /video/)
        if first_link_url&.match?(%r{^https?://(?:twitter\.com|x\.com)/\w+/status/\d+$})
          result[:is_quote]    = true
          result[:quoted_url]  = first_link_url
        end

        result
      end

      # Build Author object from username.
      def build_author(username)
        Author.new(
          username:     username,
          display_name: username,
          url:          "https://x.com/#{username}"
        )
      end

      # Build quoted_post hash with author extracted from URL.
      # @param url [String] Quote tweet URL
      # @return [Hash, nil]
      def build_quoted_post(url)
        return nil unless url

        { url: url, author: extract_author_from_url(url) }
      end

      # Extract author username from Twitter/X URL.
      # @param url [String] URL like https://twitter.com/Username/status/123
      # @return [String] Username or "unknown"
      def extract_author_from_url(url)
        return 'unknown' unless url

        match = url.match(%r{(?:twitter\.com|x\.com)/(\w+)/status/})
        match ? match[1] : 'unknown'
      end
    end
  end
end
