#!/usr/bin/env ruby
# frozen_string_literal: true

# Vrací JSON s aktuálním stavem instance.
# Použití: ruby bin/instance_status.rb
# nebo přes SSH pipe: ssh user@host "cd /app/data/zbnw-ng && ruby bin/instance_status.rb"

require 'json'
require 'time'
require 'net/http'
require 'uri'

BASE_DIR    = ENV['ZBNW_DIR'] || File.expand_path('..', __dir__)
CONFIG_DIR  = ENV['ZBNW_CONFIG_DIR'] || File.join(BASE_DIR, 'config')
LOG_DIR     = [File.join(BASE_DIR, 'logs'), File.join(BASE_DIR, 'log')].find { |d| Dir.exist?(d) } || File.join(BASE_DIR, 'logs')
QUEUE_DIR   = ENV['IFTTT_QUEUE_DIR'] || File.join(BASE_DIR, 'queue', 'ifttt')
SCHEMA      = ENV['ZPRAVOBOT_SCHEMA'] || 'zpravobot'
NITTER_URL  = ENV['NITTER_INSTANCE'] || begin
  tw_cfg = File.join(CONFIG_DIR, 'platforms', 'twitter.yml')
  if File.exist?(tw_cfg)
    require 'yaml'
    yml = YAML.safe_load(File.read(tw_cfg, encoding: 'UTF-8')) rescue {}
    yml.dig('source', 'nitter_instance') || 'http://xn.zpravobot.news:8080'
  else
    'http://xn.zpravobot.news:8080'
  end
end

# ---------------------------------------------------------------------------
# Disk
# ---------------------------------------------------------------------------
def disk_info
  line = `df -k "#{BASE_DIR}" 2>/dev/null`.lines.last
  return {} unless line

  parts = line.split
  return {} if parts.size < 4

  used_kb  = parts[2].to_i
  avail_kb = parts[3].to_i
  total_kb = used_kb + avail_kb
  percent  = total_kb > 0 ? ((used_kb.to_f / total_kb) * 100).round : 0

  {
    used_gb:  (used_kb  / 1_048_576.0).round(1),
    total_gb: (total_kb / 1_048_576.0).round(1),
    percent:  percent
  }
rescue StandardError
  {}
end

# ---------------------------------------------------------------------------
# Runner log
# ---------------------------------------------------------------------------
ERROR_PATTERNS = [
  /\berror:/i,
  /\bfailed to\b/i,
  /\bexception:/i,
  /\btimeout:/i,
  /\bcrash/i,
  /\bfatal/i,
  /❌/
].freeze

EXCLUDE_PATTERNS = [
  /failed: 0/i,
  /errors: 0/i,
  /error_count: 0/i,
  /0 errors/i,
  /no error/i
].freeze

TIMESTAMP_RE = /\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]/

def runner_info
  today    = Time.now.strftime('%Y%m%d')
  log_path = File.join(LOG_DIR, "runner_#{today}.log")

  unless File.exist?(log_path)
    return { last_run: nil, status: 'no_log', errors_last_hour: 0 }
  end

  lines = IO.popen(['tail', '-10000', log_path]) { |io| io.readlines }

  last_run_time  = nil
  errors_last_hour = 0
  cutoff = Time.now - 3600

  lines.each do |line|
    if line.include?('Run complete')
      ts = line[TIMESTAMP_RE, 1]
      last_run_time = ts if ts
    end

    ts_str = line[TIMESTAMP_RE, 1]
    next unless ts_str

    begin
      ts = Time.parse(ts_str)
      next unless ts >= cutoff
    rescue ArgumentError
      next
    end

    next if EXCLUDE_PATTERNS.any? { |p| line =~ p }
    errors_last_hour += 1 if ERROR_PATTERNS.any? { |p| line =~ p }
  end

  status = if last_run_time.nil?
             'no_run_today'
           else
             age = Time.now - Time.parse(last_run_time)
             age > 3600 ? 'stale' : 'ok'
           end

  { last_run: last_run_time, status: status, errors_last_hour: errors_last_hour }
rescue StandardError => e
  { last_run: nil, status: "error: #{e.message}", errors_last_hour: 0 }
end

# ---------------------------------------------------------------------------
# IFTTT queue (file-based)
# ---------------------------------------------------------------------------
def ifttt_info
  pending_dir = File.join(QUEUE_DIR, 'pending')
  failed_dir  = File.join(QUEUE_DIR, 'failed')

  pending = Dir.exist?(pending_dir) ? Dir.glob(File.join(pending_dir, '*.json')).size : 0
  failed  = Dir.exist?(failed_dir)  ? Dir.glob(File.join(failed_dir,  '*.json')).reject { |f| File.basename(f).start_with?('DEAD_') }.size : 0

  { pending: pending, failed: failed }
