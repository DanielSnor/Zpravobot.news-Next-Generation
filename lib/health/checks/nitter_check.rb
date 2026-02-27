# frozen_string_literal: true

require_relative '../check_result'

module HealthChecks
  class NitterCheck
    def initialize(config)
      @config = config
    end

    def run
      uri = URI("#{@config[:nitter_url]}/settings")

      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = @config.threshold('nitter_timeout')
      http.read_timeout = @config.threshold('nitter_timeout')

      response = http.get(uri.path)

      if response.code.to_i == 200
        guest_status = parse_guest_status(response.body)

        if guest_status[:healthy]
          CheckResult.new(
            name: 'Nitter Instance',
            level: :ok,
            message: "OK (#{guest_status[:message]})",
            details: guest_status
          )
        else
          CheckResult.new(
            name: 'Nitter Instance',
            level: :warning,
            message: "Degraded: #{guest_status[:message]}",
            details: guest_status,
            remediation: "Obnovit cookies:\nssh admin@xn && cd /opt/nitter && ./refresh_accounts.sh\nNebo: docker restart nitter"
          )
        end
      else
        CheckResult.new(
          name: 'Nitter Instance',
          level: :warning,
          message: "HTTP #{response.code}",
          remediation: "Zkontrolovat Nitter: docker logs nitter --tail 50"
        )
      end
    rescue Errno::ECONNREFUSED
      CheckResult.new(
        name: 'Nitter Instance',
        level: :critical,
        message: "Connection refused - Nitter nen\u00ed dostupn\u00fd",
        remediation: "Zkontrolovat kontejner: docker ps | grep nitter\nRestart: docker restart nitter"
      )
    rescue Net::OpenTimeout, Net::ReadTimeout
      CheckResult.new(
        name: 'Nitter Instance',
        level: :critical,
        message: "Timeout - Nitter neodpov\u00edd\u00e1",
        remediation: "Restart kontejneru: docker restart nitter\nLogy: docker logs nitter --tail 100"
      )
    rescue StandardError => e
      CheckResult.new(
        name: 'Nitter Instance',
        level: :warning,
        message: "Error: #{e.message}"
      )
    end

    private

    def parse_guest_status(html)
      if html.include?('Rate limited') || html.include?('rate_limit')
        { healthy: false, message: 'Rate limited', accounts_status: 'rate_limited' }
      elsif html.include?('No guest accounts') || html.include?('guest_accounts: 0')
        { healthy: false, message: "\u017d\u00e1dn\u00e9 aktivn\u00ed guest accounts", accounts_status: 'no_accounts' }
      elsif html.include?('suspended') || html.include?('Suspended')
        { healthy: false, message: "\u00da\u010det suspendov\u00e1n", accounts_status: 'suspended' }
      else
        { healthy: true, message: "Dostupn\u00fd", accounts_status: 'ok' }
      end
    end
  end
end
