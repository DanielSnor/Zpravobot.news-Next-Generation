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
#   # Basic (webhook only, queue processed by cron)
#   ruby bin/ifttt_webhook.rb
#
#   # With integrated queue processing
#   ruby bin/ifttt_webhook.rb --process-queue
#
#   # With auto-shutdown after 1 hour of inactivity
#   ruby bin/ifttt_webhook.rb --idle-shutdown 3600
#
# Webhook URLs:
#   Twitter:    POST /api/ifttt/twitter
#   Test:       POST /api/ifttt/twitter?env=test
#   Broadcast:  POST /api/mastodon/broadcast (tlambot trigger)

require 'socket'
require 'json'
require 'time'
require 'fileutils'
require 'uri'
require 'openssl'

# Configuration
PORT = ENV['IFTTT_PORT']&.to_i || 8089
AUTH_TOKEN = ENV['IFTTT_AUTH_TOKEN']
BIND_ADDRESS = ENV['IFTTT_BIND'] || '0.0.0.0'

# Broadcast webhook configuration
BROADCAST_QUEUE_DIR = ENV['BROADCAST_QUEUE_DIR'] || (ENV['ZBNW_DIR'] ? "#{ENV['ZBNW_DIR']}/queue/broadcast" : 'queue/broadcast')
BROADCAST_WEBHOOK_SECRET = ENV['TLAMBOT_WEBHOOK_SECRET']
BROADCAST_TRIGGER_ACCOUNT = 'tlambot'

# Queue directories per environment
QUEUE_DIRS = {
  'prod' => ENV['IFTTT_QUEUE_DIR'] || (ENV['ZBNW_DIR'] ? "#{ENV['ZBNW_DIR']}/queue/ifttt" : '/app/data/zbnw-ng/queue/ifttt'),
  'test' => ENV['IFTTT_QUEUE_DIR_TEST'] || (ENV['ZBNW_DIR'] ? "#{ENV['ZBNW_DIR']}/queue/ifttt" : 'queue/ifttt')
}.freeze

