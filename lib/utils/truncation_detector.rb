# frozen_string_literal: true

# Detects source-side truncation (Syndication API ~280 chars, IFTTT 257 chars)
# and marks text with a trailing ellipsis as a reader-facing indicator.
#
# Stateless. Idempotent — re-running on already-marked text is a no-op.
#
# Two thresholds for two upstream sources:
#   IFTTT_THRESHOLD       = 257 (IFTTT applet truncation point)
#   SYNDICATION_THRESHOLD = 270 (CDN syndication endpoint truncation point ~280)
#
# Both are calibrated below the actual cut so we err on adding the indicator
# only when a natural terminator is also missing.
module Utils
  module TruncationDetector
    module_function

    IFTTT_THRESHOLD       = 257
    SYNDICATION_THRESHOLD = 270

    # Patterns that signal "text ended naturally" — no ellipsis needed.
    TERMINATOR_PATTERNS = {
      punctuation: /[.!?。！？…]\s*\z/,
      emoji:       /\p{Emoji}\s*\z/,
      url:         %r{https?://\S+\s*\z},
      hashtag:     /#\w+\s*\z/,
      mention:     /@\w+\s*\z/
    }.freeze

    # Detect upstream truncation and (if needed) append ellipsis.
    #
    # @param text [String] Post body
    # @param threshold [Integer] Length at/above which we consider truncation possible
    # @return [Hash] { text: String, truncated: Boolean, ellipsis_added: Boolean }
    def detect_and_mark(text, threshold:)
      return blank_result(text) if text.nil? || text.empty?
      return blank_result(text) if text.length < threshold

      already_marked = text.match?(/…\s*\z/)
      ends_with_tco  = text.match?(%r{https://t\.co/\S+\s*\z})
      has_terminator = has_natural_terminator?(text)

      # `truncated` is a property of the text (it ended incomplete), not an action.
      # Already-marked text reports truncated: true so callers can still set downstream
      # flags (force_read_more) on idempotent re-runs.
      truncated = already_marked || ends_with_tco || !has_terminator
      return blank_result(text) unless truncated

      new_text = already_marked ? text : "#{text.rstrip}…"
      { text: new_text, truncated: true, ellipsis_added: !already_marked }
    end

    # Unconditionally mark text as truncated (idempotent).
    # Use when the caller has a definitive truncation signal from the source
    # (e.g. Syndication API's `note_tweet` field = "this IS a Note Tweet, body
    # is cut at ~280") and the heuristic would be redundant or wrong.
    #
    # @param text [String]
    # @return [Hash] { text: String, truncated: Boolean, ellipsis_added: Boolean }
    def mark_as_truncated(text)
      return blank_result(text) if text.nil? || text.empty?

      already_marked = text.match?(/…\s*\z/)
      new_text       = already_marked ? text : "#{text.rstrip}…"
      { text: new_text, truncated: true, ellipsis_added: !already_marked }
    end

    # @param text [String]
    # @return [Boolean] true if text ends with punctuation/emoji/URL/hashtag/mention
    def has_natural_terminator?(text)
      return false if text.nil? || text.empty?

      # Strip trailing t.co placeholder — it masks the real terminator.
      text_for_check = text.gsub(%r{\s*https?://t\.co/\S+\s*\z}, '').rstrip
      TERMINATOR_PATTERNS.any? { |_kind, pattern| text_for_check.match?(pattern) }
    end

    def blank_result(text)
      { text: text, truncated: false, ellipsis_added: false }
    end
    private_class_method :blank_result
  end
end
