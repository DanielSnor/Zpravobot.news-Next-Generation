# frozen_string_literal: true

require_relative 'check_result'
require_relative 'checks/server_resources_check'
require_relative 'checks/log_analysis_check'
require_relative 'checks/webhook_check'
require_relative 'checks/nitter_check'
require_relative 'checks/nitter_accounts_check'
require_relative 'checks/queue_check'
require_relative 'checks/processing_check'
require_relative 'checks/mastodon_check'
require_relative 'checks/problematic_sources_check'
require_relative 'checks/runner_health_check'
require_relative 'checks/recurring_warnings_check'

class HealthMonitor
  def initialize(config)
    @config = config
    @checks = [
      HealthChecks::ServerResourcesCheck.new(config),
      HealthChecks::LogAnalysisCheck.new(config),
      HealthChecks::RecurringWarningsCheck.new(config),
      HealthChecks::WebhookCheck.new(config),
      HealthChecks::NitterCheck.new(config),
      HealthChecks::NitterAccountsCheck.new(config),
      HealthChecks::QueueCheck.new(config),
      HealthChecks::ProcessingCheck.new(config),
      HealthChecks::MastodonCheck.new(config),
      HealthChecks::ProblematicSourcesCheck.new(config),
      HealthChecks::RunnerHealthCheck.new(config)
    ]
  end

  def run_all
    @checks.map(&:run)
  end

  def overall_status(results)
    max_level = results.map { |r| CheckResult::LEVELS[r.level] }.max
    CheckResult::LEVELS.key(max_level)
  end

  def format_console(results, detailed: false)
    output = []
    output << "=" * 60
    output << "\u{1F527} \u00dadr\u017ebot - #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
    output << "=" * 60
    output << ""

    results.each do |result|
      output << "#{result.icon} #{result.name}: #{result.message}"

      if detailed && result.remediation
        output << "   \u2514\u2500 #{result.remediation.gsub("\n", "\n      ")}"
      end

      if detailed && result.details.is_a?(Array)
        result.details.first(5).each do |detail|
          output << "   \u2022 #{detail}"
        end
      end
    end

    output << ""
    output << "=" * 60

    status = overall_status(results)
    status_icon = { ok: "\u2705", warning: "\u26a0\ufe0f", critical: "\u274c" }[status]
    output << "Overall: #{status_icon} #{status.upcase}"
    output << "=" * 60

    output.join("\n")
  end

  def format_json(results)
    {
      timestamp: Time.now.iso8601,
      overall_status: overall_status(results),
      checks: results.map(&:to_h)
    }.to_json
  end

  def format_mastodon_alert(results)
    problems = results.reject(&:ok?)
    return nil if problems.empty?

    lines = []
    lines << "\u{1F527} \u00dadr\u017ebot hl\u00e1s\u00ed [#{Time.now.strftime('%Y-%m-%d %H:%M')}]"
    lines << ""

    problems.sort_by { |r| -CheckResult::LEVELS[r.level] }.each do |result|
      lines << "#{result.icon} #{result.name}: #{result.message}"
      if result.remediation
        result.remediation.split("\n").each do |line|
          lines << "   \u2192 #{line}"
        end
      end
      lines << ""
    end

    ok_items = results.select(&:ok?)
    if ok_items.any?
      ok_names = ok_items.map { |r| r.name.gsub(' ', '') }.join(', ')
      lines << "\u2705 OK: #{ok_names}"
    end

    lines << ""
    lines << "#\u00fadr\u017ebot #zpravobot"

    content = lines.join("\n")

    if content.length > 2400
      content = content[0..2350] + "\n\n[...zkr\u00e1ceno]\n#\u00fadr\u017ebot #zpravobot"
    end

    content
  end

  def format_smart_alert(results, analysis)
    lines = []
    lines << "\u{1F527} \u00dadr\u017ebot hl\u00e1s\u00ed [#{Time.now.strftime('%Y-%m-%d %H:%M')}]"
    lines << ""

    # Nove problemy
    if analysis[:new].any?
      lines << "\u{1F6A8} Nov\u00e9 probl\u00e9my:"
      analysis[:new].each do |problem|
        icon = problem[:level] == :critical ? "\u274c" : "\u26a0\ufe0f"
        lines << "#{icon} #{problem[:name]}: #{problem[:message]}"
        if problem[:remediation]
          problem[:remediation].split("\n").each do |line|
            lines << "   \u2192 #{line}"
          end
        end
      end
      lines << ""
    end

    # Pretrvavajici problemy
    if analysis[:persisting].any?
      lines << "\u23f3 P\u0159etrvav\u00e1j\u00edc\u00ed probl\u00e9my:"
      analysis[:persisting].each do |problem|
        icon = problem[:level] == :critical ? "\u274c" : "\u26a0\ufe0f"
        duration = format_duration_human(problem[:duration_minutes])
        lines << "#{icon} #{problem[:name]} (#{duration}): #{problem[:message]}"
        if problem[:remediation]
          problem[:remediation].split("\n").first(2).each do |line|
            lines << "   \u2192 #{line}"
          end
        end
      end
      lines << ""
    end

    # Vyresene problemy
    if analysis[:resolved].any?
      lines << "\u2705 Vy\u0159e\u0161eno:"
      analysis[:resolved].each do |problem|
        duration = format_duration_human(problem[:duration_minutes])
        lines << "\u2022 #{problem[:name]} (trval #{duration})"
      end
      lines << ""
    end

    ok_items = results.select(&:ok?)
    if ok_items.any? && (analysis[:new].any? || analysis[:persisting].any?)
      ok_names = ok_items.map { |r| r.name.gsub(' ', '') }.join(', ')
      lines << "\u2705 OK: #{ok_names}"
      lines << ""
    end

    lines << "#\u00fadr\u017ebot #zpravobot"

    content = lines.join("\n")

    if content.length > 2400
      content = content[0..2350] + "\n\n[...zkr\u00e1ceno]\n#\u00fadr\u017ebot #zpravobot"
    end

    content
  end

  def format_all_resolved(analysis)
    lines = []
    lines << "\u{1F527} \u00dadr\u017ebot hl\u00e1s\u00ed [#{Time.now.strftime('%Y-%m-%d %H:%M')}]"
    lines << ""
    lines << "\u2705 V\u0161echny probl\u00e9my vy\u0159e\u0161eny!"
    lines << ""

    analysis[:resolved].each do |problem|
      duration = format_duration_human(problem[:duration_minutes])
      lines << "\u2022 #{problem[:name]} (trval #{duration})"
    end

    lines << ""
    lines << "Syst\u00e9m op\u011bt b\u011b\u017e\u00ed norm\u00e1ln\u011b."
    lines << ""
    lines << "#\u00fadr\u017ebot #zpravobot"

    lines.join("\n")
  end

  def format_duration_human(minutes)
    if minutes < 60
      "#{minutes}min"
    elsif minutes < 1440
      hours = minutes / 60
      mins = minutes % 60
      mins > 0 ? "#{hours}h #{mins}min" : "#{hours}h"
    else
      days = minutes / 1440
      hours = (minutes % 1440) / 60
      hours > 0 ? "#{days}d #{hours}h" : "#{days}d"
    end
  end

  def format_heartbeat(results)
    lines = []
    lines << "\u{1F527} \u00dadr\u017ebot hl\u00e1s\u00ed [#{Time.now.strftime('%Y-%m-%d %H:%M')}]"
    lines << ""
    lines << "\u2705 V\u0161echny syst\u00e9my b\u011b\u017e\u00ed norm\u00e1ln\u011b."
    lines << ""

    results.each do |result|
      next unless result.ok?
      next if result.name == 'Problematic Sources'
      lines << "\u2022 #{result.name}: #{result.message}"
    end

    problematic = results.find { |r| r.name == 'Problematic Sources' }
    if problematic && problematic.details.is_a?(Array) && problematic.details.any?
      lines << ""
      lines << "\u{1F4CB} Zdroje vy\u017eaduj\u00edc\u00ed pozornost:"
      problematic.details.first(10).each do |source|
        lines << "   \u2022 #{source}"
      end
      lines << ""
      lines << "\u{1F4CE} V\u0161echny: psql \"$CLOUDRON_POSTGRESQL_URL\" -c \"SET search_path TO #{@config[:database][:schema]}; SELECT * FROM source_state WHERE error_count > 0 OR last_success < NOW() - '24h'::interval\""
    end

    lines << ""
    lines << "#\u00fadr\u017ebot #zpravobot"

    lines.join("\n")
  end

  def post_to_mastodon(content, visibility: 'private')
    token = @config[:alert_bot_token]

    unless token
      puts "\u26a0\ufe0f  ZPRAVOBOT_MONITOR_TOKEN not set, skipping Mastodon post"
      return false
    end

    uri = URI("#{@config[:mastodon_instance]}/api/v1/statuses")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = 10
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri)
    request['Authorization'] = "Bearer #{token}"
    request['Content-Type'] = 'application/json'
    request.body = JSON.generate({
      status: content,
      visibility: visibility
    })

    response = http.request(request)

    if response.code.to_i == 200
      puts "\u2705 Posted to Mastodon (#{visibility})"
      true
    else
      puts "\u274c Mastodon post failed: #{response.code} #{response.body}"
      false
    end
  rescue StandardError => e
    puts "\u274c Mastodon post error: #{e.message}"
    false
  end

  def save_report(results, format: :json)
    log_dir = @config[:health_log_dir]
    FileUtils.mkdir_p(log_dir)

    filename = "health_#{Time.now.strftime('%Y%m%d_%H%M%S')}.#{format}"
    filepath = File.join(log_dir, filename)

    content = case format
              when :json then format_json(results)
              when :txt then format_console(results, detailed: true)
              else format_json(results)
              end

    File.write(filepath, content)
    puts "\u{1F4DD} Report saved: #{filepath}"

    # Cleanup old reports (keep 7 days)
    cutoff = Time.now - (7 * 24 * 3600)
    Dir.glob(File.join(log_dir, 'health_*')).each do |file|
      File.delete(file) if File.mtime(file) < cutoff
    end
  end
end
