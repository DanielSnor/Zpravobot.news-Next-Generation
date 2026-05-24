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

  # Per-host connection pool sizing.
  # Match Publishers::MastodonPublisher::MAX_MEDIA_COUNT (4) — to je dolní hranice
  # pro paralelní upload média, kde nás per-host keep-alive zajímá nejvíc.
  MAX_POOL_SIZE_PER_HOST = 4
  CHECKOUT_TIMEOUT = 5  # seconds — kdy se vzdát čekání na uvolněnou connection

  # Network errors eligible for retry
  RETRIABLE_ERRORS = [
    Net::OpenTimeout, Net::ReadTimeout,
    Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
    SocketError, Zpravobot::NetworkError
  ].freeze

  # Errors indicating a cached connection went stale (server closed it)
  STALE_CONNECTION_ERRORS = [Errno::EPIPE, IOError, Errno::ECONNRESET].freeze

  # Vyhozen, když pool je vyčerpán a čekající vlákno přesáhlo CHECKOUT_TIMEOUT.
  class PoolTimeoutError < StandardError; end

  # Per-host connection pool.
  #
  # Net::HTTP instance NENÍ thread-safe (interní IO buffery, request/response state),
  # takže dvě vlákna nesmí současně používat stejnou Net::HTTP. Pool drží až
  # MAX_POOL_SIZE_PER_HOST connections per host; vlákno si přes #checkout vyzvedne
  # exkluzivní vlastnictví, po dokončení requestu #checkin vrátí do poolu.
  # Pokud pool je plný a všechny connections jsou in_use, vlákno čeká na
  # ConditionVariable do CHECKOUT_TIMEOUT.
  #
  # Connection s last_used starším než CONNECTION_TTL se při checkoutu zahodí
  # a nahradí čerstvou — server-side keep-alive by ji stejně zavřel.
  class ConnectionPool
    def initialize(host, port, use_ssl)
      @host = host
      @port = port
      @use_ssl = use_ssl
      @entries = []  # Array<Hash{http:, in_use:, last_used:}>
      @mutex = Mutex.new
      @cond = ConditionVariable.new
    end

    # Získej exkluzivní Net::HTTP instanci. Blokuje až do checkout_timeout,
    # pokud je pool plný a všechny connections jsou in_use.
    # @raise [PoolTimeoutError] pokud timeout vypršel
    def checkout(open_timeout, read_timeout, checkout_timeout)
      deadline = Time.now + checkout_timeout
      @mutex.synchronize do
        loop do
          idle = @entries.find { |e| !e[:in_use] }
          if idle
            # Expirovaná connection → zavři + nahraď čerstvou
            if Time.now - idle[:last_used] > CONNECTION_TTL
              idle[:http].finish rescue nil
              idle[:http] = build_http(open_timeout, read_timeout)
            else
              idle[:http].open_timeout = open_timeout
              idle[:http].read_timeout = read_timeout
            end
            idle[:in_use] = true
            idle[:last_used] = Time.now
            return idle[:http]
          end

          if @entries.size < MAX_POOL_SIZE_PER_HOST
            http = build_http(open_timeout, read_timeout)
            @entries << { http: http, in_use: true, last_used: Time.now }
            return http
          end

          # Pool je plný a vše in_use → čekej na checkin
          remaining = deadline - Time.now
          raise PoolTimeoutError, "Pool exhausted for #{@host}:#{@port} (waited #{checkout_timeout}s)" if remaining <= 0
          @cond.wait(@mutex, remaining)
        end
      end
    end

    # Vrátí connection zpět do poolu jako volnou. Probudí jedno čekající vlákno.
    def checkin(http)
      @mutex.synchronize do
        entry = @entries.find { |e| e[:http].equal?(http) }
        if entry
          entry[:in_use] = false
          entry[:last_used] = Time.now
        end
        @cond.signal
      end
    end

    # Zahodí connection úplně (stale connection retry). Uvolňuje slot v poolu.
    def drop(http)
      @mutex.synchronize do
        @entries.reject! do |e|
          if e[:http].equal?(http)
            e[:http].finish rescue nil
            true
          else
            false
          end
        end
        @cond.signal
      end
    end

    # Pouze pro testy — zavře všechny connections a vyprázdní pool.
    def close_all
      @mutex.synchronize do
        @entries.each { |e| e[:http].finish rescue nil }
        @entries.clear
        @cond.broadcast
      end
    end

    # Pouze pro testy — počet aktuálně držených connections.
    def size
      @mutex.synchronize { @entries.size }
    end

    private

    def build_http(open_timeout, read_timeout)
      http = Net::HTTP.new(@host, @port)
      http.use_ssl = @use_ssl
      http.open_timeout = open_timeout
      http.read_timeout = read_timeout
      http.keep_alive_timeout = CONNECTION_TTL
      http
    end
  end

  # Per-host pools, klíč "host:port:scheme".
  @pools = {}
  @pools_mutex = Mutex.new

  module_function

  # Pouze pro testy — zavře všechny pooly a uvolní jejich connections.
  def reset_pools!
    @pools_mutex.synchronize do
      @pools.each_value(&:close_all)
      @pools.clear
    end
  end

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
  # Vyzvedne connection z per-host poolu, provede request, vrátí ji zpět.
  # Při stale connection error ji zahodí a zopakuje s čerstvou.
  #
  # @param uri [URI] Parsed URI
  # @param request [Net::HTTPRequest] Pre-built request object
  # @param open_timeout [Integer] Connection timeout in seconds
  # @param read_timeout [Integer] Read timeout in seconds
  # @return [Net::HTTPResponse]
  def execute(uri, request, open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT)
    pool = pool_for(uri)
    http = nil
    begin
      http = pool.checkout(open_timeout, read_timeout, CHECKOUT_TIMEOUT)
      return http.request(request)
    rescue *STALE_CONNECTION_ERRORS
      # Cached connection went stale — drop it, vyzvedni čerstvou a retry.
      # ensure níž zachytí finální stav http; drop už connection odstranil,
      # takže nás zajímá jen ten druhý checkout.
      pool.drop(http) if http
      http = pool.checkout(open_timeout, read_timeout, CHECKOUT_TIMEOUT)
      http.request(request)
    ensure
      pool.checkin(http) if http
    end
  end

  # Vyzvedne / vytvoří pool pro daný host:port:scheme.
  def pool_for(uri)
    key = "#{uri.host}:#{uri.port}:#{uri.scheme}"
    @pools_mutex.synchronize do
      @pools[key] ||= ConnectionPool.new(uri.host, uri.port, uri.scheme == 'https')
    end
  end
end
