#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Zpravobot ZBNW-NG Broadcast Tool
# ============================================================
# Send the same message to all or selected Mastodon accounts.
#
# Usage:
#   ruby bin/broadcast.rb                                    # Interactive mode
#   ruby bin/broadcast.rb --message "Text"                   # Non-interactive
#   ruby bin/broadcast.rb --message "..." --dry-run          # Preview only
#   ruby bin/broadcast.rb --target all                       # All accounts
#   ruby bin/broadcast.rb --account betabot                  # Single account
#   ruby bin/broadcast.rb --account betabot,enkocz           # Multiple accounts
#   ruby bin/broadcast.rb --media file.png --alt "Desc"      # With media
#
# Exit codes:
#   0 = success (all published)
#   1 = partial failure (some accounts failed)
#   2 = bad arguments / validation error
#   130 = SIGINT (graceful shutdown)
# ============================================================

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'optparse'
require 'broadcast/broadcaster'

# ============================================================
# Signal handling — graceful shutdown
# ============================================================
$shutdown_requested = false

%w[INT TERM].each do |signal|
  trap(signal) do
    if $shutdown_requested
      puts "\n  Druhy signal, ukoncuji okamzite."
      exit 130
    end
    $shutdown_requested = true
    puts "\n  Prijat signal #{signal}, dokoncuji aktualni ucet..."
  end
end

# ============================================================
# Parse CLI arguments
# ============================================================
options = {}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby bin/broadcast.rb [options]"
  opts.separator ""
  opts.separator "Options:"

  opts.on('--message TEXT', 'Message text (interactive if missing)') do |v|
    options[:message] = v
  end

  opts.on('--target TARGET', 'zpravobot (default) | all') do |v|
    options[:target] = v
  end

  opts.on('--account ID,...', 'Specific account(s), comma-separated') do |v|
    options[:account] = v
  end

  opts.on('--visibility VIS', 'public (default) | unlisted | direct') do |v|
    options[:visibility] = v
  end

  opts.on('--media FILE', 'Path to media attachment') do |v|
    options[:media] = v
  end

  opts.on('--alt TEXT', 'Alt text for media attachment') do |v|
    options[:alt] = v
  end

  opts.on('--dry-run', 'Just show what would happen') do
    options[:dry_run] = true
  end

  opts.on('--test', 'Use test environment') do
    options[:test] = true
  end

  opts.on('-h', '--help', 'Show this help') do
    puts opts
    exit 0
  end
end.parse!

# ============================================================
# Run broadcast
# ============================================================
begin
  broadcaster = Broadcast::Broadcaster.new(options)
  exit_code = broadcaster.run

  if $shutdown_requested
    exit 130
  else
    exit exit_code
  end
rescue StandardError => e
  $stderr.puts "FATAL: #{e.message}"
  $stderr.puts e.backtrace.first(5).join("\n") if ENV['DEBUG']
  exit 4
end
