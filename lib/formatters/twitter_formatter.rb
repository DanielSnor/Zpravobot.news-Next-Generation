# frozen_string_literal: true

# Twitter Formatter - Delegating to UniversalFormatter
# =====================================================
#
# Wrapper který zachovává stávající API (format(post)) ale interně
# používá UniversalFormatter pro konzistentní formátování.
#
# Toto je přechodná verze pro bezpečnou migraci.
# Po ověření funkčnosti lze nahradit přímým použitím UniversalFormatter.
#

require_relative 'universal_formatter'
require_relative '../utils/hash_helpers'

module Formatters
  class TwitterFormatter
    # Backwards-compatible DEFAULTS pro existující kód
    DEFAULTS = {
      prefix_repost: '𝕏🔁',
      prefix_quote: '𝕏💬',
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
      # :mentions záměrně chybí — UniversalFormatter PLATFORM_DEFAULTS[:twitter] definuje výchozí hodnotu
      url_domain: Formatters::TWITTER_URL_DOMAIN,
      rewrite_domains: Formatters::TWITTER_REWRITE_DOMAINS,
      max_length: 500,
      source_name: nil
    }.freeze

    def initialize(options = {})
      @options = DEFAULTS.merge(HashHelpers.symbolize_keys(options))
      
      # Build config for UniversalFormatter
      @universal = UniversalFormatter.new(build_universal_config)
      
      # Log pro debugging (lze odstranit po ověření)
      # puts "[TwitterFormatter] Delegating to UniversalFormatter"
    end

    # Main entry point - backwards compatible
    # @param post [Post] Post object from TwitterAdapter
    # @return [String] Formatted status text
    def format(post)
      @universal.format(post, runtime_config(post))
    end

    private

    def build_universal_config
      config = {
        platform: :twitter,
        source_name: @options[:source_name],
        prefix_repost: @options[:prefix_repost],
        prefix_quote: @options[:prefix_quote],
        prefix_thread: @options[:prefix_thread],
        prefix_video: @options[:prefix_video],
        prefix_post_url: @options[:prefix_post_url],
        prefix_self_reference: @options[:prefix_self_reference],
        language: @options[:language],
        self_reference_texts: @options[:self_reference_texts],
        url_domain: @options[:url_domain],
        rewrite_domains: @options[:rewrite_domains],
        max_length: @options[:max_length],
        thread_handling: @options[:thread_handling] || { show_indicator: true }
      }
      # Předáme :mentions pouze pokud bylo explicitně zadáno; jinak necháme
      # UniversalFormatter použít PLATFORM_DEFAULTS[:twitter][:mentions].
      config[:mentions] = @options[:mentions] if @options.key?(:mentions)
      config
    end

    # Runtime config that may vary per-post
    def runtime_config(post)
      {
        # Source name může být override per-post pokud je v options
        source_name: @options[:source_name]
      }
    end
  end
end
