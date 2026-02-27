# frozen_string_literal: true

require_relative '../check_result'
require_relative '../database_helper'

module HealthChecks
  class ProcessingCheck
    include DatabaseHelper

    def initialize(config)
      @config = config
      @conn = nil
    end

    def run
      connect_db

      results = []

      # 1. Posledni publikovani
      results << check_last_publish

      # 2. Zdroje s chybami
      results << check_error_sources

      # 3. IFTTT webhook aktivita
      results << check_ifttt_activity

      # 4. Trend oproti baseline (přeskočit v nočních hodinách — false positive)
      current_hour = Time.now.hour
      if current_hour < 6
        results << CheckResult.new(
          name: 'Activity Trend',
          level: :ok,
          message: 'Noční režim (baseline check přeskočen)'
        )
      else
        results << check_activity_trend
      end

      # Agregovat vysledky
      worst_level = results.map { |r| CheckResult::LEVELS[r.level] }.max
      level = CheckResult::LEVELS.key(worst_level)

      messages = results.reject(&:ok?).map { |r| "#{r.icon} #{r.name}: #{r.message}" }

      if messages.empty?
        CheckResult.new(
          name: 'Processing',
          level: :ok,
          message: "V\u0161echny subsyst\u00e9my OK",
          details: results.map(&:to_h)
        )
      else
        worst = results.max_by { |r| CheckResult::LEVELS[r.level] }
        CheckResult.new(
          name: 'Processing',
          level: level,
          message: worst.message,
          details: results.map(&:to_h),
          remediation: worst.remediation
        )
      end
    rescue PG::Error => e
      CheckResult.new(
        name: 'Processing',
        level: :critical,
        message: "Database error: #{e.message}",
        remediation: "Zkontrolovat PostgreSQL:\nsystemctl status postgresql\npsql -c 'SELECT 1'"
      )
    ensure
      @conn&.close
    end

    private

    def check_last_publish
      result = @conn.exec(<<~SQL)
        SELECT MAX(created_at) as last_publish
        FROM activity_log
        WHERE action = 'publish'
        AND created_at > NOW() - INTERVAL '24 hours'
      SQL

      last_publish = result[0]['last_publish']

      if last_publish.nil?
        CheckResult.new(
          name: 'Last Publish',
          level: :warning,
          message: "\u017d\u00e1dn\u00e9 publikov\u00e1n\u00ed za 24h",
          remediation: "Zkontrolovat cron jobs: crontab -l\nRu\u010dn\u00ed run: ruby bin/run_zbnw.rb --dry-run"
        )
      else
        last_time = Time.parse(last_publish)
        minutes_ago = ((Time.now - last_time) / 60).to_i

        if minutes_ago > @config.threshold('no_publish_minutes')
          CheckResult.new(
            name: 'Last Publish',
            level: :warning,
            message: "Posledn\u00ed publikov\u00e1n\u00ed p\u0159ed #{minutes_ago} min",
            remediation: "Zkontrolovat orchestrator:\ntail -f logs/runner_*.log\nruby bin/run_zbnw.rb"
          )
        else
          CheckResult.new(
            name: 'Last Publish',
            level: :ok,
            message: "P\u0159ed #{minutes_ago} min"
          )
        end
      end
    end

    def check_error_sources
      result = @conn.exec_params(<<~SQL, [@config.threshold('error_threshold')])
        SELECT source_id, error_count, last_error
        FROM source_state
        WHERE error_count >= $1
        ORDER BY error_count DESC
        LIMIT 5
      SQL

      if result.ntuples > 0
        sources = result.map { |r| "#{r['source_id']}(#{r['error_count']})" }.join(', ')
        CheckResult.new(
          name: 'Error Sources',
          level: :warning,
          message: "#{result.ntuples} zdroj\u016f s opakovan\u00fdmi chybami: #{sources}",
          details: result.map { |r| r.to_h },
          remediation: "Zkontrolovat konkr\u00e9tn\u00ed zdroj:\nruby bin/run_zbnw.rb --source SOURCE_ID --dry-run\nReset error count: UPDATE source_state SET error_count=0 WHERE source_id='X'"
        )
      else
        CheckResult.new(
          name: 'Error Sources',
          level: :ok,
          message: "\u017d\u00e1dn\u00e9 zdroje s opakovan\u00fdmi chybami"
        )
      end
    end

    def check_ifttt_activity
      result = @conn.exec(<<~SQL)
        SELECT MAX(created_at) as last_webhook
        FROM activity_log
        WHERE action = 'webhook_received'
        OR (action = 'fetch' AND details::text LIKE '%ifttt%')
      SQL

      if result[0]['last_webhook'].nil?
        queue_dir = @config[:queue_dir]
        processed_dir = File.join(queue_dir, 'processed')

        if Dir.exist?(processed_dir)
          latest_file = Dir.glob(File.join(processed_dir, '*.json'))
                           .max_by { |f| File.mtime(f) }

          if latest_file
            last_time = File.mtime(latest_file)
            minutes_ago = ((Time.now - last_time) / 60).to_i

            if minutes_ago > @config.threshold('ifttt_no_webhook_minutes')
              return CheckResult.new(
                name: 'IFTTT Activity',
                level: :warning,
                message: "Posledn\u00ed IFTTT webhook p\u0159ed #{minutes_ago} min",
                remediation: "Zkontrolovat IFTTT applety: https://ifttt.com/my_applets\nTestovat webhook: curl -X POST http://localhost:8080/api/ifttt/twitter -d '{}'"
              )
            else
              return CheckResult.new(
                name: 'IFTTT Activity',
                level: :ok,
                message: "Posledn\u00ed webhook p\u0159ed #{minutes_ago} min"
              )
            end
          end
        end

        CheckResult.new(
          name: 'IFTTT Activity',
          level: :warning,
          message: "\u017d\u00e1dn\u00e1 IFTTT aktivita",
          remediation: "Zkontrolovat IFTTT applety a webhook server"
        )
      else
        last_time = Time.parse(result[0]['last_webhook'])
        minutes_ago = ((Time.now - last_time) / 60).to_i

        if minutes_ago > @config.threshold('ifttt_no_webhook_minutes')
          CheckResult.new(
            name: 'IFTTT Activity',
            level: :warning,
            message: "Posledn\u00ed webhook p\u0159ed #{minutes_ago} min (>#{@config.threshold('ifttt_no_webhook_minutes')} min)",
            remediation: "Zkontrolovat IFTTT applety: https://ifttt.com/my_applets\nWebhook server: curl http://localhost:8080/health"
          )
        else
          CheckResult.new(
            name: 'IFTTT Activity',
            level: :ok,
            message: "Posledn\u00ed webhook p\u0159ed #{minutes_ago} min"
          )
        end
      end
    end

    def check_activity_trend
      current_hour = Time.now.hour

      result = @conn.exec_params(<<~SQL, [current_hour, current_hour])
        WITH today AS (
          SELECT COUNT(*) as cnt
          FROM activity_log
          WHERE action = 'publish'
          AND created_at::date = CURRENT_DATE
          AND EXTRACT(hour FROM created_at) <= $1
        ),
        baseline AS (
          SELECT AVG(daily_count) as avg_cnt
          FROM (
            SELECT created_at::date, COUNT(*) as daily_count
            FROM activity_log
            WHERE action = 'publish'
            AND created_at::date BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE - 1
            AND EXTRACT(hour FROM created_at) <= $2
            GROUP BY created_at::date
          ) daily
        )
        SELECT today.cnt as today_count, COALESCE(baseline.avg_cnt, 0) as baseline_avg
        FROM today, baseline
      SQL

      today_count = result[0]['today_count'].to_i
      baseline_avg = result[0]['baseline_avg'].to_f

      if baseline_avg > 0
        variance = (today_count - baseline_avg) / baseline_avg

        if variance < -@config.threshold('activity_baseline_variance')
          pct = (variance.abs * 100).to_i
          CheckResult.new(
            name: 'Activity Trend',
            level: :warning,
            message: "-#{pct}% oproti baseline (dnes #{today_count}, pr\u016fm\u011br #{baseline_avg.to_i})",
            remediation: "Neobvykle n\u00edzk\u00e1 aktivita. Zkontrolovat:\n- Zdroje: ruby bin/health_monitor.rb --details\n- Logy: tail -100 logs/runner_*.log"
          )
        else
          CheckResult.new(
            name: 'Activity Trend',
            level: :ok,
            message: "Dnes #{today_count} post\u016f (baseline #{baseline_avg.to_i})"
          )
        end
      else
        CheckResult.new(
          name: 'Activity Trend',
          level: :ok,
          message: "Dnes #{today_count} post\u016f (baseline nedostupn\u00e1)"
        )
      end
    end
  end
end
