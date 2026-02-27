# frozen_string_literal: true

# RSS Formatter - Delegating to UniversalFormatter
# =================================================
#
# Wrapper který zachovává stávající API ale interně používá UniversalFormatter.
# Zachovává RSS-specific funkce jako Facebook processing a rss_source_type.
#

require_relative 'universal_formatter'
require_relative '../utils/hash_helpers'
require_relative '../models/post_text_wrapper'

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

    # Mention prefixes for different RSS source types
    MENTIONS_BY_SOURCE_TYPE = {
      'facebook' => { type: 'suffix', value: 'https://facebook.com/' },
      'instagram' => { type: 'suffix', value: 'https://instagram.com/' },
      'rss' => { type: 'none', value: '' },
      'other' => { type: 'none', value: '' }
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
      raise ArgumentError, "Post cannot be nil" if post.nil?
      
      # Pre-processing: Facebook-specific processing
      if @config[:rss_source_type] == 'facebook'
        post = apply_facebook_preprocessing(post)
      end
      
      # Delegate to UniversalFormatter
      @universal.format(post, runtime_config)
    end

    private

    # Setup mentions config based on rss_source_type
    def setup_mentions_config
      source_type = @config[:rss_source_type].to_s.downcase
      
      # If explicit mentions config provided with actual type, use it
      if @config[:mentions] && @config[:mentions][:type] && @config[:mentions][:type] != 'none'
        return
      end
      
      # Otherwise, derive from source type
      mentions_config = MENTIONS_BY_SOURCE_TYPE[source_type] || MENTIONS_BY_SOURCE_TYPE['rss']
      @config[:mentions] = mentions_config
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

    # Apply Facebook-specific preprocessing
    # Handles em-dash duplicates from RSS.app
    def apply_facebook_preprocessing(post)
      return post unless defined?(Processors::FacebookProcessor)
      
      # Only process if post has text
      return post unless post.respond_to?(:text) && post.text
      
      processor = Processors::FacebookProcessor.new
      processed_text = processor.process(post.text)
      
      # Create modified post with processed text
      # We need to handle this without modifying the original post
      if post.respond_to?(:dup)
        modified = post.dup
        if modified.respond_to?(:text=)
          modified.text = processed_text
          return modified
        end
      end
      
      # Fallback: create wrapper that overrides text
      PostTextWrapper.new(post, processed_text)
    end
  end
end
