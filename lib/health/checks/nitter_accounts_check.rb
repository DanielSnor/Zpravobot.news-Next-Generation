# frozen_string_literal: true

require_relative '../check_result'
require_relative '../database_helper'

module HealthChecks
  class NitterAccountsCheck
    include DatabaseHelper

    def initialize(config)
      @config = config
      @conn = nil
    end

    def run
      connect_db

      # Hledat chybove vzory souvisejici s burner ucty
      keywords = @config.threshold('nitter_error_keywords')
      placeholders = keywords.each_with_index.map { |_, i| "details::text ILIKE $#{i + 1}" }.join(' OR ')
      params = keywords.map { |k| "%#{k}%" }

      result = @conn.exec_params(<<~SQL, params)
        SELECT COUNT(*) as error_count,
               MAX(created_at) as last_error
        FROM activity_log
        WHERE action = 'error'
        AND created_at > NOW() - INTERVAL '1 hour'
        AND (#{placeholders})
      SQL

      error_count = result[0]['error_count'].to_i
      last_error = result[0]['last_error']

      if error_count > 10
        CheckResult.new(
          name: 'Nitter Accounts',
          level: :critical,
          message: "#{error_count} account-related chyb za posledn\u00ed hodinu",
          remediation: "Burner \u00fa\u010dty pravd\u011bpodobn\u011b expirovan\u00e9!\n1. SSH na Nitter server: ssh admin@xn.zpravobot.news\n2. Obnovit cookies: cd /opt/nitter && ./refresh_accounts.sh\n3. Restart: docker restart nitter"
        )
      elsif error_count > 3
        CheckResult.new(
          name: 'Nitter Accounts',
          level: :warning,
          message: "#{error_count} account-related chyb za posledn\u00ed hodinu",
          remediation: "Mo\u017en\u00e9 probl\u00e9my s burner \u00fa\u010dty.\nZkontrolovat: docker logs nitter --tail 50 | grep -i 'rate\\|account\\|guest'"
        )
      else
        CheckResult.new(
          name: 'Nitter Accounts',
          level: :ok,
          message: "\u017d\u00e1dn\u00e9 account-related chyby"
        )
      end
    rescue PG::Error => e
      CheckResult.new(
        name: 'Nitter Accounts',
        level: :warning,
        message: "Database error: #{e.message}"
      )
    ensure
      @conn&.close
    end
  end
end
