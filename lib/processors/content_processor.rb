
# frozen_string_literal: true

# Content Processor for Zpravobot NG
# Handles text processing, trimming, and normalization
#
# Features:
# - Trimming strategies: smart (sentence-aware), word, hard
# - Ellipsis normalization (... → …, …… → …)
# - URL-aware sentence detection (skips dots inside URLs)
# - URL artifact cleanup after trimming

module Processors
  class ContentProcessor
    TRIM_STRATEGIES = %i[sentence word smart hard].freeze

    def initialize(max_length: 500, strategy: :smart, tolerance_percent: 12)
      @max_length = max_length
      @strategy = TRIM_STRATEGIES.include?(strategy) ? strategy : :smart
      @tolerance_percent = tolerance_percent.clamp(5, 25)
    end

    # Process content: normalize and trim to max length
    # @param text [String] Text to process
    # @return [String] Processed text
    def process(text)
      return '' if text.nil? || text.empty?

      # Normalize whitespace
      text = normalize(text)

      # Trim if needed
      text = trim(text) if text.length > @max_length

      text
    end

    private

    def normalize(text)
      result = text.dup

      # Normalize whitespace
      result.gsub!(/[ \t]+/, ' ')
      result.gsub!(/\n{3,}/, "\n\n")
      result.gsub!(/\n +/, "\n")
      result.gsub!(/ +\n/, "\n")

      # Normalize ellipsis: ... → …, …… → …, ...... → …
      result.gsub!(/\.{3,}/, '…')
      result.gsub!(/…{2,}/, '…')

      result.strip
    end

    def trim(text)
      case @strategy
      when :sentence
        trim_by_sentence(text)
      when :word
        trim_by_word(text)
      when :smart
        trim_smart(text)
      else
        trim_hard(text)
      end
    end

    def trim_by_sentence(text)
      target = @max_length - 1  # Leave room for ellipsis

      # Find last sentence ending before target
      sentences = text.scan(/[^.!?]+[.!?]+/)

      result = ''
      sentences.each do |sentence|
        break if (result + sentence).length > target
        result += sentence
      end

      if result.empty? || result.length < target * 0.5
        # Fall back to word trim
        trim_by_word(text)
      else
        result.strip
      end
    end

    def trim_by_word(text)
      target = @max_length - 1
      truncated = text[0...target]
      last_space = truncated.rindex(' ')

      result = if last_space && last_space > target * 0.7
                 truncated[0...last_space]
               else
                 truncated
               end

      result = clean_url_artifacts(result)
      result.rstrip + '…'
    end

    def trim_smart(text)
      target = @max_length - 1
      tolerance = (@max_length * @tolerance_percent / 100.0).to_i
      min_length = target - tolerance

      # Also track best sentence boundary even if below min_length
      last_sentence = nil
      best_sentence = nil
      text[0...target].scan(/[.!?]+(?=\s|$)/) do
        pos = $~.end(0)
        preceding = text[0...pos]
        # Skip dots inside URLs (e.g. example.com, clanek.html)
        next if preceding =~ /https?:\/\/\S*$/
        # Skip dots in abbreviations (single uppercase letter before dot, e.g. U.S.)
        next if preceding =~ /\b[A-Z]\.\z/

        best_sentence = pos
        last_sentence = pos if pos >= min_length && pos <= target
      end

      # Prefer sentence within tolerance; fallback to best sentence if > 70% of target
      chosen = last_sentence || (best_sentence && best_sentence > target * 0.7 ? best_sentence : nil)

      if chosen
        result = text[0...chosen].strip
        result = clean_url_artifacts(result)
        # Indicate truncation if text continues beyond the sentence boundary
        if chosen < text.length && (result.length + 2) <= @max_length
          result += ' …'
        end
        result
      else
        trim_by_word(text)
      end
    end

    def clean_url_artifacts(text)
      # Case 1: Incomplete/truncated URL at end
      if text =~ /(https?:\/\/\S+)$/
        url = $1
        url_body = url.sub(%r{^https?://}, '')
        if !url_body.include?('.') || url_body =~ /\.[a-z]{0,1}$/i
          return text[0...text.rindex(url)].rstrip
        end
      end

      # Case 2: Complete URL followed by non-sentence fragment
      if (m = text.match(/(https?:\/\/\S+)\s+(\S.*)/))
        after_url = m[2]
        unless after_url.match?(/[.!?]$/)
          url_end_pos = m.begin(0) + m[1].length
          return text[0...url_end_pos]
        end
      end

      text
    end

    def trim_hard(text)
      text[0...@max_length - 1] + '…'
    end
  end
end
