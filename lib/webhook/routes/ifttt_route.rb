# frozen_string_literal: true

require 'json'
require_relative '../queue_writer'
require_relative '../signature_verifier'

module Webhook
  module Routes
    # Handles POST /api/ifttt/twitter — queues IFTTT webhook payloads.
    class IftttRoute
      def initialize(queue_dirs:, auth_token:)
        @queue_dirs = queue_dirs
        @auth_token = auth_token
      end

      # @return [Array(Integer, Hash, String|nil)] [status, body_hash, log_message]
      def call(headers, client, query_params, max_payload_size:)
        # Fail-closed: bez nastaveného @auth_token odmítá všechno. Server se sám
        # nespustí bez IFTTT_AUTH_TOKEN (bin/ifttt_webhook.rb), tohle je defense
        # in depth pro programaticky vytvořené instance route.
        return [401, { error: 'Unauthorized' }] unless @auth_token && !@auth_token.empty?

        unless SignatureVerifier.secure_compare(
          "Bearer #{@auth_token}", headers['authorization'].to_s
        )
          return [401, { error: 'Unauthorized' }]
        end

        body = read_body(client, headers, max_payload_size)
        return [413, { error: 'Payload too large' }] if body == :too_large

        payload = parse_json(body)
        return [400, { error: 'Invalid JSON' }] unless payload
        return [400, { error: 'Missing required fields' }] unless valid?(payload)

        env       = query_params['env'] == 'test' ? 'test' : 'prod'
        queue_dir = @queue_dirs[env]
        filepath  = QueueWriter.write(payload, queue_dir: queue_dir)
        post_id   = QueueWriter.extract_post_id(payload['link_to_tweet'] || payload['LinkToTweet'])
        username  = payload['username'] || payload['UserName']

        label = env == 'test' ? '🧪 TEST' : '🚀 PROD'
        [200,
         { status: 'queued', environment: env,
           queue_file: File.basename(filepath), post_id: post_id },
         "Queued [#{label}]: @#{username}/#{post_id}"]
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

      def valid?(payload)
        link     = payload['link_to_tweet'] || payload['LinkToTweet']
        text     = payload['text']          || payload['Text']
        username = payload['username']      || payload['UserName']
        link && QueueWriter.extract_post_id(link) &&
          text && !text.empty? && username && !username.empty?
      end
    end
  end
end
