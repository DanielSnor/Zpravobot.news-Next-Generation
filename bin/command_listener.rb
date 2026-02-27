#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Udrzbot - Command Listener
# ============================================================
# Polls Mastodon notifications for mentions and responds to commands.
#
# Usage:
#   ruby bin/command_listener.rb              # Single poll run
#   ruby bin/command_listener.rb --dry-run    # Parse but don't reply
#   ruby bin/command_listener.rb --config FILE # Custom config
#
# Cron:
#   */5 * * * * cd /app/data/zbnw-ng && ./cron_command_listener.sh
#
# ============================================================

require 'bundler/setup'
require 'fileutils'
require 'optparse'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

# ============================================================
# Lockfile - prevence overlapping cron runs
# ============================================================

LOCKFILE = File.expand_path('../tmp/command_listener.lock', __dir__)

def acquire_lock
  FileUtils.mkdir_p(File.dirname(LOCKFILE))
  @lock_file = File.open(LOCKFILE, File::RDWR | File::CREAT)
  unless @lock_file.flock(File::LOCK_NB | File::LOCK_EX)
    return false
  end
  true
rescue Errno::EACCES
  false
end

# ============================================================
# Parse options
# ============================================================

options = {
  dry_run: false,
  config: File.expand_path('../config/health_monitor.yml', __dir__)
}

OptionParser.new do |opts|
  opts.banner = "Usage: #{$PROGRAM_NAME} [options]"

  opts.on('--dry-run', 'Parse commands but do not reply or dismiss') do
    options[:dry_run] = true
  end

  opts.on('-c', '--config FILE', 'Config file path') do |f|
    options[:config] = f
  end

  opts.on('-h', '--help', 'Show help') do
    puts opts
    exit
  end
end.parse!

# ============================================================
# Acquire lock
# ============================================================

unless acquire_lock
  puts "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] Jina instance command_listener jiz bezi, ukoncuji."
  exit 0
end

# ============================================================
# Load dependencies and run
# ============================================================

# Health monitor - z lib/health/
require 'health/health_config'
require 'health/check_result'
require 'health/database_helper'
require 'health/health_monitor'
require 'health/alert_state_manager'

# command listener a handlery
require 'monitoring/command_listener'

config = HealthConfig.new(options[:config])
listener = Monitoring::CommandListener.new(config)
listener.run(dry_run: options[:dry_run])
