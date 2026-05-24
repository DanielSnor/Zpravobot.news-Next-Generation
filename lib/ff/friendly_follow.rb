# frozen_string_literal: true

require 'uri'
require 'json'
require 'yaml'
require 'fileutils'

require_relative '../utils/http_client'
require_relative '../utils/html_cleaner'
require_relative '../utils/atomic_file'
require_relative '../publishers/mastodon_publisher'
require_relative '../support/loggable'

module FF
  # Generates and publishes daily #FF (Friendly Follow) posts
  # recommending 3 Zpravobot.news accounts with their display name and bio.
  #
  # Rotation state is persisted in data/ff_rotation.json.
  # Each account appears exactly once per cycle.
  # New accounts added to mastodon_accounts.yml are injected into
  # the current cycle automatically.
  #
  # Usage:
  #   ff = FF::FriendlyFollow.new(
  #     config_dir:   'config',
  #     state_path:   'data/ff_rotation.json',
  #     instance_url: 'https://zpravobot.news',
  #     access_token: 'token',
  #     dry_run:      false
  #   )
  #   result = ff.run
  #   # => { posted: true, accounts: ['ct24', ...], post_text: '...', url: '...' }
  #
  class FriendlyFollow
    include Support::Loggable

    EXCLUDED_ACCOUNTS = %w[betabot].freeze
    ACCOUNTS_PER_POST = 3
    BIO_MAX_CHARS     = 500
    POST_MAX_CHARS    = 2500   # Mastodon
    BS_CHAR_LIMIT     = 300    # graphemes — Bluesky
    DEFAULT_INSTANCE  = 'zpravobot.news'
    HASHTAGS          = '#zpravobot #ffcz'

    MONTHS_CS = %w[_ ledna února března dubna května června července srpna září října listopadu prosince].freeze
    DAYS_CS   = %w[neděli pondělí úterý středu čtvrtek pátek sobotu].freeze

    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10

    def initialize(config_dir:, state_path:, instance_url:, access_token:,
                   dry_run: false, bluesky_publisher: nil)
      @config_dir        = config_dir
      @state_path        = state_path
      @instance_url      = instance_url.to_s.chomp('/')
      @access_token      = access_token
      @dry_run           = dry_run
      @bluesky_publisher = bluesky_publisher
    end

    # Main entry point.
    # @return [Hash] { posted:, accounts:, posts:, url: (if posted) }
    def run
      accounts_config = load_accounts_config
      state = load_or_init_rotation(accounts_config)

      if state[:remaining].empty?
        log_warn('[FF] No accounts available to promote')
        return { posted: false, accounts: [], posts: [] }
      end

      # Select accounts
      selected_ids = state[:remaining].sample([ACCOUNTS_PER_POST, state[:remaining].size].min)
      state[:remaining] -= selected_ids
      state[:promoted]  += selected_ids

      # Fetch profiles for selected accounts
      instance_host = @instance_url.sub(%r{^https?://}, '')
      accounts_data = selected_ids.map do |id|
        creds = accounts_config[id] || {}
        profile = fetch_account_profile(id, creds)
        { id: id, instance_host: instance_host }.merge(profile)
      end

      post_text = format_post(accounts_data, Time.now)
      bs_posts  = format_posts(accounts_data, Time.now)

      log_info("[FF] Mastodon post (#{post_text.length} chars):\n#{post_text}")

      if @dry_run
        puts post_text
        return { posted: false, accounts: selected_ids, post_text: post_text }
      end

      # Publish to Mastodon as single post
      publisher = Publishers::MastodonPublisher.new(
        instance_url: @instance_url,
        access_token: @access_token
      )
      result = publisher.publish(post_text, visibility: 'public')
      log_info("[FF] Published: #{result['url']}")

      # Publish to Bluesky as thread (non-fatal)
      publish_to_bluesky(bs_posts)

      # Save state only after successful publish
      save_state(state)

      { posted: true, accounts: selected_ids, post_text: post_text, url: result['url'] }
    end

    private

    # ---------- Config ----------

    def load_accounts_config
      path = File.join(@config_dir, 'mastodon_accounts.yml')
      raw  = YAML.safe_load(
        File.read(path, encoding: 'UTF-8'),
        permitted_classes: [], permitted_symbols: [], aliases: true
      )
      raw.transform_values { |v| v.transform_keys(&:to_sym) }
    end

    def eligible_ids(accounts_config)
      accounts_config.keys
                     .map(&:to_s)
                     .reject { |id| EXCLUDED_ACCOUNTS.include?(id) }
    end

    # ---------- Rotation ----------

    def load_or_init_rotation(accounts_config)
      eligible = eligible_ids(accounts_config)
      state    = read_state

      if state.nil? || state[:remaining].empty? && state[:promoted].empty?
        return new_cycle(eligible, 0)
      end

      # Inject new accounts that appeared since last rotation read
      known        = (state[:promoted] + state[:remaining]).map(&:to_s)
      new_accounts = eligible - known
      unless new_accounts.empty?
        log_info("[FF] Adding #{new_accounts.size} new account(s) to current cycle: #{new_accounts.join(', ')}")
        state[:remaining] += new_accounts.shuffle
      end

      # Trim accounts no longer in mastodon_accounts.yml
      state[:remaining] = state[:remaining].map(&:to_s) & eligible
      state[:promoted]  = state[:promoted].map(&:to_s)  & eligible

      # Start new cycle if nothing left to promote
      if state[:remaining].empty?
        return new_cycle(eligible, state[:cycle])
      end

      state
    end

    def new_cycle(eligible, prev_cycle)
      cycle = prev_cycle + 1
      log_info("[FF] Starting new cycle ##{cycle} (#{eligible.size} accounts)")
      { cycle: cycle, promoted: [], remaining: eligible.shuffle }
    end

    def read_state
      return nil unless File.exist?(@state_path)

      data = JSON.parse(File.read(@state_path, encoding: 'UTF-8'))
      {
        cycle:     data['cycle'].to_i,
        promoted:  Array(data['promoted']).map(&:to_s),
        remaining: Array(data['remaining']).map(&:to_s)
      }
    rescue JSON::ParserError, StandardError
      log_warn("[FF] Could not read state from #{@state_path}, starting fresh")
      nil
    end

    def save_state(state)
      content = JSON.pretty_generate(
        'cycle'     => state[:cycle],
        'promoted'  => state[:promoted],
        'remaining' => state[:remaining]
      )
      Utils::AtomicFile.write(@state_path, content, encoding: 'UTF-8')
    end

    # ---------- Profile fetching ----------

    def fetch_account_profile(account_id, creds)
      token    = creds[:token]
      instance = resolve_instance(creds)

      return { display_name: account_id, bio: nil } unless token

      uri = URI("#{instance}/api/v1/accounts/verify_credentials")
      response = HttpClient.get(
        uri,
        headers: { 'Authorization' => "Bearer #{token}" },
        open_timeout: OPEN_TIMEOUT,
        read_timeout: READ_TIMEOUT
      )
      unless (200..299).include?(response.code.to_i)
        log_warn("[FF] #{account_id}: HTTP #{response.code}")
        return { display_name: account_id, bio: nil }
      end

      data         = JSON.parse(response.body)
      display_name = data['display_name'].to_s
      display_name = account_id if display_name.strip.empty?

      bio = parse_bio(data['note'])

      { display_name: display_name, bio: bio }
    rescue => e
      log_warn("[FF] #{account_id}: #{e.class} #{e.message}")
      { display_name: account_id, bio: nil }
    end

    def resolve_instance(creds)
      inst = creds[:instance].to_s.strip
      return @instance_url if inst.empty?

      inst.start_with?('http') ? inst.chomp('/') : "https://#{inst.chomp('/')}"
    end

    def parse_bio(note)
      return nil if note.nil? || note.to_s.strip.empty?

      bio = HtmlCleaner.sanitize_html(note.to_s)
      bio = bio.gsub(/\s+/, ' ').strip
      bio = nil if bio.empty?
      bio ? truncate_bio(bio) : nil
    end

    def truncate_bio(text, max = BIO_MAX_CHARS)
      return text if text.length <= max

      truncated  = text[0, max - 1]
      last_space = truncated.rindex(' ')
      truncated  = truncated[0, last_space] if last_space
      "#{truncated.rstrip}\u2026"  # …
    end

    # ---------- Formatting ----------

    # Single Mastodon post (up to POST_MAX_CHARS), progressive bio truncation.
    def format_post(accounts_data, time)
      day_name      = DAYS_CS[time.wday]
      date_str      = "#{time.day}. #{MONTHS_CS[time.month]} #{time.year}"
      header        = "#FF 🇨🇿 tip na #{day_name}, #{date_str}:"
      instance_host = accounts_data.first&.dig(:instance_host) || DEFAULT_INSTANCE

      text = build_post_text(accounts_data, header, instance_host)
      return text if text.length <= POST_MAX_CHARS

      max_bio = BIO_MAX_CHARS
      loop do
        max_bio -= 50
        break if max_bio <= 0

        trimmed = accounts_data.map { |a| a[:bio] ? a.merge(bio: truncate_bio(a[:bio], max_bio)) : a }
        text    = build_post_text(trimmed, header, instance_host)
        return text if text.length <= POST_MAX_CHARS
      end

      build_post_text(accounts_data.map { |a| a.merge(bio: nil) }, header, instance_host)
    end

    def build_post_text(accounts_data, header, instance_host)
      parts = [header, '']
      accounts_data.each do |acc|
        parts << "#{acc[:display_name]} \u2014 @#{acc[:id]}@#{instance_host}"
        parts << acc[:bio] if acc[:bio]
        parts << ''
      end
      parts.pop if parts.last == ''
      parts.push('', HASHTAGS)
      parts.join("\n")
    end

    # Builds one post per account as a thread (for Bluesky):
    #   Post 0: header + first account (handle + bio)
    #   Post 1+: one account each (handle + bio)
    # Hashtags only on the last post (stripped by BlueskyTextSplitter for BS).
    # Each post is ≤ POST_CHAR_LIMIT graphemes.
    def format_posts(accounts_data, time)
      day_name      = DAYS_CS[time.wday]
      date_str      = "#{time.day}. #{MONTHS_CS[time.month]} #{time.year}"
      header        = "#FF 🇨🇿 tip na #{day_name}, #{date_str}:"
      instance_host = accounts_data.first&.dig(:instance_host) || DEFAULT_INSTANCE

      accounts_data.each_with_index.map do |acc, idx|
        first  = idx == 0
        last   = idx == accounts_data.size - 1
        suffix = last ? "\n\n#{HASHTAGS}" : ''

        handle_line = "#{acc[:display_name]} \u2014 @#{acc[:id]}@#{instance_host}"
        base        = first ? "#{header}\n\n#{handle_line}" : handle_line

        build_account_post(base, acc[:bio], suffix)
      end
    end

    def build_account_post(base, bio, suffix)
      return "#{base}#{suffix}" unless bio

      candidate = "#{base}\n#{bio}#{suffix}"
      return candidate if grapheme_length(candidate) <= BS_CHAR_LIMIT

      budget = BS_CHAR_LIMIT - grapheme_length("#{base}\n#{suffix}") - 1
      return "#{base}#{suffix}" if budget < 10

      "#{base}\n#{truncate_to_graphemes(bio, budget)}#{suffix}"
    end

    def publish_to_bluesky(posts)
      return unless @bluesky_publisher

      require_relative '../publishers/bluesky_text_splitter'
      splitter = Publishers::BlueskyTextSplitter.new
      # Each post is already ≤ 300 graphemes; splitter strips trailing hashtags
      bs_posts = posts.flat_map { |p| splitter.split(p) }
      return if bs_posts.empty?

      @bluesky_publisher.publish_thread(bs_posts)
    rescue StandardError => e
      log_warn("[FF] Bluesky publish failed: #{e.message}")
    end

    # ---------- Grapheme helpers ----------

    def grapheme_length(str)
      str.scan(/\X/).length
    end

    def truncate_to_graphemes(text, max)
      graphemes = text.scan(/\X/)
      return text if graphemes.length <= max

      graphemes.first(max - 1).join + "\u2026"
    end

    # Exposed for testing
    public

    def format_czech_date(time)
      "#{time.day}. #{MONTHS_CS[time.month]} #{time.year}"
    end
  end
end
