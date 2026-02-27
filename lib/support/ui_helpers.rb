# frozen_string_literal: true

module Support
  # Shared interactive CLI helpers for terminal-based tools.
  # Stateless — no instance variables needed.
  # Used by SourceGenerator (wizard) and Broadcast::Broadcaster.
  module UiHelpers
    # Safe stdin read with UTF-8 encoding handling
    def safe_gets
      input = $stdin.gets || ''
      input.force_encoding('UTF-8')
           .encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
           .chomp
           .strip
    end

    def ask(prompt, required: false, default: nil)
      default_str = default ? " [#{default}]" : ''
      required_str = required ? ' *' : ''

      print "  #{prompt}#{required_str}#{default_str}: "
      answer = safe_gets

      if answer.empty?
        return default if default
        if required
          puts '  ⚠️  Toto pole je povinné!'
          return ask(prompt, required: required, default: default)
        end
      end

      answer.empty? ? (default || '') : answer
    end

    def ask_choice(prompt, options, default: nil)
      default_idx = default ? options.index(default) : nil

      puts "  #{prompt}:"
      options.each_with_index do |opt, idx|
        marker = (default_idx == idx) ? ' (default)' : ''
        puts "    #{idx + 1}. #{opt}#{marker}"
      end

      default_hint = default_idx ? " [#{default_idx + 1}]" : ''
      print "  Vyber číslo#{default_hint}: "
      answer = safe_gets

      if answer.empty? && default
        return default
      end

      idx = answer.to_i - 1
      if idx >= 0 && idx < options.length
        options[idx]
      else
        puts '  ⚠️  Neplatná volba, zkus znovu.'
        ask_choice(prompt, options, default: default)
      end
    end

    def ask_yes_no(prompt, default: nil)
      default_str = case default
                    when true then ' [A/n]'
                    when false then ' [a/N]'
                    else ' [a/n]'
                    end

      print "  #{prompt}#{default_str}: "
      answer = safe_gets.downcase

      return default if answer.empty? && !default.nil?

      case answer
      when 'a', 'ano', 'y', 'yes', '1', 'true'
        true
      when 'n', 'ne', 'no', '0', 'false'
        false
      else
        puts '  ⚠️  Odpověz "a" nebo "n".'
        ask_yes_no(prompt, default: default)
      end
    end

    def ask_number(prompt, default: nil)
      answer = ask(prompt, required: false, default: default&.to_s)
      answer.to_s.empty? ? default : answer.to_i
    end

    def separator(title)
      puts "  ── #{title} ──"
    end
  end
end
