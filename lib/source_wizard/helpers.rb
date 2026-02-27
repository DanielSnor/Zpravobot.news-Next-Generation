# frozen_string_literal: true

class SourceGenerator
  def sanitize_handle(handle)
    handle.to_s.gsub(/^@/, '').strip
  end

  def parse_categories(input)
    return [] if input.nil? || input.empty?
    input.split(',').map(&:strip).reject(&:empty?)
  end

  # Generate source ID with platform/type suffix
  # For aggregators: {account}_{handle/source}_{platform}
  # For standalone:  {account}_{platform}
  def generate_id(data)
    base = data[:mastodon_account] || case data[:platform]
           when 'twitter'
             sanitize_id(data[:handle])
           when 'bluesky'
             if data[:bluesky_source_type] == 'feed'
               extract_bluesky_feed_rkey(data[:feed_url])
             else
               sanitize_id(data[:handle])
             end
           when 'rss'
             extract_domain(data[:feed_url])
           when 'youtube'
             sanitize_id(data[:channel_id])
           end

    suffix = platform_suffix(data)

    # Pro agregatory: vlozit identifikator zdroje mezi account a platform
    if data[:is_aggregator]
      source_part = case data[:platform]
                    when 'twitter'
                      sanitize_id(data[:handle])
                    when 'bluesky'
                      if data[:bluesky_source_type] == 'feed'
                        extract_bluesky_feed_rkey(data[:feed_url])
                      else
                        sanitize_id(data[:handle])
                      end
                    when 'rss'
                      extract_domain(data[:feed_url])
                    when 'youtube'
                      sanitize_id(data[:channel_id])
                    end
      "#{base}_#{source_part}_#{suffix}"
    else
      "#{base}_#{suffix}"
    end
  end

  # Get platform suffix for ID (respects RSS source type)
  def platform_suffix(data)
    if data[:platform] == 'rss'
      type = data[:rss_source_type] || 'rss'
      if type == 'other'
        data[:rss_custom_suffix] || 'rss'
      else
        RSS_SOURCE_TYPES[type][:suffix]
      end
    elsif data[:platform] == 'bluesky'
      type = data[:bluesky_source_type] || 'handle'
      BLUESKY_SOURCE_TYPES[type][:suffix]
    else
      data[:platform]
    end
  end

  # Extract rkey from Bluesky feed URL
  def extract_bluesky_feed_rkey(feed_url)
    if feed_url =~ %r{bsky\.app/profile/([^/]+)/feed/([^/?]+)}
      sanitize_id($2)  # rkey
    else
      'feed'
    end
  end

  def sanitize_id(text)
    text.to_s
        .gsub('@', '')
        .gsub('.bsky.social', '')
        .gsub(/[^a-zA-Z0-9]/, '_')
        .gsub(/_+/, '_')
        .gsub(/^_|_$/, '')
        .downcase
  end

  def extract_domain(url)
    require 'uri'
    uri = URI.parse(url)
    uri.host.to_s.gsub('www.', '').split('.').first
  rescue
    'feed'
  end

  def platform_label(platform)
    case platform
    when 'twitter' then 'Twitter'
    when 'bluesky' then 'Bluesky'
    when 'rss' then 'RSS'
    when 'youtube' then 'YouTube'
    else platform.capitalize
    end
  end

  # Check if this is an RSS.app source (Facebook/Instagram)
  def rssapp_source?(data)
    return false unless data[:platform] == 'rss'
    %w[facebook instagram].include?(data[:rss_source_type])
  end

  # Get default banned phrases for RSS.app sources (Facebook/Instagram)
  def rssapp_banned_phrases(data)
    return [] unless rssapp_source?(data)
    RSSAPP_BANNED_PHRASES[data[:rss_source_type]] || []
  end

  # Safe YAML string quoting -- handles any external input (display names, etc.)
  # Uses single quotes for strings with double quotes, double quotes with escaping otherwise.
  # Ensures YAML roundtrip: YAML.safe_load("key: #{yaml_quote(input)}")['key'] == input
  # @param str [String, nil] String to quote for YAML output
  # @return [String] Safely quoted YAML string value
  def yaml_quote(str)
    return '""' if str.nil? || str.to_s.empty?

    s = str.to_s
    has_double = s.include?('"')
    has_single = s.include?("'")

    if has_double && !has_single
      # Single quotes preserve double quotes literally: 'Jana "Dezinfo"'
      "'#{s}'"
    elsif has_double && has_single
      # Both quote types: double-quote with escaping
      escaped = s.gsub('\\') { '\\\\' }.gsub('"', '\\"')
      "\"#{escaped}\""
    elsif s.match?(/[:\\#\[\]{}&*!|>%@`,\\\n\t]/) ||
          s.match?(/\A[\s\-?]/) || s.match?(/\s\z/)
      # YAML-special chars or leading/trailing whitespace: double-quote with escaping
      escaped = s.gsub('\\') { '\\\\' }.gsub('"', '\\"')
      "\"#{escaped}\""
    else
      # Simple string -- double-quote for consistency
      "\"#{s}\""
    end
  end

  # Extract domain from instance URL (bez https://)
  def extract_instance_domain(url)
    url.to_s.gsub(%r{^https?://}, '').gsub(%r{/.*$}, '')
  end

  # Read a value from config/global.yml using deep symbol key path
  # @param keys [Array<Symbol>] key path, e.g. :infrastructure, :bluesky_api
  # @return [Object, nil] config value or nil if not found / not available
  def load_global_config_value(*keys)
    return nil unless defined?(@config_dir) && @config_dir

    global_path = File.join(@config_dir, 'global.yml')
    return nil unless File.exist?(global_path)

    raw = YAML.safe_load(File.read(global_path), permitted_classes: [], aliases: true)
    return nil unless raw.is_a?(Hash)

    config = deep_symbolize_keys_simple(raw)
    config.dig(*keys)
  rescue StandardError
    nil
  end

  private

  # Minimal deep_symbolize_keys for global.yml reading (avoids requiring HashHelpers)
  def deep_symbolize_keys_simple(hash)
    hash.each_with_object({}) do |(k, v), result|
      key = k.is_a?(String) ? k.to_sym : k
      result[key] = v.is_a?(Hash) ? deep_symbolize_keys_simple(v) : v
    end
  end
end
