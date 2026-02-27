# frozen_string_literal: true

require 'fileutils'
require 'time'

module Broadcast
  # Separate append-only logger for broadcast operations.
  # Writes to logs/broadcast_YYYYMMDD.log.
  # Only used for actual broadcasts (not dry-run).
  class BroadcastLogger
    attr_reader :log_dir, :log_file

    def initialize(log_dir: 'logs')
      @log_dir = log_dir
      @log_file = nil
      @started = false
    end

    def start(message:, target:, account_count:, visibility:, media_path: nil)
      FileUtils.mkdir_p(@log_dir)
      filename = "broadcast_#{Time.now.strftime('%Y%m%d')}.log"
      @log_file = File.join(@log_dir, filename)
      @started = true

      write('=' * 60)
      write('BROADCAST START')
      write("Time: #{Time.now.iso8601}")
      write("Message: #{message[0..100]}#{message.length > 100 ? '...' : ''}")
      write("Target: #{target}")
      write("Accounts: #{account_count}")
      write("Visibility: #{visibility}")
      write("Media: #{media_path || 'none'}")
      write('=' * 60)
    end

    def log_account_result(account_id:, success:, status_id: nil, error: nil, attempt: 1)
      return unless @started

      if success
        write("OK  #{account_id} -> #{status_id}")
      else
        write("ERR #{account_id} (attempt #{attempt}): #{error}")
      end
    end

    def finish(success_count:, fail_count:, skipped_count: 0, duration_seconds:)
      return unless @started

      write('=' * 60)
      write('BROADCAST END')
      write("Time: #{Time.now.iso8601}")
      write("Duration: #{duration_seconds.round(1)}s")
      write("Success: #{success_count}")
      write("Failed: #{fail_count}")
      write("Skipped: #{skipped_count}") if skipped_count > 0
      write('=' * 60)
      write('')
      @started = false
    end

    private

    def write(message)
      return unless @log_file

      File.open(@log_file, 'a') do |f|
        f.puts("[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] #{message}")
      end
    end
  end
end
