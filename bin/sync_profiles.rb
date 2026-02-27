#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Zprávobot ZBNW-NG Profile Sync Runner
# ============================================================
# Synchronizuje profily ze zdrojových platforem do Mastodonu
#
# Usage:
#   bundle exec ruby bin/sync_profiles.rb                        # Všechny enabled sources
#   bundle exec ruby bin/sync_profiles.rb --source X             # Konkrétní source
#   bundle exec ruby bin/sync_profiles.rb --platform bluesky     # Jen Bluesky
#   bundle exec ruby bin/sync_profiles.rb --exclude-platform twitter  # Vše kromě Twitteru
#   bundle exec ruby bin/sync_profiles.rb --dry-run              # Jen preview
#   bundle exec ruby bin/sync_profiles.rb --platform twitter --group 0  # Twitter skupina 0
#
# Group rotation (for Twitter):
#   Sources are split into 3 groups (0, 1, 2) by hash of source_id.
#   Cron rotates groups across days: Mon/Thu=0, Tue/Fri=1, Wed/Sat=2.
#
# Logging:
#   Logs are written to logs/profile_sync_YYYYMMDD.log with daily rotation.
#   - New file created at midnight
#   - Old files deleted after 7 days
#
# Cron example (4x denně):
#   0 6,12,18,0 * * * cd /app/data/zbnw-ng && bundle exec ruby bin/sync_profiles.rb
#
# ============================================================

require 'bundler/setup'
require 'fileutils'
require 'optparse'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'logging'
require_relative '../lib/config/config_loader'
require_relative '../lib/syncers/bluesky_profile_syncer'
require_relative '../lib/syncers/twitter_profile_syncer'
require_relative '../lib/syncers/facebook_profile_syncer'

# ============================================================
# Lockfile - prevents overlapping runs
# ============================================================
LOCKFILE = File.expand_path('../tmp/sync_profiles.lock', __dir__)

def acquire_lock
  FileUtils.mkdir_p(File.dirname(LOCKFILE))
  @lock_file = File.open(LOCKFILE, File::RDWR | File::CREAT)
  @lock_file.flock(File::LOCK_NB | File::LOCK_EX)
rescue Errno::EACCES
  false
end

# ============================================================
# Signal handling - graceful shutdown
# ============================================================
$shutdown_requested = false

%w[INT TERM].each do |signal|
  trap(signal) do
    $shutdown_requested = true
    Logging.warn("Received #{signal}, stopping after current source...")
  end
end

