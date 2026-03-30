#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Cleanup Duplicate Posts
# ============================================================
#
# Identifies and removes duplicate Mastodon posts caused by
# ZBNW_SCHEMA switch (zpravobot_test → zpravobot) on 2026-03-27.
#
# Duplicates = posts in zpravobot.published_posts published after
# CUTOFF_TIME where the same (source_id, post_id) was already
# published earlier via zpravobot_test schema.
#
# Usage:
#   ruby bin/cleanup_duplicate_posts.rb              # Dry run — list duplicates
#   ruby bin/cleanup_duplicate_posts.rb --delete     # Delete from Mastodon + DB
#   ruby bin/cleanup_duplicate_posts.rb --since 2026-03-27T11:00:00  # Custom cutoff
#

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'optparse'
require 'yaml'
require 'pg'
require 'net/http'
require 'uri'
require 'json'

require 'config/config_loader'
require 'state/database_connection'

# ============================================================
# CLI options
# ============================================================
options = {
  delete:  false,
  since:   '2026-03-27T10:30:00'
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby bin/cleanup_duplicate_posts.rb [options]"
  opts.on('--delete',         'Actually delete posts (default: dry run)') { options[:delete] = true }
  opts.on('--since DATETIME', 'Cutoff datetime (default: 2026-03-27T10:30:00)') { |v| options[:since] = v }
  opts.on('-h', '--help') { puts opts; exit 0 }
end.parse!

def log(msg)
  $stdout.puts "[#{Time.now.strftime('%H:%M:%S')}] #{msg}"
  $stdout.flush
end

# ============================================================
# Step 1 — Connect to DB (prod schema)
# ============================================================
config_dir = ENV.fetch('ZBNW_CONFIG_DIR',
               ENV['ZBNW_DIR'] ? "#{ENV['ZBNW_DIR']}/config" : 'config')
config_loader = Config::ConfigLoader.new(config_dir)

db_prod = State::DatabaseConnection.new(schema: 'zpravobot')
db_prod.connect
log "Connected to DB (schema: zpravobot)"

conn = db_prod.conn
cutoff = options[:since]

# ============================================================
# Step 2 — Find duplicates
# ============================================================
# Posts published in zpravobot AFTER cutoff where the same
# (source_id, post_id) exists in zpravobot_test with EARLIER published_at

log "Looking for duplicates published after #{cutoff}..."

duplicates_sql = <<~SQL
  SELECT
    p.source_id,
    p.post_id,
    p.mastodon_status_id,
    p.post_url,
    p.published_at AS prod_published_at,
    t.published_at AS test_published_at
  FROM zpravobot.published_posts p
  JOIN zpravobot_test.published_posts t
    ON p.source_id = t.source_id
   AND p.post_id   = t.post_id
  WHERE p.published_at >= $1::timestamptz
    AND t.published_at < p.published_at
    AND p.mastodon_status_id IS NOT NULL
  ORDER BY p.source_id, p.published_at
SQL

result = conn.exec_params(duplicates_sql, [cutoff])
log "Found #{result.ntuples} duplicate posts"

if result.ntuples == 0
  log "Nothing to do."
  db_prod.disconnect
  exit 0
end

# Group by source_id for display
by_source = Hash.new { |h, k| h[k] = [] }
result.each { |row| by_source[row['source_id']] << row }

puts
puts "=" * 70
puts "DUPLICATES BY SOURCE (dry run#{options[:delete] ? ' — WILL DELETE' : ''})"
puts "=" * 70
by_source.each do |source_id, rows|
  puts "  #{source_id}: #{rows.size} posts"
end
puts
puts "Total: #{result.ntuples} posts"
puts

unless options[:delete]
  log "Dry run. Use --delete to actually remove posts."
  db_prod.disconnect
  exit 0
end

# ============================================================
# Step 3 — Load credentials (source_id → mastodon_account → token)
# ============================================================
log "Loading source configs and credentials..."

source_account_map = {}
config_loader.load_all_sources.each do |source|
  sid  = source[:id]&.to_s
  acct = source.dig(:target, :mastodon_account)&.to_s
  source_account_map[sid] = acct if sid && acct
end

# Cache credentials per account
creds_cache = {}
get_token = lambda do |source_id|
  account = source_account_map[source_id]
  return nil unless account

  creds_cache[account] ||= begin
    config_loader.mastodon_credentials(account)
  rescue => e
    log "  WARN: Cannot load credentials for account '#{account}' (source: #{source_id}): #{e.message}"
    nil
  end

  creds_cache[account]&.fetch(:token, nil)
end

mastodon_instance = 'https://zpravobot.news'

# ============================================================
# Step 4 — Delete from Mastodon and DB
# ============================================================
deleted  = 0
skipped  = 0
errors   = 0

result.each_with_index do |row, i|
  source_id         = row['source_id']
  mastodon_status_id = row['mastodon_status_id']
  post_url          = row['post_url']

  token = get_token.call(source_id)

  unless token
    log "  [#{i+1}/#{result.ntuples}] SKIP #{source_id} / #{mastodon_status_id} — no token"
    skipped += 1
    next
  end

  # Call Mastodon DELETE API
  begin
    uri = URI("#{mastodon_instance}/api/v1/statuses/#{mastodon_status_id}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 15

    req = Net::HTTP::Delete.new(uri.path)
    req['Authorization'] = "Bearer #{token}"
    response = http.request(req)

    case response.code.to_i
    when 200, 204
      # Remove from DB too
      conn.exec_params(
        "DELETE FROM zpravobot.published_posts WHERE source_id = $1 AND mastodon_status_id = $2",
        [source_id, mastodon_status_id]
      )
      log "  [#{i+1}/#{result.ntuples}] DELETED #{source_id} / #{mastodon_status_id}"
      deleted += 1
    when 404
      # Already gone — just remove from DB
      conn.exec_params(
        "DELETE FROM zpravobot.published_posts WHERE source_id = $1 AND mastodon_status_id = $2",
        [source_id, mastodon_status_id]
      )
      log "  [#{i+1}/#{result.ntuples}] NOT FOUND (already deleted) #{source_id} / #{mastodon_status_id} — removed from DB"
      deleted += 1
    else
      log "  [#{i+1}/#{result.ntuples}] ERROR #{response.code} #{source_id} / #{mastodon_status_id}: #{response.body[0, 100]}"
      errors += 1
    end

    sleep 0.3  # rate limit courtesy
  rescue => e
    log "  [#{i+1}/#{result.ntuples}] EXCEPTION #{source_id} / #{mastodon_status_id}: #{e.message}"
    errors += 1
  end
end

puts
log "Done. Deleted: #{deleted}, Skipped (no token): #{skipped}, Errors: #{errors}"

db_prod.disconnect
exit(errors > 0 ? 1 : 0)