rescue StandardError
  { pending: -1, failed: -1 }
end

# ---------------------------------------------------------------------------
# Pauzované zdroje (z YAML + DB)
# ---------------------------------------------------------------------------
def paused_sources
  begin
    require 'pg'
    pg_ok = true
  rescue LoadError
    pg_ok = false
  end

  sources_dir = File.join(CONFIG_DIR, 'sources')
  return [] unless Dir.exist?(sources_dir)

  db_rows = {}
  if pg_ok
    begin
      require_relative '../lib/utils/database_helpers'
      DatabaseHelpers.validate_schema!(SCHEMA)
      conn = PG.connect(
        host:     ENV['ZPRAVOBOT_DB_HOST'] || 'localhost',
        port:     (ENV['ZPRAVOBOT_DB_PORT'] || 5432).to_i,
        dbname:   ENV['ZPRAVOBOT_DB_NAME'] || 'zpravobot',
        user:     ENV['ZPRAVOBOT_DB_USER'] || 'zpravobot',
        password: ENV['ZPRAVOBOT_DB_PASSWORD'] || ''
      )
      conn.exec("SET search_path TO #{SCHEMA}")
      result = conn.exec('SELECT source_id, disabled_at FROM source_state WHERE disabled_at IS NOT NULL')
      result.each { |r| db_rows[r['source_id']] = r['disabled_at'] }
      conn.close
    rescue StandardError
      # DB nedostupná — pokračujeme jen z YAML
    end
  end

  paused = []

  Dir.glob(File.join(sources_dir, '*.yml')).sort.each do |path|
    source_id = File.basename(path, '.yml')
    content   = File.read(path, encoding: 'UTF-8') rescue next

    yaml_disabled  = content.match?(/^enabled:\s*false/)
    db_disabled_at = db_rows[source_id]

    next unless yaml_disabled || db_disabled_at

    paused_at     = content[/^#\s*paused_at:\s*(.+)$/, 1]&.strip
    paused_reason = content[/^#\s*paused_reason:\s*(.+)$/, 1]&.strip

    since = paused_at || (db_disabled_at ? db_disabled_at.to_s[0, 16] : nil)

    paused << { source: source_id, since: since, reason: paused_reason }
  end

  paused
rescue StandardError
  []
end

# ---------------------------------------------------------------------------
# Nitter health
# ---------------------------------------------------------------------------
def nitter_status
  uri = URI.parse(NITTER_URL)
  http = Net::HTTP.new(uri.host, uri.port)
  http.open_timeout = 3
  http.read_timeout = 5
  resp = http.get('/')
  resp.code.to_i < 500 ? 'ok' : "http_#{resp.code}"
rescue Errno::ECONNREFUSED
  'down'
rescue Net::OpenTimeout, Errno::ETIMEDOUT
  'timeout'
rescue StandardError => e
  "error: #{e.class}"
end

# ---------------------------------------------------------------------------
# IFTTT log errors last hour
# ---------------------------------------------------------------------------
def ifttt_errors_last_hour
  today    = Time.now.strftime('%Y%m%d')
  log_path = File.join(LOG_DIR, "ifttt_#{today}.log")
  return 0 unless File.exist?(log_path)

  cutoff = Time.now - 3600
  count  = 0

  IO.popen(['tail', '-5000', log_path]) do |io|
    io.each_line do |line|
      ts_str = line[TIMESTAMP_RE, 1]
      next unless ts_str
      begin
        next unless Time.parse(ts_str) >= cutoff
      rescue ArgumentError
        next
      end
      next if EXCLUDE_PATTERNS.any? { |p| line =~ p }
      count += 1 if ERROR_PATTERNS.any? { |p| line =~ p }
    end
  end

  count
rescue StandardError
  0
end

# ---------------------------------------------------------------------------
# Assemble
# ---------------------------------------------------------------------------
runner = runner_info
ifttt  = ifttt_info

result = {
  timestamp:      Time.now.strftime('%Y-%m-%d %H:%M:%S'),
  disk:           disk_info,
  runner:         runner,
  ifttt:          ifttt,
  paused_sources: paused_sources,
  errors_last_hour: {
    runner: runner[:errors_last_hour],
    ifttt:  ifttt_errors_last_hour
  },
  nitter: { status: nitter_status }
}

puts JSON.generate(result)
