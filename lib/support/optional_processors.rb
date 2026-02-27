# frozen_string_literal: true

# Shared availability flags for optional processors
#
# Centralizes the try/rescue LoadError pattern that was duplicated
# in orchestrator.rb and ifttt_queue_processor.rb.
#
# Usage:
#   require_relative 'support/optional_processors'
#   include Support::OptionalProcessors  # or reference directly
#
#   if CONTENT_PROCESSOR_AVAILABLE
#     # use ContentProcessor
#   end

module Support
  module OptionalProcessors
    CONTENT_PROCESSOR_AVAILABLE = begin
      require_relative '../processors/content_processor'
      true
    rescue LoadError
      false
    end

    CONTENT_FILTER_AVAILABLE = begin
      require_relative '../processors/content_filter'
      true
    rescue LoadError
      false
    end

    URL_PROCESSOR_AVAILABLE = begin
      require_relative '../processors/url_processor'
      true
    rescue LoadError
      false
    end

  end
end
