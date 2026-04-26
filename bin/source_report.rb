#!/usr/bin/env ruby
# frozen_string_literal: true

# Automatický denní nástroj pro detekci změn v mastodon_accounts.yml.
# Porovnává aktuální stav se snapshotu a publikuje post na @zpravobot.
#
# Použití:
#   ruby bin/source_report.rb             # normální cron běh
#   ruby bin/source_report.rb --dry-run   # ukáže post, nepostuje, neaktualizuje snapshot
#   ruby bin/source_report.rb --init      # inicializuje snapshot bez postu (první spuštění)
#   ruby bin/source_report.rb --test      # testovací schéma (pro vývoj)

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require_relative '../lib/reporting/source_reporter'
require_relative '../lib/publishers/mastodon_publisher'

# ── Konfigurace ──────────────────────────────────────────────

BASE_DIR       = File.expand_path('..', __dir__)
ACCOUNTS_FILE  = File.join(BASE_DIR, 'config', 'mastodon_accounts.yml')
SNAPSHOT_PATH  = File.join(BASE_DIR, 'data', 'source_report_snapshot.yml')
INSTANCE_URL   = 'https://zpravobot.news'

dry_run    = ARGV.include?('--dry-run')
init_mode  = ARGV.include?('--init')
use_bluesky = ARGV.include?('--bluesky')

# ── Validace prostředí ───────────────────────────────────────

unless File.exist?(ACCOUNTS_FILE)
  warn "❌ mastodon_accounts.yml nenalezen: #{ACCOUNTS_FILE}"
  exit 1
end

unless dry_run || init_mode
  token = ENV['ZPRAVOBOT_REPORT_TOKEN']
  if token.nil? || token.strip.empty?
    warn '❌ ENV proměnná ZPRAVOBOT_REPORT_TOKEN není nastavena.'
    exit 2
  end
end

# ── Sestavení publisheru ─────────────────────────────────────

publisher = if dry_run || init_mode
              nil
            else
              Publishers::MastodonPublisher.new(
                instance_url:  INSTANCE_URL,
                access_token:  ENV['ZPRAVOBOT_REPORT_TOKEN']
              )
            end

bs_publisher = if use_bluesky && !dry_run && !init_mode
                 require_relative '../lib/publishers/bluesky_publisher'
                 Publishers::BlueskyPublisher.new(account_id: 'zpravobot')
               end

# ── Spuštění ─────────────────────────────────────────────────

reporter = Reporting::SourceReporter.new(
  accounts_file:     ACCOUNTS_FILE,
  snapshot_path:     SNAPSHOT_PATH,
  publisher:         publisher,
  bluesky_publisher: bs_publisher,
  dry_run:           dry_run,
  default_instance:  'zpravobot.news'
)

if init_mode
  reporter.init
else
  reporter.run
end
