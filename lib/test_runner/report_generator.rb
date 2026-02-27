# frozen_string_literal: true

require 'fileutils'

module TestRunner
  class ReportGenerator
    def initialize(results, start_time, options)
      @results = results
      @start_time = start_time
      @end_time = Time.now
      @options = options
    end

    # Writes the report to output_dir and returns the file path
    def write(output_dir)
      FileUtils.mkdir_p(output_dir)
      timestamp = @start_time.strftime('%Y%m%d_%H%M%S')
      path = File.join(output_dir, "test_report_#{timestamp}.md")
      File.write(path, generate)
      path
    end

    private

    def generate
      lines = []
      lines << "# ZBNW-NG Test Report"
      lines << ""
      lines << "**Date:** #{@start_time.strftime('%Y-%m-%d %H:%M:%S')}"
      lines << "**Duration:** #{format('%.1f', @end_time - @start_time)}s"
      lines << "**Filters:** #{describe_filters}"
      lines << ""

      # Summary
      lines << "## Summary"
      lines << ""

      pass_c  = @results.count { |r| r.status == :pass }
      fail_c  = @results.count { |r| r.status == :fail }
      err_c   = @results.count { |r| r.status == :error }
      time_c  = @results.count { |r| r.status == :timeout }
      skip_c  = @results.count { |r| r.status == :skip }
      total   = @results.size

      lines << "| Status | Count |"
      lines << "|--------|-------|"
      lines << "| Passed | #{pass_c} |"
      lines << "| Failed | #{fail_c} |"       if fail_c > 0
      lines << "| Errors | #{err_c} |"        if err_c > 0
      lines << "| Timeout | #{time_c} |"      if time_c > 0
      lines << "| Skipped | #{skip_c} |"      if skip_c > 0
      lines << "| **Total** | **#{total}** |"
      lines << ""

      # Results by category
      categories = @results.group_by(&:category)
      category_order = [:unit, :network, :db, :e2e]
      category_order.each do |cat|
        cat_results = categories[cat]
        next unless cat_results && !cat_results.empty?

        lines << "## #{cat.to_s.capitalize} Tests"
        lines << ""
        lines << "| # | Test | Status | Time | Assertions | Detail |"
        lines << "|---|------|--------|------|------------|--------|"

        cat_results.each_with_index do |r, i|
          status_text = status_label(r.status)
          assertions = format_assertions(r)
          detail = escape_md(r.detail || "")
          lines << "| #{i + 1} | `#{r.name}` | #{status_text} | #{format('%.1f', r.duration)}s | #{assertions} | #{detail} |"
        end
        lines << ""
      end

      # Failed test details
      failures = @results.select { |r| [:fail, :error, :timeout].include?(r.status) }
      unless failures.empty?
        lines << "## Failed Test Details"
        lines << ""

        failures.each do |r|
          lines << "### `#{r.name}`"
          lines << ""
          lines << "- **File:** `#{r.file}`"
          lines << "- **Status:** #{r.status}"
          lines << "- **Exit code:** #{r.exit_code || 'N/A'}"
          lines << "- **Duration:** #{format('%.1f', r.duration)}s"
          lines << "- **Detail:** #{r.detail}" if r.detail
          lines << ""

          if r.stderr && !r.stderr.strip.empty?
            lines << "**stderr:**"
            lines << "```"
            stderr_lines = r.stderr.strip.split("\n")
            lines << stderr_lines.first(20).join("\n")
            lines << "..." if stderr_lines.size > 20
            lines << "```"
            lines << ""
          end

          if r.stdout && !r.stdout.strip.empty?
            lines << "<details><summary>stdout (click to expand)</summary>"
            lines << ""
            lines << "```"
            safe_stdout = r.stdout.dup.force_encoding('UTF-8')
                            .encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
            stdout_lines = safe_stdout.strip.split("\n")
            lines << stdout_lines.last(50).join("\n")
            lines << "```"
            lines << "</details>"
            lines << ""
          end
        end
      end

      lines.join("\n")
    end

    def status_label(status)
      case status
      when :pass    then "PASS"
      when :fail    then "**FAIL**"
      when :error   then "**ERR**"
      when :timeout then "**TIMEOUT**"
      when :skip    then "SKIP"
      else status.to_s.upcase
      end
    end

    def format_assertions(result)
      if result.parsed_pass && result.parsed_fail &&
         (result.parsed_pass > 0 || result.parsed_fail > 0)
        total = result.parsed_pass + result.parsed_fail
        "#{result.parsed_pass}/#{total}"
      else
        "-"
      end
    end

    def escape_md(text)
      text.gsub('|', '\\|').gsub("\n", ' ')
    end

    def describe_filters
      parts = []
      if @options[:categories]&.any?
        parts << "categories: #{@options[:categories].join(', ')}"
      end
      if @options[:tags]&.any?
        parts << "tags: #{@options[:tags].join(', ')}"
      end
      if @options[:file_pattern]
        parts << "pattern: #{@options[:file_pattern]}"
      end
      parts.empty? ? "default (unit)" : parts.join('; ')
    end
  end
end
