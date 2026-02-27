# frozen_string_literal: true

require_relative '../check_result'

module HealthChecks
  # Detects runner crashes by analyzing the runner log for:
  # 1. Staleness — how long since last successful "Run complete"
  # 2. Consecutive crashes — trailing "exit code: N" (N != 0) without "Run complete"
  #
  # This catches scenarios where the runner repeatedly crashes on startup
  # (e.g. missing gem, syntax error) but produces no ERROR-level log lines,
  # so LogAnalysisCheck misses it entirely.
  class RunnerHealthCheck
    SUCCESS_PATTERN = /Run complete/
    CRASH_PATTERN = /exit code: (\d+)/
    TIMESTAMP_PATTERN = /\[(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})\]/
    TIMESTAMP_SHORT_PATTERN = /\[(\d{2}:\d{2}:\d{2})\]/

    def initialize(config)
      @config = config
    end

    def run
      log_dir = @config[:log_dir]
      today = Time.now.strftime('%Y%m%d')
      log_path = File.join(log_dir, "runner_#{today}.log")

      unless File.exist?(log_path)
        return CheckResult.new(
          name: 'Runner Health',
          level: :ok,
          message: "Log neexistuje (runner dnes ještě neběžel)"
        )
      end

      lines = IO.popen(['tail', '-5000', log_path]) { |io| io.readlines }

      last_success_time = find_last_success_time(lines)
      consecutive_crashes = count_trailing_crashes(lines)

      stale_minutes = @config.threshold(:runner_stale_minutes) || 30
      critical_minutes = @config.threshold(:runner_critical_minutes) || 60
      crash_threshold = @config.threshold(:runner_consecutive_crashes) || 3

      now = Time.now
      staleness_seconds = last_success_time ? (now - last_success_time) : nil

      remediation = build_remediation(log_dir, today)

      if last_success_time.nil? && consecutive_crashes >= crash_threshold
        # Runner nikdy dnes úspěšně nedoběhl a opakovaně padá
        CheckResult.new(
          name: 'Runner Health',
          level: :critical,
          message: "Runner neběží! #{consecutive_crashes} crashů, žádný úspěšný run dnes",
          remediation: remediation
        )
      elsif staleness_seconds && staleness_seconds > critical_minutes * 60
        CheckResult.new(
          name: 'Runner Health',
          level: :critical,
          message: "Runner neběží #{format_duration(staleness_seconds)}! (#{consecutive_crashes} crashů)",
          remediation: remediation
        )
      elsif staleness_seconds && staleness_seconds > stale_minutes * 60
        CheckResult.new(
          name: 'Runner Health',
          level: :warning,
          message: "Poslední OK run před #{format_duration(staleness_seconds)} (#{consecutive_crashes} crashů)",
          remediation: remediation
        )
      elsif consecutive_crashes >= crash_threshold
        CheckResult.new(
          name: 'Runner Health',
          level: :warning,
          message: "#{consecutive_crashes} po sobě jdoucích crashů (poslední OK: #{format_time(last_success_time)})",
          remediation: remediation
        )
      else
        msg = if last_success_time
                "Poslední OK run: #{format_time(last_success_time)}"
              else
                "Runner ještě nedokončil run"
              end
        CheckResult.new(
          name: 'Runner Health',
          level: :ok,
          message: msg
        )
      end
    rescue StandardError => e
      CheckResult.new(
        name: 'Runner Health',
        level: :warning,
        message: "Error: #{e.message}"
      )
    end

    private

    def find_last_success_time(lines)
      last_time = nil

      lines.each do |line|
        next unless line.match?(SUCCESS_PATTERN)

        time = parse_line_time(line)
        last_time = time if time
      end

      last_time
    end

    def count_trailing_crashes(lines)
      count = 0

      lines.reverse_each do |line|
        if line.match?(SUCCESS_PATTERN)
          break
        elsif (m = line.match(CRASH_PATTERN))
          count += 1 if m[1] != '0'
        end
      end

      count
    end

    def parse_line_time(line)
      if (m = line.match(TIMESTAMP_PATTERN))
        Time.parse("#{m[1]} #{m[2]}")
      elsif (m = line.match(TIMESTAMP_SHORT_PATTERN))
        Time.parse("#{Time.now.to_date} #{m[1]}")
      end
    rescue ArgumentError
      nil
    end

    def format_duration(seconds)
      if seconds < 3600
        "#{(seconds / 60).to_i}min"
      else
        hours = (seconds / 3600).to_i
        mins = ((seconds % 3600) / 60).to_i
        mins > 0 ? "#{hours}h #{mins}min" : "#{hours}h"
      end
    end

    def format_time(time)
      time&.strftime('%H:%M:%S')
    end

    def build_remediation(log_dir, today)
      "Runner neběží! Zkontrolovat:\n" \
        "tail -5 #{log_dir}/runner_#{today}.log\n" \
        "Ruční test: bundle exec ruby bin/run_zbnw.rb --exclude-platform twitter 2>&1 | head -20\n" \
        "Častá příčina: chybějící gem (bundle install)"
    end
  end
end
