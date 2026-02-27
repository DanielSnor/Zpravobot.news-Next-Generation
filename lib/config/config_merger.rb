# frozen_string_literal: true

require_relative '../utils/hash_helpers'

module Config
  # Merges hierarchical YAML configuration
  #
  # Hierarchy (later overrides earlier):
  #   1. global.yml
  #   2. platforms/{platform}.yml
  #   3. sources/{source_id}.yml
  class ConfigMerger
    # Merge config hierarchy for a source
    # @param global [Hash] Global configuration
    # @param platform_config [Hash] Platform configuration
    # @param source_config [Hash] Source configuration
    # @return [Hash] Merged configuration
    def merge(global, platform_config, source_config)
      HashHelpers.deep_merge_all(global, platform_config, source_config)
    end
  end
end
