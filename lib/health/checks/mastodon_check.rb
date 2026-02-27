# frozen_string_literal: true

require_relative '../check_result'

module HealthChecks
  class MastodonCheck
    def initialize(config)
      @config = config
    end

    def run
      uri = URI("#{@config[:mastodon_instance]}/api/v1/instance")

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = 5
      http.read_timeout = 10

      response = http.get(uri.path)

      if response.code.to_i == 200
        data = JSON.parse(response.body)
        CheckResult.new(
          name: 'Mastodon API',
          level: :ok,
          message: "OK (#{data['title'] || @config[:mastodon_instance]})",
          details: { version: data['version'], users: data.dig('stats', 'user_count') }
        )
      else
        CheckResult.new(
          name: 'Mastodon API',
          level: :warning,
          message: "HTTP #{response.code}",
          remediation: "Zkontrolovat Mastodon instance: #{@config[:mastodon_instance]}"
        )
      end
    rescue StandardError => e
      CheckResult.new(
        name: 'Mastodon API',
        level: :critical,
        message: "Error: #{e.message}",
        remediation: "Mastodon instance nedostupn\u00e1!\nZkontrolovat: curl #{@config[:mastodon_instance]}/api/v1/instance"
      )
    end
  end
end
