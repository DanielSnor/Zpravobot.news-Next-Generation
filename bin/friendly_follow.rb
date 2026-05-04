#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Friendly Follow (#FF) — denní doporučení účtů
# ============================================================
#
# Publikuje denní #FF post od @zpravobot doporučující 3 účty
# z Zpravobot.news s jejich display name a bio.
#
# Použití:
#   ruby bin/friendly_follow.rb             # normální běh (publish)
#   ruby bin/friendly_follow.rb --dry-run   # ukáže post, nepostuje, neaktualizuje state
#   ruby bin/friendly_follow.rb --test      # (zatím nepoužito — placeholder)
#
# Token priority:
#   1. ZBNW_MASTODON_TOKEN_ZPRAVOBOT  (env)
#   2. ZPRAVOBOT_REPORT_TOKEN         (env)
#   3. mastodon_accounts.yml → zpravobot → token
#
# Cron (Cloudron) — čas TBD:
#   # 15 15 * * * source /app/data/zbnw-ng/env.sh && cd /app/data/zbnw-ng && ruby bin/friendly_follow.rb >> logs/friendly_follow.log 2>&1
#   # 15 16 * * * source /app/data/zbnw-ng/env.sh && cd /app/data/zbnw-ng && ruby bin/friendly_follow.rb >> logs/friendly_follow.log 2>&1
#
# ============================================================

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'optparse'
require 'yaml'

require 'ff/friendly_follow'

# ============================================================
# Parse CLI arguments
# ============================================================
options = { dry_run: false, test: false, bluesky: false }

OptionParser.new do |opts|
  opts.banner = 'Usage: ruby bin/friendly_follow.rb [options]'
  opts.on('--dry-run', 'Show post, do not publish or update state') { options[:dry_run] = true }
  opts.on('--test',    'Use test schema (placeholder, not yet used)') { options[:test] = true }
  opts.on('--bluesky', 'Also publish to Bluesky')                    { options[:bluesky] = true }
  opts.on('-h', '--help', 'Show help') { puts opts; exit 0 }
end.parse!

# ============================================================
# Helpers
# ============================================================

def log(msg)
  $stdout.puts "[#{Time.now.strftime('%H:%M:%S')}] #{msg}"
  $stdout.flush
end

def die(msg, code: 1)
  $stderr.puts "ERROR: #{msg}"
  exit code
end

# ============================================================
# Paths
# ============================================================
base_dir   = ENV['ZBNW_DIR'] || File.expand_path('..', __dir__)
config_dir = ENV.fetch('ZBNW_CONFIG_DIR', File.join(base_dir, 'config'))
state_path = File.join(base_dir, 'data', 'ff_rotation.json')

instance_url = 'https://zpravobot.news'

# ============================================================
# Resolve access token
# ============================================================
access_token = ENV['ZBNW_MASTODON_TOKEN_ZPRAVOBOT'] || ENV['ZPRAVOBOT_REPORT_TOKEN']

unless access_token
  accounts_file = File.join(config_dir, 'mastodon_accounts.yml')
  begin
    accounts = YAML.safe_load(
      File.read(accounts_file, encoding: 'UTF-8'),
      permitted_classes: [], permitted_symbols: [], aliases: true
    )
    access_token = accounts&.dig('zpravobot', 'token')
  rescue => e
    die "Cannot load mastodon_accounts.yml: #{e.message}"
  end
end

die 'No access token for zpravobot. Set ZPRAVOBOT_REPORT_TOKEN or add zpravobot to mastodon_accounts.yml' \
  unless access_token

# ============================================================
# Run
# ============================================================
log "Friendly Follow#{options[:dry_run] ? ' [DRY RUN]' : ''}#{options[:bluesky] ? ' +Bluesky' : ''}"

bs_publisher = if options[:bluesky] && !options[:dry_run]
                 require 'publishers/bluesky_publisher'
                 Publishers::BlueskyPublisher.try_create(account_id: 'zpravobot')
               end

ff = FF::FriendlyFollow.new(
  config_dir:        config_dir,
  state_path:        state_path,
  instance_url:      instance_url,
  access_token:      access_token,
  dry_run:           options[:dry_run],
  bluesky_publisher: bs_publisher
)

result = ff.run

if result[:posted]
  log "Posted: #{result[:url]}"
  log "Promoted: #{result[:accounts].join(', ')}"
elsif result[:accounts].any?
  log 'Dry run — post NOT published, state NOT updated'
  log "Would promote: #{result[:accounts].join(', ')}"
else
  log 'No accounts available to promote'
  exit 2
end
