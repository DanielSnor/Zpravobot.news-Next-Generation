# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require_relative '../errors'

# Shared HTTP client with standard retry, timeout and User-Agent handling
# Eliminates duplicated Net::HTTP boilerplate across adapters, syncers, and services
#
# Usage:
#   # Simple GET
#   response = HttpClient.get(url)
#
#   # GET with custom headers and timeouts
#   response = HttpClient.get(url,
#     headers: { 'Accept' => 'application/json' },
#     open_timeout: 5,
#     read_timeout: 10
#   )
#
#   # GET with retry
#   response = HttpClient.get_with_retry(url, max_retries: 3)
#
#   # POST with JSON body
#   response = HttpClient.post_json(url, { status: "Hello" },
#     headers: { 'Authorization' => 'Bearer token' }
#   )
#
#   # PUT with JSON body
#   response = HttpClient.put_json(url, { status: "Updated" },
#     headers: { 'Authorization' => 'Bearer token' }
#   )
#
#   # DELETE request
#   response = HttpClient.delete(url,
#     headers: { 'Authorization' => 'Bearer token' }
#   )
#
#   # Download binary data (follows redirects)
#   data = HttpClient.download(url)
#
#   # Any method with retry (rate limit + server error aware)
#   response = HttpClient.request_with_retry(:post_json, url, { status: "Hello" },
#     headers: { 'Authorization' => 'Bearer token' },
#     max_retries: 3
#   )
#
#   # HEAD request (for redirects)
#   response = HttpClient.head(url, open_timeout: 3, read_timeout: 3)
#
module HttpClient
  # Standard User-Agent strings
  DEFAULT_UA  = 'Zpravobot/1.0 (+https://zpravobot.news)'
  GOOGLEBOT_UA = 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)'

  # Default timeouts (seconds)
  DEFAULT_OPEN_TIMEOUT = 10
  DEFAULT_READ_TIMEOUT = 30

  # Default retry configuration
  DEFAULT_MAX_RETRIES  = 3
  DEFAULT_RETRY_DELAYS = [1, 2, 4].freeze

  # Connection cache TTL — close idle connections after this many seconds
  CONNECTION_TTL = 30

  # Network errors eligible for retry
  RETRIABLE_ERRORS = [
    Net::OpenTimeout, Net::ReadTimeout,
    Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
    SocketError, Zpravobot::NetworkError
  ].freeze

  # Errors indicating a cached connection went stale (server closed it)
  STALE_CONNECTION_ERRORS = [Errno::EPIPE, IOError, Errno::ECONNRESET].freeze

  # Per-host connection cache: "host:port" → { http: Net::HTTP, last_used: Time }
  @connections = {}
  @connections_mutex = Mutex.new

  module_function

  # Perform a GET request
  #
  # @param url [String, URI] URL to fetch
  # @param headers [Hash] Additional request headers
  # @param open_timeout [Integer] Connection timeout in seconds
  # @param read_timeout [Integer] Read timeout in seconds
  # @param user_agent [String] User-Agent header value
  # @return [Net::HTTPResponse]
  def get(url, headers: {}, open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT, user_agent: DEFAULT_UA)
    uri = url.is_a?(URI) ? url : URI(url)
    request = Net::HTTP::Get.new(uri)
    request['User-Agent'] = user_agent
    headers.each { |k, v| request[k] = v }

    execute(uri, request, open_timeout: open_timeout, read_timeout: read_timeout)
  end

  # Perform a POST request with JSON body
  #
  # @param url [String, URI] URL to post to
  # @param body [Hash, nil] Request body (will be JSON-encoded)
  # @param headers [Hash] Additional request headers
  # @param open_timeout [Integer] Connection timeout in seconds
  # @param read_timeout [Integer] Read timeout in seconds
  # @param user_agent [String] User-Agent header value
  # @return [Net::HTTPResponse]
  def post_json(url, body = nil, headers: {}, open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT, user_agent: DEFAULT_UA)
    uri = url.is_a?(URI) ? url : URI(url)
    request = Net::HTTP::Post.new(uri)
    request['User-Agent'] = user_agent
    request['Content-Type'] = 'application/json'
    headers.each { |k, v| request[k] = v }
    request.body = JSON.generate(body) if body

    execute(uri, request, open_timeout: open_timeout, read_timeout: read_timeout)
  end

  # Perform a POST request with raw body (for multipart uploads etc.)
  #
  # @param url [String, URI] URL to post to
  # @param request [Net::HTTP::Post] Pre-built request with body and headers
  # @param open_timeout [Integer] Connection timeout
  # @param read_timeout [Integer] Read timeout
  # @return [Net::HTTPResponse]
  def post_raw(url, request, open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT)
    uri = url.is_a?(URI) ? url : URI(url)
    execute(uri, request, open_timeout: open_timeout, read_timeout: read_timeout)
  end

  # Perform a PUT request with JSON body
  #
  # @param url [String, URI] URL
  # @param body [Hash, nil] Request body (will be JSON-encoded)
  # @param headers [Hash] Additional request headers
  # @param open_timeout [Integer] Connection timeout
  # @param read_timeout [Integer] Read timeout
  # @param user_agent [String] User-Agent header
  # @return [Net::HTTPResponse]
  def put_json(url, body = nil, headers: {}, open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT, user_agent: DEFAULT_UA)
    uri = url.is_a?(URI) ? url : URI(url)
    request = Net::HTTP::Put.new(uri)
    request['User-Agent'] = user_agent
    request['Content-Type'] = 'application/json'
    headers.each { |k, v| request[k] = v }
    request.body = JSON.generate(body) if body

    execute(uri, request, open_timeout: open_timeout, read_timeout: read_timeout)
  end

  # Perform a PATCH request with form/multipart body
  #
  # @param url [String, URI] URL
  # @param request [Net::HTTP::Patch] Pre-built request
  # @param open_timeout [Integer] Connection timeout
  # @param read_timeout [Integer] Read timeout
  # @return [Net::HTTPResponse]
  def patch_raw(url, request, open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT)
    uri = url.is_a?(URI) ? url : URI(url)
    execute(uri, request, open_timeout: open_timeout, read_timeout: read_timeout)
  end

  # Perform a DELETE request
  #
  # @param url [String, URI] URL
  # @param headers [Hash] Additional request headers
  # @param open_timeout [Integer] Connection timeout
  # @param read_timeout [Integer] Read timeout
  # @param user_agent [String] User-Agent header
  # @return [Net::HTTPResponse]
  def delete(url, headers: {}, open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT, user_agent: DEFAULT_UA)
    uri = url.is_a?(URI) ? url : URI(url)
    request = Net::HTTP::Delete.new(uri)
    request['User-Agent'] = user_agent
    headers.each { |k, v| request[k] = v }

    execute(uri, request, open_timeout: open_timeout, read_timeout: read_timeout)
  end

  # Perform a HEAD request
  #
  # @param url [String, URI] URL to check
  # @param open_timeout [Integer] Connection timeout in seconds
  # @param read_timeout [Integer] Read timeout in seconds
  # @param user_agent [String] User-Agent header value
  # @return [Net::HTTPResponse]
  def head(url, open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT, user_agent: DEFAULT_UA)
    uri = url.is_a?(URI) ? url : URI(url)
    request = Net::HTTP::Head.new(uri)
    request['User-Agent'] = user_agent

    execute(uri, request, open_timeout: open_timeout, read_timeout: read_timeout)
  end

  # Download binary data from URL with redirect following
  #
  # @param url [String, URI] URL to download
  # @param max_redirects [Integer] Maximum number of redirects to follow
  # @param max_size [Integer, nil] Maximum response body size in bytes (nil = no limit)
  # @param headers [Hash] Additional request headers
  # @param open_timeout [Integer] Connection timeout
  # @param read_timeout [Integer] Read timeout
  # @param user_agent [String] User-Agent header
  # @return [Net::HTTPResponse, nil] Response with body, or nil on failure
  def download(url, max_redirects: 3, max_size: nil, headers: {},
               open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT,
               user_agent: DEFAULT_UA, on_failure: nil)
    uri = url.is_a?(URI) ? url : URI(url)
    redirect_count = 0

    loop do
      # Use streaming GET when max_size is set — avoids loading entire body
      # into memory just to check its size (critical for large video files).
      response = max_size \
        ? streaming_get(uri, headers: headers, open_timeout: open_timeout,
                        read_timeout: read_timeout, user_agent: user_agent, max_size: max_size)
        : get(uri, headers: headers, open_timeout: open_timeout,
                   read_timeout: read_timeout, user_agent: user_agent)

      if response.is_a?(Net::HTTPRedirection)
        redirect_count += 1
        return nil if redirect_count > max_redirects

        new_uri = URI(response['location'])
        uri = new_uri.host ? new_uri : URI.join(uri, response['location'])
        next
      end

      return :too_large if response == :too_large

      unless response.is_a?(Net::HTTPSuccess)
        on_failure&.call(response)
        return nil
      end

      return response
    end
  end

  # Streaming GET — reads body in chunks, returns :too_large if limit exceeded.
  # Uses a dedicated connection (no pool) so early abort is always safe.
  # Content-Length header is checked first; falls back to byte-counting during read.
  def streaming_get(uri, headers:, open_timeout:, read_timeout:, user_agent:, max_size:)
    request = Net::HTTP::Get.new(uri)
    request['User-Agent'] = user_agent
    headers.each { |k, v| request[k] = v }

    Net::HTTP.start(uri.host, uri.port,
                    use_ssl:      uri.scheme == 'https',
                    open_timeout: open_timeout,
                    read_timeout: read_timeout) do |http|
      http.request(request) do |resp|
        # Non-success (redirects, errors): drain small body and return as-is
        unless resp.is_a?(Net::HTTPSuccess)
          resp.read_body
          return resp
        end

        # Check Content-Length header first — skip body entirely if over limit
        cl = resp['content-length']&.to_i
        return :too_large if cl && cl > max_size

        # Stream body in chunks, counting bytes
        total  = 0
        chunks = []
        resp.read_body do |chunk|
          total += chunk.bytesize
          return :too_large if total > max_size
          chunks << chunk
        end

        resp.instance_variable_set(:@body, chunks.join)
        resp
      end
    end
  rescue *STALE_CONNECTION_ERRORS
    nil
  end

  # Perform a GET request with automatic retry and exponential backoff
  #
  # @param url [String, URI] URL to fetch
  # @param headers [Hash] Additional request headers
  # @param open_timeout [Integer] Connection timeout in seconds
  # @param read_timeout [Integer] Read timeout in seconds
  # @param user_agent [String] User-Agent header value
  # @param max_retries [Integer] Maximum number of attempts
  # @param retry_delays [Array<Numeric>] Delay (seconds) between retries
  # @param on_retry [Proc, nil] Optional callback(attempt, error) called before sleep
  # @return [Net::HTTPResponse]
  # @raise [StandardError] Last error if all retries exhausted
  def get_with_retry(url, headers: {}, open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT,
                     user_agent: DEFAULT_UA, max_retries: DEFAULT_MAX_RETRIES,
                     retry_delays: DEFAULT_RETRY_DELAYS, on_retry: nil)
    last_error = nil

    max_retries.times do |attempt|
      begin
        response = get(url, headers: headers, open_timeout: open_timeout,
                           read_timeout: read_timeout, user_agent: user_agent)
        return response
      rescue *RETRIABLE_ERRORS => e
        last_error = e

        if attempt < max_retries - 1
          delay = retry_delays[attempt] || retry_delays.last
          on_retry&.call(attempt, e)
          sleep(delay)
        end
      end
    end

    raise last_error
  end

  # Execute any method with retry, including rate limit (429) and server error (5xx) handling
  #
  # @param method [Symbol] HttpClient method to call (:get, :post_json, :put_json, :delete)
  # @param args [Array] Positional arguments for the method
  # @param max_retries [Integer] Maximum retry attempts
  # @param retry_delays [Array<Numeric>] Delays between retries
  # @param on_retry [Proc, nil] Optional callback(attempt, error)
  # @param kwargs [Hash] Keyword arguments for the method
  # @return [Net::HTTPResponse]
  # @raise [Zpravobot::RateLimitError, Zpravobot::ServerError, StandardError]
  def request_with_retry(method, *args, max_retries: DEFAULT_MAX_RETRIES,
                         retry_delays: DEFAULT_RETRY_DELAYS, on_retry: nil, **kwargs)
    last_error = nil

    max_retries.times do |attempt|
      begin
        response = send(method, *args, **kwargs)

        # Raise on rate limit to trigger retry
        if response.code.to_i == 429
          retry_after = (response['Retry-After'] || '5').to_i
          raise Zpravobot::RateLimitError.new("Rate limited (429)", retry_after: retry_after)
        end

        # Raise on server error to trigger retry
        if response.code.to_i >= 500
          raise Zpravobot::ServerError.new(status_code: response.code.to_i)
        end

        return response

      rescue Zpravobot::RateLimitError => e
        last_error = e
        if attempt < max_retries - 1
          wait = e.retry_after + rand(1..3)
          on_retry&.call(attempt, e)
          sleep(wait)
        end

      rescue Zpravobot::ServerError => e
        last_error = e
        if attempt < max_retries - 1
          wait = retry_delays[attempt] || retry_delays.last
          on_retry&.call(attempt, e)
          sleep(wait)
        end

      rescue *RETRIABLE_ERRORS => e
        last_error = e
        if attempt < max_retries - 1
          delay = retry_delays[attempt] || retry_delays.last
          on_retry&.call(attempt, e)
          sleep(delay)
        end
      end
    end

    raise last_error
  end

  # Execute an arbitrary pre-built request (GET, POST, PATCH, etc.)
  # Retries once on stale cached connection.
  #
  # @param uri [URI] Parsed URI
  # @param request [Net::HTTPRequest] Pre-built request object
  # @param open_timeout [Integer] Connection timeout in seconds
  # @param read_timeout [Integer] Read timeout in seconds
  # @return [Net::HTTPResponse]
  def execute(uri, request, open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT)
    http = build_http(uri, open_timeout: open_timeout, read_timeout: read_timeout)
    http.start unless http.started?
    http.request(request)
  rescue *STALE_CONNECTION_ERRORS
    # Cached connection went stale — drop it and retry with a fresh one
    drop_cached_connection(uri)
    http = build_http(uri, open_timeout: open_timeout, read_timeout: read_timeout)
    http.start unless http.started?
    http.request(request)
  end

  # Build or reuse a configured Net::HTTP instance.
  # Caches connections per host:port with TTL-based expiry.
  # Connection is started lazily in execute, not here (keeps unit tests offline).
  #
  # @param uri [URI] Parsed URI
  # @param open_timeout [Integer] Connection timeout
  # @param read_timeout [Integer] Read timeout
  # @return [Net::HTTP]
  def build_http(uri, open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT)
    key = "#{uri.host}:#{uri.port}:#{Thread.current.object_id}"

    @connections_mutex.synchronize do
      cached = @connections[key]
      if cached && cached[:http].started? && (Time.now - cached[:last_used]) < CONNECTION_TTL
        http = cached[:http]
        http.open_timeout = open_timeout
        http.read_timeout = read_timeout
        cached[:last_used] = Time.now
        return http
      end

      # Close stale/expired connection if present
      if cached
        cached[:http].finish rescue nil
        @connections.delete(key)
      end

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.open_timeout = open_timeout
      http.read_timeout = read_timeout
      http.keep_alive_timeout = CONNECTION_TTL

      @connections[key] = { http: http, last_used: Time.now }
      http
    end
  end

  # Close all cached connections (call at end of run)
  def close_all_connections
    @connections_mutex.synchronize do
      @connections.each_value { |c| c[:http].finish rescue nil }
      @connections.clear
    end
  end

  # Drop a single cached connection (used on stale connection retry)
  def drop_cached_connection(uri)
    key = "#{uri.host}:#{uri.port}:#{Thread.current.object_id}"
    @connections_mutex.synchronize do
      cached = @connections.delete(key)
      cached[:http].finish rescue nil if cached
    end
  end
end
