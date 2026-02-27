# frozen_string_literal: true

# Shared hash utility methods
# Eliminates duplicated symbolize_keys / deep_merge across formatters and config
module HashHelpers
  module_function

  # Recursively convert string keys to symbols (Hash only, ignores arrays)
  # @param hash [Hash] Input hash with string or symbol keys
  # @return [Hash] New hash with all keys symbolized (deep)
  def symbolize_keys(hash)
    return {} unless hash.is_a?(Hash)

    hash.each_with_object({}) do |(key, value), result|
      sym_key = key.is_a?(String) ? key.to_sym : key
      result[sym_key] = value.is_a?(Hash) ? symbolize_keys(value) : value
    end
  end

  # Recursively convert string keys to symbols (handles nested Hashes and Arrays)
  # @param obj [Object] Input object (Hash, Array, or scalar)
  # @return [Object] Transformed object with all hash keys symbolized
  def deep_symbolize_keys(obj)
    case obj
    when Hash
      obj.each_with_object({}) do |(key, val), result|
        result[key.to_s.to_sym] = deep_symbolize_keys(val)
      end
    when Array
      obj.map { |v| deep_symbolize_keys(v) }
    else
      obj
    end
  end

  # Deep merge two hashes (override wins, nil values in override are ignored)
  # @param base [Hash] Base hash
  # @param override [Hash] Override hash (takes precedence)
  # @return [Hash] Merged hash
  def deep_merge(base, override)
    base.merge(override) do |_key, base_val, override_val|
      if base_val.is_a?(Hash) && override_val.is_a?(Hash)
        deep_merge(base_val, override_val)
      else
        override_val.nil? ? base_val : override_val
      end
    end
  end

  # Deep merge multiple hashes (later overrides earlier)
  # @param hashes [Array<Hash>] Hashes to merge
  # @return [Hash] Merged result
  def deep_merge_all(*hashes)
    hashes.reduce({}) do |result, hash|
      next result unless hash.is_a?(Hash)
      deep_merge(result, hash)
    end
  end
end