# ============================================================
# Main runner class
# ============================================================
class ProfileSyncRunner
  VALID_PLATFORMS = %w[twitter bluesky facebook rss].freeze
  VALID_GROUPS = [0, 1, 2].freeze
  NUM_GROUPS = 3

  def initialize(options = {})
    @options = options
    @config_loader = Config::ConfigLoader.new
    @stats = { synced: 0, skipped: 0, errors: 0 }
  end

  def run
    Logging.info('=' * 60)
    Logging.info('Zpravobot Profile Sync')
    Logging.info('=' * 60)
    Logging.info("Dry run: #{@options[:dry_run] || false}")
    Logging.info("Exclude platform: #{@options[:exclude_platform]}") if @options[:exclude_platform]
    Logging.info("Platform: #{@options[:platform]}") if @options[:platform]
    Logging.info("Source: #{@options[:source]}") if @options[:source]
    Logging.info("Group: #{@options[:group]} of 0..#{NUM_GROUPS - 1}") if @options[:group]
    Logging.info('=' * 60)

    sources = load_sources

    sources.each do |source|
      break if $shutdown_requested
      sync_source(source)
    end

    Logging.info('=' * 60)
    Logging.info('Summary')
    Logging.info('=' * 60)
    Logging.info("Synced:  #{@stats[:synced]}")
    Logging.info("Skipped: #{@stats[:skipped]}")
    Logging.info("Errors:  #{@stats[:errors]}")
    Logging.info('=' * 60)

    # Return exit code based on errors
    @stats[:errors] > 0 ? 1 : 0
  end

  private

  def load_sources
    raw_sources = if @options[:source]
                    source = load_source(@options[:source])
                    source ? [source] : []
                  elsif @options[:platform]
                    @config_loader.load_sources_by_platform(@options[:platform])
                  else
                    @config_loader.load_all_sources
                  end

    # Convert to SourceConfig objects and filter
    # Note: Using map + compact instead of filter_map for Ruby 2.6 compatibility
    sources = raw_sources.map do |source|
      # Wrap Hash in SourceConfig if needed
      config = source.is_a?(Hash) ? Config::SourceConfig.new(source) : source

      # Skip if not valid
      next nil unless config.respond_to?(:enabled?) && config.respond_to?(:id)
      # Skip if not enabled
      next nil unless config.enabled?
      # Skip example files (start with ! or contain 'example')
      next nil if config.id.to_s.start_with?('!') || config.id.to_s.include?('example')
      # Check profile_sync enabled
      next nil unless profile_sync_enabled?(config)
      # Skip excluded platform
      next nil if @options[:exclude_platform] && config.platform == @options[:exclude_platform]

      config
    end.compact

    # Deduplicate by ID
    sources = sources.uniq { |s| s.id }

    # Filter by group (deterministic hash-based assignment)
    if @options[:group]
      total = sources.length
      sources = sources.select { |s| source_group(s.id) == @options[:group] }
      Logging.info("Group #{@options[:group]}: #{sources.length} of #{total} sources")
    end

    sources
  end

  def load_source(source_id)
    @config_loader.load_source(source_id)
  rescue StandardError => e
    Logging.error("Failed to load source #{source_id}: #{e.message}")
    nil
  end

  def profile_sync_enabled?(source)
    sync_config = source.data.dig(:profile_sync) || {}
    sync_config[:enabled] != false  # Default to true if not specified
  end

  # Deterministic group assignment based on source_id hash
  # @param source_id [String] Source identifier
  # @return [Integer] Group number (0, 1, or 2)
  def source_group(source_id)
    source_id.to_s.bytes.sum % NUM_GROUPS
  end

  def sync_source(source)
    Logging.info("[#{source.id}] Syncing profile...")

    # Determine effective platform:
    # - _facebook / _instagram suffixed sources are RSS feeds but sync as their own platform
    # - rss_source_type override also supported for explicit config
    effective_platform = if source.platform == 'rss'
                           id = source.id.to_s
                           if id.end_with?('_facebook') || source.rss_source_type == 'facebook'
                             'facebook'
                           elsif id.end_with?('_instagram')
                             'instagram'
                           else
                             'rss'
                           end
                         else
                           source.platform
                         end

    case effective_platform
    when 'bluesky'
      sync_bluesky(source)
    when 'twitter'
      sync_twitter(source)
    when 'facebook'
      sync_facebook(source)
    when 'rss'
      sync_rss(source)
    else
      Logging.warn("[#{source.id}] Profile sync not supported for platform: #{source.platform}")
      @stats[:skipped] += 1
    end

  rescue StandardError => e
    Logging.error("[#{source.id}] Error: #{e.message}")
    Logging.debug(e.backtrace.first) if ENV['DEBUG']
    @stats[:errors] += 1
  end

  def sync_bluesky(source)
    sync_config = source.data.dig(:profile_sync) || {}

    # Load platform config for mentions
    platform_config = @config_loader.load_platform_config('bluesky')
    mentions_config = platform_config[:mentions] || { type: 'prefix', value: 'https://bsky.app/profile/' }

    global = @config_loader.load_global_config

    syncer = Syncers::BlueskyProfileSyncer.new(
      bluesky_handle: source.source_handle,
      bluesky_api: global.dig(:infrastructure, :bluesky_api),
      bluesky_profile_prefix: global.dig(:infrastructure, :bluesky_profile_prefix),
      mastodon_instance: source.mastodon_instance,
      mastodon_token: source.mastodon_token,
      language: sync_config.fetch(:language, 'cs'),
      retention_days: sync_config.fetch(:retention_days, 90),
      mentions_config: mentions_config
    )

    run_syncer(source, syncer, sync_config)
  end

  def sync_twitter(source)
    sync_config = source.data.dig(:profile_sync) || {}

    # Load platform config for mentions
    platform_config = @config_loader.load_platform_config('twitter')
    mentions_config = platform_config[:mentions] || { type: 'domain_suffix', value: 'twitter.com' }

    syncer = Syncers::TwitterProfileSyncer.new(
      twitter_handle: source.source_handle,
      nitter_instance: source.nitter_instance,
      mastodon_instance: source.mastodon_instance,
      mastodon_token: source.mastodon_token,
      language: sync_config.fetch(:language, 'cs'),
      retention_days: sync_config.fetch(:retention_days, 90),
      mentions_config: mentions_config
    )

    run_syncer(source, syncer, sync_config)
  end

  def sync_facebook(source)
    sync_config = source.data.dig(:profile_sync) || {}

    # Load platform config for mentions and Facebook-specific settings
    platform_config = @config_loader.load_platform_config('facebook')
    mentions_config = platform_config[:mentions] || { type: 'domain_suffix', value: 'facebook.com' }

    # Get Browserless token from platform config or ENV
    raw_token = platform_config.dig(:source, :browserless_token)
    browserless_token = resolve_env_value(raw_token) || ENV['BROWSERLESS_TOKEN']
    raise 'BROWSERLESS_TOKEN not configured' if browserless_token.nil? || browserless_token.empty?

    # Get Facebook cookies from platform config or ENV
    facebook_cookies = build_facebook_cookies(platform_config)
    raise 'Facebook cookies not configured' if facebook_cookies.empty?

    global = @config_loader.load_global_config

    syncer = Syncers::FacebookProfileSyncer.new(
      facebook_handle: source.source_handle,
      browserless_api: global.dig(:infrastructure, :browserless_api),
      mastodon_instance: source.mastodon_instance,
      mastodon_token: source.mastodon_token,
      browserless_token: browserless_token,
      facebook_cookies: facebook_cookies,
      language: sync_config.fetch(:language, 'cs'),
      retention_days: sync_config.fetch(:retention_days, 90),
      mentions_config: mentions_config
    )

    run_syncer(source, syncer, sync_config)
  end

  def sync_rss(source)
    sync_config   = source.data.dig(:profile_sync) || {}
    social_profile = sync_config[:social_profile]

    unless social_profile && social_profile[:platform] && social_profile[:handle]
      Logging.warn("[#{source.id}] RSS profile sync: no social_profile configured, skipping")
      @stats[:skipped] += 1
      return
    end

    platform = social_profile[:platform].to_s
    handle   = social_profile[:handle].to_s

    case platform
    when 'twitter'
      sync_twitter_for_rss(source, handle, sync_config)
    when 'bluesky'
      sync_bluesky_for_rss(source, handle, sync_config)
    when 'facebook'
      sync_facebook_for_rss(source, handle, sync_config)
    else
      Logging.warn("[#{source.id}] RSS profile sync: unsupported platform '#{platform}', skipping")
      @stats[:skipped] += 1
    end
  end

  def sync_twitter_for_rss(source, twitter_handle, sync_config)
    platform_config = @config_loader.load_platform_config('twitter')
    mentions_config = platform_config[:mentions] || { type: 'domain_suffix', value: 'twitter.com' }

    syncer = Syncers::TwitterProfileSyncer.new(
      twitter_handle: twitter_handle,
      nitter_instance: source.nitter_instance,
      mastodon_instance: source.mastodon_instance,
      mastodon_token: source.mastodon_token,
      language: sync_config.fetch(:language, 'cs'),
      retention_days: sync_config.fetch(:retention_days, 90),
      mentions_config: mentions_config
    )

    run_syncer(source, syncer, sync_config)
  end

  def sync_bluesky_for_rss(source, bluesky_handle, sync_config)
    platform_config = @config_loader.load_platform_config('bluesky')
    mentions_config = platform_config[:mentions] || { type: 'prefix', value: 'https://bsky.app/profile/' }
    global = @config_loader.load_global_config

    syncer = Syncers::BlueskyProfileSyncer.new(
      bluesky_handle: bluesky_handle,
      bluesky_api: global.dig(:infrastructure, :bluesky_api),
      bluesky_profile_prefix: global.dig(:infrastructure, :bluesky_profile_prefix),
      mastodon_instance: source.mastodon_instance,
      mastodon_token: source.mastodon_token,
      language: sync_config.fetch(:language, 'cs'),
      retention_days: sync_config.fetch(:retention_days, 90),
      mentions_config: mentions_config
    )

    run_syncer(source, syncer, sync_config)
  end

  def sync_facebook_for_rss(source, facebook_handle, sync_config)
    platform_config = @config_loader.load_platform_config('facebook')
    mentions_config = platform_config[:mentions] || { type: 'domain_suffix', value: 'facebook.com' }

    raw_token = platform_config.dig(:source, :browserless_token)
    browserless_token = resolve_env_value(raw_token) || ENV['BROWSERLESS_TOKEN']
    raise 'BROWSERLESS_TOKEN not configured' if browserless_token.nil? || browserless_token.empty?

    facebook_cookies = build_facebook_cookies(platform_config)
    raise 'Facebook cookies not configured' if facebook_cookies.empty?

    global = @config_loader.load_global_config

    syncer = Syncers::FacebookProfileSyncer.new(
      facebook_handle: facebook_handle,
      browserless_api: global.dig(:infrastructure, :browserless_api),
      mastodon_instance: source.mastodon_instance,
      mastodon_token: source.mastodon_token,
      browserless_token: browserless_token,
      facebook_cookies: facebook_cookies,
      language: sync_config.fetch(:language, 'cs'),
      retention_days: sync_config.fetch(:retention_days, 90),
      mentions_config: mentions_config
    )

    run_syncer(source, syncer, sync_config)
  end

  def run_syncer(source, syncer, sync_config)
    if @options[:dry_run]
      syncer.preview
      @stats[:skipped] += 1
    else
      result = syncer.sync!(
        sync_avatar: sync_config.fetch(:sync_avatar, true),
        sync_banner: sync_config.fetch(:sync_banner, true),
        sync_bio:    sync_config.fetch(:sync_bio, true),
        sync_fields: sync_config.fetch(:sync_fields, true)
      )
      result[:success] ? @stats[:synced] += 1 : @stats[:errors] += 1
    end
  end

  def build_facebook_cookies(platform_config)
    cookies_config = platform_config.dig(:source, :facebook_cookies) || []

    # If cookies have ENV placeholders, resolve them
    cookies_config.map do |cookie|
      {
        name: cookie[:name],
        value: resolve_env_value(cookie[:value]),
        domain: cookie[:domain] || '.facebook.com'
      }
    end.reject { |c| c[:value].nil? || c[:value].empty? || c[:value].start_with?('${') }
  end

  def resolve_env_value(value)
    return value unless value.is_a?(String)

    # Replace ${ENV_VAR} with actual ENV value
    if value =~ /^\$\{(\w+)\}$/
      ENV[$1]
    else
      value
    end
  end
