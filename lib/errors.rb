# frozen_string_literal: true

# ============================================================
# Zpravobot Error Hierarchy
# ============================================================
# Centralized exception classes for consistent error handling
# across all components.
#
# Usage:
#   raise Zpravobot::NetworkError, "Connection refused"
#   raise Zpravobot::RateLimitError.new(retry_after: 30)
#   raise Zpravobot::ConfigError, "Missing mastodon_token"
#
# Rescue patterns:
#   # Catch all Zpravobot errors
#   rescue Zpravobot::Error => e
#
#   # Catch network-related errors (includes rate limit, server)
#   rescue Zpravobot::NetworkError => e
#
#   # Catch specific HTTP errors
#   rescue Zpravobot::RateLimitError => e
#     sleep e.retry_after
# ============================================================

module Zpravobot
  # Base error class for all Zpravobot errors
  class Error < StandardError; end

  # Network/HTTP connection failures (timeouts, refused, reset)
  class NetworkError < Error; end

  # HTTP 429 Too Many Requests
  class RateLimitError < NetworkError
    attr_reader :retry_after

    def initialize(message = "Rate limited", retry_after: 5)
      @retry_after = retry_after
      super(message)
    end
  end

  # HTTP 5xx server errors
  class ServerError < NetworkError
    attr_reader :status_code

    def initialize(message = nil, status_code: 500)
      @status_code = status_code
      super(message || "Server error: #{status_code}")
    end
  end

  # Invalid configuration (missing keys, bad values)
  class ConfigError < Error; end

  # Mastodon publish/update/delete failures
  class PublishError < Error; end

  # Source adapter fetch failures
  class AdapterError < Error; end

  # Database/state persistence failures
  class StateError < Error; end

  # Status not found (404 from Mastodon API)
  class StatusNotFoundError < PublishError; end

  # Edit/delete not allowed (403 from Mastodon API)
  class EditNotAllowedError < PublishError; end

  # Validation error (422 from Mastodon API)
  class ValidationError < PublishError; end
end
