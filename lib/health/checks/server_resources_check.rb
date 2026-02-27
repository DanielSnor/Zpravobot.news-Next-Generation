# frozen_string_literal: true

require_relative '../check_result'

module HealthChecks
  class ServerResourcesCheck
    def initialize(config)
      @config = config
    end

    def run
      results = []

      results << check_cpu_load
      results << check_disk
      results << check_memory
      results << check_swap

      # Agregovat vysledky
      worst_level = results.map { |r| CheckResult::LEVELS[r.level] }.max
      level = CheckResult::LEVELS.key(worst_level)

      problems = results.reject(&:ok?)

      if problems.empty?
        cpu = results[0].details[:load_1m]
        disk = results[1].details[:pct]
        mem = results[2].details[:available_mb]
        swap_d = results[3].details
        swap_summary = if swap_d[:swap_io] > 0
                         "I/O #{swap_d[:swap_io]}/s"
                       elsif swap_d[:swap_used_mb] && swap_d[:swap_used_mb] > 0
                         "#{swap_d[:swap_used_mb]}MB used"
                       else
                         "OK"
                       end

        CheckResult.new(
          name: 'Server',
          level: :ok,
          message: "CPU #{cpu} | Disk #{disk}% | RAM #{mem}MB free | Swap #{swap_summary}",
          details: results.map(&:to_h)
        )
      else
        CheckResult.new(
          name: 'Server',
          level: level,
          message: problems.map { |r| "#{r.name}: #{r.message}" }.join('; '),
          details: results.map(&:to_h),
          remediation: problems.map { |r| r.remediation }.compact.join("\n")
        )
      end
    rescue StandardError => e
      CheckResult.new(
        name: 'Server',
        level: :warning,
        message: "Error: #{e.message}"
      )
    end

    private

    def check_cpu_load
      load_avg = File.read('/proc/loadavg').split
      load_1m = load_avg[0].to_f
      load_5m = load_avg[1].to_f
      load_15m = load_avg[2].to_f

      if load_1m >= 4.0
        CheckResult.new(
          name: 'CPU',
          level: :critical,
          message: "Load #{load_1m}/#{load_5m}/#{load_15m}",
          details: { load_1m: load_1m, load_5m: load_5m, load_15m: load_15m },
          remediation: "CPU kriticky vysok\u00e9!\nTop procesy: ps aux --sort=-%cpu | head -10"
        )
      elsif load_1m >= 2.0
        CheckResult.new(
          name: 'CPU',
          level: :warning,
          message: "Load #{load_1m}/#{load_5m}/#{load_15m}",
          details: { load_1m: load_1m, load_5m: load_5m, load_15m: load_15m },
          remediation: "CPU vysok\u00e9.\nTop procesy: ps aux --sort=-%cpu | head -5"
        )
      else
        CheckResult.new(
          name: 'CPU',
          level: :ok,
          message: "Load #{load_1m}",
          details: { load_1m: load_1m, load_5m: load_5m, load_15m: load_15m }
        )
      end
    end

    def check_disk
      df_output = `df /app/data`.lines[1].split
      total_kb = df_output[1].to_f
      used_kb = df_output[2].to_f
      pct = ((used_kb / total_kb) * 100).round(0)

      total_gb = (total_kb / 1024 / 1024).round(0)
      used_gb = (used_kb / 1024 / 1024).round(0)

      if pct >= 95
        CheckResult.new(
          name: 'Disk',
          level: :critical,
          message: "#{pct}% (#{used_gb}G/#{total_gb}G)",
          details: { pct: pct, used_gb: used_gb, total_gb: total_gb },
          remediation: "Disk kriticky pln\u00fd!\ndu -sh /app/data/* | sort -hr | head -10\nfind /app/data -name '*.log' -mtime +7 -delete"
        )
      elsif pct >= 80
        CheckResult.new(
          name: 'Disk',
          level: :warning,
          message: "#{pct}% (#{used_gb}G/#{total_gb}G)",
          details: { pct: pct, used_gb: used_gb, total_gb: total_gb },
          remediation: "Disk t\u00e9m\u011b\u0159 pln\u00fd.\ndu -sh /app/data/* | sort -hr | head -5"
        )
      else
        CheckResult.new(
          name: 'Disk',
          level: :ok,
          message: "#{pct}%",
          details: { pct: pct, used_gb: used_gb, total_gb: total_gb }
        )
      end
    end

    def check_memory
      mem_line = `free -m`.lines[1].split
      total_mb = mem_line[1].to_i
      available_mb = mem_line[6].to_i  # 'available' column

      if available_mb < 200
        CheckResult.new(
          name: 'RAM',
          level: :critical,
          message: "#{available_mb}MB available",
          details: { available_mb: available_mb, total_mb: total_mb },
          remediation: "RAM kriticky n\u00edzk\u00e1!\nTop procesy: ps aux --sort=-%mem | head -10"
        )
      elsif available_mb < 500
        CheckResult.new(
          name: 'RAM',
          level: :warning,
          message: "#{available_mb}MB available",
          details: { available_mb: available_mb, total_mb: total_mb },
          remediation: "RAM n\u00edzk\u00e1.\nTop procesy: ps aux --sort=-%mem | head -5"
        )
      else
        CheckResult.new(
          name: 'RAM',
          level: :ok,
          message: "#{available_mb}MB free",
          details: { available_mb: available_mb, total_mb: total_mb }
        )
      end
    end

    def check_swap
      vmstat_output = `vmstat 1 2`.lines.last.split
      swap_in = vmstat_output[6].to_i   # si
      swap_out = vmstat_output[7].to_i  # so
      swap_io = swap_in + swap_out
      swap_used_mb = read_swap_used_mb

      details = { swap_in: swap_in, swap_out: swap_out, swap_io: swap_io, swap_used_mb: swap_used_mb }
      used_info = swap_used_mb ? " (#{swap_used_mb}MB used)" : ""

      if swap_io >= 500
        CheckResult.new(
          name: 'Swap',
          level: :critical,
          message: "I/O #{swap_io}/s (in:#{swap_in}, out:#{swap_out})#{used_info}",
          details: details,
          remediation: "Aktivn\u00ed swapping! Syst\u00e9m je p\u0159et\u00ed\u017een\u00fd.\nTop memory: ps aux --sort=-%mem | head -10"
        )
      elsif swap_io >= 100
        CheckResult.new(
          name: 'Swap',
          level: :warning,
          message: "I/O #{swap_io}/s#{used_info}",
          details: details,
          remediation: "Swap aktivita detekov\u00e1na.\nZkontrolovat memory usage."
        )
      else
        ok_msg = if swap_io > 0
                   "I/O #{swap_io}/s#{used_info}"
                 elsif swap_used_mb && swap_used_mb > 0
                   "OK (#{swap_used_mb}MB used)"
                 else
                   "OK"
                 end
        CheckResult.new(
          name: 'Swap',
          level: :ok,
          message: ok_msg,
          details: details
        )
      end
    end

    # Cte celkove vyuziti swap prostoru z /proc/swaps
    # @return [Integer, nil] MB pouziteho swapu, nebo nil pokud neni dostupne
    def read_swap_used_mb
      lines = File.readlines('/proc/swaps')
      return nil if lines.size < 2  # zadny swap neni nakonfigurovan

      total_used_kb = lines[1..].sum do |line|
        parts = line.split
        parts.size >= 4 ? parts[3].to_i : 0
      end
      (total_used_kb / 1024).round
    rescue StandardError
      nil
    end
  end
end
