# frozen_string_literal: true

require 'set'

module Processors
  # Facebook Content Processor for Zpravobot Next Generation
  #
  # Handles Facebook-specific content issues from RSS.app feeds:
  # - Em-dash duplicate removal (Reels often have "Text… ”” Text…")
  # - Can be extended for other FB-specific cleanup
  #
  # Usage:
  #   processor = Processors::FacebookProcessor.new
  #   cleaned = processor.process("Čo ďalšie odznelo? bit.ly/xxx ”” Čo ďalšie odznelo? bit.ly/xxx")
  #   # => "Čo ďalšie odznelo? bit.ly/xxx"
  #
  # Called from ContentFormatter when rss_source_type is 'facebook'
  #
  class FacebookProcessor
    # Em-dash separator used by RSS.app to join title and description
    EM_DASH_SEPARATOR = ' — '

    # Minimum similarity ratio to consider as duplicate (0.0-1.0)
    # Lower value = more aggressive deduplication
    SIMILARITY_THRESHOLD = 0.6

    def initialize(config = {})
      @config = config
    end

    # Process Facebook content - main entry point
    # @param text [String] Text to process
    # @return [String] Processed text
    def process(text)
      return '' if text.nil? || text.empty?

      result = text.dup

      # 1. Remove em-dash duplicates (Reels: "Text… ”” Text…")
      result = remove_emdash_duplicate(result)

      # 2. Future: other FB-specific cleanup can be added here

      result.strip
    end

    # Detect and remove duplicate content after em-dash separator
    # RSS.app often combines title and description with " ”” "
    # For Reels, both contain the same (or similar) content
    #
    # Examples:
    #   "Čo ďalšie odznelo? bit.ly/xxx ”” Čo ďalšie odznelo? bit.ly/xxx"
    #   => "Čo ďalšie odznelo? bit.ly/xxx"
    #
    #   "Full post text here… ”” Shorter version…"
    #   => "Full post text here…"
    #
    # @param text [String] Text with potential em-dash duplicate
    # @return [String] Text with duplicate removed (if detected)
    def remove_emdash_duplicate(text)
      return text unless text.include?(EM_DASH_SEPARATOR)

      parts = text.split(EM_DASH_SEPARATOR, 2)
      return text if parts.length < 2

      first_part = parts[0].strip
      second_part = parts[1].strip

      # Skip if either part is empty
      return text if first_part.empty? || second_part.empty?

      # Check if parts are duplicates or near-duplicates
      if duplicate_content?(first_part, second_part)
        # Return the longer part (more complete content)
        longer_part = first_part.length >= second_part.length ? first_part : second_part
        
        # Recursively check for more duplicates (handles "A ”” A ”” A")
        return remove_emdash_duplicate(longer_part)
      end

      # Not a duplicate - keep original
      text
    end

    # Check if two parts are duplicates or near-duplicates
    # Handles cases where one part is truncated version of the other
    #
    # @param first [String] First part
    # @param second [String] Second part
    # @return [Boolean] True if parts are duplicates
    def duplicate_content?(first, second)
      # Normalize for comparison
      first_norm = normalize_for_comparison(first)
      second_norm = normalize_for_comparison(second)

      # Exact match
      return true if first_norm == second_norm

      # One is prefix of the other (truncated duplicate)
      return true if prefix_match?(first_norm, second_norm)

      # High similarity score
      return true if similarity_score(first_norm, second_norm) >= SIMILARITY_THRESHOLD

      false
    end

    # Check if one string is a prefix of the other
    # Handles truncated content where one part ends with ellipsis
    #
    # @param first [String] First normalized string
    # @param second [String] Second normalized string
    # @return [Boolean] True if prefix match
    def prefix_match?(first, second)
      # Determine shorter and longer strings
      shorter, longer = [first, second].sort_by(&:length)

      # Check if shorter is prefix of longer
      # Use 80% of shorter length to handle minor differences
      min_match_length = (shorter.length * 0.8).to_i
      return false if min_match_length < 10  # Too short to reliably compare

      longer.start_with?(shorter[0...min_match_length])
    end

    # Calculate similarity score between two strings (0.0-1.0)
    # Uses word overlap for simplicity and speed
    #
    # @param first [String] First normalized string
    # @param second [String] Second normalized string
    # @return [Float] Similarity score
    def similarity_score(first, second)
      first_words = first.split(/\s+/).to_set
      second_words = second.split(/\s+/).to_set

      return 0.0 if first_words.empty? || second_words.empty?

      # Jaccard similarity: intersection / union
      intersection = (first_words & second_words).size
      union = (first_words | second_words).size

      return 0.0 if union.zero?

      intersection.to_f / union
    end

    private

    # Normalize text for comparison
    # Removes ellipsis, punctuation, lowercases
    #
    # @param text [String] Text to normalize
    # @return [String] Normalized text
    def normalize_for_comparison(text)
      normalized = text.dup

      # Remove ellipsis (both Unicode and ASCII)
      normalized = normalized.gsub(/[…]|\.{2,}/, '')

      # Remove common URL patterns (they're often duplicated too)
      normalized = normalized.gsub(%r{https?://\S+}, '')
      normalized = normalized.gsub(/bit\.ly\/\S+/, '')

      # Remove hashtags for comparison (they're often the same)
      normalized = normalized.gsub(/#\S+/, '')

      # Lowercase and normalize whitespace
      normalized = normalized.downcase
      normalized = normalized.gsub(/\s+/, ' ')

      normalized.strip
    end
  end
end
