# frozen_string_literal: true

require_relative '../check_result'

module HealthChecks
  class QueueCheck
    def initialize(config)
      @config = config
    end

    def run
      queue_dir = @config[:queue_dir]
      pending_dir = File.join(queue_dir, 'pending')
      processed_dir = File.join(queue_dir, 'processed')
      failed_dir = File.join(queue_dir, 'failed')

      unless Dir.exist?(pending_dir)
        return CheckResult.new(
          name: 'IFTTT Queue',
          level: :warning,
          message: 'Queue directory neexistuje',
          remediation: "Vytvo\u0159it: mkdir -p #{pending_dir} #{processed_dir} #{failed_dir}"
        )
      end

      pending_files = Dir.glob(File.join(pending_dir, '*.json'))
      pending_count = pending_files.size
      all_failed = Dir.glob(File.join(failed_dir, '*.json'))
      failed_count = all_failed.reject { |f| File.basename(f).start_with?('DEAD_') }.size
      dead_count   = all_failed.count { |f| File.basename(f).start_with?('DEAD_') }

      # Zkontrolovat stari nejstarsiho pending
      oldest_pending = nil
      stale_count = 0
      stale_threshold = Time.now - (@config.threshold('queue_stale_minutes') * 60)

      pending_files.each do |file|
        mtime = File.mtime(file)
        oldest_pending = mtime if oldest_pending.nil? || mtime < oldest_pending
        stale_count += 1 if mtime < stale_threshold
      end

      if pending_count > @config.threshold('queue_max_pending')
        CheckResult.new(
          name: 'IFTTT Queue',
          level: :critical,
          message: "#{pending_count} pending (max #{@config.threshold('queue_max_pending')})",
          details: { pending: pending_count, failed: failed_count, dead: dead_count, stale: stale_count },
          remediation: "Queue je p\u0159epln\u011bn\u00e1! Zkontrolovat processor:\nruby lib/webhook/ifttt_queue_processor.rb\nNebo manu\u00e1ln\u011b: ls -la #{pending_dir}"
        )
      elsif stale_count > 0
        age_minutes = ((Time.now - oldest_pending) / 60).to_i
        CheckResult.new(
          name: 'IFTTT Queue',
          level: :warning,
          message: "#{stale_count} polo\u017eek \u010dek\u00e1 >#{@config.threshold('queue_stale_minutes')} min (nejstar\u0161\u00ed #{age_minutes} min)",
          details: { pending: pending_count, failed: failed_count, dead: dead_count, stale: stale_count, oldest_age_min: age_minutes },
          remediation: "Zkontrolovat IFTTT processor:\nps aux | grep ifttt\nRu\u010dn\u00ed zpracov\u00e1n\u00ed: ruby lib/webhook/ifttt_queue_processor.rb"
        )
      elsif failed_count > 10
        CheckResult.new(
          name: 'IFTTT Queue',
          level: :warning,
          message: "#{failed_count} failed polo\u017eek",
          details: { pending: pending_count, failed: failed_count, dead: dead_count },
          remediation: "Zkontrolovat failed polo\u017eky:\nls -la #{failed_dir}\nhead #{failed_dir}/*.json | head -50"
        )
      else
        CheckResult.new(
          name: 'IFTTT Queue',
          level: :ok,
          message: pending_count > 0 ? "#{pending_count} pending, #{failed_count} failed" : "Pr\u00e1zdn\u00e1 (#{failed_count} failed)",
          details: { pending: pending_count, failed: failed_count, dead: dead_count }
        )
      end
    rescue StandardError => e
      CheckResult.new(
        name: 'IFTTT Queue',
        level: :warning,
        message: "Error: #{e.message}"
      )
    end
  end
end
