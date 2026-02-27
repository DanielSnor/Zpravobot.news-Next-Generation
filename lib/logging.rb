# frozen_string_literal: true
require 'date'
require 'logger'
require 'fileutils'
# ============================================================
# Centralized Logging for ZBNW-NG
# ============================================================
# Provides daily rotating file logs with configurable retention.
#
# Features:
#   - Daily rotation at midnight (new file per day)
#   - Files named as: runner_20260119.log
#   - Automatic cleanup of files older than 7 days
#   - Outputs to both file and stdout
#   - Thread-safe
#
# Usage:
#   # In entry point (bin/run_zbnw.rb):
#   Logging.setup(name: 'runner', dir: 'logs')
#
#   # Anywhere in code:
#   Logging.info("Processing source")
#   Logging.error("Something went wrong")
#   Logging.debug("Verbose info")  # Only if DEBUG=1
#
# ============================================================
module Logging
  # Default configuration
  DEFAULT_KEEP_DAYS = 7
  DEFAULT_DIR = 'logs'
  class << self
    attr_reader :logger, :file_logger
    # Setup logging - call once at application start
    # @param name [String] Log file prefix (e.g., 'runner' -> runner_20260119.log)
    # @param dir [String] Directory for log files
    # @param keep_days [Integer] Number of days to keep old logs
    # @param stdout [Boolean] Also output to stdout (default: true)
    def setup(name:, dir: DEFAULT_DIR, keep_days: DEFAULT_KEEP_DAYS, stdout: true)
      @name = name
      @dir = dir
      @keep_days = keep_days
      @current_date = Date.today
      FileUtils.mkdir_p(dir)
      
      # Create log file with today's date
      log_path = log_path_for_date(@current_date)
      # File logger (no built-in rotation - we handle it via filename)
      @file_logger = Logger.new(log_path)
      @file_logger.formatter = method(:format_message)
      # Combined logger (file + optional stdout)
      if stdout
        @stdout_logger = Logger.new($stdout)
        @stdout_logger.formatter = method(:format_message_short)
        @logger = MultiLogger.new(@file_logger, @stdout_logger)
      else
        @logger = @file_logger
      end
      @logger.level = ENV['DEBUG'] ? Logger::DEBUG : Logger::INFO
      # Cleanup old log files
      cleanup_old_logs
      info("Logging initialized: #{log_path} (keep: #{keep_days} days)")
      @logger
    end
    # Quick setup with defaults - for backward compatibility
    def setup_default(name: 'app')
      setup(name: name)
    end
    # Convenience methods
    def info(message)
      ensure_setup
      check_date_rollover
      @logger.info(message)
    end
    def debug(message)
      ensure_setup
      check_date_rollover
      @logger.debug(message)
    end
    def warn(message)
      ensure_setup
      check_date_rollover
      @logger.warn(message)
    end
    def error(message)
      ensure_setup
      check_date_rollover
      @logger.error(message)
    end
    def fatal(message)
      ensure_setup
      check_date_rollover
      @logger.fatal(message)
    end
    # Check if logger is set up
    def setup?
      !@logger.nil?
    end
    private
    def ensure_setup
      setup_default unless setup?
    end
    # Generate log path for a specific date
    # @param date [Date] Date for log file
    # @return [String] Full path to log file
    def log_path_for_date(date)
      filename = "#{@name}_#{date.strftime('%Y%m%d')}.log"
      File.join(@dir, filename)
    end
    # Check if we need to roll over to a new day's log file
    def check_date_rollover
      return unless @file_logger
      
      today = Date.today
      return if @current_date == today
      
      # Date changed - roll over to new file
      @current_date = today
      new_path = log_path_for_date(today)
      
      # Close old logger and create new one
      @file_logger.close rescue nil
      @file_logger = Logger.new(new_path)
      @file_logger.formatter = method(:format_message)
      @file_logger.level = ENV['DEBUG'] ? Logger::DEBUG : Logger::INFO
      
      # Update multi-logger if used
      if @logger.is_a?(MultiLogger)
        @logger.update_file_logger(@file_logger)
      else
        @logger = @file_logger
      end
      
      # Cleanup old logs on date change
      cleanup_old_logs
      
      # Log the rollover
      @logger.info("Log rolled over to: #{new_path}")
    end
    # Remove log files older than keep_days
    def cleanup_old_logs
      return unless @dir && @name && @keep_days
      cutoff_date = Date.today - @keep_days
      pattern = File.join(@dir, "#{@name}_*.log")
      
      Dir.glob(pattern).each do |file|
        # Extract date from filename (name_YYYYMMDD.log)
        basename = File.basename(file, '.log')
        date_str = basename.split('_').last
        
        begin
          file_date = Date.strptime(date_str, '%Y%m%d')
          if file_date < cutoff_date
            File.delete(file)
            # Log to stdout only (file might be the one we're deleting)
            puts "[#{Time.now.strftime('%H:%M:%S')}] 🗑️  Deleted old log: #{File.basename(file)}"
          end
        rescue ArgumentError
          # Skip files that don't match date pattern
          next
        end
      end
    end
    # Full format for file logs
    def format_message(severity, time, _progname, msg)
      "[#{time.strftime('%Y-%m-%d %H:%M:%S')}] #{severity}: #{msg}\n"
    end
    # Shorter format for stdout (no date, just time)
    def format_message_short(severity, time, _progname, msg)
      prefix = case severity
               when 'ERROR', 'FATAL' then '❌'
               when 'WARN' then '⚠️ '
               when 'DEBUG' then '🔍'
               else 'ℹ️ '
               end
      "[#{time.strftime('%H:%M:%S')}] #{prefix} #{msg}\n"
    end
  end
  # Multi-target logger - writes to multiple destinations
  class MultiLogger
    def initialize(file_logger, stdout_logger)
      @file_logger = file_logger
      @stdout_logger = stdout_logger
    end
    def level=(level)
      @file_logger.level = level
      @stdout_logger.level = level
    end
    def update_file_logger(new_logger)
      @file_logger = new_logger
    end
    %i[debug info warn error fatal].each do |method|
      define_method(method) do |message = nil, &block|
        @file_logger.send(method, message, &block)
        @stdout_logger.send(method, message, &block)
      end
    end
    def add(severity, message = nil, progname = nil, &block)
      @file_logger.add(severity, message, progname, &block)
      @stdout_logger.add(severity, message, progname, &block)
    end
    def close
      @file_logger.close
      @stdout_logger.close
    end
  end
end
