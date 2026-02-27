#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Process Tlambot Broadcast Queue
# ============================================================
# Processes pending broadcast jobs queued by the webhook handler.
# Designed for cron invocation (every minute).
#
# Usage:
#   ruby bin/process_broadcast_queue.rb
#
# Cron:
#   * * * * * cd /app/data/zbnw-ng && ruby bin/process_broadcast_queue.rb
#
# Exit codes:
#   0 = success (or empty queue)
#   1 = some broadcasts failed
#   4 = fatal error
# ============================================================

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'broadcast/tlambot_queue_processor'

# Graceful shutdown on SIGINT/SIGTERM
$shutdown_requested = false
trap('INT') { $shutdown_requested = true }
trap('TERM') { $shutdown_requested = true }

queue_dir = ENV['BROADCAST_QUEUE_DIR'] || (ENV['ZBNW_DIR'] ? "#{ENV['ZBNW_DIR']}/queue/broadcast" : 'queue/broadcast')

begin
  processor = Broadcast::TlambotQueueProcessor.new(queue_dir: queue_dir)
  stats = processor.process_queue

  exit(stats[:failed] > 0 ? 1 : 0)
rescue StandardError => e
  $stderr.puts "Fatal: #{e.message}"
  $stderr.puts e.backtrace.first(5).join("\n")
  exit 4
end
