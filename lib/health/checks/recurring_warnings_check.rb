# frozen_string_literal: true

require_relative '../check_result'

module HealthChecks
  class RecurringWarningsCheck
    # Vzory pro detekci WARN řádků
    WARN_PATTERNS = [
      /\bWARN:/i,
      /⚠️/
    ].freeze

    # Vyloučit false positives (stejné jako v LogAnalysisCheck)
    EXCLUDE_PATTERNS = [
      /failed: 0/i,
      /errors: 0/i,
      /error_count: 0/i,
      /Queue processing complete/i
    ].freeze

    def initialize(config)
      @config = config
    end

    def run
      log_dir = @config[:log_dir]
      today = Time.now.strftime('%Y%m%d')
      cutoff_time = Time.now - 3600 # Poslední hodina

      log_files = {
        'runner' => { path: File.join(log_dir, "runner_#{today}.log"), daily: true },
        'ifttt' => { path: File.join(log_dir, 'ifttt_processor.log'), daily: false },
        'webhook' => { path: File.join(log_dir, 'webhook_server.log'), daily: false }
      }

      # Sbírat všechny WARN řádky za poslední hodinu
      warnings = []

      log_files.each do |_name, info|
        next unless File.exist?(info[:path])

        file_warnings = extract_recent_warnings(info[:path], cutoff_time, info[:daily])
        warnings.concat(file_warnings)
      end

      # Normalizovat a seskupit
      grouped = group_warnings(warnings)

      # Filtrovat nad threshold
      warn_threshold = @config.threshold('recurring_warn_threshold') || 10
      critical_threshold = @config.threshold('recurring_warn_critical') || 100

      recurring = grouped.select { |_pattern, count| count >= warn_threshold }

      if recurring.any? { |_pattern, count| count >= critical_threshold }
        top = format_top_warnings(recurring, 5)
        CheckResult.new(
          name: 'Recurring Warnings',
          level: :critical,
          message: "#{recurring.size} opakující se warning(y)",
          details: top,
          remediation: format_remediation(recurring)
        )
      elsif recurring.any?
        top = format_top_warnings(recurring, 5)
        CheckResult.new(
          name: 'Recurring Warnings',
          level: :warning,
          message: "#{recurring.size} opakující se warning(y)",
          details: top,
          remediation: format_remediation(recurring)
        )
      else
        CheckResult.new(
          name: 'Recurring Warnings',
          level: :ok,
          message: 'Žádné opakující se warningy'
        )
      end
    rescue StandardError => e
      CheckResult.new(
        name: 'Recurring Warnings',
        level: :warning,
        message: "Error: #{e.message}"
      )
    end

    private

    def extract_recent_warnings(filepath, cutoff_time, daily_log)
      today = Time.now.to_date
      warnings = []

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
        # Format 2: [HH:MM:SS] - předpokládáme dnešek (jen pro denně rotované logy)
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
        next unless WARN_PATTERNS.any? { |pattern| line =~ pattern }

        warnings << line.strip
      end

      warnings
    end

    def normalize_warning(line)
      # Odstranit timestamp
      msg = line.sub(/^\[?\d{4}-\d{2}-\d{2}[T ]?\d{2}:\d{2}:\d{2}\]?\s*/, '')
      msg = msg.sub(/^\[\d{2}:\d{2}:\d{2}\]\s*/, '')

      # Odstranit emoji prefix
      msg = msg.sub(/^[⚠️ℹ️❌✅🔧]+\s*/, '')

      # Normalizovat URL (konkrétní URL → <URL>)
      msg = msg.gsub(%r{https?://\S+}, '<URL>')

      # Normalizovat čísla (konkrétní hodnoty → <N>)
      msg = msg.gsub(/\b\d+\b/, '<N>')

      msg.strip
    end

    def group_warnings(warnings)
      grouped = Hash.new(0)

      warnings.each do |line|
        normalized = normalize_warning(line)
        grouped[normalized] += 1
      end

      # Seřadit sestupně podle počtu
      grouped.sort_by { |_pattern, count| -count }.to_h
    end

    def format_top_warnings(recurring, limit)
      recurring.first(limit).map do |pattern, count|
        "#{pattern} (#{count}×/h)"
      end
    end

    def format_remediation(recurring)
      lines = []
      recurring.first(3).each do |pattern, count|
        lines << "• #{pattern} (#{count}×/h)"
      end
      lines << "Zkontrolovat logy: grep -i 'WARN' logs/runner_*.log | tail -50"
      lines.join("\n")
    end
  end
end
