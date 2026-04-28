# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'yaml'
require 'time'

require_relative '../support/loggable'

module Publishers
  # Publishes posts to Bluesky via the AT Protocol (XRPC).
  #
  # Usage:
  #   publisher = Publishers::BlueskyPublisher.new(account_id: 'zpravobot')
  #   publisher.publish("Hello Bluesky!")
  #   publisher.publish_thread(["Post 1", "Post 2"])
  #
  # Credentials are loaded from config/bluesky_accounts.yml (identifier + ENV var name)
  # and the actual app password from the ENV var named in that file.
  class BlueskyPublisher
    include Support::Loggable

    class BlueskyAuthError      < StandardError; end
    class BlueskyPublishError   < StandardError; end
    class BlueskyRateLimitError < StandardError; end

    THROTTLE_SECONDS = 1
    MAX_RETRIES      = 3
    CHAR_LIMIT       = 300
    OPEN_TIMEOUT     = 5
    READ_TIMEOUT     = 20

    URL_PATTERN            = %r{https?://[^\s]+}
    MASTODON_HANDLE_PATTERN = /@([\w][\w.-]*)@([\w][\w.-]*\.[a-z]{2,})/

    def initialize(account_id: 'zpravobot')
      creds      = load_credentials(account_id.to_s)
      @pds_url   = creds[:pds_url].chomp('/')
      session    = create_session(creds[:identifier], creds[:password])
      @access_jwt = session['accessJwt']
      @did        = session['did']
      @handle     = session['handle']
      log_info("[BS] Authenticated as #{@handle}")
    end

    # Safe constructor: returns a publisher on success, or nil if init/auth
    # fails. Use from cron entry points so a Bluesky outage does not abort
    # the primary Mastodon publish path.
    def self.try_create(account_id: 'zpravobot')
      new(account_id: account_id)
    rescue StandardError => e
      warn "[BS] Init failed for '#{account_id}' (#{e.class}: #{e.message}) — Bluesky publishing skipped"
      nil
    end

    # Publish a single post.
    # @return [Hash] { uri:, cid: }
    def publish(text)
      result = create_record(build_record(text))
      log_info("[BS] Published: #{result['uri']}")
      { uri: result['uri'], cid: result['cid'] }
    end

    # Publish an array of texts as a reply chain (thread).
    # @param posts [Array<String>]
    # @return [Array<Hash>] array of { uri:, cid: }
    def publish_thread(posts)
      results    = []
      root_ref   = nil
      parent_ref = nil

      posts.each_with_index do |text, idx|
        sleep(THROTTLE_SECONDS) if idx > 0

        record = build_record(text)

        unless idx.zero?
          record['reply'] = {
            'root'   => { 'uri' => root_ref[:uri],   'cid' => root_ref[:cid] },
            'parent' => { 'uri' => parent_ref[:uri], 'cid' => parent_ref[:cid] }
          }
        end

        result = create_record(record)
        ref    = { uri: result['uri'], cid: result['cid'] }
        log_info("[BS] Published #{idx + 1}/#{posts.size}: #{ref[:uri]}")

        root_ref   ||= ref
        parent_ref   = ref
        results << ref
      end

      results
    end

    private

    # ----------------------------------------------------------------
    # Credentials
    # ----------------------------------------------------------------

    def load_credentials(account_id)
      path     = accounts_file_path
      accounts = YAML.safe_load(File.read(path, encoding: 'UTF-8'),
                                permitted_classes: [], aliases: true)
      account  = accounts&.dig(account_id)
      raise "Bluesky account '#{account_id}' not found in #{path}" unless account

      identifier = account['identifier']
      env_name   = account['app_password_env']
      password   = ENV[env_name]
      pds_url    = account['pds_url'] || 'https://bsky.social'

      raise "ENV var #{env_name} not set (app password for account '#{account_id}')" unless password

      { identifier: identifier, password: password, pds_url: pds_url }
    end

    def accounts_file_path
      if ENV['ZBNW_CONFIG_DIR']
        File.join(ENV['ZBNW_CONFIG_DIR'], 'bluesky_accounts.yml')
      elsif ENV['ZBNW_DIR']
        File.join(ENV['ZBNW_DIR'], 'config', 'bluesky_accounts.yml')
      else
        File.expand_path('../../../config/bluesky_accounts.yml', __FILE__)
      end
    end

    # ----------------------------------------------------------------
    # Session
    # ----------------------------------------------------------------

    def create_session(identifier, password)
      response = xrpc_post(
        'com.atproto.server.createSession',
        { identifier: identifier, password: password }
      )
      response
    rescue BlueskyPublishError => e
      raise BlueskyAuthError, "Authentication failed: #{e.message}"
    end

    # ----------------------------------------------------------------
    # Record building
    # ----------------------------------------------------------------

    def build_record(text)
      text   = text.gsub(MASTODON_HANDLE_PATTERN) { "https://#{$2}/@#{$1}" }
      record = {
        '$type'     => 'app.bsky.feed.post',
        'text'      => text,
        'createdAt' => Time.now.utc.iso8601(3),
        'langs'     => ['cs']
      }
      facets = build_facets(text)
      record['facets'] = facets unless facets.empty?
      record
    end

    def build_facets(text)
      facets = []
      text.scan(URL_PATTERN) do |url|
        match      = Regexp.last_match
        byte_start = text[0...match.begin(0)].bytesize
        byte_end   = byte_start + url.bytesize
        facets << {
          'index'    => { 'byteStart' => byte_start, 'byteEnd' => byte_end },
          'features' => [{ '$type' => 'app.bsky.richtext.facet#link', 'uri' => url }]
        }
      end
      facets
    end

    # ----------------------------------------------------------------
    # XRPC
    # ----------------------------------------------------------------

    def create_record(record)
      with_retry do
        xrpc_post(
          'com.atproto.repo.createRecord',
          { repo: @did, collection: 'app.bsky.feed.post', record: record },
          jwt: @access_jwt
        )
      end
    end

    def xrpc_post(endpoint, body, jwt: nil)
      uri  = URI("#{@pds_url}/xrpc/#{endpoint}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = uri.scheme == 'https'
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      req = Net::HTTP::Post.new(uri.path)
      req['Content-Type']  = 'application/json'
      req['Authorization'] = "Bearer #{jwt}" if jwt
      req.body = JSON.generate(body)

      resp = http.request(req)
      handle_response(resp, endpoint)
    end

    def handle_response(resp, endpoint)
      code = resp.code.to_i

      if code == 429
        retry_after = [resp['Retry-After'].to_i, 60].min
        retry_after = 5 if retry_after < 1
        log_warn("[BS] Rate limited — waiting #{retry_after}s")
        sleep(retry_after)
        raise BlueskyRateLimitError, "Rate limited on #{endpoint}"
      end

      if code == 401 || code == 403
        data = safe_parse_json(resp.body)
        msg  = data&.dig('message') || data&.dig('error') || resp.body[0, 200]
        raise BlueskyAuthError, "HTTP #{code} from #{endpoint}: #{msg}"
      end

      unless resp.is_a?(Net::HTTPSuccess)
        data = safe_parse_json(resp.body)
        msg  = data&.dig('message') || data&.dig('error') || resp.body[0, 200]
        raise BlueskyPublishError, "HTTP #{code} from #{endpoint}: #{msg}"
      end

      JSON.parse(resp.body)
    end

    def with_retry
      attempts = 0
      begin
        attempts += 1
        yield
      rescue BlueskyRateLimitError
        raise if attempts >= MAX_RETRIES
        retry
      rescue BlueskyPublishError => e
        raise if attempts >= MAX_RETRIES
        backoff = 2**attempts
        log_warn("[BS] Transient error (attempt #{attempts}/#{MAX_RETRIES}), retrying in #{backoff}s: #{e.message}")
        sleep(backoff)
        retry
      end
    end

    def safe_parse_json(body)
      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end
  end
end
