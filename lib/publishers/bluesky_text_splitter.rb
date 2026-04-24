# frozen_string_literal: true

module Publishers
  # Splits Mastodon post text into Bluesky-compatible chunks (≤ 300 graphemes).
  #
  # Responsibilities:
  #   1. Strip trailing hashtag-only lines (Bluesky posts don't use hashtags)
  #   2. Split by words, respecting paragraph boundaries where possible
  #
  # Usage:
  #   chunks = Publishers::BlueskyTextSplitter.new.split(text)
  #   # => Array<String>
  class BlueskyTextSplitter
    CHAR_LIMIT = 300

    def split(text)
      cleaned = strip_hashtags(text.to_s)
      return [] if cleaned.empty?

      chunks  = []
      current = ''

      cleaned.split(/\n{2,}/).each do |para|
        candidate = current.empty? ? para : "#{current}\n\n#{para}"

        if grapheme_length(candidate) <= CHAR_LIMIT
          current = candidate
        elsif !current.empty?
          chunks << current
          current = split_paragraph_by_words(para, chunks)
        else
          current = split_paragraph_by_words(para, chunks)
        end
      end

      chunks << current unless current.empty?
      chunks
    end

    private

    # Remove trailing lines that contain only hashtag tokens (#word).
    def strip_hashtags(text)
      lines = text.rstrip.split("\n")
      lines.pop while lines.last&.match?(/\A\s*(#\w+\s*)*\s*\z/)
      lines.join("\n").rstrip
    end

    # Split a single paragraph by words, appending full chunks to the array.
    # Returns the leftover (incomplete) current chunk.
    def split_paragraph_by_words(para, chunks)
      current = ''
      para.split(' ').each do |word|
        candidate = current.empty? ? word : "#{current} #{word}"
        if grapheme_length(candidate) <= CHAR_LIMIT
          current = candidate
        else
          chunks << current unless current.empty?
          current = word
        end
      end
      current
    end

    def grapheme_length(str)
      str.scan(/\X/).length
    end
  end
end
