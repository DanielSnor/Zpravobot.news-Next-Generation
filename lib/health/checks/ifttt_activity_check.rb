# frozen_string_literal: true

require_relative '../check_result'

module HealthChecks
  class IftttActivityCheck
    def initialize(config)
      @config = config
    end

    def run
      queue_dir = @config[:queue_dir]
      processed_dir = File.join(queue_dir, 'processed')

      unless Dir.exist?(processed_dir)
        return CheckResult.new(
          name: 'IFTTT Activity',
          level: :warning,
          message: 'Processed directory neexistuje — žádná historická aktivita'
        )
      end

      newest = Dir.glob(File.join(processed_dir, '*.json')).max_by { |f| File.mtime(f) }

      unless newest
        return CheckResult.new(
          name: 'IFTTT Activity',
          level: :ok,
          message: 'Žádné zpracované eventy (nový systém?)'
        )
      end

      age_minutes = ((Time.now - File.mtime(newest)) / 60).to_i
      threshold = @config.threshold('ifttt_no_webhook_minutes')

      if age_minutes > threshold
        age_str = format_age(age_minutes)
        CheckResult.new(
          name: 'IFTTT Activity',
          level: :warning,
          message: "Žádný IFTTT event #{age_str} (práh #{threshold} min)",
          details: { last_event_minutes_ago: age_minutes, threshold_minutes: threshold,
                     last_file: File.basename(newest) },
          remediation: "Zkontrolovat webhook server a IFTTT applety:\n" \
                       "curl -s http://localhost:8089/health | jq .\n" \
                       "Ověřit bind adresu: ss -tlnp | grep 8089"
        )
      else
        CheckResult.new(
          name: 'IFTTT Activity',
          level: :ok,
          message: "Poslední event před #{format_age(age_minutes)}",
          details: { last_event_minutes_ago: age_minutes }
        )
      end
    rescue StandardError => e
      CheckResult.new(
        name: 'IFTTT Activity',
        level: :warning,
        message: "Error: #{e.message}"
      )
    end

    private

    def format_age(minutes)
      if minutes < 60
        "#{minutes} min"
      else
        hours = minutes / 60
        mins = minutes % 60
        mins > 0 ? "#{hours}h #{mins}min" : "#{hours}h"
      end
    end
  end
end
