# frozen_string_literal: true

# Bluesky Formatter - Delegating to UniversalFormatter
# =====================================================
#
# Wrapper který zachovává stávající API (format(post)) ale interně
# používá UniversalFormatter pro konzistentní formátování.

require_relative 'universal_formatter'
require_relative '../utils/hash_helpers'

module Formatters
  class BlueskyFormatter
    # Backwards-compatible DEFAULTS
    DEFAULTS = {
      prefix_repost: '🦋🔁',
      prefix_quote: '🦋💬',
      prefix_thread: '🧵',
      prefix_video: '🎬',
      prefix_post_url: "\n",
      prefix_self_reference: 'svůj post',
      language: 'cs',
      self_reference_texts: {
        'cs' => 'svůj post',
        'sk' => 'vlastný príspevok',
        'en' => 'own post'
      },
      mentions: {
        type: 'none',
        value: ''
      },
      url_domain: nil,  # Bluesky URLs zůstávají
      rewrite_domains: [],
      max_length: 500,
      source_name: nil,
      # Bluesky specific
      url_domain_fixes: [],
      move_url_to_end: false
    }.freeze

    def initialize(options = {})
      @options = DEFAULTS.merge(HashHelpers.symbolize_keys(options))
      @universal = UniversalFormatter.new(build_universal_config)
    end

    # Main entry point
    # @param post [Post] Post object from BlueskyAdapter
    # @return [String] Formatted status text
    def format(post)
      @universal.format(post, runtime_config(post))
    end

    private

    def build_universal_config
      {
        platform: :bluesky,
        source_name: @options[:source_name],
        prefix_repost: @options[:prefix_repost],
        prefix_quote: @options[:prefix_quote],
        prefix_thread: @options[:prefix_thread],
        prefix_video: @options[:prefix_video],
        prefix_post_url: @options[:prefix_post_url],
        prefix_self_reference: @options[:prefix_self_reference],
        language: @options[:language],
        self_reference_texts: @options[:self_reference_texts],
        mentions: @options[:mentions],
        url_domain: @options[:url_domain],
        rewrite_domains: @options[:rewrite_domains],
        max_length: @options[:max_length],
        move_url_to_end: @options[:move_url_to_end],
        thread_handling: @options[:thread_handling] || { show_indicator: true },
        show_author_header: @options[:show_author_header],
        platform_emoji: @options[:platform_emoji]
      }
    end

    def runtime_config(post)
      {
        source_name: @options[:source_name]
      }
    end
  end
end
