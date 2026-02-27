# frozen_string_literal: true

require 'uri'
require_relative '../utils/html_cleaner'

module Webhook
  # Parses webhook payload and resolves bot configuration
  #
  # Extracts: bot_id, post_id, username, text from IFTTT JSON payload
  # Resolves: source config (bot_config) via ConfigLoader
  class WebhookPayloadParser
    # Parsed webhook data
    ParsedPayload = Struct.new(
      :bot_id, :post_id, :username, :text, :bot_config, :source_id,
      keyword_init: true
    )

    # Parse webhook payload and resolve config
    # @param payload [Hash] Raw webhook data (string keys from JSON.parse)
    # @param config_finder [#call] Callable(bot_id, username) → bot_config hash
    # @return [ParsedPayload]
    def parse(payload, config_finder)
      bot_id = payload['bot_id']
      post_id = extract_post_id(payload['link_to_tweet'])
      username = payload['username']
      text = payload['text'] || ''

      # IFTTT sends text URL-encoded (+ for spaces, %xx for special chars)
      # and may contain HTML entities (&gt;, &amp;, etc.)
      # Decode once here to prevent double-decode crashes (e.g. 92%25 → 92% → crash)
      text = decode_ifttt_text(text)

      bot_config = config_finder.call(bot_id, username)
      return nil unless bot_config

      ParsedPayload.new(
        bot_id: bot_id,
        post_id: post_id,
        username: username,
        text: text,
        bot_config: bot_config,
        source_id: bot_config[:id]
      )
    end

    private

    # Decode IFTTT URL-encoded text + HTML entities in one pass
    # @param text [String] Raw IFTTT text (URL-encoded, may contain HTML entities)
    # @return [String] Decoded plain text
    def decode_ifttt_text(text)
      return '' if text.nil? || text.empty?

      # 1. URL decode (IFTTT encodes: + → space, %xx → chars)
      text = URI.decode_www_form_component(text)
      # 2. HTML entity decode (IFTTT includes &gt;, &amp;, etc.)
      HtmlCleaner.decode_html_entities(text)
    end

    def extract_post_id(url)
      return nil unless url
      match = url.match(%r{(?:twitter\.com|x\.com)/\w+/status/(\d+)})
      match ? match[1] : nil
    end
  end
end
