# frozen_string_literal: true

# ============================================================
# Udrzbot - Command Listener
# ============================================================
# Polls Mastodon notifications API for mentions, parses commands,
# dispatches to handlers, and replies via direct message.
# Akceptuje pouze mentions-only (DM) posty — veřejné mentions ignoruje.
#
# Designed for cron-based invocation (every 5 minutes).
# Uses cursor-based polling via last_notification_id persistence.
#
# Dependencies:
#   - HealthConfig, HealthMonitor (from lib/health/)
#   - Publishers::MastodonPublisher (from lib/publishers/)
#   - HtmlCleaner (from lib/utils/)
#   - Monitoring::CommandHandlers (from lib/monitoring/)
# ============================================================

require 'json'
require 'fileutils'
require 'time'

require_relative '../utils/http_client'
require_relative '../utils/html_cleaner'
require_relative '../publishers/mastodon_publisher'
require_relative 'command_handlers'
require_relative '../support/loggable'

module Monitoring
  class CommandListener
    include Support::Loggable
    POLL_LIMIT = 30
    MAX_RESPONSE_LENGTH = 2400
    STATE_FILENAME = 'command_listener_state.json'

    def initialize(config)
      @config = config
      @listener_config = config[:command_listener] || {}
      @instance_url = config[:mastodon_instance]
      @token = config[:alert_bot_token]
      @command_counts = Hash.new(0)
    end

    # Hlavní vstupní bod - jedno spuštění per cron cyklus
    # @param dry_run [Boolean] pokud true, jen parsuje bez reply/dismiss
    def run(dry_run: false)
      unless @token
        log "ZPRAVOBOT_MONITOR_TOKEN not set, aborting.", level: :error
        return
      end

      state = load_state
      handlers = nil
      publisher = nil

      # ============================================================
      # 1. Self-commands: poll vlastní DM timeline (Mastodon nedoručí
      #    notifikaci pro vlastní posty, takže musíme pollovat timeline)
      # ============================================================
      process_self_commands(state, dry_run) do |h, p|
        handlers ||= h
        publisher ||= p
      end

      # ============================================================
      # 2. External mentions: standardní notifications API
      # ============================================================

      # Fetch nových mentions
      notifications = fetch_mentions(state['last_notification_id'])

      if notifications.empty? && !@self_commands_processed
        log "Žádné nové mentions."
        return
      end

      # První spuštění - nastavit cursor bez zpracování
      if state['last_notification_id'].nil? && notifications.any?
        highest_id = notifications.last['id']
        log "První spuštění: nastavuji cursor na #{highest_id}, přeskakuji #{notifications.size} historických mentions."
        save_state({ 'last_notification_id' => highest_id, 'last_run_at' => Time.now.iso8601 })
        return
      end

      if notifications.any?
        log "Nalezeno #{notifications.size} nových mentions."
      end

      # Inicializace handlerů a publisheru (pokud ještě nebyly z self-commands)
      handlers ||= CommandHandlers.new(@config)
      publisher ||= init_publisher

      highest_id = state['last_notification_id']

      notifications.each do |notification|
        notification_id = notification['id']
        account_acct = notification.dig('account', 'acct') || 'unknown'

        # Autorizace
        unless authorized?(account_acct)
          log "Neautorizovaná mention od #{account_acct}, ignoruji."
          dismiss_notification(notification_id) unless dry_run
          highest_id = notification_id
          next
        end

        # Rate limiting
        if rate_limited?(account_acct)
          log "Rate limit pro #{account_acct}."
          reply_rate_limited(publisher, notification, account_acct) unless dry_run
          dismiss_notification(notification_id) unless dry_run
          highest_id = notification_id
          next
        end

        # Visibility filter — akceptovat jen mentions-only (DM)
        visibility = notification.dig('status', 'visibility')
        unless visibility == 'direct'
          log "Veřejná mention od #{account_acct} (visibility: #{visibility}), ignoruji."
          dismiss_notification(notification_id) unless dry_run
          highest_id = notification_id
          next
        end

        # Parsování příkazu
        html_content = notification.dig('status', 'content')
        unless html_content
          log "Notification #{notification_id} nemá status content, přeskakuji."
          dismiss_notification(notification_id) unless dry_run
          highest_id = notification_id
          next
        end

        parsed = parse_command(html_content)
        log "Příkaz od #{account_acct}: '#{parsed[:command]}' args='#{parsed[:args]}'"

        # Dispatch
        response_text = handlers.dispatch(parsed[:command], parsed[:args])

        # Reply
        unless dry_run
          send_reply(publisher, notification, account_acct, response_text)
          dismiss_notification(notification_id)
        else
          log "[DRY RUN] Odpověď (#{response_text.length} znaků):\n#{response_text}"
        end

        record_command(account_acct)
        highest_id = notification_id
      end

      # Uložit nový cursor
      if highest_id && highest_id != state['last_notification_id']
        save_state({
          'last_notification_id' => highest_id,
          'last_run_at' => Time.now.iso8601
        })
      end

      log "Hotovo."
    end

    private

    # ============================================================
    # Self-commands: poll vlastní DM timeline
    # ============================================================
    # Mastodon negeneruje notifikaci pro vlastní posty.
    # Proto pollujeme vlastní statuses a hledáme DM s příkazem.

    def process_self_commands(state, dry_run)
      @self_commands_processed = false

      # Zjistit vlastní account ID
      account_id = fetch_own_account_id
      return unless account_id

      bot_account = @listener_config[:bot_account] || 'udrzbot'
      since_id = state['last_self_status_id']

      # První spuštění — nastavit cursor bez zpracování
      if since_id.nil?
        statuses = fetch_own_statuses(account_id, nil, limit: 1)
        if statuses.any?
          new_cursor = statuses.first['id']
          log "Self-commands: první spuštění, cursor nastaven na #{new_cursor}."
          merge_state('last_self_status_id' => new_cursor)
        end
        return
      end

      statuses = fetch_own_statuses(account_id, since_id)
      return if statuses.empty?

      # Filtrovat statusy, které obsahují self-mention (@udrzbot)
      # Pro self-commands akceptujeme jakoukoli visibility (direct, private, unlisted)
      # protože bot je sám sobě důvěryhodný.
      # Přeskočit reply (in_reply_to_id) — to jsou vlastní odpovědi, ne příkazy.
      commands = statuses.select do |s|
        s['in_reply_to_id'].nil? &&
          %w[direct private unlisted].include?(s['visibility']) &&
          self_mention?(s['content'], bot_account)
      end

      if commands.empty?
        # Posunout cursor i pro ne-příkazové statusy
        merge_state('last_self_status_id' => statuses.last['id'])
        return
      end

      log "Self-commands: #{commands.size} příkaz(ů) od #{bot_account}."
      @self_commands_processed = true

      handlers = CommandHandlers.new(@config)
      publisher = init_publisher
      yield handlers, publisher if block_given?

      commands.each do |status|
        parsed = parse_command(status['content'])
        log "Self-příkaz: '#{parsed[:command]}' args='#{parsed[:args]}'"

        response_text = handlers.dispatch(parsed[:command], parsed[:args])

        unless dry_run
          send_self_reply(publisher, status, bot_account, response_text)
        else
          log "[DRY RUN] Self-odpověď (#{response_text.length} znaků):\n#{response_text}"
        end
      end

      merge_state('last_self_status_id' => statuses.last['id'])
    rescue StandardError => e
      log "Self-commands error: #{e.message}", level: :error
    end

    def fetch_own_account_id
      response = mastodon_get('/api/v1/accounts/verify_credentials')
      return nil unless response && response.code.to_i == 200

      data = JSON.parse(response.body)
      data['id']
    rescue StandardError => e
      log "Nelze zjistit vlastní account ID: #{e.message}", level: :error
      nil
    end

    def fetch_own_statuses(account_id, since_id, limit: 10)
      params = { 'limit' => limit.to_s, 'exclude_replies' => 'false' }
      params['since_id'] = since_id if since_id

      query = URI.encode_www_form(params)
      path = "/api/v1/accounts/#{account_id}/statuses?#{query}"

      response = mastodon_get(path)
      return [] unless response && response.code.to_i == 200

      statuses = JSON.parse(response.body)
      return [] unless statuses.is_a?(Array)

      # API vrací nejnovější první — otočit na oldest-first
      statuses.reverse
    rescue StandardError => e
      log "Chyba při fetch vlastních statusů: #{e.message}", level: :error
      []
    end

    def self_mention?(html_content, bot_account)
      return false unless html_content
      text = HtmlCleaner.clean(html_content)
      text.match?(/@\s*#{Regexp.escape(bot_account)}/i)
    end

    def send_self_reply(publisher, status, bot_account, response_text)
      visibility = @listener_config[:response_visibility] || 'direct'
      mention = "@#{bot_account}"
      full_text = "#{mention} #{response_text}"
      chunks = split_response(full_text)

      reply_to_id = status['id']

      chunks.each_with_index do |chunk, index|
        begin
          result = publisher.publish(
            chunk,
            visibility: visibility,
            in_reply_to_id: reply_to_id
          )
          reply_to_id = result['id'] if result && result['id']
        rescue StandardError => e
          log "Chyba při self-reply (chunk #{index + 1}/#{chunks.size}): #{e.message}", level: :error
          break
        end
      end
    end

    def merge_state(updates)
      state = load_state
      state.merge!(updates)
      state['last_run_at'] = Time.now.iso8601
      save_state(state)
    end

    # ============================================================
    # Mastodon API - Notifications
    # ============================================================

    def fetch_mentions(since_id)
      limit = @listener_config[:poll_limit] || POLL_LIMIT

      params = { 'types[]' => 'mention', 'limit' => limit.to_s }
      params['since_id'] = since_id if since_id

      query = URI.encode_www_form(params)
      path = "/api/v1/notifications?#{query}"

      response = mastodon_get(path)
      return [] unless response && response.code.to_i == 200

      notifications = JSON.parse(response.body)
      return [] unless notifications.is_a?(Array)

      # API vrací nejnovější první - otočit na oldest-first
      notifications.reverse
    rescue JSON::ParserError => e
      log "JSON parse error při čtení notifikací: #{e.message}", level: :error
      []
    rescue StandardError => e
      log "Chyba při fetch notifikací: #{e.message}", level: :error
      []
    end

    def dismiss_notification(notification_id)
      response = mastodon_post("/api/v1/notifications/#{notification_id}/dismiss")

      if response && [200, 204].include?(response.code.to_i)
        true
      else
        code = response&.code || 'N/A'
        log "Dismiss notifikace #{notification_id} selhal: HTTP #{code}", level: :warn
        false
      end
    rescue StandardError => e
      log "Chyba při dismiss notifikace #{notification_id}: #{e.message}", level: :warn
      false
    end

    # ============================================================
    # Command Parsing
    # ============================================================

    def parse_command(html_content)
      # HTML -> plaintext
      text = HtmlCleaner.clean(html_content)

      # Odstranit @udrzbot mention (lokální i plně kvalifikovaný)
      # HtmlCleaner nahradí HTML tagy mezerou, takže Mastodon mention
      # <span class="h-card"><a href="...">@<span>udrzbot</span></a></span>
      # se stane "@ udrzbot" (s mezerou mezi @ a jménem)
      bot_account = @listener_config[:bot_account] || 'udrzbot'
      text = text.gsub(/@\s*#{Regexp.escape(bot_account)}(?:\s*@\s*[^\s]+)?\s*/i, '')
      text = text.strip

      # Rozdělit na příkaz a argumenty
      parts = text.split(/\s+/, 2)
      command = (parts[0] || '').downcase
      args = (parts[1] || '').strip

      # Prázdný nebo neznámý -> help
      command = 'help' if command.empty?

      { command: command, args: args }
    end

    # ============================================================
    # Reply
    # ============================================================

    def send_reply(publisher, notification, account_acct, response_text)
      status_id = notification.dig('status', 'id')
      visibility = @listener_config[:response_visibility] || 'direct'

      # Přidat mention na začátek
      mention = "@#{account_acct}"
      full_text = "#{mention} #{response_text}"

      # Split na chunky pokud příliš dlouhé
      chunks = split_response(full_text)

      reply_to_id = status_id

      chunks.each_with_index do |chunk, index|
        # První chunk je odpověď na původní status, další na předchozí chunk
        begin
          result = publisher.publish(
            chunk,
            visibility: visibility,
            in_reply_to_id: reply_to_id
          )
          reply_to_id = result['id'] if result && result['id']
        rescue StandardError => e
          log "Chyba při odesílání odpovědi (chunk #{index + 1}/#{chunks.size}): #{e.message}", level: :error
          break
        end
      end
    end

    def reply_rate_limited(publisher, notification, account_acct)
      status_id = notification.dig('status', 'id')
      visibility = @listener_config[:response_visibility] || 'direct'

      text = "@#{account_acct} Příliš mnoho příkazů v jednom cyklu. Zkuste to znovu za 5 minut."

      publisher.publish(text, visibility: visibility, in_reply_to_id: status_id)
    rescue StandardError => e
      log "Chyba při rate limit odpovědi: #{e.message}", level: :warn
    end

    def split_response(text)
      return [text] if text.length <= MAX_RESPONSE_LENGTH

      chunks = []
      remaining = text
      continuation = "\n\n[...pokračování]"
      target_length = MAX_RESPONSE_LENGTH - continuation.length

      while remaining.length > MAX_RESPONSE_LENGTH
        # Najít vhodné místo pro rozdělení
        split_point = remaining.rindex("\n\n", target_length)
        split_point ||= remaining.rindex("\n", target_length)
        split_point ||= remaining.rindex(' ', target_length)
        split_point ||= target_length

        chunk = remaining[0...split_point] + continuation
        remaining = remaining[split_point..].lstrip
        chunks << chunk
      end

      chunks << remaining unless remaining.empty?
      chunks
    end

    # ============================================================
    # Authorization & Rate Limiting
    # ============================================================

    def authorized?(account_acct)
      allowed = @listener_config[:allowed_accounts]

      # Prázdný nebo nil whitelist = nikdo nemá přístup (bezpečné výchozí)
      return false if allowed.nil? || allowed.empty?

      # Normalizace: porovnávat case-insensitive
      normalized_acct = account_acct.downcase
      allowed.any? { |a| a.downcase == normalized_acct }
    end

    def rate_limited?(account_acct)
      max = @listener_config[:rate_limit_per_cycle] || 3
      @command_counts[account_acct] >= max
    end

    def record_command(account_acct)
      @command_counts[account_acct] += 1
    end

    # ============================================================
    # State Persistence
    # ============================================================

    def load_state
      state_path = state_file_path
      return default_state unless File.exist?(state_path)

      JSON.parse(File.read(state_path))
    rescue JSON::ParserError, Errno::ENOENT => e
      log "Chyba čtení state souboru: #{e.message}, používám výchozí.", level: :warn
      default_state
    end

    def save_state(state)
      path = state_file_path
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(state))
    rescue StandardError => e
      log "Chyba zápisu state souboru: #{e.message}", level: :error
    end

    def state_file_path
      dir = @config[:health_log_dir] || 'logs/health'
      File.join(dir, STATE_FILENAME)
    end

    def default_state
      { 'last_notification_id' => nil, 'last_run_at' => nil }
    end

    # ============================================================
    # MastodonPublisher inicializace
    # ============================================================

    def init_publisher
      Publishers::MastodonPublisher.new(
        instance_url: @instance_url,
        access_token: @token
      )
    end

    # ============================================================
    # HTTP Helpers (pro Notifications API) — delegate to HttpClient
    # ============================================================

    def mastodon_auth_headers
      { 'Authorization' => "Bearer #{@token}" }
    end

    def mastodon_get(path)
      url = "#{@instance_url}#{path}"
      HttpClient.get(url, headers: mastodon_auth_headers, read_timeout: 15)
    rescue StandardError => e
      log "HTTP GET #{path} error: #{e.message}", level: :error
      nil
    end

    def mastodon_post(path, body = nil)
      url = "#{@instance_url}#{path}"
      HttpClient.post_json(url, body, headers: mastodon_auth_headers, read_timeout: 15)
    rescue StandardError => e
      log "HTTP POST #{path} error: #{e.message}", level: :error
      nil
    end

  end
end
