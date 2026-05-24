# frozen_string_literal: true

require 'json'
require_relative '../queue_writer'
require_relative '../signature_verifier'

module Webhook
  module Routes
    # Handles POST /api/mastodon/broadcast — queues tlambot Mastodon status events.
    class BroadcastRoute
      TRIGGER_ACCOUNT = 'tlambot'

      def initialize(queue_dir:, secret:)
        @queue_dir = queue_dir
        @secret    = secret
      end

      # @return [Array(Integer, Hash, String|nil)] [status, body_hash, log_message]
      def call(headers, client, max_payload_size:)
        body = read_body(client, headers, max_payload_size)
        return [413, { error: 'Payload too large' }] if body == :too_large

        unless SignatureVerifier.verify_broadcast_signature(
          body, headers['x-hub-signature'], secret: @secret
        )
          return [401, { error: 'Invalid signature' }]
        end

        payload = parse_json(body)
        return [400, { error: 'Invalid JSON' }] unless payload

        return [200, { status: 'ignored', reason: 'not status.created' }] \
          unless payload['event'] == 'status.created'

        username = payload.dig('object', 'account', 'username')&.downcase
        return [200, { status: 'ignored', reason: "not #{TRIGGER_ACCOUNT}" }] \
          unless username == TRIGGER_ACCOUNT

        return [200, { status: 'ignored', reason: 'reblog' }]  if payload.dig('object', 'reblog')
        return [200, { status: 'ignored', reason: 'reply' }]   if payload.dig('object', 'in_reply_to_id')

        status_id = payload.dig('object', 'id') || 'unknown'
        filename  = QueueWriter.write_raw(body, dir: @queue_dir, prefix: 'tlambot', id: status_id)

        [200,
         { status: 'queued', queue_file: filename, status_id: status_id },
         "📢 Broadcast queued: tlambot/#{status_id}"]
      end

      private

      def read_body(client, headers, max_size)
        cl = headers['content-length']&.to_i || 0
        return :too_large if cl > max_size
        cl > 0 ? client.read(cl) : ''
      end

      def parse_json(body)
        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
