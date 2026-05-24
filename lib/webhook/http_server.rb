# frozen_string_literal: true

require 'socket'
require 'json'
require 'time'
require 'fileutils'
require 'uri'

require_relative 'routes/ifttt_route'
require_relative 'routes/broadcast_route'

module Webhook
  # Lightweight HTTP server for IFTTT and broadcast webhooks.
  #
  # Accepts incoming POST requests, routes them to the appropriate handler,
  # and optionally runs an integrated queue processor thread.
  #
  # Usage:
  #   server = Webhook::HttpServer.new(
  #     port: 8089, bind: '0.0.0.0',
  #     auth_token: ENV['IFTTT_AUTH_TOKEN'],
  #     queue_dirs: { 'prod' => '/path/to/queue', 'test' => '/path/to/queue-test' },
  #     broadcast_queue_dir: '/path/to/broadcast',
  #     broadcast_secret: ENV['TLAMBOT_WEBHOOK_SECRET']
  #   )
  #   server.start
  class HttpServer
    MAX_PAYLOAD_SIZE = 1_048_576  # 1 MB — defence against OOM via crafted Content-Length
    REQUEST_TIMEOUT  = 5          # seconds — SO_RCVTIMEO/SO_SNDTIMEO on accepted sockets

    def initialize(port:, bind:, auth_token:, queue_dirs:, broadcast_queue_dir:,
                   broadcast_secret:, process_queue: false, idle_shutdown: nil)
      @port                = port
      @bind                = bind
      @process_queue       = process_queue
      @idle_shutdown       = idle_shutdown
      @queue_dirs          = queue_dirs
      @broadcast_queue_dir = broadcast_queue_dir

      @running         = true
      @request_count   = 0
      @env_counts      = { 'prod' => 0, 'test' => 0 }
      @broadcast_count = 0
      @last_activity   = Time.now

      @ifttt_route     = Routes::IftttRoute.new(queue_dirs: queue_dirs, auth_token: auth_token)
      @broadcast_route = Routes::BroadcastRoute.new(queue_dir: broadcast_queue_dir, secret: broadcast_secret)

      ensure_queue_dirs
    end

    def start
      server = Socket.new(:INET, :STREAM)
      server.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)
      server.bind(Socket.sockaddr_in(@port, @bind))
      server.listen(Socket::SOMAXCONN)

      log "IFTTT Webhook server listening on #{@bind}:#{@port}"
      log "Queue directories:"
      log "  IFTTT PROD: #{@queue_dirs['prod']}"
      log "  IFTTT TEST: #{@queue_dirs['test']}"
      log "  Broadcast:  #{@broadcast_queue_dir}"
      log "Process queue: #{@process_queue ? 'enabled' : 'disabled (use cron)'}"
      log "Idle shutdown: #{@idle_shutdown ? "#{@idle_shutdown}s" : 'disabled'}"

      setup_signal_handlers
      start_queue_processor if @process_queue
      start_idle_checker    if @idle_shutdown

      while @running
        begin
          ready = IO.select([server], nil, nil, 1)
          next unless ready

          client, = server.accept
          timeval = [REQUEST_TIMEOUT, 0].pack('l_2')
          client.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, timeval)
          client.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDTIMEO, timeval)
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

    # ----------------------------------------------------------------
    # Request handling
    # ----------------------------------------------------------------

    def handle_request(client)
      @last_activity = Time.now
      @request_count += 1

      request_line = client.gets
      return client.close unless request_line

      method, full_path, _version = request_line.split
      path, query_string = full_path.to_s.split('?', 2)
      query_params = parse_query_string(query_string)
      headers      = read_headers(client)

      status, body_hash, log_msg = route(method, path, query_params, headers, client)
      body = body_hash.is_a?(String) ? body_hash : JSON.generate(body_hash)

      send_response(client, status, body)
      log log_msg if log_msg
      client.close
    rescue StandardError => e
      log "Request error: #{e.message}", level: :error
      send_response(client, 500, JSON.generate({ error: e.message })) rescue nil
      client.close rescue nil
    end

    def route(method, path, query_params, headers, client)
      case [method, path]
      when ['POST', '/api/ifttt/twitter']
        status, data, msg = @ifttt_route.call(headers, client, query_params,
                                              max_payload_size: MAX_PAYLOAD_SIZE)
        @env_counts[query_params['env'] == 'test' ? 'test' : 'prod'] += 1 if status == 200
        [status, data, msg]

      when ['POST', '/api/mastodon/broadcast']
        status, data, msg = @broadcast_route.call(headers, client, max_payload_size: MAX_PAYLOAD_SIZE)
        @broadcast_count += 1 if status == 200 && data.is_a?(Hash) && data[:status] == 'queued'
        [status, data, msg]

      when ['GET', '/health']
        [200, { status: 'healthy', service: 'ifttt-webhook',
                uptime: uptime, requests: @request_count }]

      when ['GET', '/stats']
        [200, build_stats]

      else
        [404, { error: 'Not found' }]
      end
    end

    def parse_query_string(qs)
      return {} unless qs
      qs.split('&').each_with_object({}) do |pair, h|
        k, v = pair.split('=', 2)
        h[URI.decode_www_form_component(k)] = URI.decode_www_form_component(v || '')
      end
    rescue StandardError
      {}
    end

    def read_headers(client)
      headers = {}
      while (line = client.gets) && line != "\r\n"
        k, v = line.split(': ', 2)
        headers[k.downcase] = v&.strip
      end
      headers
    end

    def send_response(client, status, body)
      text = { 200 => 'OK', 400 => 'Bad Request', 401 => 'Unauthorized',
               404 => 'Not Found', 413 => 'Payload Too Large',
               500 => 'Internal Server Error' }[status] || 'Unknown'
      client.print([
        "HTTP/1.1 #{status} #{text}",
        "Content-Type: application/json",
        "Content-Length: #{body.bytesize}",
        "Connection: close",
        "",
        body
      ].join("\r\n"))
    end

    # ----------------------------------------------------------------
    # Stats & helpers
    # ----------------------------------------------------------------

    def build_stats
      envs = @queue_dirs.transform_values do |dir|
        { queue_dir:  dir,
          pending:    count_files(dir, 'pending'),
          processed:  count_files(dir, 'processed'),
          failed:     count_files(dir, 'failed') }
      end
      {
        server: { requests: @request_count, uptime: uptime,
                  requests_by_env: @env_counts.dup },
        environments: envs,
        broadcast: {
          queue_dir:    @broadcast_queue_dir,
          queued_total: @broadcast_count,
          pending:      count_files(@broadcast_queue_dir, 'pending'),
          processed:    count_files(@broadcast_queue_dir, 'processed'),
          failed:       count_files(@broadcast_queue_dir, 'failed')
        }
      }
    end

    def count_files(dir, subdir)
      Dir.glob(File.join(dir, subdir, '*.json')).count
    rescue StandardError
      0
    end

    def uptime
      @start_time ? (Time.now - @start_time).to_i : 0
    end

    def ensure_queue_dirs
      @queue_dirs.each_value do |dir|
        %w[pending processed failed].each { |s| FileUtils.mkdir_p(File.join(dir, s)) }
      end
      %w[pending processed failed].each { |s| FileUtils.mkdir_p(File.join(@broadcast_queue_dir, s)) }
      @start_time = Time.now
    end

    # ----------------------------------------------------------------
    # Background threads
    # ----------------------------------------------------------------

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
      pending_dir = File.join(@queue_dirs['prod'], 'pending')
      files = Dir.glob(File.join(pending_dir, '*.json')).sort
      return if files.empty?

      log "Processing #{files.count} pending webhooks (PROD)..."
      require_relative 'ifttt_queue_processor'
      Webhook::IftttQueueProcessor.new.process_queue
    rescue StandardError => e
      log "Queue processing error: #{e.message}", level: :error
    end

    def start_idle_checker
      Thread.new do
        while @running
          sleep 60
          idle = Time.now - @last_activity
          if idle > @idle_shutdown
            log "Idle timeout (#{idle.to_i}s), shutting down..."
            @running = false
          end
        end
      end
    end

    def setup_signal_handlers
      %w[INT TERM].each do |sig|
        trap(sig) { log "Received #{sig}, shutting down..."; @running = false }
      end
    end

    def log(message, level: :info)
      prefix = level == :error ? '❌' : 'ℹ️'
      puts "[#{Time.now.strftime('%H:%M:%S')}] #{prefix} #{message}"
    end
  end
end
