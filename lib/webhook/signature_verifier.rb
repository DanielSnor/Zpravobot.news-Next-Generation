# frozen_string_literal: true

require 'openssl'

module Webhook
  # Constant-time signature helpers for webhook authentication.
  module SignatureVerifier
    module_function

    # Constant-time string comparison — prevents timing attacks.
    def secure_compare(a, b)
      return false unless a.bytesize == b.bytesize
      OpenSSL.fixed_length_secure_compare(a, b)
    end

    # Verify HMAC-SHA256 signature for broadcast webhook.
    # Returns true when secret is not configured (allows unauthenticated in dev).
    def verify_broadcast_signature(body, signature_header, secret:)
      return true unless secret && !secret.empty?
      return false unless signature_header.is_a?(String) && signature_header.start_with?('sha256=')

      expected = signature_header.sub('sha256=', '')
      computed = OpenSSL::HMAC.hexdigest('SHA256', secret, body)
      secure_compare(computed, expected)
    rescue StandardError
      false
    end
  end
end
