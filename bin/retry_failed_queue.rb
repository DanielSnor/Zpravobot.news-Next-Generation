#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# IFTTT Failed Queue Retry
# ============================================================
# Zpracuje soubory z queue/ifttt/failed/ a zkusí je znovu.
# Permanentní chyby a příliš staré soubory → DEAD_ prefix.
# Ostatní → přesunout zpět do pending/ k dalšímu zpracování.
#
# Spouštět 1x za hodinu cronem (viz cron_retry_failed.sh).
#
# Usage:
#   ruby bin/retry_failed_queue.rb             # prod
#   ruby bin/retry_failed_queue.rb --dry-run   # nic nepřesouvá
#   ruby bin/retry_failed_queue.rb --verbose   # detailní výstup
#
# Exit codes:
#   0 = success
#   1 = fatal error
# ============================================================

require 'json'
require 'fileutils'
require 'time'
require 'optparse'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

MAX_RETRIES    = 1           # Po 1 neúspěšném retry → DEAD (celkem 2 pokusy)
MAX_RETRY_AGE  = 6 * 3600   # 6 hodin od failed_at — tweet je pak příliš starý

PERMANENT_ERRORS = [
  /Invalid JSON/i,
  /tweet likely deleted/i,
  /No config found/i,
  /unknown bot_id/i,
  /Text cannot be empty/i
].freeze

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def log(msg)
  ts = Time.now.strftime('%H:%M:%S')
  puts "[#{ts}] #{msg}"
  $stdout.flush
end

def permanent_error?(reason)
  return false if reason.nil? || reason.empty?
  PERMANENT_ERRORS.any? { |pattern| reason.match?(pattern) }
end

def too_old?(failed_at_str)
  return false if failed_at_str.nil? || failed_at_str.empty?
  failed_at = Time.parse(failed_at_str)
  (Time.now - failed_at) > MAX_RETRY_AGE
rescue ArgumentError, TypeError
  false
end

def max_retries_exceeded?(retry_count)
  retry_count.to_i >= MAX_RETRIES
end

def mark_dead(filepath, dead_reason, data)
  data['_failure'] ||= {}
  data['_failure']['dead_reason'] = dead_reason
  data['_failure']['dead_at']     = Time.now.iso8601
  File.write(filepath, JSON.pretty_generate(data))
  new_path = File.join(File.dirname(filepath), "DEAD_#{File.basename(filepath)}")
  File.rename(filepath, new_path)
  new_path
end

def move_to_pending(filepath, data, pending_dir)
  failure = data['_failure'] ||= {}
  current_count = failure['retry_count'].to_i
  failure['retry_count']    = current_count + 1
  failure['last_retry_at']  = Time.now.iso8601
  File.write(filepath, JSON.pretty_generate(data))
  dest = File.join(pending_dir, File.basename(filepath))
  FileUtils.mv(filepath, dest)
  dest
end

# ---------------------------------------------------------------------------
# Option parsing
# ---------------------------------------------------------------------------

options = { dry_run: false, verbose: false }

OptionParser.new do |opts|
  opts.banner = "Usage: #{$PROGRAM_NAME} [options]"

  opts.on('--dry-run', 'Zobrazit co by se stalo, nic nepřesouvat') do
    options[:dry_run] = true
  end

  opts.on('--verbose', 'Detailní výstup') do
    options[:verbose] = true
  end

  opts.on('-h', '--help', 'Zobrazit nápovědu') do
    puts opts
    exit 0
  end
end.parse!

dry_run = options[:dry_run]
verbose = options[:verbose]

# ---------------------------------------------------------------------------
# Directories
# ---------------------------------------------------------------------------

queue_base  = ENV['IFTTT_QUEUE_DIR'] ||
              (ENV['ZBNW_DIR'] ? "#{ENV['ZBNW_DIR']}/queue/ifttt" : '/app/data/zbnw-ng/queue/ifttt')
failed_dir  = File.join(queue_base, 'failed')
pending_dir = File.join(queue_base, 'pending')

unless Dir.exist?(failed_dir)
  log "ℹ️  Failed dir neexistuje: #{failed_dir}"
  exit 0
end

# ---------------------------------------------------------------------------
# Candidates: *.json v failed/, bez DEAD_* prefixu
# ---------------------------------------------------------------------------

candidates = Dir.glob(File.join(failed_dir, '*.json'))
                .reject { |f| File.basename(f).start_with?('DEAD_') }
                .sort

if candidates.empty?
  log 'ℹ️  Retry failed queue: žádní kandidáti' if verbose
  exit 0
end

log "ℹ️  Retry failed queue: #{candidates.size} kandidátů#{dry_run ? ' [DRY RUN]' : ''}"

# ---------------------------------------------------------------------------
# Process each candidate
# ---------------------------------------------------------------------------

queued = 0
dead   = 0

candidates.each do |filepath|
  filename = File.basename(filepath)

  begin
    data = JSON.parse(File.read(filepath))
  rescue JSON::ParserError => e
    log "⚠️  Nelze parsovat JSON v #{filename}: #{e.message}"
    next
  end

  failure     = data['_failure'] || {}
  reason      = failure['reason'].to_s
  failed_at   = failure['failed_at'].to_s
  retry_count = failure['retry_count'].to_i

  log "   #{filename}: reason=#{reason.inspect}, retry_count=#{retry_count}, failed_at=#{failed_at}" if verbose

  if permanent_error?(reason)
    log "💀 DEAD (permanent):  #{filename} — #{reason}"
    unless dry_run
      mark_dead(filepath, 'permanent_error', data)
    end
    dead += 1
    next
  end

  if too_old?(failed_at)
    age_h = failed_at.empty? ? '?' : ((Time.now - Time.parse(failed_at)) / 3600).round(1)
    log "💀 DEAD (too old):    #{filename} — #{age_h}h old"
    unless dry_run
      mark_dead(filepath, 'too_old', data)
    end
    dead += 1
    next
  end

  if max_retries_exceeded?(retry_count)
    log "💀 DEAD (max_retries): #{filename} — retry_count=#{retry_count}"
    unless dry_run
      mark_dead(filepath, 'max_retries_exceeded', data)
    end
    dead += 1
    next
  end

  attempt = retry_count + 1
  log "♻️   Retry: #{filename} (attempt #{attempt}/#{MAX_RETRIES})"
  unless dry_run
    move_to_pending(filepath, data, pending_dir)
  end
  queued += 1
end

log "✅ Retry complete: #{queued} queued for retry, #{dead} marked as DEAD"
