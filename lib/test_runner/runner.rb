# frozen_string_literal: true

require 'open3'
require 'timeout'
require 'yaml'
require 'time'

module TestRunner
  TestResult = Struct.new(
    :name,           # String: test identifier from catalog
    :file,           # String: relative path to test file
    :category,       # Symbol: :unit, :network, :e2e, :db
    :status,         # Symbol: :pass, :fail, :error, :skip, :timeout
    :exit_code,      # Integer or nil
    :stdout,         # String: captured stdout
    :stderr,         # String: captured stderr
    :duration,       # Float: seconds
    :parsed_pass,    # Integer: count of parsed pass indicators
    :parsed_fail,    # Integer: count of parsed fail indicators
    :detail,         # String: human-readable explanation
    keyword_init: true
  )

  class Runner
    DEFAULT_TIMEOUTS = {
      unit: 30,
      network: 60,
      e2e: 120,
      db: 60
    }.freeze

    def initialize(catalog_path:, project_root:, options: {})
      @project_root = project_root
      @catalog = YAML.load_file(catalog_path)
      @options = options
      @results = []
      @parser = OutputParser.new
      @start_time = Time.now

      # Load custom default timeouts from catalog
      defaults = @catalog['defaults'] || {}
      @timeouts = DEFAULT_TIMEOUTS.merge(
        unit: defaults['timeout_unit'] || DEFAULT_TIMEOUTS[:unit],
        network: defaults['timeout_network'] || DEFAULT_TIMEOUTS[:network],
        e2e: defaults['timeout_e2e'] || DEFAULT_TIMEOUTS[:e2e],
        db: defaults['timeout_db'] || DEFAULT_TIMEOUTS[:db]
      )
    end

    def run
      tests = select_tests

      if tests.empty?
        puts "  No tests match the given filters."
        return
      end

      print_header(tests)

      tests.each_with_index do |(name, meta), idx|
        result = execute_test(name, meta)
        @results << result
        print_result_line(result, idx + 1, tests.size)
      end

      print_summary

      report = ReportGenerator.new(@results, @start_time, @options)
      report_path = report.write(File.join(@project_root, 'tmp'))
      puts "\n  Report: #{report_path}"

      # Return non-zero if any failures
      has_failures = @results.any? { |r| [:fail, :error, :timeout].include?(r.status) }
      exit(has_failures ? 1 : 0)
    end

    def list
      tests = select_tests
      if tests.empty?
        puts "  No tests match the given filters."
        return
      end

      puts ""
      puts "  #{tests.size} tests:"
      puts "  #{'=' * 60}"
      tests.each do |name, meta|
        cat = (meta['category'] || 'unknown').ljust(8)
        tags = (meta['tags'] || []).join(', ')
        interactive = meta['interactive'] ? ' [interactive]' : ''
        puts "  #{cat} #{name.ljust(35)} [#{tags}]#{interactive}"
      end
      puts ""
    end

    private

    def select_tests
      all_tests = @catalog['tests'] || {}
      selected = all_tests.to_a

      # Filter by category
      if @options[:categories] && !@options[:categories].empty?
        selected.select! { |_name, meta| @options[:categories].include?(meta['category']) }
      end

      # Filter by tag
      if @options[:tags] && !@options[:tags].empty?
        selected.select! do |_name, meta|
          tags = meta['tags'] || []
          @options[:tags].any? { |t| tags.include?(t) }
        end
      end

      # Filter by file name pattern
      if @options[:file_pattern]
        pattern = @options[:file_pattern]
        selected.select! { |name, _meta| name.include?(pattern) }
      end

      # Skip interactive tests unless explicitly included
      unless @options[:include_interactive]
        selected.reject! { |_name, meta| meta['interactive'] }
      end

      # Skip visual/diagnostic tests unless --visual
      if @options[:skip_visual]
        selected.reject! { |_name, meta| (meta['tags'] || []).include?('visual') }
      end

      selected
    end

    def execute_test(name, meta)
      file_path = File.join(@project_root, meta['file'])
      category = (meta['category'] || 'unit').to_sym
      timeout_sec = meta['timeout'] || @timeouts[category] || 30
      args = meta['args'] || []
      cmd = ['ruby', file_path] + args

      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stdout_str = ''
      stderr_str = ''
      exit_code = nil
      status = nil
      detail = nil

      unless File.exist?(file_path)
        duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
        return TestResult.new(
          name: name, file: meta['file'], category: category,
          status: :error, exit_code: nil,
          stdout: '', stderr: "File not found: #{file_path}",
          duration: duration, parsed_pass: 0, parsed_fail: 0,
          detail: "File not found"
        )
      end

      begin
        pid = nil
        Timeout.timeout(timeout_sec) do
          Open3.popen3(*cmd, chdir: @project_root) do |stdin, stdout, stderr, wait_thr|
            pid = wait_thr.pid
            stdin.close
            # Read stdout and stderr in threads to avoid deadlock
            stdout_thread = Thread.new { stdout.read }
            stderr_thread = Thread.new { stderr.read }
            stdout_str = stdout_thread.value
            stderr_str = stderr_thread.value
            exit_code = wait_thr.value.exitstatus
          end
        end
      rescue Timeout::Error
        # Kill the process if still running
        if pid
          begin
            Process.kill('TERM', pid)
            sleep(0.5)
            Process.kill('KILL', pid)
          rescue Errno::ESRCH
            # Process already gone
          end
        end
        status = :timeout
        detail = "Timed out after #{timeout_sec}s"
      rescue StandardError => e
        status = :error
        detail = "#{e.class}: #{e.message}"
        stderr_str = "#{stderr_str}\n#{e.class}: #{e.message}"
      end

      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

      # Parse output
      parsed = @parser.parse(
        stdout_str, stderr_str, exit_code,
        exit_code_reliable: meta['exit_code_reliable']
      )

      # Use parser result unless we already determined status (timeout/crash)
      status ||= parsed[:status]
      detail ||= parsed[:detail]

      TestResult.new(
        name: name,
        file: meta['file'],
        category: category,
        status: status,
        exit_code: exit_code,
        stdout: stdout_str,
        stderr: stderr_str,
        duration: duration,
        parsed_pass: parsed[:pass_count],
        parsed_fail: parsed[:fail_count],
        detail: detail
      )
    end

    # ---- Terminal output ----

    def print_header(tests)
      categories = tests.map { |_, m| m['category'] }.each_with_object(Hash.new(0)) { |c, h| h[c] += 1 }
      cat_summary = categories.map { |k, v| "#{v} #{k}" }.join(', ')

      puts ""
      puts "  #{colorize('ZBNW-NG Test Runner', :bold)}"
      puts "  #{tests.size} tests selected: #{cat_summary}"
      puts "  #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
      puts "  #{'=' * 60}"
      puts ""
    end

    def print_result_line(result, idx, total)
      icon = case result.status
             when :pass    then colorize('PASS', :green)
             when :fail    then colorize('FAIL', :red)
             when :error   then colorize('ERR ', :red)
             when :timeout then colorize('TIME', :yellow)
             when :skip    then colorize('SKIP', :cyan)
             end

      duration = format('%5.1fs', result.duration)
      counts = if result.parsed_pass && result.parsed_fail &&
                  (result.parsed_pass > 0 || result.parsed_fail > 0)
                 total_assertions = result.parsed_pass + result.parsed_fail
                 " (#{result.parsed_pass}/#{total_assertions})"
               else
                 ""
               end
      detail = result.detail ? "  #{result.detail}" : ""

      puts "  [#{icon}] #{idx.to_s.rjust(2)}/#{total} #{result.name.ljust(35)} #{duration}#{counts}#{detail}"
    end

    def print_summary
      pass_c  = @results.count { |r| r.status == :pass }
      fail_c  = @results.count { |r| r.status == :fail }
      err_c   = @results.count { |r| r.status == :error }
      time_c  = @results.count { |r| r.status == :timeout }
      skip_c  = @results.count { |r| r.status == :skip }
      total_time = @results.sum(&:duration)

      puts ""
      puts "  #{'=' * 60}"

      parts = []
      parts << colorize("#{pass_c} passed", :green)
      parts << colorize("#{fail_c} failed", :red)   if fail_c > 0
      parts << colorize("#{err_c} errors", :red)     if err_c > 0
      parts << colorize("#{time_c} timeouts", :yellow) if time_c > 0
      parts << colorize("#{skip_c} skipped", :cyan)  if skip_c > 0

      puts "  #{parts.join(', ')} in #{format('%.1f', total_time)}s"
      puts "  #{'=' * 60}"
    end

    def colorize(text, color)
      return text unless $stdout.tty?
      codes = { green: 32, red: 31, yellow: 33, cyan: 36, bold: 1 }
      code = codes[color]
      return text unless code
      "\e[#{code}m#{text}\e[0m"
    end
  end
end
