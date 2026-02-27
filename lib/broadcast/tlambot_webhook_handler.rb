# frozen_string_literal: true

# ============================================================
# Tlambot Webhook Handler
# ============================================================
# Parses Mastodon webhook payloads (status.created) from tlambot
# and extracts broadcast job data: text, media, target accounts.
#
# Mention-based routing:
#   - No mentions (besides @tlambot) → broadcast to ALL accounts
#   - @zpravobot → broadcast to zpravobot.news domain accounts only
#   - @jedenbot → broadcast to jedenbot only
#   - @jedenbot @druhy → broadcast to both
#
# All @mentions are stripped from the broadcast text.
# ============================================================

require 'openssl'
require 'json'
require_relative '../utils/html_cleaner'
require_relative '../support/loggable'

module Broadcast
  class TlambotWebhookHandler
    include Support::Loggable

    TRIGGER_ACCOUNT = 'tlambot'
    ZPRAVOBOT_KEYWORD = 'zpravobot'

    # @param webhook_secret [String] HMAC-SHA256 secret for signature verification
    # @param trigger_account [String] Mastodon username that triggers broadcasts
    def initialize(webhook_secret:, trigger_account: TRIGGER_ACCOUNT)
      @webhook_secret = webhook_secret
      @trigger_account = trigger_account.downcase
    end

    # Verify HMAC-SHA256 signature from X-Hub-Signature header
    #
    # @param body [String] Raw request body
    # @param signature_header [String] Value of X-Hub-Signature header ("sha256=...")
    # @return [Boolean]
    def verify_signature(body, signature_header)
      return false if @webhook_secret.nil? || @webhook_secret.empty?
      return false unless signature_header.is_a?(String) && signature_header.start_with?('sha256=')

      expected_hex = signature_header.sub('sha256=', '')
      computed_hex = OpenSSL::HMAC.hexdigest('SHA256', @webhook_secret, body)

      # Constant-time comparison
      return false unless expected_hex.length == computed_hex.length

      computed_hex.bytes.zip(expected_hex.bytes).map { |a, b| a ^ b }.reduce(0, :|).zero?
    rescue StandardError
      false
    end

    # Parse webhook payload and extract broadcast job
    #
    # @param payload [Hash] Parsed JSON payload (symbol keys)
    # @return [Hash, nil] Job hash or nil if not a tlambot broadcast
    #   Keys: :status_id, :text, :visibility, :media_items, :routing, :trigger_account, :created_at
    def parse(payload)
      # Verify event type
      return nil unless payload[:event] == 'status.created'

      object = payload[:object]
      return nil unless object.is_a?(Hash)

      # Verify it's from tlambot
      account_username = object.dig(:account, :username)&.downcase
      return nil unless account_username == @trigger_account

      # Skip reblogs and replies
      return nil if object[:reblog]
      return nil if object[:in_reply_to_id]

      status_id = object[:id]
      html_content = object[:content] || ''
      visibility = object[:visibility] || 'public'
      mentions = object[:mentions] || []
      media_attachments = object[:media_attachments] || []

      # Determine routing from mentions
      routing = extract_targets(mentions)

      # Clean text: HTML → plain text, strip all mentions
      text = clean_broadcast_text(html_content, mentions)

      return nil if text.nil? || text.strip.empty?

      # Build media items array
      media_items = media_attachments.map do |ma|
        { url: ma[:url], description: ma[:description], type: ma[:type] }
      end.select { |mi| mi[:url] }

      {
        status_id: status_id,
        text: text,
        visibility: visibility,
        media_items: media_items,
        routing: routing,
        trigger_account: @trigger_account,
        created_at: object[:created_at]
      }
    end

    # Extract routing from mentions
    #
    # @param mentions [Array<Hash>] Mention objects from payload
    # @return [Hash] Routing directive:
    #   { target: 'all' }                              — broadcast to all accounts
    #   { target: 'zpravobot' }                        — broadcast to zpravobot.news accounts
    #   { target: 'accounts', accounts: ['bot1'] }     — broadcast to specific accounts
    def extract_targets(mentions)
      # Get all mentioned usernames except tlambot itself
      other_mentions = (mentions || [])
        .map { |m| m[:username]&.downcase }
        .compact
        .reject { |u| u == @trigger_account }

      # No other mentions → broadcast all
      return { target: 'all' } if other_mentions.empty?

      # Check for @zpravobot keyword
      has_zpravobot = other_mentions.include?(ZPRAVOBOT_KEYWORD)
      account_mentions = other_mentions.reject { |u| u == ZPRAVOBOT_KEYWORD }

      if account_mentions.empty? && has_zpravobot
        # Only @zpravobot → target zpravobot domain
        { target: 'zpravobot' }
      elsif account_mentions.any?
        # Specific accounts mentioned
        { target: 'accounts', accounts: account_mentions }
      else
        # Fallback (shouldn't reach here)
        { target: 'all' }
      end
    end

    # Clean HTML content and strip all mention text
    #
    # @param html [String] HTML content from Mastodon
    # @param mentions [Array<Hash>] Mention objects
    # @return [String] Clean broadcast text
    def clean_broadcast_text(html, mentions)
      # Convert HTML to plain text
      text = HtmlCleaner.clean(html)

      # Build list of all usernames to strip (tlambot + all mentioned)
      all_mentioned = (mentions || []).map { |m| m[:username]&.downcase }.compact
      all_mentioned << @trigger_account unless all_mentioned.include?(@trigger_account)

      # Strip each mention pattern
      # After HtmlCleaner, Mastodon h-card mentions become "@ username" or "@username"
      # Pattern from command_listener.rb line 204
      all_mentioned.each do |username|
        text = text.gsub(/@\s*#{Regexp.escape(username)}(?:\s*@\s*[^\s]+)?\s*/i, '')
      end

      # Normalize whitespace
      text.strip.gsub(/\s{2,}/, ' ')
    end
  end
end
