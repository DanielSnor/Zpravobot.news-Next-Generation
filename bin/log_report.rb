#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Log Report — parsuje logy zbnw-ng, vrací strukturovaný JSON
# ============================================================
#
# Určeno ke spuštění na prod serveru; výstup (čistý JSON na
# stdout) si klient stáhne a provede analýzu.
#
# Usage:
#   ruby bin/log_report.rb                               # včera 07:00 → dnes 07:00
#   ruby bin/log_report.rb --date 2026-04-16             # 2026-04-16 07:00 → 2026-04-17 07:00
#   ruby bin/log_report.rb --hours 12                    # posledních 12 hodin
#   ruby bin/log_report.rb --from "2026-04-16 08:00" --to "2026-04-16 20:00"
#   ruby bin/log_report.rb --pretty                      # odsazený JSON
# ============================================================

BASE_DIR = File.expand_path('..', __dir__)
LOG_DIR  = [File.join(BASE_DIR, 'logs'), File.join(BASE_DIR, 'log')]
           .find { |d| Dir.exist?(d) && Dir.glob(File.join(d, '*.log')).any? }

require 'json'
require 'date'
require 'optparse'
require 'time'

# ── CLI ──────────────────────────────────────────────────────

options = { pretty: false }

OptionParser.new do |opts|
  opts.banner = 'Usage: ruby bin/log_report.rb [options]'
  opts.on('--date DATE',        'Okno: DATE 07:00 → DATE+1 07:00')    { |v| options[:date] = v }
  opts.on('--hours N', Integer, 'Okno: posledních N hodin')           { |v| options[:hours] = v }
  opts.on('--from FROM',        'Začátek okna: "YYYY-MM-DD HH:MM"')   { |v| options[:from] = v }
  opts.on('--to TO',            'Konec okna: "YYYY-MM-DD HH:MM"')     { |v| options[:to] = v }
  opts.on('--pretty',           'Odsazený JSON výstup')               { options[:pretty] = true }
  opts.on('-h', '--help')       { puts opts; exit }
end.parse!

# ── Časové okno ───────────────────────────────────────────────

now = Time.now

window_from, window_to =
  if options[:hours]
    [now - (options[:hours] * 3600), now]
  elsif options[:from] && options[:to]
    [Time.parse(options[:from]), Time.parse(options[:to])]
  elsif options[:date]
    d = Date.parse(options[:date])
    n = d + 1
    [Time.new(d.year, d.month, d.day, 7, 0, 0),
     Time.new(n.year, n.month, n.day, 7, 0, 0)]
  else
    y = now - 86_400
    [Time.new(y.year, y.month, y.day, 7, 0, 0),
     Time.new(now.year, now.month, now.day, 7, 0, 0)]
  end

# ── Pomocníci pro log soubory ─────────────────────────────────

def dates_in_window(t_from, t_to)
  dates = []
  d = Date.new(t_from.year, t_from.month, t_from.day)
  last = Date.new(t_to.year, t_to.month, t_to.day)
  while d <= last
    dates << d
    d += 1
  end
  dates
end

def log_files_for(prefix, t_from, t_to)
  dates_in_window(t_from, t_to).map { |d|
    File.join(LOG_DIR, "#{prefix}_#{d.strftime('%Y%m%d')}.log")
  }.select { |p| File.exist?(p) }
end

def foreach_line(path, &block)
  File.open(path, 'r:UTF-8:UTF-8') do |f|
    f.each_line { |line| block.call(line) }
  end
rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
  File.open(path, 'r:binary') do |f|
    f.each_line { |line| block.call(line.encode('UTF-8', invalid: :replace, undef: :replace)) }
  end
end

# Vrátí Time ze začátku log řádku (full timestamp [YYYY-MM-DD HH:MM:SS]).
# Řádky s emoji shorttimestampem ([HH:MM:SS] ℹ️ ...) vrátí nil → přeskočeny.
TIMESTAMP_RE = /^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]/

def parse_ts(line)
  m = TIMESTAMP_RE.match(line)
  Time.parse(m[1]) if m
rescue ArgumentError
  nil
end

def in_window?(line, t_from, t_to)
  ts = parse_ts(line)
  ts && ts >= t_from && ts < t_to
end

PLATFORMS = %w[facebook instagram youtube bluesky rss twitter].freeze

def platform_of(source_id)
  PLATFORMS.find { |p| source_id.end_with?("_#{p}") }
