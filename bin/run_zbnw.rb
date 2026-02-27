#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Zprávobot ZBNW-NG Main runner
# ============================================================
# Entry point for cron jobs
#
# Usage:
#   bundle exec ruby bin/run_zbnw.rb                    # Run all sources
#   bundle exec ruby bin/run_zbnw.rb --dry-run          # Dry run (no publishing)
#   bundle exec ruby bin/run_zbnw.rb --first-run        # Initialize state only
#   bundle exec ruby bin/run_zbnw.rb --source ct24      # Run specific source
#   bundle exec ruby bin/run_zbnw.rb --platform bluesky # Run platform
#   bundle exec ruby bin/run_zbnw.rb --exclude-platform twitter  # All except Twitter
#   bundle exec ruby bin/run_zbnw.rb --priority high    # Run high priority only
#   bundle exec ruby bin/run_zbnw.rb --test             # Use test schema
#
# Environment:
#   ZPRAVOBOT_SCHEMA=zpravobot_test   # Use test schema
#   DEBUG=1                            # Enable debug output
#
# Logging:
#   Logs are written to logs/runner_YYYYMMDD.log with daily rotation.
#   - New file created at midnight
#   - Old files deleted after 7 days
#
# Cron examples:
#   # Every 15 minutes - Twitter only (Nitter rate limits)
#   */15 * * * * cd /app/data/zbnw-ng && bundle exec ruby bin/run_zbnw.rb --platform twitter
#
#   # Every 8 minutes - everything except Twitter
#   */8 * * * * cd /app/data/zbnw-ng && bundle exec ruby bin/run_zbnw.rb --exclude-platform twitter
#
# ============================================================

require 'bundler/setup'
require 'fileutils'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'optparse'
require 'logging'
require 'orchestrator'

# ============================================================
# Lockfile - prevents overlapping runs
# ============================================================
LOCKFILE = File.expand_path('../tmp/run_zbnw.lock', __dir__)

def acquire_lock
  FileUtils.mkdir_p(File.dirname(LOCKFILE))
  @lock_file = File.open(LOCKFILE, File::RDWR | File::CREAT)
  @lock_file.flock(File::LOCK_NB | File::LOCK_EX)
rescue Errno::EACCES
  false
end

# ============================================================
# Signal handling - graceful shutdown
# ============================================================
$shutdown_requested = false

%w[INT TERM].each do |signal|
  trap(signal) do
    $shutdown_requested = true
    Logging.warn("Received #{signal}, shutting down after current source...")
  end
end

# ============================================================
# Parse command line options
# ============================================================
options = {
  dry_run: false,
  first_run: false,
  source: nil,
  platform: nil,
  exclude_platform: nil,
  priority: nil,
  schema: ENV['ZPRAVOBOT_SCHEMA'] || 'zpravobot',
  config_dir: 'config',
  log_dir: 'logs'
}

OptionParser.new do |opts|
  opts.banner = "Usage: #{$PROGRAM_NAME} [options]"

  opts.on('--dry-run', 'Dry run - do not publish') do
    options[:dry_run] = true
  end

  opts.on('--first-run', 'Initialize state - mark latest valid post as published without publishing') do
    options[:first_run] = true
  end

  opts.on('--source SOURCE_ID', 'Run specific source only') do |v|
    options[:source] = v
  end

  opts.on('--platform PLATFORM', 'Run specific platform (twitter, bluesky, rss, youtube)') do |v|
    options[:platform] = v
  end

  opts.on('--exclude-platform PLATFORM', 'Run all platforms EXCEPT specified (twitter, bluesky, rss, youtube)') do |v|
    options[:exclude_platform] = v
  end

  opts.on('--priority PRIORITY', 'Run specific priority (high, normal, low)') do |v|
    options[:priority] = v
  end

  opts.on('--test', 'Use test schema (zpravobot_test)') do
    options[:schema] = 'zpravobot_test'
  end

  opts.on('--schema SCHEMA', 'Database schema to use') do |v|
    options[:schema] = v
  end

  opts.on('--config DIR', 'Config directory (default: config)') do |v|
    options[:config_dir] = v
  end

  opts.on('--log-dir DIR', 'Log directory (default: logs)') do |v|
    options[:log_dir] = v
  end

  opts.on('--verbose', 'Verbose logging (detailed post processing info)') do
    options[:verbose] = true
  end

  opts.on('-h', '--help', 'Show this help') do
    puts opts
    exit
  end
end.parse!

# ============================================================
# Validate mutual exclusivity
# ============================================================
conflicting_options = [options[:source], options[:platform], options[:exclude_platform]].compact
if conflicting_options.length > 1
  warn 'Error: --source, --platform, and --exclude-platform are mutually exclusive.'
  exit 2
end

# ============================================================
# Acquire lock
# ============================================================
unless acquire_lock
  warn 'Another instance is already running (lockfile present). Exiting.'
  exit 3
end

# ============================================================
# Initialize logging (daily rotation)
# ============================================================
Logging.setup(
  name: 'runner',
  dir: options[:log_dir],
  keep_days: 7
)

# ============================================================
# Main execution
# ============================================================

# Banner
Logging.info('=' * 60)
Logging.info('Zpravobot Scraper')
Logging.info('=' * 60)
Logging.info("Schema: #{options[:schema]}")
Logging.info("Dry run: #{options[:dry_run]}")
Logging.info("First run: #{options[:first_run]}") if options[:first_run]
Logging.info("Exclude platform: #{options[:exclude_platform]}") if options[:exclude_platform]
Logging.info("Platform: #{options[:platform]}") if options[:platform]
Logging.info("Source: #{options[:source]}") if options[:source]
Logging.info("Verbose: #{options[:verbose]}") if options[:verbose]
Logging.info('=' * 60)

begin
  runner = Orchestrator::Runner.new(
    config_dir: options[:config_dir],
    schema: options[:schema],
    first_run: options[:first_run],
    verbose: options[:verbose] || false
  )

  stats = if options[:source]
    # Run specific source
    runner.run_source(options[:source], dry_run: options[:dry_run], first_run: options[:first_run])
  elsif options[:platform]
    # Run specific platform
    runner.run_platform(options[:platform], dry_run: options[:dry_run], first_run: options[:first_run])
  elsif options[:exclude_platform]
    # Run all except specified platform
    runner.run(dry_run: options[:dry_run], priority: options[:priority], 
               exclude_platform: options[:exclude_platform], first_run: options[:first_run])
  else
    # Run all sources
    runner.run(dry_run: options[:dry_run], priority: options[:priority], first_run: options[:first_run])
  end

  Logging.info('=' * 60)
  Logging.info('Summary')
  Logging.info('=' * 60)
  Logging.info("Processed: #{stats.fetch(:processed, 0)}")
  Logging.info("Published: #{stats.fetch(:published, 0)}")
  Logging.info("Skipped:   #{stats.fetch(:skipped, 0)}")
  Logging.info("Errors:    #{stats.fetch(:errors, 0)}")
  Logging.info('=' * 60)

  # Exit with error code if there were errors
  exit 1 if stats.fetch(:errors, 0) > 0

rescue StandardError => e
  Logging.fatal("FATAL: #{e.message}")
  Logging.debug(e.backtrace.first(5).join("\n")) if ENV['DEBUG']
  exit 4
ensure
  @lock_file&.close
  File.delete(LOCKFILE) if File.exist?(LOCKFILE)
end
