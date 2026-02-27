# frozen_string_literal: true

module Adapters
  # Tweet type detection and classification extracted from TwitterAdapter
  #
  # Handles:
  # - Repost (RT) detection
  # - Quote tweet detection (RSS and HTML)
  # - Reply detection with thread awareness
  # - Reply classification (self vs external)
  # - Video detection
  #
  # Depends on:
  # - TwitterRssParser#extract_text (for quote detection from RSS)
  # - @handle (from TwitterAdapter)
  #
  module TwitterTweetClassifier
    # ============================================
    # Type Detection
    # ============================================

    def detect_repost(title)
      title.match?(/^RT by @\w+:/i)
    end

    def detect_quote(item)
      description = item[:description] || ''
      text = extract_text(description)

      !!(text =~ TwitterRssParser::QUOTE_MARKER_REGEX)
    end

    # Original simple reply detection (kept for backwards compatibility)
    def detect_reply(text)
      text.match?(/^R to @\w+:/) || text.match?(/^@\w+\s/)
    end

    # ============================================
    # Enhanced Reply Detection with Thread Awareness
    # ============================================

    # Detect reply and classify as thread (self-reply) vs external reply
    # Core of Phase 1 thread detection
    #
    # @param text [String] Tweet text or title
    # @return [Hash] { is_reply:, is_thread_post:, reply_to_handle: }
    def detect_reply_with_thread(text)
      result = {
        is_reply: false,
        is_thread_post: false,
        reply_to_handle: nil
      }

      return result unless text

      # Pattern 1: "R to @username:" (Nitter format)
      if (match = text.match(/^R to @(\w+):/i))
        result[:is_reply] = true
        result[:reply_to_handle] = match[1].downcase

        if result[:reply_to_handle] == @handle.downcase
          result[:is_thread_post] = true
        end

        return result
      end

      # Pattern 2: "@username " at start (standard reply)
      if (match = text.match(/^@(\w+)\s/i))
        result[:is_reply] = true
        result[:reply_to_handle] = match[1].downcase

        if result[:reply_to_handle] == @handle.downcase
          result[:is_thread_post] = true
        end

        return result
      end

      result
    end

    # Classify reply type
    # @param text [String] Tweet text
    # @return [Symbol] :self_reply, :external_reply, or :not_reply
    def classify_reply(text)
      info = detect_reply_with_thread(text)

      return :not_reply unless info[:is_reply]
      return :self_reply if info[:is_thread_post]
      :external_reply
    end

    # Detect video in tweet HTML (RSS format)
    # @param html [String] Tweet HTML from Nitter RSS
    # @return [Boolean] true if contains video
    def detect_video(html)
      return false unless html
      html.include?('>Video<') || html.include?('video_thumb')
    end
  end
end
