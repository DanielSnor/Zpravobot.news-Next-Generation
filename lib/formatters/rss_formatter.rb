# frozen_string_literal: true

# RSS Formatter - Delegating to UniversalFormatter
# =================================================
#
# Wrapper který zachovává stávající API ale interně používá UniversalFormatter.
# Zachovává RSS-specific funkce jako Facebook/Instagram/Threads processing
# a rss_source_type.
#
# Sociální feedy z RSS.app (rss_source_type: facebook|instagram|threads)
# procházejí dedikovaným pre-procesorem (Processors::FacebookProcessor /
# InstagramProcessor / ThreadsProcessor) ještě před delegací na
# UniversalFormatter. Mapping rss_source_type → procesor je v PROCESSORS_BY_SOURCE_TYPE
# (přidání Threads = jeden řádek + odpovídající Processors::ThreadsProcessor).
#

require_relative 'universal_formatter'
require_relative '../utils/hash_helpers'
require_relative '../models/post_text_wrapper'
require_relative '../processors/instagram_processor'
require_relative '../processors/facebook_processor'
require_relative '../processors/threads_processor'

module Formatters
  class RssFormatter
    # Backwards-compatible DEFAULTS
    DEFAULT_CONFIG = {
      # Content composition (IFTTT-compatible)
      show_title_as_content: false,
      combine_title_and_content: false,
      title_separator: ' — ',

      # URL handling
      move_url_to_end: true,
      prefix_post_url: "\n\n",

      # Length limits
      max_length: 500,

      # Optional source name
      source_name: nil,

      # RSS source type for mention formatting
      rss_source_type: 'rss',

      # Mentions config (set dynamically based on rss_source_type)
      mentions: {
        type: 'none',
        value: ''
      }
    }.freeze

    # Mention prefixes for different RSS source types.
    # Pinned: tato tabulka má vždy přednost před :mentions zděděným z platformového
    # overlaye (platforms/{rss_source_type}.yml), aby zůstal jednotný formát zmínek
    # napříč RSS-fed sociálními feedy.
    MENTIONS_BY_SOURCE_TYPE = {
      'facebook'  => { type: 'suffix', value: 'https://facebook.com/' },
      'instagram' => { type: 'suffix', value: 'https://instagram.com/' },
      'threads'   => { type: 'suffix', value: 'https://threads.net/@' },
      'rss'       => { type: 'none',   value: '' },
      'other'     => { type: 'none',   value: '' }
    }.freeze

    # Pre-procesory pro sociální feedy přes RSS.app.
    # Klíč: hodnota :rss_source_type ze source YAML.
    # Hodnota: třída procesoru (musí mít #process(text) → text).
    PROCESSORS_BY_SOURCE_TYPE = {
      'facebook'  => 'Processors::FacebookProcessor',
      'instagram' => 'Processors::InstagramProcessor',
      'threads'   => 'Processors::ThreadsProcessor'
    }.freeze

    def initialize(config = {})
      @config = DEFAULT_CONFIG.merge(HashHelpers.symbolize_keys(config))

      # Set mentions config based on rss_source_type
      setup_mentions_config

      # Create UniversalFormatter with mapped config
      @universal = UniversalFormatter.new(build_universal_config)
    end

    # Format a Post object for Mastodon
    # @param post [Post] Post object to format
    # @return [String] Formatted text ready for Mastodon
    def format(post)
      raise ArgumentError, 'Post cannot be nil' if post.nil?

      # Pre-processing: dispatch podle rss_source_type
      post = apply_social_preprocessing(post)

      # Delegate to UniversalFormatter
      @universal.format(post, runtime_config)
    end

    private

    # Pin mentions config podle rss_source_type — přepíše cokoliv, co přišlo
    # z platformového overlaye (platforms/facebook.yml, instagram.yml, threads.yml).
    # Důvod: tyto platformové YAML obsahují mentions: { type: domain_suffix }
    # určené pro PROFILE_SYNCERY (jiný formát). Pro publikované posty chceme
    # mít jednotný 'suffix' (URL v závorce), který je v MENTIONS_BY_SOURCE_TYPE.
    def setup_mentions_config
      source_type = @config[:rss_source_type].to_s.downcase

      if (pinned = MENTIONS_BY_SOURCE_TYPE[source_type])
        @config[:mentions] = pinned
        return
      end

      # Pro neznámé rss_source_type respektuj inherited mentions, jinak fallback.
      return if @config[:mentions] && @config[:mentions][:type] && @config[:mentions][:type] != 'none'

      @config[:mentions] = MENTIONS_BY_SOURCE_TYPE['rss']
    end

    # Build config for UniversalFormatter
    def build_universal_config
      {
        platform: :rss,
        source_name: @config[:source_name],
        show_title_as_content: @config[:show_title_as_content],
        combine_title_and_content: @config[:combine_title_and_content],
        title_separator: @config[:title_separator],
        move_url_to_end: @config[:move_url_to_end],
        prefix_post_url: @config[:prefix_post_url],
        max_length: @config[:max_length],
        mentions: @config[:mentions]
      }
    end

    # Runtime config (can vary per-post if needed)
    def runtime_config
      {}
    end

    # Dispatch pre-procesoru podle rss_source_type.
    # Vrací upravený post (nebo originál, pokud žádný procesor není registrován).
    def apply_social_preprocessing(post)
      processor_class = resolve_processor_class
      return post unless processor_class
      return post unless post.respond_to?(:text) && post.text

      processed_text = processor_class.new.process(post.text)
      wrap_with_text(post, processed_text)
    end

    def resolve_processor_class
      class_name = PROCESSORS_BY_SOURCE_TYPE[@config[:rss_source_type].to_s]
      return nil unless class_name

      # Lazy resolve — třída může chybět, pokud ještě není implementována (např. Threads).
      Object.const_get(class_name)
    rescue NameError
      nil
    end

    # Vrací nový post-like objekt s přepsaným textem; zachová ostatní atributy.
    def wrap_with_text(post, new_text)
      if post.respond_to?(:dup)
        modified = post.dup
        if modified.respond_to?(:text=)
          modified.text = new_text
          return modified
        end
      end
      PostTextWrapper.new(post, new_text)
    end
  end
end
