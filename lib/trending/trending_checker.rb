# frozen_string_literal: true

require 'json'
require 'time'
require 'set'
require 'fileutils'
require 'net/http'
require 'uri'

# Core logic for detecting and quote-posting new trending statuses.
#
# Usage:
#   checker = Trending::TrendingChecker.new(
#     instance_url: 'https://zpravobot.news',
#     access_token:  'abc123',
#     dry_run:       false
#   )
#   result = checker.run
#   # => { checked: 5, posted: 2 }
#
module Trending
  class TrendingChecker
    MAX_POSTS_PER_RUN  = 5
    THROTTLE_SECONDS   = 2
    MAX_ANNOUNCED_IDS  = 200
    DEFAULT_STATE_FILE = 'data/trending_state.json'
    HEADER_LINE        = '📈 Na Zprávobot.news právě trenduje'
    HASHTAGS_LINE      = '#zpravobot #trending'

    # Bot accounts whose posts are always excluded from trending quotes
    BOT_ACCOUNTS = %w[betabot udrzbot tlambot].freeze

    # @param instance_url  [String]  Base URL of the Mastodon instance (no trailing slash)
    # @param access_token  [String]  Bearer token for @zpravobot
    # @param state_path    [String]  Override for the state JSON file path
    # @param dry_run       [Boolean] When true, prints actions without HTTP POSTs
    # @param commenter     [#comment_for, nil] Optional AI commenter for Hrubot comments
    def initialize(instance_url:, access_token:, state_path: nil, dry_run: false, commenter: nil)
      @instance_url = instance_url.chomp('/')
      @access_token = access_token
      @state_path   = state_path || resolve_state_path
      @dry_run      = dry_run
      @commenter    = commenter
    end

    # Run one trending check cycle.
    #
    # @return [Hash] { checked: Integer, posted: Integer }
    def run
      trends    = fetch_trends
      state     = load_state
      new_trends = filter_new(trends, state)

      if new_trends.empty?
        update_check_time(state)
        return { checked: trends.size, posted: 0 }
      end

      posted = publish_quotes(new_trends, state)
      save_state(state)
      { checked: trends.size, posted: posted }
    end

    private

    # ----------------------------------------------------------------
    # HTTP helpers
    # ----------------------------------------------------------------

    def auth_headers
      { 'Authorization' => "Bearer #{@access_token}" }
    end

    # GET /api/v1/trends/statuses?limit=20
    # Returns array of status hashes (string keys).
    def fetch_trends
      url = "#{@instance_url}/api/v1/trends/statuses?limit=20"
      uri = URI(url)

      response = http_get(uri, auth_headers)
      code = response.code.to_i

      unless (200..299).cover?(code)
        raise "Trends API returned HTTP #{code}: #{response.body[0, 200]}"
      end

      parsed = JSON.parse(response.body)

      # Mastodon returns an Array; guard against unexpected response shapes
      # (e.g. {"error":"..."} when trends are disabled or token is invalid)
      unless parsed.is_a?(Array)
        raise "Trends API returned unexpected response (#{parsed.class}): #{response.body[0, 200]}"
      end

      parsed
    rescue JSON::ParserError => e
      raise "Failed to parse trends response: #{e.message}"
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise "Trends API timeout: #{e.message}"
    rescue SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH => e
      raise "Trends API unreachable: #{e.message}"
    end

    # POST /api/v1/statuses — publish a quote post.
    # Returns true on success, nil on HTTP 422 (quote denied) or other 4xx/5xx.
    def post_quote(trend)
      status_id = trend['id']
      url  = "#{@instance_url}/api/v1/statuses"
      uri  = URI(url)
      body = JSON.generate(
        status:           build_status_text(trend),
        quoted_status_id: status_id,
        visibility:       'public'
      )

      headers = auth_headers.merge(
        'Content-Type' => 'application/json'
      )

      response = http_post(uri, body, headers)
      code     = response.code.to_i

      if code == 422
        warn "  [WARN] Quote denied (422) for status #{status_id} — skipping"
        return nil
      end

      unless (200..299).cover?(code)
        warn "  [WARN] Publish failed (HTTP #{code}) for status #{status_id}: #{response.body[0, 200]}"
        return nil
      end

      true
    end

    # Low-level GET via Net::HTTP (SSL-aware)
    def http_get(uri, headers = {})
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                      open_timeout: 10, read_timeout: 20) do |http|
        req = Net::HTTP::Get.new(uri)
        headers.each { |k, v| req[k] = v }
        http.request(req)
      end
    end

    # Low-level POST via Net::HTTP (SSL-aware)
    def http_post(uri, body, headers = {})
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                      open_timeout: 10, read_timeout: 20) do |http|
        req = Net::HTTP::Post.new(uri)
        headers.each { |k, v| req[k] = v }
        req.body = body
        http.request(req)
      end
    end

    # ----------------------------------------------------------------
    # State helpers
    # ----------------------------------------------------------------

    def load_state
      return empty_state unless File.exist?(@state_path)

      JSON.parse(File.read(@state_path))
    rescue JSON::ParserError
      warn "  [WARN] Corrupted state file — resetting to empty state"
      empty_state
    end

    def save_state(state)
      # Rotate: keep only last MAX_ANNOUNCED_IDS (FIFO)
      state['announced_ids'] = state['announced_ids'].last(MAX_ANNOUNCED_IDS)
      state['last_check_at'] = Time.now.iso8601

      FileUtils.mkdir_p(File.dirname(@state_path))
      File.write(@state_path, JSON.pretty_generate(state))
    end

    def update_check_time(state)
      state['last_check_at'] = Time.now.iso8601
      save_state(state)
    end

    def empty_state
      { 'announced_ids' => [], 'last_check_at' => nil, 'last_post_at' => nil }
    end

    # ----------------------------------------------------------------
    # Core filtering and publishing
    # ----------------------------------------------------------------

    # Return trends that have not yet been announced, capped at MAX_POSTS_PER_RUN.
    # Excludes posts authored by system/bot accounts (SYSTEM_ACCOUNTS).
    def filter_new(trends, state)
      announced = Set.new(state['announced_ids'] || [])
      trends.reject { |t| announced.include?(t['id']) }
            .reject { |t| excluded_trend?(t) }
            .first(MAX_POSTS_PER_RUN)
    end

    # Returns true if the status should be excluded from trending quotes:
    #   - Always: posts by betabot, udrzbot, tlambot
    #   - @zpravobot: only quote posts (trending alerts created by this script)
    #     Regular @zpravobot posts are fine to quote.
    def excluded_trend?(trend)
      acct = trend.dig('account', 'acct').to_s.downcase

      return true if BOT_ACCOUNTS.include?(acct)

      # zpravobot quote posts have a non-nil 'quote' field (Mastodon 4.5+)
      return true if acct == 'zpravobot' && !trend['quote'].nil?

      false
    end

    def publish_quotes(new_trends, state)
      posted = 0

      new_trends.each_with_index do |trend, idx|
        sleep(THROTTLE_SECONDS) if idx > 0

        url = trend['url'] || trend['id']

        if @dry_run
          status_text = build_status_text(trend)
          puts "  [DRY RUN] Would quote #{trend['id']}: #{url}"
          puts "  [DRY RUN] Status text:\n#{status_text.gsub(/^/, '    ')}"
          state['announced_ids'] << trend['id']
          posted += 1
          next
        end

        result = post_quote(trend)
        if result
          state['announced_ids'] << trend['id']
          state['last_post_at'] = Time.now.iso8601
          posted += 1
        end
      end

      posted
    end

    # Sestaví text trending postu.
    #
    # Bez komentáře:
    #   📈 Na Zprávobot.news právě trenduje
    #
    #   #zpravobot #trending
    #
    # S Hrubotovým komentářem (komentář dokončí větu):
    #   📈 Na Zprávobot.news právě trenduje další důkaz, že logika bere dovolenou.
    #
    #   #zpravobot #trending
    def build_status_text(trend)
      comment = @commenter&.comment_for(trend)

      first_line = if comment && !comment.empty?
                     "#{HEADER_LINE} #{comment}."
                   else
                     HEADER_LINE
                   end

      [first_line, '', HASHTAGS_LINE].join("\n")
    end

    # ----------------------------------------------------------------
    # Path resolution
    # ----------------------------------------------------------------

    def resolve_state_path
      base = ENV['ZBNW_DIR'] || Dir.pwd
      File.join(base, DEFAULT_STATE_FILE)
    end
  end
end
