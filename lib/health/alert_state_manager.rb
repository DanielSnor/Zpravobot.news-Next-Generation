# frozen_string_literal: true

require 'json'
require 'fileutils'

class AlertStateManager
  DEFAULT_STATE = {
    'problems' => {},
    'pending_resolved' => {},  # Problemy cekajici na potvrzeni vyreseni
    'last_check_at' => nil
  }.freeze

  # Intervaly pro opakovane alerty (v minutach)
  DAY_INTERVAL = 30    # 7:00 - 23:00
  NIGHT_INTERVAL = 60  # 23:00 - 7:00
  DAY_START = 7
  DAY_END = 23

  # Stabilizacni doba pro "vyreseno" (v minutach)
  RESOLVED_STABILIZATION = 20  # 2 cykly po 10 min

  def initialize(state_file)
    @state_file = state_file
    @state = load_state
  end

  # Analyzuje vysledky a vraci co se ma poslat
  # Returns: { new: [], persisting: [], resolved: [], should_alert: bool }
  def analyze(results)
    current_problems = extract_problems(results)
    previous_problems = @state['problems'] || {}
    pending_resolved = @state['pending_resolved'] || {}
    now = Time.now

    analysis = {
      new: [],
      persisting: [],
      resolved: [],
      should_alert: false
    }

    # 1. Najit nove problemy (nebyl v problems ani v pending_resolved)
    current_problems.each do |name, info|
      if !previous_problems.key?(name) && !pending_resolved.key?(name)
        analysis[:new] << { name: name, **info }
        analysis[:should_alert] = true
      end
    end

    # 2. Problemy ktere se vratily z pending_resolved (nehlasime jako nove)
    current_problems.each do |name, info|
      if pending_resolved.key?(name) && !previous_problems.key?(name)
        prev = pending_resolved[name]
        first_seen = Time.parse(prev['first_seen_at'])
        duration_minutes = ((now - first_seen) / 60).to_i

        last_alert = Time.parse(prev['last_alert_at'])
        since_last_alert = ((now - last_alert) / 60).to_i
        interval = in_day_hours?(now) ? DAY_INTERVAL : NIGHT_INTERVAL

        if since_last_alert >= interval
          analysis[:persisting] << {
            name: name,
            duration_minutes: duration_minutes,
            **info
          }
          analysis[:should_alert] = true
        end
      end
    end

    # 3. Najit pretrvavajici problemy (byl v problems, stale je)
    current_problems.each do |name, info|
      next unless previous_problems.key?(name)

      prev = previous_problems[name]
      first_seen = Time.parse(prev['first_seen_at'])
      last_alert = Time.parse(prev['last_alert_at'])
      duration_minutes = ((now - first_seen) / 60).to_i
      since_last_alert = ((now - last_alert) / 60).to_i

      interval = in_day_hours?(now) ? DAY_INTERVAL : NIGHT_INTERVAL

      if since_last_alert >= interval
        analysis[:persisting] << {
          name: name,
          duration_minutes: duration_minutes,
          **info
        }
        analysis[:should_alert] = true
      end
    end

    # 4. Najit vyresene problemy (v pending_resolved dele nez RESOLVED_STABILIZATION)
    pending_resolved.each do |name, prev|
      next if current_problems.key?(name)  # Vratil se, neni resolved

      disappeared_at = Time.parse(prev['disappeared_at'])
      since_disappeared = ((now - disappeared_at) / 60).to_i

      if since_disappeared >= RESOLVED_STABILIZATION
        first_seen = Time.parse(prev['first_seen_at'])
        duration_minutes = ((now - first_seen) / 60).to_i
        analysis[:resolved] << {
          name: name,
          duration_minutes: duration_minutes,
          level: prev['level'],
          message: prev['message']
        }
        analysis[:should_alert] = true
      end
    end

    analysis
  end

  # Aktualizuje stav po odeslani alertu
  def update_state(results, analysis)
    now = Time.now.iso8601
    current_problems = extract_problems(results)
    previous_problems = @state['problems'] || {}
    pending_resolved = @state['pending_resolved'] || {}

    new_problems = {}
    new_pending_resolved = {}

    # Aktualizovat aktivni problemy
    current_problems.each do |name, info|
      if previous_problems.key?(name)
        was_alerted = analysis[:persisting].any? { |p| p[:name] == name }
        new_problems[name] = {
          'first_seen_at' => previous_problems[name]['first_seen_at'],
          'last_alert_at' => was_alerted ? now : previous_problems[name]['last_alert_at'],
          'level' => info[:level].to_s,
          'message' => info[:message]
        }
      elsif pending_resolved.key?(name)
        was_alerted = analysis[:persisting].any? { |p| p[:name] == name }
        new_problems[name] = {
          'first_seen_at' => pending_resolved[name]['first_seen_at'],
          'last_alert_at' => was_alerted ? now : pending_resolved[name]['last_alert_at'],
          'level' => info[:level].to_s,
          'message' => info[:message]
        }
      else
        new_problems[name] = {
          'first_seen_at' => now,
          'last_alert_at' => now,
          'level' => info[:level].to_s,
          'message' => info[:message]
        }
      end
    end

    # Presunout vyresene problemy do pending_resolved
    previous_problems.each do |name, prev|
      next if current_problems.key?(name)

      new_pending_resolved[name] = {
        'first_seen_at' => prev['first_seen_at'],
        'last_alert_at' => prev['last_alert_at'],
        'disappeared_at' => now,
        'level' => prev['level'],
        'message' => prev['message']
      }
    end

    # Zachovat pending_resolved ktere jeste nejsou potvrzene a nevratily se
    pending_resolved.each do |name, prev|
      next if current_problems.key?(name)
      next if analysis[:resolved].any? { |r| r[:name] == name }

      new_pending_resolved[name] = prev
    end

    @state = {
      'problems' => new_problems,
      'pending_resolved' => new_pending_resolved,
      'last_check_at' => now
    }

    save_state
  end

  # Vymaze stav (po vyreseni vsech problemu)
  def clear_state
    @state = DEFAULT_STATE.dup
    @state = @state.transform_values { |v| v.is_a?(Hash) ? v.dup : v }
    save_state
  end

  def has_previous_problems?
    (@state['problems'] || {}).any? || (@state['pending_resolved'] || {}).any?
  end

  private

  def extract_problems(results)
    problems = {}
    results.each do |result|
      next if result.ok?
      problems[result.name] = {
        level: result.level,
        message: result.message,
        remediation: result.remediation
      }
    end
    problems
  end

  def in_day_hours?(time)
    hour = time.hour
    hour >= DAY_START && hour < DAY_END
  end

  def load_state
    return DEFAULT_STATE.dup.transform_values { |v| v.is_a?(Hash) ? v.dup : v } unless File.exist?(@state_file)

    state = JSON.parse(File.read(@state_file))
    # Zajistit ze pending_resolved existuje (migrace stareho stavu)
    state['pending_resolved'] ||= {}
    state
  rescue JSON::ParserError, Errno::ENOENT
    DEFAULT_STATE.dup.transform_values { |v| v.is_a?(Hash) ? v.dup : v }
  end

  def save_state
    FileUtils.mkdir_p(File.dirname(@state_file))
    File.write(@state_file, JSON.pretty_generate(@state))
  end
end
