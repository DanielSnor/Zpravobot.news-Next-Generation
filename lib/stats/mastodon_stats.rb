# frozen_string_literal: true

require 'uri'
require 'json'
require_relative '../utils/http_client'
require_relative '../support/loggable'

module Stats
  # Fetches Mastodon account statistics via verify_credentials API.
  #
  # Handles external instances (some bots are on mastodonczech.cz etc.)
  # by using the per-account instance URL from mastodon_accounts.yml.
  #
  # Usage:
  #   stats = Stats::MastodonStats.new(accounts_config, global_instance)
  #   data = stats.fetch_all(delay: 0.3)
  #   # => { 'ct24' => { followers: 1234, statuses: 5678, display_name: 'ČT24', username: 'ct24' }, ... }
  #
  class MastodonStats
    include Support::Loggable

    OPEN_TIMEOUT  = 5   # seconds
    READ_TIMEOUT  = 10  # seconds

    def initialize(accounts_config, global_instance)
      @accounts        = accounts_config  # { account_id => { token:, instance: (optional), ... } }
      @global_instance = global_instance.to_s.chomp('/')
    end

    # Fetch verify_credentials for all accounts in config
    # Silently skips accounts that fail (log warn per account).
    # @param delay [Float] sleep between requests to avoid rate limiting (default: 0.3s)
    # @return [Hash] { account_id => { followers:, statuses:, display_name:, username: } }
    def fetch_all(delay: 0.3)
      result = {}
      total  = @accounts.size
      done   = 0

      @accounts.each do |account_id, creds|
        token = creds[:token]
        unless token
          log_warn("[MastodonStats] No token for #{account_id}, skipping")
          next
        end

        instance = (creds[:instance] || @global_instance).to_s.chomp('/')
        data = fetch_account(instance, token, account_id)
        result[account_id.to_s] = data if data

        done += 1
        sleep(delay) if done < total
      rescue => e
        log_warn("[MastodonStats] Unexpected error for #{account_id}: #{e.message}")
      end

      log_info("[MastodonStats] Fetched #{result.size}/#{total} accounts")
      result
    end

    private

    def fetch_account(instance, token, account_id)
      uri = URI("#{instance}/api/v1/accounts/verify_credentials")
      response = HttpClient.get(
        uri,
        headers: { 'Authorization' => "Bearer #{token}" },
        open_timeout: OPEN_TIMEOUT,
        read_timeout: READ_TIMEOUT
      )
      unless (200..299).include?(response.code.to_i)
        log_warn("[MastodonStats] #{account_id}: HTTP #{response.code}")
        return nil
      end

      data = JSON.parse(response.body)
      {
        followers:    data['followers_count'].to_i,
        statuses:     data['statuses_count'].to_i,
        display_name: data['display_name'].to_s,
        username:     data['username'].to_s
      }
    rescue => e
      log_warn("[MastodonStats] #{account_id}: #{e.class} #{e.message}")
      nil
    end
  end
end