class LightweightWebhookServer
  def initialize(port: PORT, process_queue: false, idle_shutdown: nil)
    @port = port
    @process_queue = process_queue
    @idle_shutdown = idle_shutdown
    @last_activity = Time.now
    @running = true
    @request_count = 0
    @env_counts = { 'prod' => 0, 'test' => 0 }
    @broadcast_count = 0
    
    ensure_queue_dirs
  end
  
  def start
    server = TCPServer.new(BIND_ADDRESS, @port)
    log "IFTTT Webhook server listening on #{BIND_ADDRESS}:#{@port}"
    log "Queue directories:"
    log "  IFTTT PROD: #{QUEUE_DIRS['prod']}"
    log "  IFTTT TEST: #{QUEUE_DIRS['test']}"
    log "  Broadcast:  #{BROADCAST_QUEUE_DIR}"
    log "Process queue: #{@process_queue ? 'enabled' : 'disabled (use cron)'}"
    log "Idle shutdown: #{@idle_shutdown ? "#{@idle_shutdown}s" : 'disabled'}"
    
    setup_signal_handlers
    
    # Start queue processor thread if enabled
    start_queue_processor if @process_queue
    
    # Start idle checker thread if enabled
    start_idle_checker if @idle_shutdown
    
    while @running
      begin
        # Non-blocking accept with timeout for graceful shutdown
        ready = IO.select([server], nil, nil, 1)
        next unless ready
        
        client = server.accept
        handle_request(client)
      rescue IOError, Errno::EBADF
        break unless @running
      rescue StandardError => e
        log "Error: #{e.message}", level: :error
      end
    end
    
    server.close
    log "Server stopped"
  end
  
  private
  
  # ===========================================
  # Request Handling
  # ===========================================
  
  def handle_request(client)
    @last_activity = Time.now
    @request_count += 1
    
    request_line = client.gets
    return client.close unless request_line
    
    method, full_path, _version = request_line.split
    
    # Parse path and query string
    path, query_string = full_path.split('?', 2)
    query_params = parse_query_string(query_string)
    
    headers = read_headers(client)
    
    # Route request
    status, content_type, body = route_request(method, path, query_params, headers, client)
    
    # Send response
    send_response(client, status, content_type, body)
    client.close
  rescue StandardError => e
    log "Request error: #{e.message}", level: :error
    send_response(client, 500, 'application/json', { error: e.message }.to_json) rescue nil
    client.close rescue nil
  end
  
  def parse_query_string(query_string)
    return {} unless query_string
    
    params = {}
    query_string.split('&').each do |pair|
      key, value = pair.split('=', 2)
      params[URI.decode_www_form_component(key)] = URI.decode_www_form_component(value || '')
    end
    params
  rescue StandardError
    {}
  end
  
  def route_request(method, path, query_params, headers, client)
    case [method, path]
    when ['POST', '/api/ifttt/twitter']
      handle_webhook(headers, client, query_params)
    when ['POST', '/api/mastodon/broadcast']
      handle_broadcast_webhook(headers, client)
    when ['GET', '/health']
      handle_health
    when ['GET', '/stats']
      handle_stats
    else
      [404, 'application/json', { error: 'Not found' }.to_json]
    end
  end
  
  def read_headers(client)
    headers = {}
    while (line = client.gets) && line != "\r\n"
      key, value = line.split(': ', 2)
      headers[key.downcase] = value&.strip
    end
    headers
  end
  
  def send_response(client, status, content_type, body)
    status_text = {
      200 => 'OK',
      400 => 'Bad Request',
      401 => 'Unauthorized',
      404 => 'Not Found',
      405 => 'Method Not Allowed',
      500 => 'Internal Server Error'
    }[status] || 'Unknown'
    
    response = [
      "HTTP/1.1 #{status} #{status_text}",
      "Content-Type: #{content_type}",
      "Content-Length: #{body.bytesize}",
      "Connection: close",
      "",
      body
    ].join("\r\n")
    
    client.print(response)
  end
  
  # ===========================================
  # Endpoints
  # ===========================================
  
  def handle_webhook(headers, client, query_params = {})
    # Auth check
    if AUTH_TOKEN && headers['authorization'] != "Bearer #{AUTH_TOKEN}"
      return [401, 'application/json', { error: 'Unauthorized' }.to_json]
    end
    
    # Read body
    content_length = headers['content-length']&.to_i || 0
    body = content_length > 0 ? client.read(content_length) : ''
    
    # Parse JSON
    begin
      payload = JSON.parse(body)
    rescue JSON::ParserError
      return [400, 'application/json', { error: 'Invalid JSON' }.to_json]
    end
    
    # Validate
    unless valid_payload?(payload)
      return [400, 'application/json', { error: 'Missing required fields' }.to_json]
    end
    
    # Determine target environment from query param
    env = query_params['env'] == 'test' ? 'test' : 'prod'
    queue_dir = QUEUE_DIRS[env]
    
    # Queue to appropriate directory
    queue_file = queue_webhook(payload, queue_dir: queue_dir)
    post_id = extract_post_id(payload['link_to_tweet'] || payload['LinkToTweet'])
    username = payload['username'] || payload['UserName']
    
    # Track per-environment stats
    @env_counts[env] += 1
    
    env_label = env == 'test' ? '🧪 TEST' : '🚀 PROD'
    log "Queued [#{env_label}]: @#{username}/#{post_id}"
    
    [200, 'application/json', { 
      status: 'queued',
      environment: env,
      queue_file: File.basename(queue_file),
      post_id: post_id
    }.to_json]
  end
  
  def handle_broadcast_webhook(headers, client)
    # Read body
    content_length = headers['content-length']&.to_i || 0
    body = content_length > 0 ? client.read(content_length) : ''

    # Verify HMAC signature
    unless verify_broadcast_signature(body, headers['x-hub-signature'])
      return [401, 'application/json', { error: 'Invalid signature' }.to_json]
    end

    # Parse JSON
    begin
      payload = JSON.parse(body)
    rescue JSON::ParserError
      return [400, 'application/json', { error: 'Invalid JSON' }.to_json]
    end

    # Quick filter: only status.created events
    unless payload['event'] == 'status.created'
      return [200, 'application/json', { status: 'ignored', reason: 'not status.created' }.to_json]
    end

    # Quick filter: only tlambot posts
    account_username = payload.dig('object', 'account', 'username')&.downcase
    unless account_username == BROADCAST_TRIGGER_ACCOUNT
      return [200, 'application/json', { status: 'ignored', reason: "not #{BROADCAST_TRIGGER_ACCOUNT}" }.to_json]
    end

    # Skip reblogs and replies
    if payload.dig('object', 'reblog')
      return [200, 'application/json', { status: 'ignored', reason: 'reblog' }.to_json]
    end
    if payload.dig('object', 'in_reply_to_id')
      return [200, 'application/json', { status: 'ignored', reason: 'reply' }.to_json]
    end

    # Queue the raw payload
    status_id = payload.dig('object', 'id') || 'unknown'
    timestamp = Time.now.strftime('%Y%m%d%H%M%S%L')
    filename = "#{timestamp}_tlambot_#{status_id}.json"
    pending_dir = File.join(BROADCAST_QUEUE_DIR, 'pending')
    FileUtils.mkdir_p(pending_dir)
    filepath = File.join(pending_dir, filename)

    File.write(filepath, body)

    @broadcast_count += 1
    log "📢 Broadcast queued: tlambot/#{status_id}"

    [200, 'application/json', {
      status: 'queued',
      queue_file: filename,
      status_id: status_id
    }.to_json]
  end

  def verify_broadcast_signature(body, signature_header)
    # Skip verification if no secret configured (development)
    return true unless BROADCAST_WEBHOOK_SECRET && !BROADCAST_WEBHOOK_SECRET.empty?
    return false unless signature_header.is_a?(String) && signature_header.start_with?('sha256=')

    expected_hex = signature_header.sub('sha256=', '')
    computed_hex = OpenSSL::HMAC.hexdigest('SHA256', BROADCAST_WEBHOOK_SECRET, body)

    # Constant-time comparison
    return false unless expected_hex.length == computed_hex.length

    computed_hex.bytes.zip(expected_hex.bytes).map { |a, b| a ^ b }.reduce(0, :|).zero?
  rescue StandardError
    false
  end

  def handle_health
    [200, 'application/json', {
      status: 'healthy',
      service: 'ifttt-webhook-light',
      uptime: (Time.now - @start_time).to_i,
      requests: @request_count,
      environments: %w[prod test]
    }.to_json]
  end
  
  def handle_stats
    stats = {
      server: { 
        requests: @request_count, 
        uptime: (Time.now - @start_time).to_i,
        requests_by_env: @env_counts.dup
      },
      environments: {}
    }
    
    QUEUE_DIRS.each do |env, queue_dir|
      stats[:environments][env] = {
        queue_dir: queue_dir,
        pending: count_files(queue_dir, 'pending'),
        processed: count_files(queue_dir, 'processed'),
        failed: count_files(queue_dir, 'failed')
      }
    end

    stats[:broadcast] = {
      queue_dir: BROADCAST_QUEUE_DIR,
      queued_total: @broadcast_count,
      pending: count_files(BROADCAST_QUEUE_DIR, 'pending'),
      processed: count_files(BROADCAST_QUEUE_DIR, 'processed'),
      failed: count_files(BROADCAST_QUEUE_DIR, 'failed')
    }
    
    [200, 'application/json', JSON.pretty_generate(stats)]
  end
  
  def count_files(queue_dir, subdir)
    Dir.glob(File.join(queue_dir, subdir, '*.json')).count
  rescue StandardError
    0
  end
  
  # ===========================================
  # Queue Management
  # ===========================================
  
  def valid_payload?(payload)
    link = payload['link_to_tweet'] || payload['LinkToTweet']
    text = payload['text'] || payload['Text']
    username = payload['username'] || payload['UserName']
    
    link && extract_post_id(link) && text && !text.empty? && username && !username.empty?
  end
  
  def queue_webhook(payload, queue_dir:)
    normalized = {
      'text' => payload['text'] || payload['Text'],
      'embed_code' => payload['embed_code'] || payload['TweetEmbedCode'],
      'link_to_tweet' => payload['link_to_tweet'] || payload['LinkToTweet'],
      'first_link_url' => payload['first_link_url'] || payload['FirstLinkUrl'],
      'username' => payload['username'] || payload['UserName'],
      'bot_id' => payload['bot_id'],
      'received_at' => Time.now.iso8601
    }
    
    post_id = extract_post_id(normalized['link_to_tweet'])
    timestamp = Time.now.strftime('%Y%m%d%H%M%S%L')
    filename = "#{timestamp}_#{normalized['username']}_#{post_id}.json"
    filepath = File.join(queue_dir, 'pending', filename)
    
    # Ensure directory exists (in case it was deleted)
    FileUtils.mkdir_p(File.join(queue_dir, 'pending'))
    
    File.write(filepath, JSON.generate(normalized))
    filepath
  end
  
  def extract_post_id(url)
    return nil unless url
    match = url.match(%r{(?:twitter\.com|x\.com)/\w+/status/(\d+)})
    match ? match[1] : nil
  end
  
  def ensure_queue_dirs
    QUEUE_DIRS.each_value do |queue_dir|
      %w[pending processed failed].each do |subdir|
        FileUtils.mkdir_p(File.join(queue_dir, subdir))
      end
    end
    # Broadcast queue
    %w[pending processed failed].each do |subdir|
      FileUtils.mkdir_p(File.join(BROADCAST_QUEUE_DIR, subdir))
    end
    @start_time = Time.now
  end
  
  # ===========================================
  # Background Threads
  # ===========================================
  
  def start_queue_processor
    Thread.new do
      log "Queue processor thread started (30s interval)"
      while @running
        sleep 30
        process_pending_queue
      end
    end
  end
  
  def process_pending_queue
    # Process only PROD queue when running integrated
    # Test queue should be processed by test cron
    pending_dir = File.join(QUEUE_DIRS['prod'], 'pending')
    files = Dir.glob(File.join(pending_dir, '*.json')).sort
    return if files.empty?
    
    log "Processing #{files.count} pending webhooks (PROD)..."
    
    # Lazy-load processor only when needed
    require_relative '../lib/webhook/ifttt_queue_processor'
    processor = Webhook::IftttQueueProcessor.new
    processor.process_queue
  rescue StandardError => e
    log "Queue processing error: #{e.message}", level: :error
  end
  
  def start_idle_checker
    Thread.new do
      while @running
        sleep 60
        idle_time = Time.now - @last_activity
        if idle_time > @idle_shutdown
          log "Idle timeout (#{idle_time.to_i}s), shutting down..."
          @running = false
        end
      end
    end
  end
  
  def setup_signal_handlers
    %w[INT TERM].each do |signal|
      trap(signal) do
        log "Received #{signal}, shutting down..."
        @running = false
      end
    end
  end
  
  def log(message, level: :info)
    prefix = level == :error ? '❌' : 'ℹ️'
    puts "[#{Time.now.strftime('%H:%M:%S')}] #{prefix} #{message}"
  end
end

# ===========================================
# CLI
# ===========================================

if __FILE__ == $PROGRAM_NAME
  require 'optparse'
  
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
  
  server = LightweightWebhookServer.new(**options)
  server.start
end