end

# Normalizuje chybovou zprávu: odstraní URL, dlouhá čísla, IP adresy.
def normalize_error(msg)
  msg.gsub(%r{https?://\S+}, '<URL>')
     .gsub(/\b\d{7,}\b/, '<ID>')
     .gsub(/\b\d{1,3}(?:\.\d{1,3}){3}\b(?::\d+)?/, '<IP>')
     .strip
end

# ── Countery ──────────────────────────────────────────────────

runner_published_total  = 0
runner_errors_total     = 0
runner_warnings_total   = 0
platform_published      = Hash.new(0)
platform_errors         = Hash.new(0)
runner_error_messages   = Hash.new(0)

ifttt_published_total        = 0
ifttt_errors_total           = 0
ifttt_queue_skipped_total    = 0  # catch-all z Queue processing complete: zahrnuje already_published, video_dedup, content filter (reposts/replies), no_config, older_version
ifttt_failed_total           = 0
ifttt_error_messages         = Hash.new(0)

ifttt_events = {
  video_dedup_skipped:  0,
  video_fallback_thumb: 0,
  repost_corrections:   0,
  edit_skipped:         0,
  media_size_skipped:   0,
}

ifttt_skips = {
  deleted_original: 0,  # tweet smazán: HTTP 404 fetching HTML nebo Status not found
  duplicate_post:   0,  # already_published — logováno jen při DEBUG=1; na prod bez DEBUG bude 0
}

# ── Runner logy ───────────────────────────────────────────────

log_files_for('runner', window_from, window_to).each do |path|
  foreach_line(path) do |line|
    next unless in_window?(line, window_from, window_to)

    case line
    when /\[Runner\] Run complete:.*\bpublished: (\d+).*\berrors: (\d+)/
      runner_published_total += $1.to_i
      runner_errors_total    += $2.to_i

    when /\] INFO: \[PostProcessor\] \[([^\]]+)\] Published:/
      plat = platform_of($1)
      platform_published[plat] += 1 if plat

    when /\] ERROR: \[Runner\] \[([^\]]+)\] Error: (.+)/
      source_id, msg = $1, $2
      plat = platform_of(source_id)
      platform_errors[plat] += 1 if plat
      runner_error_messages[normalize_error(msg)] += 1

    when /\] WARN:/
      runner_warnings_total += 1
    end
  end
end

# ── IFTTT logy ────────────────────────────────────────────────

log_files_for('ifttt_processor', window_from, window_to).each do |path|
  foreach_line(path) do |line|
    next unless in_window?(line, window_from, window_to)

    case line
    when /Queue processing complete:.*\bpublished: (\d+).*\bskipped: (\d+).*\bfailed: (\d+)/
      ifttt_published_total        += $1.to_i
      ifttt_queue_skipped_total    += $2.to_i
      ifttt_failed_total           += $3.to_i

    when /HTTP 404 fetching HTML/
      ifttt_skips[:deleted_original] += 1

    when /\[MastodonPublisher\] Status not found:/
      ifttt_skips[:deleted_original] += 1

    when /\[PostProcessor\] .+ Already published:/
      # Pouze při DEBUG=1 — na prod bez DEBUG bude 0
      ifttt_skips[:duplicate_post] += 1

    when /\] ERROR: (.+)/
      msg = $1
      # Přeskočit deleted_original patterny — jsou v ifttt_skips, ne v errors
      unless msg.match?(/HTTP 404 fetching HTML|Status not found:/)
        ifttt_error_messages[normalize_error(msg)] += 1
        ifttt_errors_total += 1
      end

    when /Video dedup \(pHash\): skipping duplicate/
      ifttt_events[:video_dedup_skipped] += 1

    when /Video upload failed, thumbnail uploaded as fallback/
      ifttt_events[:video_fallback_thumb] += 1

    when /Corrected is_repost from fallback_post/
      ifttt_events[:repost_corrections] += 1

    when /Skipping older version/
      ifttt_events[:edit_skipped] += 1

    when /Skipping media over \d+MB/
      ifttt_events[:media_size_skipped] += 1
    end
  end
end

# IFTTT zpracovává výhradně twitter zdroje
platform_published['twitter'] += ifttt_published_total
platform_errors['twitter']    += ifttt_errors_total  # deleted_original jsou v ifttt_skips, ne zde

# ── Profile sync ─────────────────────────────────────────────

