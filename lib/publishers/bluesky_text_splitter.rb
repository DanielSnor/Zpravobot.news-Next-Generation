# frozen_string_literal: true

module Publishers
  # Splits Mastodon post text into Bluesky-compatible chunks (≤ 300 graphemes).
  #
  # Responsibilities:
  #   1. Strip trailing hashtag-only lines (Bluesky posts don't use hashtags)
  #   2. Split by complete lines within paragraphs (never mid-word or mid-line)
  #   3. When a paragraph must be split, repeat its first line as a
  #      "- pokračování:" continuation header in the next chunk
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
          current = split_paragraph_by_lines(para, chunks)
        else
          current = split_paragraph_by_lines(para, chunks)
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

    # Split a paragraph by complete lines (never mid-line).
    # When the paragraph must be split, the first line is treated as a section
    # header and repeated with "- pokračování:" in each continuation chunk.
    # Falls back to word-split only for a single line that exceeds CHAR_LIMIT.
    def split_paragraph_by_lines(para, chunks)
      lines       = para.split("\n")
      header_line = lines.first
      cont_header = "#{header_line.chomp(':')} - pokračování:"
      current     = ''

      lines.each do |line|
        candidate = current.empty? ? line : "#{current}\n#{line}"

        if grapheme_length(candidate) <= CHAR_LIMIT
          current = candidate
        else
          chunks << current unless current.empty?

          # Start the continuation chunk
          next_base = (line == header_line) ? line : "#{cont_header}\n#{line}"

          if grapheme_length(next_base) <= CHAR_LIMIT
            current = next_base
          else
            # Single line exceeds limit — last resort word split
            current = split_line_by_words(next_base, chunks)
          end
        end
      end

      current
    end

    # Word-split fallback for lines that are themselves > CHAR_LIMIT graphemes.
    def split_line_by_words(line, chunks)
      current = ''
      line.split(' ').each do |word|
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
