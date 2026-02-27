# frozen_string_literal: true

# Base Adapter for Zpravobot NG
# Abstract base class for all platform adapters

require_relative '../support/loggable'

module Adapters
  class BaseAdapter
    include Support::Loggable

    USER_AGENT = 'Zpravobot/1.0 (+https://zpravobot.news)'

    attr_reader :config

    def initialize(config = {})
      @config = config
      validate_config!
    end

    # Platform identifier (override in subclass)
    def platform
      raise NotImplementedError, "#{self.class} must implement #platform"
    end

    # Fetch posts from the platform (override in subclass)
    # @param since [Time, nil] Only return posts after this time
    # @param limit [Integer] Maximum number of posts to return
    # @return [Array<Post>] Array of Post objects
    def fetch_posts(since: nil, limit: 50)
      raise NotImplementedError, "#{self.class} must implement #fetch_posts"
    end

    protected

    # Validate configuration (override in subclass if needed)
    def validate_config!
      # Override in subclass
    end
  end
end
