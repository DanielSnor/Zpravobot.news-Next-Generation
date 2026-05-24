# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'uri'
require 'time'
require_relative '../utils/atomic_file'

module Webhook
  # Atomic queue file management for IFTTT and broadcast webhooks.
  module QueueWriter
    module_function

    # Normalize and enqueue an IFTTT webhook payload.
    # @return [String] filepath of written queue file
    def write(payload, queue_dir:)
      normalized = {
        'text'           => payload['text']           || payload['Text'],
        'embed_code'     => payload['embed_code']     || payload['TweetEmbedCode'],
        'link_to_tweet'  => payload['link_to_tweet']  || payload['LinkToTweet'],
        'first_link_url' => payload['first_link_url'] || payload['FirstLinkUrl'],
        'username'       => payload['username']       || payload['UserName'],
        'bot_id'         => payload['bot_id'],
        'received_at'    => Time.now.iso8601
      }

      post_id   = extract_post_id(normalized['link_to_tweet'])
      timestamp = Time.now.strftime('%Y%m%d%H%M%S%L')
      filename  = "#{timestamp}_#{sanitize(normalized['username'])}_#{sanitize(post_id, 30)}.json"
      filepath  = File.join(queue_dir, 'pending', filename)

      FileUtils.mkdir_p(File.join(queue_dir, 'pending'))
      Utils::AtomicFile.write(filepath, JSON.generate(normalized))
      filepath
    end

    # Write a raw body (e.g. broadcast webhook payload) to a queue directory.
    # @return [String] filename of written queue file
    def write_raw(body, dir:, prefix:, id:)
      timestamp = Time.now.strftime('%Y%m%d%H%M%S%L')
      filename  = "#{timestamp}_#{prefix}_#{sanitize(id, 30)}.json"
      filepath  = File.join(dir, 'pending', filename)
      FileUtils.mkdir_p(File.join(dir, 'pending'))
      Utils::AtomicFile.write(filepath, body)
      filename
    end

    # Extract numeric tweet/post ID from a Twitter/X URL.
    def extract_post_id(url)
      return nil unless url
      m = url.match(%r{(?:twitter\.com|x\.com)/\w+/status/(\d+)})
      m ? m[1] : nil
    end

    # Sanitize a string for use as a filename segment.
    def sanitize(str, max_len = 100)
      str.to_s.gsub(/[^a-zA-Z0-9_.-]/, '_')[0...max_len]
    end
  end
end
