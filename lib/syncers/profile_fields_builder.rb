# frozen_string_literal: true

# ============================================================
# ProfileFieldsBuilder — Mastodon profile field construction
# ============================================================
#
# Module included in BaseProfileSyncer. Provides pure field-building
# logic: constructing the 4 Mastodon profile metadata fields
# (platform link, web:, spravuje:, retence:) from source platform data.
#
# Depends on instance methods provided by the including class:
#   - language         → 'cs' / 'sk' / 'en'
#   - retention_days   → Integer
#   - mentions_config  → Hash with 'type' and 'value'
#   - field_prefix     → 'x:' / 'bsky:' / 'fb:' etc.
#   - platform_name    → 'Twitter' / 'Bluesky' etc.
#   - platform_key     → 'twitter' / 'bluesky' etc.
#
# Subclasses may override:
#   - build_profile_url(handle)         → hardcode platform URL
#   - build_profile_url_fallback(handle) → custom fallback URL
#   - build_fields(handle, current_fields, extra_data) → platform-specific field logic
#
# ============================================================

module Syncers
  module ProfileFieldsBuilder
    FIELD_LABELS = {
      'cs' => { managed: 'spravuje:', retention: 'retence:', days: 'dní', from: 'z' },
      'sk' => { managed: 'spravované:', retention: 'retencia:', days: 'dní', from: 'z' },
      'en' => { managed: 'managed by:', retention: 'retention:', days: 'days', from: 'from' }
    }.freeze

    VALID_RETENTION_DAYS = [7, 30, 90, 180].freeze
    MANAGED_BY = '@zpravobot@zpravobot.news'

    # Short display labels for each source platform, used in the SPRAVUJE field.
    PLATFORM_LABELS = {
      'twitter'   => 'X',
      'bluesky'   => 'Bluesky',
      'facebook'  => 'FB',
      'instagram' => 'IG',
      'youtube'   => 'YT',
      'rss'       => 'RSS'
    }.freeze

    # Build profile URL based on mentions_config from platform YAML.
    # Subclasses can override to hardcode a platform URL.
    # @param handle [String] Platform handle
    # @return [String] Profile URL
    def build_profile_url(handle)
      config_type  = mentions_config['type']  || mentions_config[:type]
      config_value = mentions_config['value'] || mentions_config[:value]

      case config_type
      when 'prefix'        then "#{config_value}#{handle}"
      when 'domain_suffix' then "https://#{config_value}/#{handle}"
      else                      build_profile_url_fallback(handle)
      end
    end

    # Fallback URL when mentions_config type is unknown.
    # Subclasses can override for platform-specific URLs.
    # @param handle [String] Platform handle
    # @return [String] Fallback profile URL
    def build_profile_url_fallback(handle)
      "https://#{platform_name.downcase}.com/#{handle}"
    end

    # Build all 4 Mastodon metadata fields.
    # Subclasses can override to add platform-specific field logic (e.g., website).
    # @param handle [String] Platform handle
    # @param current_fields [Array<Hash>] Current Mastodon fields
    # @param extra_data [Hash] Additional profile data (website, source_platforms, etc.)
    # @return [Array<Hash>] 4-element fields array with :name and :value
    def build_fields(handle, current_fields, extra_data = {})
      labels = FIELD_LABELS[language]

      [
        { name: field_prefix,      value: build_profile_url(handle) },
        { name: 'web:',            value: extract_web_value(current_fields) },
        { name: labels[:managed],  value: build_managed_by_value(source_platforms: extra_data[:source_platforms]) },
        { name: labels[:retention], value: "#{retention_days} #{labels[:days]}" }
      ]
    end

    # Extract the current web: field value from Mastodon fields.
    # @param fields [Array<Hash>] Current fields (each with :name and :value)
    # @return [String] Web value, or '""' if absent/empty
    def extract_web_value(fields)
      web_field = fields.find { |f| f[:name].downcase.start_with?('web') }
      value = web_field&.dig(:value)&.strip
      (value.nil? || value.empty?) ? '""' : value.chomp('/')
    end

    # Build the SPRAVUJE field value, e.g. "@zpravobot@zpravobot.news z X".
    # @param source_platforms [Array<String>, nil] Override platform list.
    #   When nil, uses [platform_key] from the syncer subclass.
    # @return [String] Full managed-by string
    def build_managed_by_value(source_platforms: nil)
      labels = FIELD_LABELS[language]
      platforms = source_platforms || [platform_key]
      platform_str = platforms.map { |p| PLATFORM_LABELS[p] || p }.join(', ')
      "#{MANAGED_BY} #{labels[:from]} #{platform_str}"
    end
  end
end
