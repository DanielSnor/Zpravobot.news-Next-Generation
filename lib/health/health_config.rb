# frozen_string_literal: true

require 'yaml'
require_relative '../utils/hash_helpers'

class HealthConfig
  DEFAULT_CONFIG = {
    # Komponenty
    webhook_url: 'http://localhost:8080/health',
    nitter_url: 'http://xn.zpravobot.news:8080',
    mastodon_instance: 'https://zpravobot.news',

    # Alert bot
    alert_bot_token: ENV['ZPRAVOBOT_MONITOR_TOKEN'],
    alert_visibility: 'private',  # followers-only

    # Prahy (v minutach, pokud neni uvedeno jinak)
    thresholds: {
      webhook_timeout: 5,           # sekundy
      nitter_timeout: 10,           # sekundy
      ifttt_no_webhook_minutes: 120, # 2 hodiny bez webhooku
      queue_stale_minutes: 30,      # pending > 30 min
      queue_max_pending: 100,       # max pending polozek
      no_publish_minutes: 60,       # 1 hodina bez publikovani (aktivni platformy)
      error_threshold: 5,           # po sobe jdouci chyby
      nitter_error_keywords: %w[rate_limit guest_account unauthorized suspended],
      activity_baseline_variance: 0.5,  # 50% odchylka od baseline
      runner_stale_minutes: 30,          # 30 min bez Run complete = warning
      runner_critical_minutes: 60,       # 60 min = critical
      runner_consecutive_crashes: 3      # 3+ po sobě jdoucích crashů = warning
    },

    # Database - auto-detect Cloudron or use ENV vars
    database: {
      url: ENV['CLOUDRON_POSTGRESQL_URL'] || ENV['DATABASE_URL'],
      host: ENV['ZPRAVOBOT_DB_HOST'] || ENV['PGHOST'] || 'localhost',
      dbname: ENV['ZPRAVOBOT_DB_NAME'] || ENV['PGDATABASE'] || 'zpravobot',
      user: ENV['ZPRAVOBOT_DB_USER'] || ENV['PGUSER'] || 'zpravobot_app',
      password: ENV['ZPRAVOBOT_DB_PASSWORD'] || ENV['PGPASSWORD'],
      schema: ENV['ZPRAVOBOT_SCHEMA'] || 'zpravobot'
    },

    # Paths
    queue_dir: ENV['ZBNW_DIR'] ? "#{ENV['ZBNW_DIR']}/queue/ifttt" : '/app/data/zbnw-ng/queue/ifttt',
    log_dir: ENV['ZBNW_DIR'] ? "#{ENV['ZBNW_DIR']}/logs" : '/app/data/zbnw-ng/logs',
    health_log_dir: ENV['ZBNW_DIR'] ? "#{ENV['ZBNW_DIR']}/logs/health" : '/app/data/zbnw-ng/logs/health'
  }.freeze

  def initialize(config_path = nil)
    @config = DEFAULT_CONFIG.dup

    if config_path && File.exist?(config_path)
      raw = YAML.safe_load(
        File.read(config_path, encoding: 'UTF-8'),
        permitted_classes: [],
        permitted_symbols: [],
        aliases: true
      )
      custom = HashHelpers.deep_symbolize_keys(raw) if raw
      @config = HashHelpers.deep_merge(@config, custom) if custom
    end
  end

  def [](key)
    @config[key.to_sym]
  end

  def threshold(name)
    @config[:thresholds][name.to_sym]
  end
end
