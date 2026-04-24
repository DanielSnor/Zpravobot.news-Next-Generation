#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Zpravobot Týdeník — Weekly Stats Hitparáda (#ZpravobotStats)
# ============================================================
#
# Generates and optionally publishes weekly stats hitparáda
# as a 2-post thread: CZ post → SK reply.
#
# Usage:
#   ruby bin/zpravobot_stats.rb                   # Dry run — print to stdout
#   ruby bin/zpravobot_stats.rb --publish          # Publish CZ+SK thread
#   ruby bin/zpravobot_stats.rb --snapshot-only    # Save snapshot, no post
#   ruby bin/zpravobot_stats.rb --lang cz          # Only CZ post (no thread)
#   ruby bin/zpravobot_stats.rb --week 12          # Override ISO week number
#   ruby bin/zpravobot_stats.rb --account betabot  # Override publisher account
#   ruby bin/zpravobot_stats.rb --test             # Use zpravobot_test schema
#
# Publisher account priority:
#   1. --account CLI flag
#   2. ZPRAVOBOT_STATS_ACCOUNT env var
#   3. betabot (test default)
#
# Cron (Cloudron):
#   0 20 * * 0  cd /app/data/zbnw-ng && ruby bin/zpravobot_stats.rb --publish 2>&1 >> logs/stats.log
#
# ============================================================

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'optparse'
require 'date'
require 'yaml'
require 'set'

require 'config/config_loader'
require 'state/database_connection'
require 'stats/snapshot_store'
require 'stats/publishing_stats'
require 'stats/mastodon_stats'
require 'stats/skokan_detector'
require 'stats/stats_post_formatter'

