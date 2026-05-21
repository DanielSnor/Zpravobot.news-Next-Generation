# frozen_string_literal: true

require 'uri'

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
# Security: all values that originate from external platforms (website,
# handle-derived URLs) are sanitized before being written to Mastodon.
# See sanitize_field_value / sanitize_url_field.
#
# ============================================================

module Syncers
  module ProfileFieldsBuilder
    FIELD_LABELS = {
      'cs' => { managed: 'spravuje:', retention: 'retence:', days: 'dní', from: 'z' },
      'sk' => { managed: 'spravované:', retention: 'retencia:', days: 'dní', from: 'z' },
      'en' => { managed: 'managed by:', retention: 'retention:', days: 'days', from: 'from' }
    }.freeze

    VALID_RETENTION_DAYS = [7, 14, 30, 90, 180].freeze
    MANAGED_BY = '@zpravobot@zpravobot.news'

    # Mastodon hard limit for a single field value (characters).
    MASTODON_FIELD_VALUE_MAX = 255

    # Short display labels for each source platform, used in the SPRAVUJE field.
    PLATFORM_LABELS = {
      'twitter'   => 'X',
      'bluesky'   => 'Bluesky',
      'facebook'  => 'FB',
      'instagram' => 'IG',
      'threads'   => 'Threads',
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
    # @param handle [String] Platform handle
    # @param current_fields [Array<Hash>] Current Mastodon fields
    # @param extra_data [Hash] Additional profile data.
    #   :website          → when present, used for web: instead of the current Mastodon value
    #   :source_platforms → overrides the managed-by platform list
    # @return [Array<Hash>] 4-element fields array with :name and :value
    def build_fields(handle, current_fields, extra_data = {})
      labels = FIELD_LABELS[language]

      website   = extra_data[:website]
      web_value = if website && !website.empty?
                    sanitize_url_field(website.chomp('/'))
                  else
                    extract_web_value(current_fields)
                  end
      web_value = '""' if web_value.empty?

      [
        { name: field_prefix,       value: sanitize_url_field(build_profile_url(handle)) },
        { name: 'web:',             value: web_value },
        { name: labels[:managed],   value: build_managed_by_value(source_platforms: extra_data[:source_platforms]) },
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

    # ============================================================
    # Sanitization helpers (package-private — used by build_fields)
    # ============================================================

    # Strip HTML tags, control characters, and null bytes from an external
    # string, then truncate to Mastodon's field-value limit.
    #
    # Intended for plain-text field values (display names, labels).
    # For URL fields use sanitize_url_field instead.
    #
    # @param value [String, nil]
    # @return [String] sanitized value (never nil)
    def sanitize_field_value(value)
      return '' if value.nil?

      str = value.to_s
      # Strip HTML tags (keep text content)
      str = str.gsub(/<[^>]*>/, '')
      # Remove null bytes and ASCII control characters (keep \t, \n, \r)
      str = str.gsub(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/n, '')
      # Collapse consecutive whitespace and strip ends
      str = str.gsub(/[[:space:]]+/, ' ').strip
      # Enforce Mastodon field value limit
      str.length > MASTODON_FIELD_VALUE_MAX ? str[0, MASTODON_FIELD_VALUE_MAX] : str
    end

    # Validate and sanitize a URL intended for a Mastodon field value.
    #
    # Rejects any URL whose scheme is not http or https (e.g. javascript:,
    # data:, vbscript:). Returns '' for blank or unparseable input so the
    # caller can fall back to '""'.
    #
    # @param url [String, nil]
    # @return [String] sanitized http/https URL, or ''
    def sanitize_url_field(url)
      return '' if url.nil? || url.to_s.strip.empty?

      cleaned = sanitize_field_value(url)
      return '' if cleaned.empty?

      uri = URI.parse(cleaned)
      return '' unless %w[http https].include?(uri.scheme)

      cleaned
    rescue URI::InvalidURIError
      ''
    end
  end
end
