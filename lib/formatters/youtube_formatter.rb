# frozen_string_literal: true

# YouTube Formatter - Delegating to UniversalFormatter
# =====================================================
#
# Wrapper který zachovává stávající API ale interně používá UniversalFormatter.
# Zachovává YouTube-specific funkce jako description_max_lines a include_views.
#

require_relative 'universal_formatter'
require_relative '../utils/hash_helpers'
require_relative '../models/post_text_wrapper'

module Formatters
  class YouTubeFormatter
    # Backwards-compatible DEFAULTS
    DEFAULT_CONFIG = {
      # Content composition (IFTTT-compatible, same as RSS)
      show_title_as_content: false,
      combine_title_and_content: false,
      title_separator: ' — ',
      
      # URL handling
      move_url_to_end: true,
      prefix_post_url: "\n\n🎬 ",
      
      # Length limits
      max_length: 500,
      
      # YouTube-specific
      description_max_lines: 3,
      include_views: false,
      
      # Optional source name
      source_name: nil,
      
      # Mentions config (YouTube doesn't have traditional @mentions)
      mentions: {
        type: 'none',
        value: ''
      }
    }.freeze

    def initialize(config = {})
      @config = DEFAULT_CONFIG.merge(HashHelpers.symbolize_keys(config))
      # Ensure mentions is a hash
      @config[:mentions] = DEFAULT_CONFIG[:mentions].merge(@config[:mentions] || {})
      
      # Create UniversalFormatter with mapped config
      @universal = UniversalFormatter.new(build_universal_config)
    end

    # Format a YouTube Post for Mastodon
    # @param post [Post] YouTube post object
    # @return [String] Formatted status text
    def format(post)
      raise ArgumentError, "Post cannot be nil" if post.nil?
      
      # Pre-processing: limit description lines
      post = apply_description_limit(post)
      
      # Delegate to UniversalFormatter
      result = @universal.format(post, runtime_config)
      
      # Post-processing: add views if enabled
      if @config[:include_views]
        result = append_views(result, post)
      end
      
      result
    end

    private

    # Build config for UniversalFormatter
    def build_universal_config
      {
        platform: :youtube,
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

    # Runtime config
    def runtime_config
      {}
    end

    # Limit description to max lines
    def apply_description_limit(post)
      max_lines = @config[:description_max_lines]
      return post unless max_lines && max_lines > 0
      return post unless post.respond_to?(:text) && post.text
      
      text = post.text.to_s
      lines = text.split(/\n/).map(&:strip).reject(&:empty?)
      
      # Only modify if we have more lines than allowed
      return post if lines.length <= max_lines
      
      limited_text = lines.first(max_lines).join("\n")
      
      # Create wrapper with limited text
      PostTextWrapper.new(post, limited_text)
    end

    # Append view count if available
    def append_views(content, post)
      return content unless post.respond_to?(:raw) && post.raw
      
      views = post.raw[:views] || post.raw['views']
      return content unless views
      
      # Insert before URL if present
      if content.include?(@config[:prefix_post_url])
        parts = content.split(@config[:prefix_post_url], 2)
        "#{parts[0]}\n\n👁 #{format_number(views)} zhlédnutí#{@config[:prefix_post_url]}#{parts[1]}"
      else
        "#{content}\n\n👁 #{format_number(views)} zhlédnutí"
      end
    end

    # Format large numbers with spaces (Czech style)
    def format_number(num)
      num.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1 ').reverse
    end
  end
end
