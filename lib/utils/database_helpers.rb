# frozen_string_literal: true

# Shared database utility methods
module DatabaseHelpers
  ALLOWED_SCHEMAS = %w[zpravobot zpravobot_test].freeze

  module_function

  # Validate schema name against allowlist to prevent SQL injection
  # @param schema [String] Schema name to validate
  # @raise [ArgumentError] if schema is not in allowlist
  def validate_schema!(schema)
    unless ALLOWED_SCHEMAS.include?(schema)
      raise ArgumentError, "Invalid schema: #{schema}. Allowed: #{ALLOWED_SCHEMAS.join(', ')}"
    end
  end
end
