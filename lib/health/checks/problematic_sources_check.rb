# frozen_string_literal: true

require_relative '../check_result'
require_relative '../database_helper'

module HealthChecks
  class ProblematicSourcesCheck
    include DatabaseHelper

    def initialize(config)
      @config = config
      @conn = nil
      @config_loader = nil
    end

    def run
      connect_db

      result = begin
        @conn.exec(<<~SQL)
          SELECT
            source_id,
            error_count,
            last_error,
            last_success,
            EXTRACT(EPOCH FROM (NOW() - last_success))/3600 as hours_since_success
          FROM source_state
          WHERE disabled_at IS NULL
          AND (
            error_count > 0
            OR last_success < NOW() - INTERVAL '90 days'
          )
          ORDER BY error_count DESC, last_success ASC NULLS FIRST
        SQL
      rescue PG::UndefinedColumn
        # Backward compat: patch_add_disabled_at.sql ještě nebyl aplikován
        @conn.exec(<<~SQL)
          SELECT
            source_id,
            error_count,
            last_error,
            last_success,
            EXTRACT(EPOCH FROM (NOW() - last_success))/3600 as hours_since_success
          FROM source_state
          WHERE error_count > 0
          OR last_success < NOW() - INTERVAL '90 days'
          ORDER BY error_count DESC, last_success ASC NULLS FIRST
        SQL
      end

      filtered = result.select do |r|
        next true if r['error_count'].to_i > 0

        hours = r['hours_since_success']&.to_f
        next false unless hours

        info = resolve_source_info(r['source_id'])
        threshold = silence_threshold_hours(info[:retention_days])
        hours > threshold
      end.first(10)

      if filtered.any?
        sources = filtered.map do |r|
          hours = r['hours_since_success']&.to_f&.round(1)
          format_source_mention(r['source_id'], r['error_count'], hours)
        end

        CheckResult.new(
          name: 'Problematic Sources',
          level: filtered.any? { |r| r['error_count'].to_i >= 5 } ? :warning : :ok,
          message: "#{filtered.size} zdroj\u016f s probl\u00e9my",
          details: sources
        )
      else
        CheckResult.new(
          name: 'Problematic Sources',
          level: :ok,
          message: "\u017d\u00e1dn\u00e9 problematick\u00e9 zdroje"
        )
      end
    rescue PG::Error => e
      CheckResult.new(
        name: 'Problematic Sources',
        level: :warning,
        message: "Database error: #{e.message}"
      )
    ensure
      @conn&.close
    end

    private

    KNOWN_PLATFORMS = %w[twitter bluesky facebook youtube rss].freeze

    def format_source_mention(source_id, error_count, hours)
      info = resolve_source_info(source_id)

      status = "#{error_count} chyb"
      status += ", #{hours}h od \u00fasp\u011bchu" if hours

      account = info[:mastodon_account]
      platform = info[:platform]
      sid = source_id.downcase

      if account && platform
        prefix = "#{account}_"
        if sid.start_with?(prefix) && sid != "#{account}_#{platform}"
          suffix = sid.delete_prefix(prefix)
          "@#{account} (#{suffix}): #{status}"
        else
          "@#{account} (#{platform}): #{status}"
        end
      elsif info[:handle] && platform
        "@#{info[:handle]} (#{platform}): #{status}"
      else
        "#{source_id}: #{status}"
      end
    end

    def resolve_source_info(source_id)
      @source_info_cache ||= {}
      return @source_info_cache[source_id] if @source_info_cache.key?(source_id)

      result = resolve_source_info_from_config(source_id)
      result ||= resolve_source_info_from_id(source_id)

      @source_info_cache[source_id] = result
    end

    def resolve_source_info_from_config(source_id)
      config_dir = File.expand_path('../../config', __dir__)
      @config_loader ||= Config::ConfigLoader.new(config_dir)
      config = @config_loader.load_source(source_id)

      account = config.dig(:target, :mastodon_account)
      platform = config[:platform]
      retention = config.dig(:profile_sync, :retention_days)

      { mastodon_account: account, platform: platform, retention_days: retention }
    rescue StandardError
      nil
    end

    def resolve_source_info_from_id(source_id)
      sid = source_id.downcase

      platform = KNOWN_PLATFORMS.find { |p| sid.end_with?("_#{p}") }
      return { handle: nil, platform: nil, mastodon_account: nil, retention_days: nil } unless platform

      base = sid[0...-("_#{platform}".length)]
      return { handle: nil, platform: nil, mastodon_account: nil, retention_days: nil } if base.empty?

      accounts = load_mastodon_accounts
      accounts.each do |account_id, account_data|
        next unless account_data.is_a?(Hash) && account_data['aggregator']

        prefix = "#{account_id}_"
        next unless base.start_with?(prefix) && base.length > prefix.length

        return { handle: nil, platform: platform, mastodon_account: account_id, retention_days: nil }
      end

      { handle: base, platform: platform, mastodon_account: nil, retention_days: nil }
    end

    def silence_threshold_hours(retention_days)
      days = retention_days || 90
      days.to_i / 3 * 24
    end

    def load_mastodon_accounts
      return @mastodon_accounts if @mastodon_accounts

      config_dir = File.expand_path('../../config', __dir__)
      path = File.join(config_dir, 'mastodon_accounts.yml')
      @mastodon_accounts = YAML.safe_load(File.read(path)) || {}
    rescue StandardError
      @mastodon_accounts = {}
    end
  end
end
