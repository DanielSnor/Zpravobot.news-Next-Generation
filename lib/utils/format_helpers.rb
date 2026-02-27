# frozen_string_literal: true

# Shared formatting utility methods
# Eliminates duplicated format_bytes / clean_text across syncers, adapters, formatters
module FormatHelpers
  module_function

  # Format byte count to human-readable string
  # @param bytes [Numeric] Byte count
  # @return [String] e.g. "1.5 KB", "3.2 MB"
  def format_bytes(bytes)
    if bytes < 1024
      "#{bytes} B"
    elsif bytes < 1024 * 1024
      "#{(bytes / 1024.0).round(1)} KB"
    else
      "#{(bytes / (1024.0 * 1024)).round(1)} MB"
    end
  end

  # Normalize whitespace in text while preserving intentional newlines
  # @param text [String] Input text
  # @return [String] Cleaned text
  def clean_text(text)
    return '' if text.nil?

    text.to_s
      .gsub(/[ \t]+/, ' ')        # Normalize spaces/tabs to single space (NOT newlines)
      .gsub(/\n[ \t]+/, "\n")     # Trim leading whitespace from lines
      .gsub(/[ \t]+\n/, "\n")     # Trim trailing whitespace from lines
      .gsub(/\n{3,}/, "\n\n")     # Max 2 consecutive newlines
      .strip
  end
end