# Daily log (profile_sync_YYYYMMDD.log): full timestamps, datum z názvu souboru.
# Platform logy (profile_sync_twitter.log atd.): emoji formát [HH:MM:SS] ℹ️,
# datum z posledního řádku "=== Profile sync finished ===".
# Platform logy jsou appendované — hledáme stats posledního běhu.

def parse_profile_sync_platform(path)
  last_run = nil
  last = { synced: nil, skipped: nil, errors: nil }
  cur  = { synced: nil, skipped: nil, errors: nil }
  foreach_line(path) do |line|
    case line
    when /Synced:\s+(\d+)/   then cur[:synced]  = $1.to_i
    when /Skipped:\s+(\d+)/  then cur[:skipped] = $1.to_i
    when /Errors:\s+(\d+)/   then cur[:errors]  = $1.to_i
    when /^\[(\d{4}-\d{2}-\d{2}) \d{2}:\d{2}:\d{2}\] === Profile sync finished/
      last_run = $1
      last = cur.dup
      cur  = { synced: nil, skipped: nil, errors: nil }
    end
  end
  # Pokud běh ještě neskončil (chybí "finished"), vezmi aktuální hodnoty
  last_run ||= nil
  result = last[:synced] ? last : cur
  { last_run: last_run, **result }
end

profile_sync = []

# 1. Denní log — nejbližší k window_to (hledá 14 dní zpátky)
search_date = Date.new(window_to.year, window_to.month, window_to.day)
14.times do
  path = File.join(LOG_DIR, "profile_sync_#{search_date.strftime('%Y%m%d')}.log")
  if File.exist?(path)
    synced = skipped = errors = nil
    foreach_line(path) do |line|
      case line
      when /\] INFO: Synced:\s+(\d+)/  then synced  = $1.to_i
      when /\] INFO: Skipped:\s+(\d+)/ then skipped = $1.to_i
      when /\] INFO: Errors:\s+(\d+)/  then errors  = $1.to_i
      end
    end
    if synced
      profile_sync << { type: 'daily', last_run: search_date.to_s,
                        synced: synced, skipped: skipped, errors: errors }
      break
    end
  end
  search_date -= 1
end

# 2. Platform logy (stálé soubory, appendované)
%w[twitter facebook instagram youtube bluesky rss].each do |plat|
  path = File.join(LOG_DIR, "profile_sync_#{plat}.log")
  next unless File.exist?(path)
  stats = parse_profile_sync_platform(path)
  next unless stats[:synced]
  profile_sync << { type: plat, last_run: stats[:last_run],
                    synced: stats[:synced], skipped: stats[:skipped], errors: stats[:errors] }
end

# ── Platform stats ────────────────────────────────────────────

platforms_out = {}
PLATFORMS.each do |plat|
  pub  = platform_published[plat]
  err  = platform_errors[plat]
  total = pub + err
  platforms_out[plat] = {
    published:  pub,
    errors:     err,
    error_rate: total > 0 ? (err.to_f / total).round(4) : 0.0,
  }
end

# ── Top errors ────────────────────────────────────────────────

top_runner_errors = runner_error_messages
  .sort_by { |_, c| -c }.first(10)
  .map { |msg, count| { message: msg, count: count } }

top_ifttt_errors = ifttt_error_messages
  .sort_by { |_, c| -c }.first(5)
  .map { |msg, count| { message: msg, count: count } }

# ── Výstup ────────────────────────────────────────────────────

report = {
  window: {
    from: window_from.strftime('%Y-%m-%d %H:%M:%S'),
    to:   window_to.strftime('%Y-%m-%d %H:%M:%S'),
  },
  summary: {
    runner_published:         runner_published_total,
    ifttt_published:          ifttt_published_total,
    total:                    runner_published_total + ifttt_published_total,
    runner_errors:            runner_errors_total,
    runner_warnings:          runner_warnings_total,
    ifttt_errors:             ifttt_errors_total,
    ifttt_queue_skipped_total: ifttt_queue_skipped_total,
    ifttt_failed:             ifttt_failed_total,
  },
  platforms:         platforms_out,
  ifttt_events:      ifttt_events,
  ifttt_skips:       ifttt_skips,
  top_runner_errors: top_runner_errors,
  top_ifttt_errors:  top_ifttt_errors,
  profile_sync:      profile_sync,
}

puts options[:pretty] ? JSON.pretty_generate(report) : report.to_json
