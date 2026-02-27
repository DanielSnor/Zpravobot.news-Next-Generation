# frozen_string_literal: true

require_relative '../check_result'

module HealthChecks
  class WebhookCheck
    def initialize(config)
      @config = config
    end

    def run
      uri = URI(@config[:webhook_url])

      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = @config.threshold('webhook_timeout')
      http.read_timeout = @config.threshold('webhook_timeout')

      response = http.get(uri.path)
      data = JSON.parse(response.body)

      uptime = data['uptime'] || 0
      uptime_str = format_duration(uptime)

      CheckResult.new(
        name: 'Webhook Server',
        level: :ok,
        message: "OK (uptime #{uptime_str}, #{data['requests'] || 0} requests)",
        details: data
      )
    rescue Errno::ECONNREFUSED
      CheckResult.new(
        name: 'Webhook Server',
        level: :critical,
        message: "Connection refused - server nen\u00ed spu\u0161t\u011bn",
        remediation: "Spustit server: cd /app/data/zbnw-ng && ruby bin/webhook_server.rb &\nNebo: systemctl start zbnw-webhook"
      )
    rescue Net::OpenTimeout, Net::ReadTimeout
      CheckResult.new(
        name: 'Webhook Server',
        level: :critical,
        message: "Timeout - server neodpov\u00edd\u00e1",
        remediation: "Zkontrolovat proces: ps aux | grep webhook\nRestart: systemctl restart zbnw-webhook"
      )
    rescue StandardError => e
      CheckResult.new(
        name: 'Webhook Server',
        level: :warning,
        message: "Error: #{e.message}"
      )
    end

    private

    def format_duration(seconds)
      days = seconds / 86400
      hours = (seconds % 86400) / 3600
      mins = (seconds % 3600) / 60

      parts = []
      parts << "#{days}d" if days > 0
      parts << "#{hours}h" if hours > 0 || days > 0
      parts << "#{mins}m" if parts.empty? || mins > 0
      parts.join(' ')
    end
  end
end
