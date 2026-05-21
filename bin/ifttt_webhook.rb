#!/usr/bin/env ruby
# frozen_string_literal: true

# Lightweight IFTTT Webhook Handler for Cloudron/Mastodon
#
# Minimalistický HTTP server optimalizovaný pro běh na Mastodon instanci:
# - Nízká paměťová náročnost (~10-15MB)
# - Žádné external dependencies (jen stdlib)
# - Automatický shutdown po období neaktivity (volitelné)
# - Integrovaný queue processing (volitelné)
# - Podpora pro test/prod prostředí pomocí ?env=test parametru
#
# Usage:
#   ruby bin/ifttt_webhook.rb
#   ruby bin/ifttt_webhook.rb --process-queue
#   ruby bin/ifttt_webhook.rb --idle-shutdown 3600
#
# Webhook URLs:
#   Twitter:    POST /api/ifttt/twitter
#   Test:       POST /api/ifttt/twitter?env=test
#   Broadcast:  POST /api/mastodon/broadcast (tlambot trigger)

$LOAD_PATH.unshift File.join(__dir__, '..', 'lib')
require 'optparse'
require 'webhook/http_server'

# Configuration from environment
PORT                = ENV['IFTTT_PORT']&.to_i || 8089
BIND_ADDRESS        = ENV['IFTTT_BIND'] || '0.0.0.0'
AUTH_TOKEN          = ENV['IFTTT_AUTH_TOKEN']
BROADCAST_SECRET    = ENV['TLAMBOT_WEBHOOK_SECRET']
BROADCAST_QUEUE_DIR = ENV['BROADCAST_QUEUE_DIR'] ||
                      (ENV['ZBNW_DIR'] ? "#{ENV['ZBNW_DIR']}/queue/broadcast" : 'queue/broadcast')

QUEUE_DIRS = {
  'prod' => ENV['IFTTT_QUEUE_DIR'] ||
            (ENV['ZBNW_DIR'] ? "#{ENV['ZBNW_DIR']}/queue/ifttt" : '/app/data/zbnw-ng/queue/ifttt'),
  'test' => ENV['IFTTT_QUEUE_DIR_TEST'] ||
            (ENV['ZBNW_DIR'] ? "#{ENV['ZBNW_DIR']}/queue/ifttt" : 'queue/ifttt')
}.freeze

# Warn on startup if secrets are not configured
warn "WARN: IFTTT_AUTH_TOKEN not set — webhook accepts unauthenticated requests" \
  unless AUTH_TOKEN && !AUTH_TOKEN.empty?
warn "WARN: TLAMBOT_WEBHOOK_SECRET not set — broadcast webhook signature not verified" \
  unless BROADCAST_SECRET && !BROADCAST_SECRET.empty?

if __FILE__ == $PROGRAM_NAME
  options = {}

  OptionParser.new do |opts|
    opts.banner = "Usage: #{$PROGRAM_NAME} [options]"

    opts.on('-p', '--port PORT', Integer, "Port (default: #{PORT})") do |p|
      options[:port] = p
    end

    opts.on('-q', '--process-queue', 'Enable integrated queue processing (PROD only)') do
      options[:process_queue] = true
    end

    opts.on('-i', '--idle-shutdown SECONDS', Integer, 'Shutdown after N seconds of inactivity') do |s|
      options[:idle_shutdown] = s
    end

    opts.on('-h', '--help', 'Show help') do
      puts opts
      puts
      puts "Webhook URLs:"
      puts "  Twitter:    POST http://localhost:#{PORT}/api/ifttt/twitter"
      puts "  Test:       POST http://localhost:#{PORT}/api/ifttt/twitter?env=test"
      puts "  Broadcast:  POST http://localhost:#{PORT}/api/mastodon/broadcast"
      puts
      puts "Queue directories:"
      puts "  IFTTT PROD: #{QUEUE_DIRS['prod']}"
      puts "  IFTTT TEST: #{QUEUE_DIRS['test']}"
      puts "  Broadcast:  #{BROADCAST_QUEUE_DIR}"
      exit
    end
  end.parse!

  Webhook::HttpServer.new(
    port:                options[:port] || PORT,
    bind:                BIND_ADDRESS,
    auth_token:          AUTH_TOKEN,
    queue_dirs:          QUEUE_DIRS,
    broadcast_queue_dir: BROADCAST_QUEUE_DIR,
    broadcast_secret:    BROADCAST_SECRET,
    process_queue:       options[:process_queue] || false,
    idle_shutdown:       options[:idle_shutdown]
  ).start
end
