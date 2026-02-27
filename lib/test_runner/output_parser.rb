# frozen_string_literal: true

module TestRunner
  class OutputParser
    # Parses test stdout/stderr and returns a result hash:
    #   { status: :pass/:fail/:error/:skip, pass_count: N, fail_count: N, detail: "..." }
    def parse(stdout, stderr, exit_code, exit_code_reliable: false)
      # Normalize to valid UTF-8 — Open3 captures as binary, tests emit Unicode (✓ ✗ ✅ ❌)
      stdout = safe_encode(stdout)
      stderr = safe_encode(stderr)

      result = {
        pass_count: 0,
        fail_count: 0,
        status: nil,
        detail: nil
      }

      # 1. Check for crash/load errors first
      if load_error?(stdout, stderr)
        result[:status] = :skip
        result[:detail] = "LoadError: missing dependency"
        return result
      end

      if crash?(stderr)
        result[:status] = :error
        result[:detail] = extract_error_summary(stderr)
        return result
      end

      # 2. Try to extract a structured summary line (most reliable)
      summary = extract_summary(stdout)
      if summary
        result[:pass_count] = summary[:passed]
        result[:fail_count] = summary[:failed]
      else
        # 3. Fallback: count individual pass/fail indicators per line
        counts = count_indicators(stdout)
        result[:pass_count] = counts[:pass]
        result[:fail_count] = counts[:fail]
      end

      # 4. Determine final status
      result[:status] = determine_status(
        result[:pass_count],
        result[:fail_count],
        exit_code,
        exit_code_reliable
      )

      # 5. Build detail message
      result[:detail] = build_detail(result, exit_code, exit_code_reliable)

      result
    end

    private

    # ---- Summary line extraction ----
    # Tries multiple regex patterns to find a structured summary.
    # Returns { passed: N, failed: N } or nil.
    def extract_summary(stdout)
      return nil if stdout.nil? || stdout.empty?

      # Pattern: "Results: N/M tests passed" or "N/M passed"
      if stdout =~ /(\d+)\s*\/\s*(\d+)\s*(?:tests?\s+)?passed/i
        total = $2.to_i
        passed = $1.to_i
        return { passed: passed, failed: total - passed }
      end

      # Pattern: "N passed, N failed" (with optional surrounding text)
      if stdout =~ /(\d+)\s+passed[,.\s]+(\d+)\s+failed/i
        return { passed: $1.to_i, failed: $2.to_i }
      end

      # Pattern: "Passed: N" + "Failed: N" (may be on separate lines)
      passed_match = stdout.match(/Passed:\s*(\d+)/i)
      failed_match = stdout.match(/Failed:\s*(\d+)/i)
      if passed_match && failed_match
        return { passed: passed_match[1].to_i, failed: failed_match[1].to_i }
      end

      # Pattern: "Total: N passed, N failed out of M"
      if stdout =~ /Total:\s*(\d+)\s+passed.*?(\d+)\s+failed/i
        return { passed: $1.to_i, failed: $2.to_i }
      end

      nil
    end

    # ---- Per-line indicator counting ----
    def count_indicators(stdout)
      pass_count = 0
      fail_count = 0

      return { pass: 0, fail: 0 } if stdout.nil? || stdout.empty?

      stdout.each_line do |line|
        # Strip ANSI escape codes for clean matching
        stripped = line.gsub(/\e\[[0-9;]*m/, '')

        # Pass indicators (count at most 1 per line to avoid double-counting)
        if stripped.include?("\u2705")         # ✅
          pass_count += 1
        elsif stripped =~ /[✓]\s/             # checkmark (Pattern B)
          pass_count += 1
        elsif stripped =~ /Result:\s*PASS\b/i # Plain text (Pattern G)
          pass_count += 1
        end

        # Fail indicators (count at most 1 per line)
        if stripped.include?("\u274C")         # ❌
          fail_count += 1
        elsif stripped =~ /[✗]\s/             # x-mark (Pattern B)
          fail_count += 1
        elsif stripped =~ /Result:\s*FAIL\b/i # Plain text (Pattern G)
          fail_count += 1
        elsif stripped.include?("\u{1F4A5}")   # 💥 (crash emoji)
          fail_count += 1
        end
      end

      { pass: pass_count, fail: fail_count }
    end

    # ---- Status determination ----
    def determine_status(pass_count, fail_count, exit_code, exit_code_reliable)
      if fail_count > 0
        :fail
      elsif exit_code_reliable && exit_code && exit_code != 0
        :fail
      elsif !exit_code_reliable && exit_code && exit_code != 0 && pass_count == 0
        # Unreliable exit code, but also no pass indicators -- likely a real error
        :error
      elsif pass_count > 0
        :pass
      elsif exit_code.nil? || exit_code == 0
        # No assertions detected, but exited cleanly
        :pass
      else
        :error
      end
    end

    # ---- Detail message ----
    def build_detail(result, exit_code, exit_code_reliable)
      case result[:status]
      when :fail
        if result[:fail_count] > 0
          "#{result[:fail_count]} assertion(s) failed"
        elsif exit_code_reliable && exit_code && exit_code != 0
          "exit code #{exit_code}"
        end
      when :error
        "exit code #{exit_code}, no assertions detected"
      when :pass
        if result[:pass_count] == 0
          "no assertions (visual/diagnostic)"
        else
          nil
        end
      end
    end

    # ---- Encoding helper ----
    # Subprocess output arrives as ASCII-8BIT/US-ASCII bytes that are actually UTF-8.
    # Reinterpret as UTF-8 (force_encoding) then validate/repair.
    def safe_encode(str)
      return '' if str.nil?
      str = str.dup.force_encoding('UTF-8')
      str.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
    rescue StandardError
      ''
    end

    # ---- Crash detection ----
    def crash?(stderr)
      return false if stderr.nil? || stderr.strip.empty?

      stderr.include?("Traceback") ||
        stderr =~ /NameError|NoMethodError|SyntaxError|ArgumentError|TypeError/ ||
        stderr.include?("Segmentation fault") ||
        (stderr =~ /Error/ && stderr.include?("from "))
    end

    def load_error?(stdout, stderr)
      combined = "#{stdout}\n#{stderr}"
      combined.include?("LoadError") ||
        combined.include?("cannot load such file") ||
        combined =~ /Skipping\s+\w+.*\.rb/i
    end

    def extract_error_summary(stderr)
      lines = stderr.strip.split("\n")
      error_line = lines.find { |l| l =~ /Error|error|undefined|cannot/ }
      error_line ||= lines.first
      error_line&.strip&.slice(0, 150)
    end
  end
end
