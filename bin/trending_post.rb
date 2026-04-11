#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# ZBNW-NG Trending Post
# ============================================================
# Checks for new trending statuses on zpravobot.news and
# publishes quote posts from @zpravobot.
#
# Usage:
#   ruby bin/trending_post.rb              # Normal run
#   ruby bin/trending_post.rb --dry-run    # Preview without posting
#   ruby bin/trending_post.rb --test       # Use test schema/config
#
# Token priority:
#   1. ZBNW_MASTODON_TOKEN_ZPRAVOBOT env var
#   2. mastodon_accounts.yml → key :zpravobot → :token
#
# Cron (Cloudron):
#   45 * * * * /app/data/zbnw-ng/cron_trending.sh
#
# ============================================================

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'optparse'
require 'config/config_loader'
require 'trending/trending_checker'
require 'trending/hrubot_commenter'

# ============================================================
# CLI arguments
# ============================================================
options = { dry_run: false, test: false }

OptionParser.new do |opts|
  opts.banner = "Usage: #{$PROGRAM_NAME} [options]"
  opts.on('--dry-run', 'Preview new trends without publishing') { options[:dry_run] = true }
  opts.on('--test',    'Use test environment config')           { options[:test]    = true }
  opts.on('-h', '--help', 'Show help') { puts opts; exit 0 }
end.parse!

# ============================================================
# Load config
# ============================================================
config_dir = if options[:test]
               ENV['ZBNW_TEST_CONFIG_DIR'] || File.expand_path('../config', __dir__)
             else
               ENV['ZBNW_CONFIG_DIR'] || File.join(ENV['ZBNW_DIR'] || Dir.pwd, 'config')
             end

begin
  config_loader = Config::ConfigLoader.new(config_dir)
  global        = config_loader.load_global_config
rescue => e
  $stderr.puts "[#{Time.now.iso8601}] ❌ Config load failed: #{e.message}"
  exit 1
end

instance_url = global.dig(:mastodon, :instance) || 'https://zpravobot.news'

# Token priority:
#   1. ZBNW_MASTODON_TOKEN_ZPRAVOBOT  (explicit override)
#   2. ZPRAVOBOT_REPORT_TOKEN         (shared @zpravobot token, already in env.sh)
#   3. mastodon_accounts.yml → :zpravobot → :token
token = ENV['ZBNW_MASTODON_TOKEN_ZPRAVOBOT'] ||
        ENV['ZPRAVOBOT_REPORT_TOKEN']

unless token
  begin
    creds = config_loader.mastodon_credentials(:zpravobot)
    token = creds[:token]
  rescue => e
    $stderr.puts "[#{Time.now.iso8601}] ❌ Cannot resolve @zpravobot token: #{e.message}"
    $stderr.puts "    Nastav ZPRAVOBOT_REPORT_TOKEN nebo ZBNW_MASTODON_TOKEN_ZPRAVOBOT v env.sh"
    exit 1
  end
end

unless token
  $stderr.puts "[#{Time.now.iso8601}] ❌ Chybí token pro @zpravobot"
  exit 1
end

# ============================================================
# Run
# ============================================================
state_path = ENV['ZBNW_TRENDING_STATE'] ||
             File.join(ENV['ZBNW_DIR'] || Dir.pwd, 'data/trending_state.json')

ai_comments_enabled = ENV['TRENDING_AI_COMMENTS_ENABLED'].to_s.downcase == 'true'
commenter = nil
if ai_comments_enabled
  commenter = Trending::HrubotCommenter.new
  unless commenter.enabled?
    warn "[#{Time.now.iso8601}] ⚠️  TRENDING_AI_COMMENTS_ENABLED=true, ale ANTHROPIC_API_KEY chybí — komentáře budou přeskočeny"
    commenter = nil
  end
end

puts "[#{Time.now.iso8601}] 📈 Trending check start#{options[:dry_run] ? ' (dry run)' : ''}"
puts "[#{Time.now.iso8601}]    instance:    #{instance_url}"
puts "[#{Time.now.iso8601}]    state file:  #{state_path}"
puts "[#{Time.now.iso8601}]    AI comments: #{commenter ? 'enabled' : 'disabled'}"

begin
  checker = Trending::TrendingChecker.new(
    instance_url: instance_url,
    access_token:  token,
    state_path:    state_path,
    dry_run:       options[:dry_run],
    commenter:     commenter
  )

  result = checker.run

  puts "[#{Time.now.iso8601}] ✅ #{result[:checked]} trendů zkontrolováno, #{result[:posted]} quote postů publikováno"
rescue => e
  $stderr.puts "[#{Time.now.iso8601}] ❌ Trending check failed: #{e.class}: #{e.message}"
  $stderr.puts e.backtrace.first(5).join("\n")
  exit 1
end
