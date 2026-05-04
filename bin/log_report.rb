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
#   ruby bin/log_report.rb --source 12345_bluesky        # slim report jen pro daný source_id
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
  opts.on('--source SOURCE_ID', 'Slim report jen pro daný source_id') { |v| options[:source] = v }
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

# ── Per-source helpery ───────────────────────────────────────
#
# Sdíleno problematic_sources sekcí (běží pro zdroje vyplavané z health
# snapshotů) a slim --source větví (běží pro jeden explicitně zadaný zdroj).

HEALTH_ENTRY_LIMIT = 20  # max last_entries per problematický zdroj

LOG_LINE_RE = /^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]\s*(?:INFO|ERROR|WARN|DEBUG|FATAL):\s*/

# Source-less helpery, které sub-stepují publish a v jejichž log řádcích nefiguruje source_id.
# Jejich chyby je třeba korelovat časem k source chybě (PostProcessor Publish failed).
INFRA_LOGGERS = %w[MastodonPublisher SyndicationMediaFetcher].freeze

# ERROR/WARN řádky z infra loggerů bez source_id.
# - Standardní infra loggery: [MastodonPublisher], [SyndicationMediaFetcher]
# - Speciál: [PostProcessor] následovaný 2+ mezerami = "Dummy image upload failed"
#   (běžné PostProcessor řádky mají [PostProcessor] [source_id] s jednou mezerou).
INFRA_LINE_RE = /\] (?:ERROR|WARN): (?:\[(?:#{INFRA_LOGGERS.join('|')})\]|\[PostProcessor\] {2,})/

# Korelační okno: infra chyba předchází source chybě. MastodonPublisher retry sekvence
# trvá ~20-25s, finální ERROR přijde ~10s před PostProcessor ERROR. Okno [-30s, 0s].
INFRA_CORRELATION_WINDOW = 30

# Pro daný source_id v rámci okna vrátí:
# - published count (jen runner — IFTTT nelogguje per-source publish)
# - source ERROR/WARN entries: count, agregaci po normalizované zprávě, posledních N raw
# - korelované infra řádky per source chyba (heuristika, ±30s před, riziko false positive
#   při paralelní publikaci více zdrojů)
# - agregované infra chyby za celé okno (ground truth, bez vazby na zdroj)
def source_log_detail(source_id, runner_files, ifttt_files, t_from, t_to, limit)
  source_pattern    = /\[#{Regexp.escape(source_id)}\]/
  published_pattern = /\] INFO: \[PostProcessor\] \[#{Regexp.escape(source_id)}\] Published:/
  source_entries = []
  infra_entries  = []
  published      = 0

  (runner_files + ifttt_files).each do |path|
    foreach_line(path) do |line|
      next unless in_window?(line, t_from, t_to)

      if line.match?(source_pattern)
        if line.match?(/\] (?:ERROR|WARN):/)
          ts = parse_ts(line)
          next unless ts
          level   = line.include?('] ERROR:') ? 'error' : 'warn'
          message = line.sub(LOG_LINE_RE, '').strip
          source_entries << { ts: ts, level: level, message: message }
        elsif line.match?(published_pattern)
          published += 1
        end
      elsif line.match?(INFRA_LINE_RE)
        ts = parse_ts(line)
        next unless ts
        level   = line.include?('] ERROR:') ? 'error' : 'warn'
        message = line.sub(LOG_LINE_RE, '').strip
        infra_entries << { ts: ts, level: level, message: message }
      end
    end
  end

  # Agregace source chyb + per-error korelace s infra řádky v okně [-N, 0] sec
  agg = Hash.new { |h, k| h[k] = { count: 0, first: nil, last: nil, _correlated: {} } }
  source_entries.each do |e|
    a = agg[normalize_error(e[:message])]
    a[:count] += 1
    a[:first] ||= e[:ts].strftime('%H:%M:%S')
    a[:last]   = e[:ts].strftime('%H:%M:%S')

    infra_entries.each do |i|
      diff = e[:ts] - i[:ts]
      next unless diff >= 0 && diff <= INFRA_CORRELATION_WINDOW
      key = "#{i[:ts].to_i}|#{i[:level]}|#{i[:message]}"
      a[:_correlated][key] ||= { ts: i[:ts].strftime('%H:%M:%S'),
                                 level: i[:level], message: i[:message] }
    end
  end

  errors_aggregated = agg.sort_by { |_, v| -v[:count] }.map { |msg, v|
    {
      message:          msg,
      count:            v[:count],
      first:            v[:first],
      last:             v[:last],
      correlated_lines: v[:_correlated].values,
    }
  }

  # Agregace infra chyb — ground truth, nezávisle na korelaci se source chybami
  infra_agg = Hash.new { |h, k| h[k] = { count: 0, first: nil, last: nil, level: nil } }
  infra_entries.each do |e|
    a = infra_agg[normalize_error(e[:message])]
    a[:count] += 1
    a[:first] ||= e[:ts].strftime('%H:%M:%S')
    a[:last]   = e[:ts].strftime('%H:%M:%S')
    # ERROR vyhrává nad WARN, pokud spadnou pod stejnou normalizovanou zprávu
    a[:level] = e[:level] if a[:level].nil? || e[:level] == 'error'
  end
  infra_aggregated = infra_agg.sort_by { |_, v| -v[:count] }.map { |msg, v|
    { message: msg, level: v[:level], count: v[:count], first: v[:first], last: v[:last] }
  }

  {
    published:                       published,
    total_errors:                    source_entries.size,
    errors_aggregated:               errors_aggregated,
    last_entries:                    source_entries.last(limit).map { |e|
                                       { ts: e[:ts].strftime('%H:%M:%S'),
                                         level: e[:level], message: e[:message] }
                                     },
    infrastructure_errors_in_window: infra_aggregated,
  }
end

# V kolika health snapshotech v okně se daný source_id objevil v Processing → Error Sources.
def source_health_appearances(source_id, health_dir, t_from, t_to)
  result = { count: 0, first: nil, last: nil }
  return result unless health_dir && Dir.exist?(health_dir)

  date_from_s = t_from.strftime('%Y%m%d')
  date_to_s   = t_to.strftime('%Y%m%d')

  Dir.glob(File.join(health_dir, 'health_*.json')).sort.each do |path|
    fname = File.basename(path)
    next unless (m = fname.match(/health_(\d{8})_\d{6}\.json/))
    next unless m[1] >= date_from_s && m[1] <= date_to_s

    begin
      data = JSON.parse(File.read(path, encoding: 'UTF-8'))
      ts   = Time.parse(data['timestamp'])
    rescue JSON::ParserError, ArgumentError, Errno::ENOENT
      next
    end
    next unless ts >= t_from && ts < t_to

    found = (data['checks'] || []).any? do |check|
      next false unless check['name'] == 'Processing' && check['level'] != 'ok'
      (check['details'] || []).any? do |sub|
        next false unless sub.is_a?(Hash) && sub['name'] == 'Error Sources' && sub['level'] != 'ok'
        (sub['details'] || []).any? do |src|
          src.is_a?(Hash) && src['source_id'] == source_id
        end
      end
    end

    next unless found
    result[:count] += 1
    result[:first] ||= ts.strftime('%Y-%m-%d %H:%M')
    result[:last]   = ts.strftime('%Y-%m-%d %H:%M')
  end

  result
end

# ── Slim --source režim ──────────────────────────────────────
# Když je zadán --source, vrátíme fokusovaný JSON jen pro ten jeden zdroj
# a přeskočíme veškerou globální agregaci.

if options[:source]
  source_id    = options[:source]
  runner_files = log_files_for('runner', window_from, window_to)
  ifttt_files  = log_files_for('ifttt_processor', window_from, window_to)
  detail       = source_log_detail(source_id, runner_files, ifttt_files,
                                   window_from, window_to, HEALTH_ENTRY_LIMIT)
  health_dir   = LOG_DIR ? File.join(LOG_DIR, 'health') : nil
  health       = source_health_appearances(source_id, health_dir, window_from, window_to)

  report = {
    mode: 'single_source',
    window: {
      from: window_from.strftime('%Y-%m-%d %H:%M:%S'),
      to:   window_to.strftime('%Y-%m-%d %H:%M:%S'),
    },
    source_id:                       source_id,
    platform:                        platform_of(source_id),
    published:                       detail[:published],
    errors_total:                    detail[:total_errors],
    errors_aggregated:               detail[:errors_aggregated],
    last_entries:                    detail[:last_entries],
    infrastructure_errors_in_window: detail[:infrastructure_errors_in_window],
    health_appearances:              health,
  }

  puts options[:pretty] ? JSON.pretty_generate(report) : report.to_json
  exit
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

runner_log_files = log_files_for('runner', window_from, window_to)
runner_log_files.each do |path|
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

ifttt_log_files = log_files_for('ifttt_processor', window_from, window_to)
ifttt_log_files.each do |path|
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

# ── Health JSON agregace ──────────────────────────────────────
#
# Čte log/health/health_YYYYMMDD_HHMMSS.json (jeden soubor každých ~5 min).
# Z "Processing → Error Sources" sub-checku extrahuje source_id se strukturovanými
# daty (SQL výsledek). "Problematic Sources" details jsou plain stringy — ignorujeme,
# source_id bereme ze Error Sources.

health_dir            = LOG_DIR ? File.join(LOG_DIR, 'health') : nil
health_snaps_total    = 0
health_snaps_ok       = 0
health_checks_tally   = Hash.new { |h, k| h[k] = { 'ok' => 0, 'warning' => 0, 'critical' => 0 } }
health_non_ok_map     = {}   # "check|level|message" → { check:, level:, message:, count:, first:, last: }
prob_source_map       = Hash.new { |h, k| h[k] = { count: 0, first: nil, last: nil } }

if health_dir && Dir.exist?(health_dir)
  date_from_s = window_from.strftime('%Y%m%d')
  date_to_s   = window_to.strftime('%Y%m%d')

  Dir.glob(File.join(health_dir, 'health_*.json')).sort.each do |path|
    fname = File.basename(path)
    next unless (m = fname.match(/health_(\d{8})_\d{6}\.json/))
    next unless m[1] >= date_from_s && m[1] <= date_to_s

    begin
      data = JSON.parse(File.read(path, encoding: 'UTF-8'))
      ts   = Time.parse(data['timestamp'])
    rescue JSON::ParserError, ArgumentError, Errno::ENOENT
      next
    end
    next unless ts >= window_from && ts < window_to

    health_snaps_total += 1
    health_snaps_ok    += 1 if data['overall_status'] == 'ok'

    (data['checks'] || []).each do |check|
      name  = check['name']
      level = check['level'] || 'ok'
      tally = health_checks_tally[name]
      tally[level] = (tally[level] || 0) + 1

      if level != 'ok'
        # Deduplikované non-ok události (stejná zpráva → sloučíme, first/last/count)
        key = "#{name}|#{level}|#{check['message']}"
        e   = health_non_ok_map[key] ||= {
          check: name, level: level, message: check['message'],
          occurrences: 0, first: nil, last: nil
        }
        e[:occurrences] += 1
        e[:first] ||= ts.strftime('%Y-%m-%d %H:%M')
        e[:last]   = ts.strftime('%Y-%m-%d %H:%M')

        # Extrahuj problematické source_id z Processing → Error Sources
        next unless name == 'Processing'
        (check['details'] || []).each do |sub|
          next unless sub.is_a?(Hash) &&
                      sub['name'] == 'Error Sources' &&
                      sub['level'] != 'ok'
          (sub['details'] || []).each do |src|
            next unless src.is_a?(Hash) && (sid = src['source_id'])
            s = prob_source_map[sid]
            s[:count] += 1
            s[:first] ||= ts.strftime('%Y-%m-%d %H:%M')
            s[:last]   = ts.strftime('%Y-%m-%d %H:%M')
          end
        end
      end
    end
  end
end

health_ok_rate = health_snaps_total > 0 ? (health_snaps_ok.to_f / health_snaps_total).round(4) : nil

health_out = {
  snapshots_in_window: health_snaps_total,
  snapshots_ok:        health_snaps_ok,
  ok_rate:             health_ok_rate,
  checks_summary:      health_checks_tally,
  non_ok_events:       health_non_ok_map.values.sort_by { |e| e[:first].to_s },
}

# ── Per-source detail pro problematické zdroje ────────────────

problematic_sources_out = prob_source_map
  .sort_by { |_, v| -v[:count] }
  .map do |sid, v|
    {
      source_id:          sid,
      health_appearances: v[:count],
      first_seen:         v[:first],
      last_seen:          v[:last],
      log_entries:        source_log_detail(
                            sid, runner_log_files, ifttt_log_files,
                            window_from, window_to, HEALTH_ENTRY_LIMIT
                          ),
    }
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
  top_runner_errors:    top_runner_errors,
  top_ifttt_errors:     top_ifttt_errors,
  profile_sync:         profile_sync,
  health:               health_out,
  problematic_sources:  problematic_sources_out,
}

puts options[:pretty] ? JSON.pretty_generate(report) : report.to_json
