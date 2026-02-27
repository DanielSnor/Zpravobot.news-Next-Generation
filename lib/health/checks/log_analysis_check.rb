# frozen_string_literal: true

require_relative '../check_result'

module HealthChecks
  class LogAnalysisCheck
    # Vzory pro skutecne chyby
    ERROR_PATTERNS = [
      /\berror:/i,               # "error:"
      /\bfailed to\b/i,          # "failed to" (skutecna chyba)
      /\bexception:/i,
      /\btimeout:/i,
      /\bcrash/i,
      /\bfatal/i,
      /\u274c/                    # Emoji indikator chyby
    ].freeze

    # Warningy které eskalujeme na error úroveň (indikují reálný problém)
    ESCALATED_WARN_PATTERNS = [
      /HTTP 4\d\d/i,                    # HTTP client errors (429, 403, etc.)
      /HTTP 5\d\d/i,                    # HTTP server errors
      /\bretry\b.*\bfailed\b/i,        # retry attempts that failed
      /\ball \d+ attempts failed\b/i   # all attempts exhausted
    ].freeze

    # Vzory ktere vyloucime (false positives)
    EXCLUDE_PATTERNS = [
      /failed: 0/i,              # statistika
      /errors: 0/i,
      /error_count: 0/i,
      /Queue processing complete/i,  # summary radek
      /nitter error: 4\d\d/i,        # Nitter HTTP 4xx — ošetřeno v profile_synceru, není systémový problém
      /duplicate key value violates unique constraint/i  # DB konflikt — ošetřeno v kódu
    ].freeze

    def initialize(config)
      @config = config
    end

    def run
      log_dir = @config[:log_dir]
      today = Time.now.strftime('%Y%m%d')
      cutoff_time = Time.now - 3600  # Posledni hodina

      log_files = {
        'runner' => { path: File.join(log_dir, "runner_#{today}.log"), daily: true },
        'ifttt' => { path: File.join(log_dir, 'ifttt_processor.log'), daily: false },
        'webhook' => { path: File.join(log_dir, 'webhook_server.log'), daily: false }
      }

      total_errors = 0
      error_details = {}

      log_files.each do |name, info|
        next unless File.exist?(info[:path])

        count = count_recent_errors(info[:path], cutoff_time, info[:daily])
        total_errors += count
        error_details[name] = count if count > 0
      end

      if total_errors >= 50
        CheckResult.new(
          name: 'Log Errors',
          level: :critical,
          message: "#{total_errors} chyb/h (#{format_details(error_details)})",
          details: error_details,
          remediation: "Vysok\u00fd po\u010det chyb!\ntail -100 #{log_dir}/runner_#{today}.log | grep -i error"
        )
      elsif total_errors >= 20
        CheckResult.new(
          name: 'Log Errors',
          level: :warning,
          message: "#{total_errors} chyb/h (#{format_details(error_details)})",
          details: error_details,
          remediation: "Zv\u00fd\u0161en\u00fd po\u010det chyb.\ngrep -i error #{log_dir}/runner_#{today}.log | tail -20"
        )
      else
        CheckResult.new(
          name: 'Log Errors',
          level: :ok,
          message: total_errors > 0 ? "#{total_errors} chyb/h" : "\u017d\u00e1dn\u00e9 chyby/h"
        )
      end
    rescue StandardError => e
      CheckResult.new(
        name: 'Log Errors',
        level: :warning,
        message: "Error: #{e.message}"
      )
    end

    private

    def count_recent_errors(filepath, cutoff_time, daily_log)
      count = 0
      today = Time.now.to_date

      lines = if daily_log
                IO.popen(['tail', '-5000', filepath]) { |io| io.readlines }
              else
                IO.popen(['tail', '-2000', filepath]) { |io| io.readlines }
              end

      lines.each do |line|
        line_time = nil

        # Format 1: [YYYY-MM-DD HH:MM:SS] nebo YYYY-MM-DDTHH:MM:SS
        if line =~ /\[?(\d{4}-\d{2}-\d{2})[T ]?(\d{2}:\d{2}:\d{2})/
          begin
            line_time = Time.parse("#{$1} #{$2}")
          rescue ArgumentError
            next
          end
        # Format 2: [HH:MM:SS] - predpokladame dnesek (jen pro denne rotovane logy)
        elsif daily_log && line =~ /\[(\d{2}:\d{2}:\d{2})\]/
          begin
            line_time = Time.parse("#{today} #{$1}")
          rescue ArgumentError
            next
          end
        else
          next
        end

        next if line_time < cutoff_time
        next if EXCLUDE_PATTERNS.any? { |pattern| line =~ pattern }

        count += 1 if ERROR_PATTERNS.any? { |pattern| line =~ pattern }

        # Eskalované WARN řádky — warningy indikující reálný problém
        if line =~ /\bWARN:/i || line =~ /⚠️/
          count += 1 if ESCALATED_WARN_PATTERNS.any? { |pattern| line =~ pattern }
        end
      end

      count
    end

    def format_details(details)
      details.map { |k, v| "#{k}:#{v}" }.join(', ')
    end
  end
end