# ============================================================
# Parse CLI arguments
# ============================================================
options = {
  publish:       false,
  snapshot_only: false,
  test:          false,
  week:          nil,
  account:       nil,
  lang:          nil,   # nil = both CZ+SK; 'cz' or 'sk' = only that lang
  bluesky:       false
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby bin/zpravobot_stats.rb [options]"
  opts.on('--publish',         'Publish thread via Mastodon API') { options[:publish] = true }
  opts.on('--snapshot-only',   'Save snapshot only, no post')     { options[:snapshot_only] = true }
  opts.on('--week N', Integer, 'Override ISO week number')        { |v| options[:week] = v }
  opts.on('--account ID',      'Mastodon account to post from')   { |v| options[:account] = v }
  opts.on('--lang LANG',       'Only generate post for cz or sk') { |v| options[:lang] = v.downcase }
  opts.on('--test',            'Use zpravobot_test schema')       { options[:test] = true }
  opts.on('--bluesky',         'Also publish to Bluesky')         { options[:bluesky] = true }
  opts.on('-h', '--help', 'Show this help') { puts opts; exit 0 }
end.parse!

# ============================================================
# Helpers
# ============================================================

def log(msg)
  $stdout.puts "[#{Time.now.strftime('%H:%M:%S')}] #{msg}"
  $stdout.flush
end

def die(msg, code: 3)
  $stderr.puts "ERROR: #{msg}"
  exit code
end

# ============================================================
# Step 1 — Load config
# ============================================================
config_dir    = ENV.fetch('ZBNW_CONFIG_DIR',
                  ENV['ZBNW_DIR'] ? "#{ENV['ZBNW_DIR']}/config" : 'config')
config_loader = Config::ConfigLoader.new(config_dir)
global_config = config_loader.load_global_config
mastodon_instance = global_config.dig(:mastodon, :instance) || 'https://zpravobot.news'

log "Config: #{config_dir} | Instance: #{mastodon_instance}"

# Load mastodon_accounts.yml raw
accounts_raw = begin
  YAML.safe_load(
    File.read(File.join(config_dir, 'mastodon_accounts.yml'), encoding: 'UTF-8'),
    permitted_classes: [], permitted_symbols: [], aliases: true
  )
rescue => e
  die "Cannot load mastodon_accounts.yml: #{e.message}"
end
accounts_config = accounts_raw.transform_values { |v| v.transform_keys(&:to_sym) }

account_categories = accounts_config.transform_values do |creds|
  Array(creds[:categories]).map(&:to_s)
end

# ============================================================
# Step 2 — Build language → account set from source configs
# ============================================================
log "Building language groups from source configs..."

lang_accounts = Hash.new { |h, k| h[k] = Set.new }  # { 'cz' => Set<account_id>, 'sk' => Set<...> }

config_loader.load_all_sources.each do |source|
  lang    = source[:language]&.to_s&.downcase
  account = source.dig(:target, :mastodon_account)&.to_s
  next unless account

  # CZ zdroje nemají language: field — implicitní default je 'cs'
  lang = 'cs' if lang.nil? || lang.empty?
  lang_accounts[lang].add(account)
end

log "Language groups: " + lang_accounts.map { |l, accs| "#{l.upcase}=#{accs.size}" }.join(', ')

# Accounts on zpravobot.news instance only (exclude external instances)
local_accounts = accounts_config.each_with_object(Set.new) do |(acc_id, creds), set|
  instance = creds[:instance].to_s
  set.add(acc_id.to_s) if instance.empty? || instance.include?('zpravobot.news')
end
log "Local accounts (zpravobot.news): #{local_accounts.size} / #{accounts_config.size}"

# ============================================================
# Step 3 — Connect to DB
# ============================================================
schema = options[:test] ? 'zpravobot_test' : nil
db = State::DatabaseConnection.new(schema: schema)
begin
  db.connect
rescue => e
  die "DB connection failed: #{e.message}"
end
log "Connected to DB (schema: #{db.schema})"

# ============================================================
# Step 4 — Fetch Mastodon API stats (all accounts)
# ============================================================
log "Fetching Mastodon stats (#{accounts_config.size} accounts)..."
mastodon_fetcher = Stats::MastodonStats.new(accounts_config, mastodon_instance)
all_mastodon     = mastodon_fetcher.fetch_all(delay: 0.3)
log "Fetched: #{all_mastodon.size} accounts"

# ============================================================
# Step 5 — Fetch publishing stats from DB (all sources)
# ============================================================
log "Fetching publishing stats..."
pub_stats = Stats::PublishingStats.new(db)

# Build source_id → account_id map (all sources)
source_account_map = {}
config_loader.load_all_sources.each do |source|
  sid  = source[:id]&.to_s
  acct = source.dig(:target, :mastodon_account)&.to_s
  source_account_map[sid] = acct if sid && acct
end
log "Source→account map: #{source_account_map.size} sources"

all_posts_by_account = pub_stats.posts_per_account(source_account_map, days: 7)

# ============================================================
# Step 6 — Save snapshot (all accounts)
# ============================================================
today = Date.today
snap_store = Stats::SnapshotStore.new(db)
posts_for_snapshot = all_posts_by_account.transform_values { |v| v[:this_week].to_i }

log "Saving snapshot for #{today}..."
snap_store.save_snapshot(today, all_mastodon, posts_for_snapshot)
snap_store.cleanup_old_snapshots(keep_weeks: 52)

if options[:snapshot_only]
  log "Snapshot saved. --snapshot-only, exiting."
  db.disconnect
  exit 0
end

# ============================================================
# Step 7 — Load previous snapshot
# ============================================================
log "Loading previous snapshot..."
prev_snapshot = snap_store.previous_snapshot(today, weeks_back: 1)
log prev_snapshot ? "Previous snapshot: #{prev_snapshot.size} accounts" : "No previous snapshot (week 1)"

# ============================================================
# Step 8 — Determine week number and date range
# ============================================================
week_number = options[:week] || today.cweek
# date_from = Monday of the current ISO week; date_to = Sunday (or today if running mid-week)
date_from = today - (today.cwday - 1)        # Monday
date_to   = date_from + 6                     # Sunday of the same ISO week

# ============================================================
# Step 9 — Generate posts per language
# ============================================================
detector  = Stats::SkokanDetector.new
formatter = Stats::StatsPostFormatter.new

target_langs = options[:lang] ? [options[:lang]] : ['cs', 'sk']

lang_posts = {}

target_langs.each do |lang|
  acct_set = lang_accounts[lang]
  if acct_set.empty?
    log "No accounts for language '#{lang}', skipping"
    next
  end

  # Filter to this language group, local instance only (no mastodonczech.cz etc.)
  lang_mastodon  = all_mastodon.select        { |acc, _| acct_set.include?(acc.to_s) && local_accounts.include?(acc.to_s) }
  lang_posts_acc = all_posts_by_account.select { |acc, _| acct_set.include?(acc.to_s) && local_accounts.include?(acc.to_s) }
  lang_prev = prev_snapshot&.select { |acc, _| acct_set.include?(acc.to_s) }

  lang_src_map = source_account_map.select { |_, acc| acct_set.include?(acc.to_s) }
  lang_cat_stats = pub_stats.category_stats(account_categories, lang_src_map, days: 7)

  skokan = detector.detect(lang_posts_acc, lang_prev, lang_mastodon)

  data = {
    lang:              lang,
    week_number:       week_number,
    date_from:         date_from,
    date_to:           date_to,
    posts_per_account: lang_posts_acc,
    mastodon_stats:    lang_mastodon,
    category_stats:    lang_cat_stats,
    skokan:            skokan
  }

  begin
    post_text = formatter.format(data)
    lang_posts[lang] = post_text
    log "#{lang.upcase} post: #{post_text.length} znaků"
  rescue => e
    log "ERROR formatting #{lang.upcase} post: #{e.message}"
  end
end

if lang_posts.empty?
  log "No posts generated, exiting."
  db.disconnect
  exit 0
end

# ============================================================
# Step 10 — Print preview
# ============================================================
lang_posts.each do |lang, text|
  puts
  puts "=" * 60
  puts "POST #{lang.upcase} (#{text.length}/2500 znaků)"
  puts "=" * 60
  puts text
end
puts

# ============================================================
# Step 11 — Publish (or dry run)
# ============================================================
unless options[:publish]
  log "Dry run. Použij --publish pro publikaci."
  db.disconnect
  exit 0
end

publisher_account = options[:account] ||
                    ENV.fetch('ZPRAVOBOT_STATS_ACCOUNT', 'betabot')
log "Publikuji z účtu: #{publisher_account}"

begin
  creds = config_loader.mastodon_credentials(publisher_account)
rescue => e
  die "Nelze načíst credentials pro '#{publisher_account}': #{e.message}", code: 2
end

pub_instance = (creds[:instance] || mastodon_instance).to_s.chomp('/')
pub_token    = creds[:token]

require 'publishers/mastodon_publisher'
publisher = Publishers::MastodonPublisher.new(
  instance_url: pub_instance,
  access_token: pub_token
)

bs_publisher = if options[:bluesky]
                 require 'publishers/bluesky_publisher'
                 require 'publishers/bluesky_text_splitter'
                 Publishers::BlueskyPublisher.new(account_id: 'zpravobot')
               end

# Publish as thread: first post is root, subsequent posts reply to it
in_reply_to_id = nil

['cs', 'sk'].each do |lang|
  text = lang_posts[lang]
  next unless text

  begin
    result = publisher.publish(
      text,
      visibility:      'public',
      in_reply_to_id:  in_reply_to_id
    )
    log "#{lang.upcase} published: #{result['url']}"
    in_reply_to_id = result['id']   # next post replies to this one
    sleep 1                          # small pause between thread posts
  rescue => e
    $stderr.puts "PUBLISH FAILED (#{lang.upcase}): #{e.message}"
    db.disconnect
    exit 1
  end
end

# Bluesky: each language post as its own thread (BS doesn't cross-link CZ+SK)
if bs_publisher
  splitter = Publishers::BlueskyTextSplitter.new
  ['cs', 'sk'].each do |lang|
    text = lang_posts[lang]
    next unless text

    begin
      chunks = splitter.split(text)
      next if chunks.empty?

      log "Bluesky #{lang.upcase}: #{chunks.size} chunk(s)..."
      bs_publisher.publish_thread(chunks)
    rescue => e
      $stderr.puts "BLUESKY PUBLISH FAILED (#{lang.upcase}): #{e.message}"
      # Non-fatal — Mastodon publish already succeeded
    end
  end
end

db.disconnect
log "Done."
exit 0
