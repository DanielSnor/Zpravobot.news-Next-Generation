#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Údržbot - Zpravobot Health Monitor
# ============================================================
# Komplexní monitoring všech komponent ZBNW systému
# Alert bot: @udrzbot@zpravobot.news
#
# Usage:
#   ruby bin/health_monitor.rb                    # Výpis stavu
#   ruby bin/health_monitor.rb --alert            # Alert při problémech
#   ruby bin/health_monitor.rb --heartbeat        # Heartbeat post (vše OK)
#   ruby bin/health_monitor.rb --json             # JSON výstup
#   ruby bin/health_monitor.rb --details          # Detailní report
#
# Exit codes:
#   0 = OK (vše v pořádku)
#   1 = WARNING (něco vyžaduje pozornost)
#   2 = CRITICAL (vážný problém)
#
# Cron:
#   */10 * * * * cd /app/data/zbnw-ng && ruby bin/health_monitor.rb --alert
#   0 8 * * * cd /app/data/zbnw-ng && ruby bin/health_monitor.rb --heartbeat
#
# ============================================================

require 'bundler/setup'
require 'net/http'
require 'json'
require 'uri'
require 'time'
require 'yaml'
require 'pg'
require 'optparse'
require 'fileutils'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'config/config_loader'
require 'health/health_config'
require 'health/check_result'
require 'health/database_helper'
require 'health/health_monitor'
require 'health/alert_state_manager'

# ============================================================
# CLI
# ============================================================

if __FILE__ == $PROGRAM_NAME
  options = {
    alert: false,
    heartbeat: false,
    json: false,
    details: false,
    config: File.expand_path('../config/health_monitor.yml', __dir__),
    save: false
  }

  OptionParser.new do |opts|
    opts.banner = "Usage: #{$PROGRAM_NAME} [options]"

    opts.on('--alert', 'Post smart alert to Mastodon (respects intervals)') do
      options[:alert] = true
    end

    opts.on('--heartbeat', 'Post heartbeat to Mastodon (if all OK)') do
      options[:heartbeat] = true
    end

    opts.on('--json', 'Output as JSON') do
      options[:json] = true
    end

    opts.on('--details', 'Show detailed output with remediation') do
      options[:details] = true
    end

    opts.on('--save', 'Save report to health log directory') do
      options[:save] = true
    end

    opts.on('-c', '--config FILE', 'Config file path') do |f|
      options[:config] = f
    end

    opts.on('-h', '--help', 'Show help') do
      puts opts
      exit
    end
  end.parse!

  # Initialize
  config = HealthConfig.new(options[:config])
  monitor = HealthMonitor.new(config)

  # Run checks
  results = monitor.run_all

  # Output
  if options[:json]
    puts monitor.format_json(results)
  else
    puts monitor.format_console(results, detailed: options[:details])
  end

  # Save report
  monitor.save_report(results) if options[:save]

  # Smart alert logic
  status = monitor.overall_status(results)

  if options[:alert]
    state_file = File.join(config[:health_log_dir], 'alert_state.json')
    state_manager = AlertStateManager.new(state_file)
    analysis = state_manager.analyze(results)

    if analysis[:should_alert]
      if status == :ok && analysis[:resolved].any?
        # Vše vyřešeno
        content = monitor.format_all_resolved(analysis)
        monitor.post_to_mastodon(content, visibility: config[:alert_visibility])
        state_manager.clear_state
      elsif analysis[:new].any? || analysis[:persisting].any?
        # Nové nebo přetrvávající problémy (může obsahovat i resolved)
        content = monitor.format_smart_alert(results, analysis)
        monitor.post_to_mastodon(content, visibility: config[:alert_visibility])
        state_manager.update_state(results, analysis)
      elsif analysis[:resolved].any?
        # Jen resolved problémy, ale status != :ok
        # (přetrvávající problémy existují, ale interval nevypršel)
        content = monitor.format_smart_alert(results, analysis)
        monitor.post_to_mastodon(content, visibility: config[:alert_visibility])
        state_manager.update_state(results, analysis)
      end
    else
      # Žádný alert, ale aktualizovat stav
      state_manager.update_state(results, analysis) if status != :ok || state_manager.has_previous_problems?
      puts "ℹ️  Žádný alert (interval nevypršel)" if status != :ok || state_manager.has_previous_problems?
    end
  end

  if options[:heartbeat] && status == :ok
    content = monitor.format_heartbeat(results)
    monitor.post_to_mastodon(content, visibility: config[:alert_visibility])
  end

  # Exit code
  exit_code = { ok: 0, warning: 1, critical: 2 }[status]
  exit(exit_code)
end