end

if $0 == __FILE__

# ============================================================
# Parse command line arguments
# ============================================================
options = {
  dry_run: false,
  source: nil,
  platform: nil,
  exclude_platform: nil,
  group: nil,
  log_dir: 'logs'
}

OptionParser.new do |opts|
  opts.banner = "Usage: bundle exec ruby bin/sync_profiles.rb [OPTIONS]"

  opts.on('--source SOURCE_ID', 'Sync only specific source') do |v|
    options[:source] = v
  end

  opts.on('--platform PLATFORM', 'Sync only sources for platform (bluesky, twitter)') do |v|
    options[:platform] = v
  end

  opts.on('--exclude-platform PLATFORM', 'Sync all platforms EXCEPT specified (bluesky, twitter)') do |v|
    options[:exclude_platform] = v
  end

  opts.on('--group GROUP', Integer, 'Sync only sources in group 0, 1, or 2 (for rotation scheduling)') do |v|
    options[:group] = v
  end

  opts.on('--dry-run', 'Preview only, do not update Mastodon') do
    options[:dry_run] = true
  end

  opts.on('--log-dir DIR', 'Log directory (default: logs)') do |v|
    options[:log_dir] = v
  end

  opts.on('-h', '--help', 'Show this help') do
    puts opts
    exit 0
  end
