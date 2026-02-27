# frozen_string_literal: true

# ============================================================
# Loggable Mixin - Unified logging for ZBNW-NG components
# ============================================================
#
# Provides a `log` method that integrates with the centralized
# Logging module when available, falling back to puts-based
# output when it's not set up (tests, standalone scripts).
#
# Usage:
#   class MyClass
#     include Support::Loggable
#
#     def do_work
#       log "Starting work"
#       log "Something went wrong", level: :error
#       log "Completed!", level: :success
#     end
#   end
#
# Supported levels: :info, :debug, :warn, :error, :success
#
# When Logging is set up (entry points call Logging.setup):
#   - All messages go to file log + stdout via Logging module
#   - :success maps to INFO severity in file logs
#
# When Logging is NOT set up:
#   - Falls back to puts with emoji prefixes (current behavior)
#
# ============================================================

module Support
  module Loggable
    LEVEL_PREFIXES = {
      error:   '❌',
      warn:    '⚠️',
      success: '✅',
      debug:   '🔍',
      info:    'ℹ️'
    }.freeze

    private

    # Log a message with optional level
    #
    # @param message [String] The message to log
    # @param level [Symbol] :info, :debug, :warn, :error, or :success
    def log(message, level: :info)
      prefix_tag = log_class_prefix
      full_message = "[#{prefix_tag}] #{message}"

      if logging_available?
        case level
        when :error   then Logging.error(full_message)
        when :warn    then Logging.warn(full_message)
        when :debug   then Logging.debug(full_message)
        when :success then Logging.info(full_message)
        else               Logging.info(full_message)
        end
      else
        emoji = LEVEL_PREFIXES[level] || LEVEL_PREFIXES[:info]
        puts "#{emoji} [#{prefix_tag}] #{message}"
      end
    end

    # Convenience aliases matching PostProcessor/EditDetector convention
    def log_info(msg);  log(msg, level: :info);  end
    def log_debug(msg); log(msg, level: :debug); end
    def log_warn(msg);  log(msg, level: :warn);  end
    def log_error(msg); log(msg, level: :error); end

    # Derive class name prefix for log messages
    # @return [String] Short class name (without module path)
    def log_class_prefix
      self.class.name&.split('::')&.last || 'Unknown'
    end

    # Check if centralized Logging module is available and set up
    # @return [Boolean]
    def logging_available?
      defined?(::Logging) && ::Logging.respond_to?(:setup?) && ::Logging.setup?
    end
  end
end
