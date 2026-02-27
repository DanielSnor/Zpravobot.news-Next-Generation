# frozen_string_literal: true

class CheckResult
  LEVELS = { ok: 0, warning: 1, critical: 2 }.freeze

  attr_reader :name, :level, :message, :details, :remediation

  def initialize(name:, level:, message:, details: nil, remediation: nil)
    @name = name
    @level = level
    @message = message
    @details = details
    @remediation = remediation
  end

  def ok?
    level == :ok
  end

  def warning?
    level == :warning
  end

  def critical?
    level == :critical
  end

  def icon
    case level
    when :ok then "\u2705"
    when :warning then "\u26a0\ufe0f"
    when :critical then "\u274c"
    end
  end

  def to_h
    {
      name: name,
      level: level,
      message: message,
      details: details,
      remediation: remediation
    }.compact
  end
end