end.parse!

# ============================================================
# Validate options
# ============================================================

# Validate mutual exclusivity
conflicting_options = [options[:source], options[:platform], options[:exclude_platform]].compact
if conflicting_options.length > 1
  warn 'Error: --source, --platform, and --exclude-platform are mutually exclusive.'
  exit 2
end

# Validate platform values
if options[:platform] && !ProfileSyncRunner::VALID_PLATFORMS.include?(options[:platform])
  warn "Error: Invalid platform '#{options[:platform]}'. Valid: #{ProfileSyncRunner::VALID_PLATFORMS.join(', ')}"
  exit 2
end

if options[:exclude_platform] && !ProfileSyncRunner::VALID_PLATFORMS.include?(options[:exclude_platform])
  warn "Error: Invalid platform '#{options[:exclude_platform]}'. Valid: #{ProfileSyncRunner::VALID_PLATFORMS.join(', ')}"
  exit 2
end

if options[:group] && !ProfileSyncRunner::VALID_GROUPS.include?(options[:group])
  warn "Error: Invalid group '#{options[:group]}'. Valid: #{ProfileSyncRunner::VALID_GROUPS.join(', ')}"
  exit 2
end

# ============================================================
# Acquire lock and run
# ============================================================
unless acquire_lock
  warn 'Another instance is already running (lockfile present). Exiting.'
  exit 3
end

# ============================================================
# Initialize logging (daily rotation)
# ============================================================
Logging.setup(
  name: 'profile_sync',
  dir: options[:log_dir],
  keep_days: 7
)

runner = ProfileSyncRunner.new(options)
exit runner.run

end # if $0 == __FILE__
