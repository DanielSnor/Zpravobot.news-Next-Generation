# frozen_string_literal: true

# ============================================================
# Údržbot - Command Handlers
# ============================================================
# Implementace jednotlivých příkazů pro interaktivní komunikaci.
# Používá existující HealthMonitor a HealthChecks třídy z
# lib/health/ adresáře.
#
# Příkazy:
#   help      - seznam příkazů
#   status    - stručný přehled stavu
#   detail    - plný report s remediací
#   heartbeat - heartbeat (status + problematické zdroje)
#   sources   - problematické zdroje
#   check X   - detail jednoho checku
# ============================================================

require_relative '../support/loggable'

module Monitoring
  class CommandHandlers
    include Support::Loggable

    # Registry příkazů -> metody
    COMMANDS = {
      'help'      => :handle_help,
      'status'    => :handle_status,
      'detail'    => :handle_detail,
      'details'   => :handle_detail,
      'heartbeat' => :handle_heartbeat,
      'sources'   => :handle_sources,
      'check'     => :handle_check
    }.freeze

    # Aliasy pro jednotlivé checky (používá příkaz 'check')
    CHECK_ALIASES = {
      'server'     => 'Server',
      'webhook'    => 'Webhook Server',
      'nitter'     => 'Nitter Instance',
      'accounts'   => 'Nitter Accounts',
      'queue'      => 'IFTTT Queue',
      'processing' => 'Processing',
      'mastodon'   => 'Mastodon API',
      'logs'       => 'Log Errors',
      'sources'    => 'Problematic Sources'
    }.freeze

    def initialize(config)
      @config = config
      @monitor = nil
      @results = nil
    end

    # Hlavní dispatch metoda
    # @param command [String] název příkazu (downcased)
    # @param args [String] argumenty
    # @return [String] text odpovědi
    def dispatch(command, args)
      method_name = COMMANDS[command]
      if method_name
        send(method_name, args)
      else
        handle_unknown(command)
      end
    rescue StandardError => e
      handle_error(command, e)
    end

    # Je příkaz známý?
    def known_command?(command)
      COMMANDS.key?(command)
    end

    private

    # --- Lazy inicializace ---

    def monitor
      @monitor ||= HealthMonitor.new(@config)
    end

    def run_checks
      @results ||= monitor.run_all
    end

    # --- Příkazy ---

    def handle_help(_args)
      lines = []
      lines << "Údržbot - dostupné příkazy:"
      lines << ""
      lines << "  help - tento výpis"
      lines << "  status - stručný stav systému"
      lines << "  detail - plný health report s detaily"
      lines << "  heartbeat - heartbeat (status + problematické zdroje)"
      lines << "  sources - problematické zdroje"
      lines << "  check [název] - detail jednoho checku"
      lines << ""
      lines << "Dostupné checky pro 'check':"
      lines << "  #{CHECK_ALIASES.keys.join(', ')}"
      lines << ""
      lines << "Příklad: @udrzbot status"
      lines.join("\n")
    end

    def handle_status(_args)
      results = run_checks
      status = monitor.overall_status(results)
      icon = status_icon(status)
      timestamp = Time.now.strftime('%H:%M')

      lines = []
      lines << "#{icon} System #{status.upcase} (#{timestamp})"
      lines << ""

      results.each do |result|
        lines << "#{result.icon} #{result.name}: #{result.message}"
      end

      lines.join("\n")
    end

    def handle_detail(_args)
      results = run_checks
      status = monitor.overall_status(results)
      icon = status_icon(status)
      timestamp = Time.now.strftime('%Y-%m-%d %H:%M')

      lines = []
      lines << "#{icon} Údržbot report [#{timestamp}]"
      lines << ""

      results.each do |result|
        lines << "#{result.icon} #{result.name}: #{result.message}"

        if result.remediation
          result.remediation.split("\n").each do |rem_line|
            lines << "   -> #{rem_line}"
          end
        end

        if result.details.is_a?(Array)
          result.details.first(5).each do |detail|
            lines << "   * #{format_detail(detail)}"
          end
        end
      end

      lines << ""
      lines << "Overall: #{icon} #{status.upcase}"
      lines.join("\n")
    end

    def handle_heartbeat(_args)
      results = run_checks
      status = monitor.overall_status(results)
      icon = status_icon(status)
      timestamp = Time.now.strftime('%Y-%m-%d %H:%M')

      lines = []
      lines << "#{icon} Údržbot heartbeat [#{timestamp}]"
      lines << ""

      results.each do |result|
        lines << "#{result.icon} #{result.name}: #{result.message}"
      end

      # Problematické zdroje - detail pokud existují
      problematic = results.find { |r| r.name == 'Problematic Sources' }
      if problematic && problematic.details.is_a?(Array) && problematic.details.any?
        lines << ""
        problematic.details.first(5).each do |source|
          lines << "   * #{format_detail(source)}"
        end
      end

      lines << ""
      lines << "Systém běží normálně." if status == :ok

      lines.join("\n")
    end

    def handle_sources(_args)
      results = run_checks
      problematic = results.find { |r| r.name == 'Problematic Sources' }

      unless problematic
        return "Problematic Sources check není dostupný."
      end

      lines = []
      lines << "#{problematic.icon} #{problematic.message}"
      lines << ""

      if problematic.details.is_a?(Array) && problematic.details.any?
        problematic.details.each do |source|
          lines << "  * #{source}"
        end
      else
        lines << "Žádné problematické zdroje."
      end

      lines.join("\n")
    end

    def handle_check(args)
      args = args.to_s.strip.downcase

      if args.empty?
        return "Zadejte název checku.\nDostupné: #{CHECK_ALIASES.keys.join(', ')}\nPříklad: @udrzbot check server"
      end

      check_name = CHECK_ALIASES[args]

      unless check_name
        return "Neznámý check '#{args}'.\nDostupné: #{CHECK_ALIASES.keys.join(', ')}"
      end

      results = run_checks
      result = results.find { |r| r.name == check_name }

      unless result
        return "Check '#{check_name}' nevrátil výsledek."
      end

      lines = []
      lines << "#{result.icon} #{result.name}: #{result.message}"

      if result.remediation
        lines << ""
        result.remediation.split("\n").each do |rem_line|
          lines << "-> #{rem_line}"
        end
      end

      if result.details.is_a?(Array)
        lines << ""
        result.details.first(10).each do |detail|
          lines << "* #{format_detail(detail)}"
        end
      elsif result.details.is_a?(Hash)
        lines << ""
        result.details.each do |key, value|
          lines << "* #{key}: #{value}"
        end
      end

      lines.join("\n")
    end

    def handle_unknown(command)
      "Neznámý příkaz '#{command}'.\n\nPoužijte 'help' pro seznam příkazů."
    end

    def handle_error(command, error)
      log "Error in command '#{command}': #{error.message}\n#{error.backtrace&.first(5)&.join("\n")}", level: :error
      "Chyba při zpracování příkazu '#{command}': #{error.message}"
    end

    # --- Helpers ---

    # Formátuje detail položku do čitelného textu
    # Sub-check hash: {name: "CPU", level: :ok, message: "Load 0.37", details: {...}}
    # String: nechat jak je
    def format_detail(detail)
      if detail.is_a?(Hash) || (detail.respond_to?(:to_h) && detail.respond_to?(:name))
        d = detail.is_a?(Hash) ? detail : detail.to_h rescue detail
        name = d[:name] || d['name']
        message = d[:message] || d['message']
        level = d[:level] || d['level']
        if name && message
          icon = status_icon(level) if level
          icon ? "#{icon} #{name}: #{message}" : "#{name}: #{message}"
        else
          detail.to_s
        end
      else
        detail.to_s
      end
    end

    def status_icon(level)
      case level
      when :ok then "\u2705"       # checkmark
      when :warning then "\u26a0\ufe0f"  # warning
      when :critical then "\u274c"  # cross
      else "\u2753"                 # question
      end
    end

  end
end
