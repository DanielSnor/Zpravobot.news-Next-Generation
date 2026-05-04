# frozen_string_literal: true

require_relative '../utils/hash_helpers'

module Config
  # Merges hierarchical YAML configuration
  #
  # Hierarchy (later overrides earlier):
  #   1. global.yml
  #   2. platforms/{platform}.yml
  #   3. platforms/{rss_source_type}.yml  (volitelný overlay pro RSS-fed
  #      sociální feedy: facebook/instagram/threads — viz ConfigLoader)
  #   4. sources/{source_id}.yml
  class ConfigMerger
    # Merge config hierarchy for a source
    # @param configs [Array<Hash>] Configs in priority order (later overrides earlier).
    #   Typicky: [global, platform, [rss_source_type_overlay], source]
    # @return [Hash] Merged configuration
    def merge(*configs)
      HashHelpers.deep_merge_all(*configs)
    end
  end
end
