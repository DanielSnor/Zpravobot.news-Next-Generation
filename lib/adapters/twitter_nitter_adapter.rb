# frozen_string_literal: true

# Twitter Nitter Adapter for Zpravobot Next Generation
#
# Hybridní architektura kombinující spolehlivost IFTTT s kvalitou Nitter dat.
# Tier chain (explicit fallback order):
#
# TIER 1   — přímá publikace z IFTTT dat (plný text, žádná média)
# TIER 1.5 — IFTTT + Syndication API (text + média, JSON — bez Nitteru)
# TIER 2   — IFTTT trigger + Nitter fetch (plný text + média)
# TIER 3.5 — Syndication fallback (Nitter selhal → zkusíme Syndication)
# TIER 3   — final fallback na IFTTT data (zkrácený text, best-effort)
#
# Tier chain pro nitter_enabled=true:
#   determine_tier==1 → [Tier1]
#   determine_tier==2 → [Tier2, Tier3.5, Tier3]
#
# Tier chain pro nitter_enabled=false:
#   [Tier1.5, Tier1]

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
require_relative '../utils/tco_expander'
require_relative 'twitter/tier_decision'
require_relative 'twitter/syndication_post_builder'
require_relative 'twitter/nitter_fetcher'

module Adapters
  class TwitterNitterAdapter < BaseAdapter
    include Twitter::TierDecision
    include Twitter::SyndicationPostBuilder
    include Twitter::NitterFetcher

    attr_reader :nitter_instance, :use_nitter_fallback

    def initialize(nitter_instance: nil, use_nitter_fallback: true)
      @nitter_instance     = nitter_instance || ENV['NITTER_INSTANCE']
      @use_nitter_fallback = use_nitter_fallback
    end

    # ============================================================
    # Main Entry Point
    # ============================================================

    # Process incoming IFTTT webhook payload through the tier chain.
    # @param payload [Hash] IFTTT webhook data
    # @param bot_config [Hash] Bot configuration from YAML
    # @param force_tier2 [Boolean] Force Tier 2 processing (thread batch detection)
    # @return [Post, nil] Processed post or nil if payload invalid
    def process_webhook(payload, bot_config, force_tier2: false)
      ifttt_data = parse_ifttt_payload(payload)
      return nil unless ifttt_data

      # Inject source_handle from bot_config.
      # Allows IFTTT applets to use a brand name ("drozd", "vystrahy") while still
      # fetching from Nitter using the real Twitter handle.
      if (source_handle = bot_config.dig(:source, :handle))
        ifttt_data[:source_handle] = source_handle
      end

      nitter_enabled = bot_config.dig(:nitter_processing, :enabled) != false

      if !nitter_enabled
        log "Nitter processing disabled → Tier 1.5 → Tier 1"
        log "Processing tweet #{ifttt_data[:post_id]} via Tier 1.5"
        return process_tier1_5(ifttt_data, bot_config) ||
               process_tier1(ifttt_data, bot_config)
      end

      tier = force_tier2 ? (log("Forced Tier 2"); 2) : determine_tier(ifttt_data)
      log "Processing tweet #{ifttt_data[:post_id]} via Tier #{tier}"

      case tier
      when 1
        process_tier1(ifttt_data, bot_config)
      when 2
        process_tier2(ifttt_data, bot_config) ||
          process_tier3_5_fallback(ifttt_data, bot_config) ||
          process_tier3_fallback(ifttt_data, bot_config)
      else
        log "Unknown tier: #{tier}", level: :error
        nil
      end
    end

    # ============================================================
    # IFTTT Payload Parsing
    # ============================================================

    # Parse and normalize IFTTT webhook payload.
    # @param payload [Hash] Raw webhook payload
    # @return [Hash, nil] Normalized data or nil if invalid
    def parse_ifttt_payload(payload)
      return nil unless payload.is_a?(Hash)

      link_to_tweet = payload['link_to_tweet'] || payload['LinkToTweet'] || ''
      post_id = extract_post_id(link_to_tweet)
      return nil unless post_id

      text       = decode_ifttt_field(payload['text']       || payload['Text']           || '')
      embed_code = decode_ifttt_field(payload['embed_code'] || payload['TweetEmbedCode'] || '')

      {
        post_id:        post_id,
        text:           text,
        embed_code:     embed_code,
        link_to_tweet:  link_to_tweet,
        first_link_url: payload['first_link_url'] || payload['FirstLinkUrl'] || '',
        username:       payload['username'] || payload['UserName'] || '',
        bot_id:         payload['bot_id'] || payload['bot'] || nil,
        received_at:    Time.now
      }
    end

    # Extract post ID from Twitter/X URL.
    def extract_post_id(url)
      return nil unless url.is_a?(String)

      match = url.match(%r{(?:twitter\.com|x\.com)/\w+/status/(\d+)})
      match ? match[1] : nil
    end

    # ============================================================
    # Tier 1: Direct IFTTT Processing
    # ============================================================

    def process_tier1(ifttt_data, bot_config)
      log "Tier 1: Direct processing for #{ifttt_data[:post_id]}"

      text       = ifttt_data[:text]
      username   = ifttt_data[:source_handle] || ifttt_data[:username]
      first_link = ifttt_data[:first_link_url]

      expanded_text = expand_tco_links(text)
      post_type     = detect_post_type(text, first_link)
      has_video     = first_link && first_link.match?(%r{/video/\d*$})

      # Remove video URL from text
      if has_video && first_link
        [first_link,
         first_link.gsub('twitter.com', 'x.com'),
         first_link.gsub('x.com', 'twitter.com')].each do |url|
          expanded_text = expanded_text.gsub(url, '').strip
        end
      end

      author_username = post_type[:is_repost] && post_type[:rt_original_author] ?
        post_type[:rt_original_author] : username

      Post.new(
        id:           ifttt_data[:post_id],
        platform:     'twitter',
        url:          ifttt_data[:link_to_tweet],
        text:         clean_text(expanded_text),
        author:       build_author(author_username),
        published_at: Time.now,
        media:        [],
        is_repost:    post_type[:is_repost],
        is_reply:     post_type[:is_reply],
        is_quote:     post_type[:is_quote],
        reposted_by:  post_type[:is_repost] ? username : nil,
        quoted_post:  build_quoted_post(post_type[:quoted_url]),
        has_video:    has_video,
        raw: {
          source:            'ifttt',
          tier:              1,
          original_username: username,
          tco_expanded:      (expanded_text != text),
          has_video:         has_video
        }
      )
    end

    # ============================================================
    # Tier 1.5: IFTTT + Syndication API
    # ============================================================

    # Try Syndication API for this post. Returns nil if Syndication fails.
    def process_tier1_5(ifttt_data, bot_config)
      process_syndication_tier(ifttt_data, bot_config,
        tier: 1.5,
        raw_extra: { source: 'syndication', tier: 1.5, ifttt_trigger: true })
    end

    # ============================================================
    # Tier 2: IFTTT Trigger + Nitter Fetch
    # ============================================================

    # Fetch tweet from Nitter. Returns nil on total failure (chain continues to 3.5 → 3).
    def process_tier2(ifttt_data, bot_config)
      log "Tier 2: Nitter fetch for #{ifttt_data[:post_id]}"
      fetch_tweet_from_nitter(ifttt_data, bot_config)
    rescue StandardError => e
      log "Tier 2: Unexpected error: #{e.message}", level: :error
      nil
    end

    # ============================================================
    # Tier 3.5: Syndication Fallback
    # ============================================================

    # Try Syndication API as Nitter fallback. Returns nil if Syndication fails.
    def process_tier3_5_fallback(ifttt_data, bot_config)
      log "Tier 3.5: Trying Syndication as Nitter fallback for #{ifttt_data[:post_id]}"
      process_syndication_tier(ifttt_data, bot_config,
        tier: 3.5,
        raw_extra: { source: 'syndication_fallback', tier: 3.5, nitter_failed: true })
    end

    # ============================================================
    # Tier 3: Final Fallback
    # ============================================================

    # Final fallback when both Nitter and Syndication fail.
    # Uses IFTTT data (truncated, no media). Always returns a Post.
    def process_tier3_fallback(ifttt_data, bot_config)
      log "Tier 3: Final fallback to IFTTT data for #{ifttt_data[:post_id]}", level: :warn

      post = process_tier1(ifttt_data, bot_config)

      # Remove /photo/X and /video/X URLs from text (useless without media context)
      text = post.text
                 .gsub(%r{https?://[^\s]+/(?:photo|video)/\d+}, '')
                 .gsub(/\s{2,}/, ' ')
                 .strip
      post.text = text

      # Best-effort media from IFTTT embed_code
      embed_code = ifttt_data[:embed_code]
      if post.media.empty? && embed_code && !embed_code.empty?
        images = embed_code.scan(/src="(https?:\/\/pbs\.twimg\.com\/[^"]+)"/).flatten
        images.each { |url| post.media << Media.new(type: 'image', url: url, alt_text: '') }
        log "Tier 3: Extracted #{images.count} images from embed_code" if images.any?
      end

      # Tier 3 data is unconditionally incomplete (we're here only because both Nitter
      # and Syndication failed). force_read_more makes the formatter append the read-more
      # URL; the ellipsis itself is added downstream by PostProcessor#mark_source_truncation.
      post.raw = {} unless post.raw.is_a?(Hash)
      post.raw.merge!(
        source:          'ifttt_fallback',
        tier:            3,
        truncated:       true,
        force_read_more: true
      )

      post
    end

    private

    # ============================================================
    # Shared Syndication Tier Helper
    # ============================================================

    # Try Syndication API. Returns Post on success, nil on failure.
    # Used by both process_tier1_5 and process_tier3_5_fallback.
    def process_syndication_tier(ifttt_data, bot_config, tier:, raw_extra:)
      log "Tier #{tier}: Syndication fetch for #{ifttt_data[:post_id]}"

      syndication = Services::SyndicationMediaFetcher.fetch(ifttt_data[:post_id])

      unless syndication[:success]
        log "Tier #{tier} failed (#{syndication[:error]}) → nil (chain continues)", level: :warn
        return nil
      end

      log "Tier #{tier} success: #{syndication[:photos].count} photos, " \
          "video_thumbnail: #{syndication[:video_thumbnail] ? 'yes' : 'no'}, " \
          "video_url: #{syndication[:video_url] ? 'yes' : 'no'}"

      build_syndication_post(ifttt_data, syndication, tier: tier, raw_extra: raw_extra)
    end

    # ============================================================
    # Post Type Detection (delegate to SyndicationPostBuilder)
    # ============================================================
    # detect_post_type, build_author, build_quoted_post, extract_author_from_url
    # are mixed in from Twitter::SyndicationPostBuilder.

    # ============================================================
    # Helper Methods
    # ============================================================

    # Get or create TwitterAdapter for Nitter fetching.
    def get_twitter_adapter(handle, url_domain: nil)
      TwitterAdapter.new(
        handle:          handle,
        nitter_instance: nitter_instance,
        url_domain:      url_domain
      )
    end

    # Extract media from IFTTT data (best-effort).
    def extract_media(ifttt_data)
      media      = []
      first_url  = ifttt_data[:first_link_url]

      if first_url&.match?(%r{/photo/|/video/|pbs\.twimg\.com|video\.twimg\.com})
        media << Media.new(
          type:     first_url.include?('video') ? 'video' : 'image',
          url:      first_url,
          alt_text: ''
        )
      end

      media
    end

    def clean_text(text)
      FormatHelpers.clean_text(text)
    end

    # Decode IFTTT URL-encoded field + HTML entities.
    def decode_ifttt_field(text)
      return '' if text.nil? || text.empty?

      HtmlCleaner.decode_html_entities(URI.decode_www_form_component(text))
    end

    # Expand all t.co links in text to their actual URLs.
    def expand_tco_links(text)
      Utils::TcoExpander.expand(text) do |tco_url, e|
        log "t.co expansion failed for #{tco_url}: #{e.message}", level: :warn
      end
    end
  end
end
