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
require_relative '../lib/syncers/instagram_profile_syncer'
require_relative '../lib/syncers/threads_profile_syncer'
require_relative '../lib/syncers/youtube_profile_syncer'

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
  VALID_PLATFORMS = %w[twitter bluesky facebook instagram youtube rss].freeze
  VALID_GROUPS = [0, 1, 2].freeze
  NUM_GROUPS = 3

  def initialize(options = {})
    @options = options
    @config_loader = Config::ConfigLoader.new
    @stats = { synced: 0, skipped: 0, errors: 0 }
    @account_platforms = {}
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
    build_account_platforms

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

    effective_platform = effective_platform_for(source)

    case effective_platform
    when 'bluesky'
      sync_bluesky(source)
    when 'twitter'
      sync_twitter(source)
    when 'facebook'
      sync_facebook(source)
    when 'instagram'
      sync_instagram(source)
    when 'threads'
      sync_threads(source)
    when 'youtube'
      sync_youtube(source)
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

  # Returns the canonical platform key for a source, resolving RSS suffixes.
  # Used both for routing in sync_source and for building the account_platforms map.
  def effective_platform_for(source)
    return source.platform unless source.platform == 'rss'

    id = source.id.to_s
    if id.end_with?('_facebook') || source.rss_source_type == 'facebook'
      'facebook'
    elsif id.end_with?('_instagram') || source.rss_source_type == 'instagram'
      'instagram'
    elsif id.end_with?('_threads') || source.rss_source_type == 'threads'
      'threads'
    else
      'rss'
    end
  end

  # Build a map of mastodon_account → [sorted platform keys] from ALL enabled sources.
  # Used to populate the spravuje: field with all platforms a bot aggregates from.
  def build_account_platforms
    platform_order = Syncers::BaseProfileSyncer::PLATFORM_LABELS.keys

    raw = @config_loader.load_all_sources
    raw.each do |raw_source|
      source = raw_source.is_a?(Hash) ? Config::SourceConfig.new(raw_source) : raw_source
      next unless source.respond_to?(:enabled?) && source.enabled?
      next if source.id.to_s.start_with?('!') || source.id.to_s.include?('example')

      account = source.mastodon_account
      next unless account

      platform = effective_platform_for(source)
      @account_platforms[account] ||= []
      @account_platforms[account] |= [platform]
    end

    # Sort platforms by canonical order (twitter, bluesky, facebook, instagram, youtube, rss)
    @account_platforms.transform_values! do |platforms|
      platforms.sort_by { |p| platform_order.index(p) || 999 }
    end
  end

  # Each sync_X method accepts optional handle: and sync_config: keyword args so it can be
  # called both for native sources (no args) and for RSS/delegated sources (explicit args).
  # This eliminates the former sync_X_for_rss duplicate methods.

  def sync_bluesky(source, handle: source.source_handle, sync_config: source.data.dig(:profile_sync) || {})
    global = @config_loader.load_global_config
    syncer = Syncers::BlueskyProfileSyncer.new(
      bluesky_handle:         handle,
      bluesky_api:            global.dig(:infrastructure, :bluesky_api),
      bluesky_profile_prefix: global.dig(:infrastructure, :bluesky_profile_prefix),
      mastodon_instance:      source.mastodon_instance,
      mastodon_token:         source.mastodon_token,
      language:               source.data.fetch(:language, 'cs'),
      retention_days:         sync_config.fetch(:retention_days, 90),
      mentions_config:        load_mentions_config('bluesky', { type: 'prefix', value: 'https://bsky.app/profile/' }),
      source_platforms:       @account_platforms[source.mastodon_account]
    )
    run_syncer(source, syncer, sync_config)
  end

  def sync_twitter(source, handle: source.source_handle, sync_config: source.data.dig(:profile_sync) || {})
    syncer = Syncers::TwitterProfileSyncer.new(
      twitter_handle:    handle,
      nitter_instance:   source.nitter_instance,
      mastodon_instance: source.mastodon_instance,
      mastodon_token:    source.mastodon_token,
      language:          source.data.fetch(:language, 'cs'),
      retention_days:    sync_config.fetch(:retention_days, 90),
      mentions_config:   load_mentions_config('twitter', { type: 'domain_suffix', value: 'twitter.com' }),
      source_platforms:  @account_platforms[source.mastodon_account]
    )
    run_syncer(source, syncer, sync_config)
  end

  def sync_facebook(source, handle: source.source_handle, sync_config: source.data.dig(:profile_sync) || {})
    platform_config   = @config_loader.load_platform_config('facebook')
    browserless_token = load_browserless_token(platform_config)
    facebook_cookies  = build_facebook_cookies(platform_config)
    raise 'Facebook cookies not configured' if facebook_cookies.empty?

    global = @config_loader.load_global_config
    syncer = Syncers::FacebookProfileSyncer.new(
      facebook_handle:   handle,
      browserless_token: browserless_token,
      browserless_api:   global.dig(:infrastructure, :browserless_api),
      facebook_cookies:  facebook_cookies,
      mastodon_instance: source.mastodon_instance,
      mastodon_token:    source.mastodon_token,
      language:          source.data.fetch(:language, 'cs'),
      retention_days:    sync_config.fetch(:retention_days, 90),
      mentions_config:   load_mentions_config('facebook', { type: 'domain_suffix', value: 'facebook.com' }),
      source_platforms:  @account_platforms[source.mastodon_account]
    )
    run_syncer(source, syncer, sync_config)
  end

  def sync_instagram(source, handle: nil, sync_config: source.data.dig(:profile_sync) || {})
    # Native Instagram sources have source.source_handle.
    # RSS+instagram sources (via RSS.app) pass handle: explicitly.
    # If neither is available, try social_profile from sync_config before skipping.
    instagram_handle = handle || source.source_handle
    unless instagram_handle
      social_profile = sync_config[:social_profile]
      if social_profile&.dig(:handle)
        instagram_handle = social_profile[:handle].to_s
      else
        Logging.warn("[#{source.id}] Instagram profile sync: no source.handle configured, skipping")
        @stats[:skipped] += 1
        return
      end
    end

    platform_config   = @config_loader.load_platform_config('instagram')
    browserless_token = load_browserless_token(platform_config)
    instagram_cookies = build_instagram_cookies(platform_config)
    raise 'Instagram cookies not configured' if instagram_cookies.empty?

    global = @config_loader.load_global_config
    syncer = Syncers::InstagramProfileSyncer.new(
      instagram_handle:  instagram_handle,
      browserless_token: browserless_token,
      browserless_api:   global.dig(:infrastructure, :browserless_api),
      instagram_cookies: instagram_cookies,
      mastodon_instance: source.mastodon_instance,
      mastodon_token:    source.mastodon_token,
      language:          source.data.fetch(:language, 'cs'),
      retention_days:    sync_config.fetch(:retention_days, 90),
      mentions_config:   load_mentions_config('instagram', { type: 'domain_suffix', value: 'instagram.com' }),
      source_platforms:  @account_platforms[source.mastodon_account]
    )
    run_syncer(source, syncer, sync_config)
  end

  def sync_threads(source, handle: nil, sync_config: source.data.dig(:profile_sync) || {})
    social_profile   = sync_config[:social_profile]
    threads_handle   = handle ||
                       social_profile&.dig(:handle)&.to_s ||
                       source.id.to_s.sub(/_threads$/, '')

    platform_config   = @config_loader.load_platform_config('threads')
    browserless_token = load_browserless_token(platform_config)

    global = @config_loader.load_global_config
    syncer = Syncers::ThreadsProfileSyncer.new(
      threads_handle:    threads_handle,
      browserless_token: browserless_token,
      browserless_api:   global.dig(:infrastructure, :browserless_api),
      mastodon_instance: source.mastodon_instance,
      mastodon_token:    source.mastodon_token,
      language:          source.data.fetch(:language, 'cs'),
      retention_days:    sync_config.fetch(:retention_days, 90),
      mentions_config:   load_mentions_config('threads', { type: 'domain_suffix', value: 'threads.net' }),
      source_platforms:  @account_platforms[source.mastodon_account]
    )
    run_syncer(source, syncer, sync_config)
  end

  def sync_youtube(source, handle: nil, sync_config: source.data.dig(:profile_sync) || {})
    youtube_handle = handle || source.source_handle

    # Profile sync is opt-in for YouTube. If no handle, try social_profile delegation.
    unless youtube_handle
      social_profile = sync_config[:social_profile]
      if social_profile&.dig(:platform) && social_profile.dig(:handle)
        platform = social_profile[:platform].to_s
        h        = social_profile[:handle].to_s
        case platform
        when 'facebook'  then return sync_facebook(source,  handle: h, sync_config: sync_config)
        when 'twitter'   then return sync_twitter(source,   handle: h, sync_config: sync_config)
        when 'bluesky'   then return sync_bluesky(source,   handle: h, sync_config: sync_config)
        when 'instagram' then return sync_instagram(source, handle: h, sync_config: sync_config)
        when 'threads'   then return sync_threads(source,   handle: h, sync_config: sync_config)
        end
      end
      @stats[:skipped] += 1
      return
    end

    platform_config   = @config_loader.load_platform_config('youtube')
    browserless_token = load_browserless_token(platform_config)

    global = @config_loader.load_global_config
    syncer = Syncers::YoutubeProfileSyncer.new(
      youtube_handle:    youtube_handle,
      browserless_token: browserless_token,
      browserless_api:   global.dig(:infrastructure, :browserless_api),
      mastodon_instance: source.mastodon_instance,
      mastodon_token:    source.mastodon_token,
      language:          source.data.fetch(:language, 'cs'),
      retention_days:    sync_config.fetch(:retention_days, 180),
      mentions_config:   load_mentions_config('youtube', { type: 'none', value: '' }),
      source_platforms:  @account_platforms[source.mastodon_account]
    )
    run_syncer(source, syncer, sync_config)
  end

  def sync_rss(source)
    sync_config    = source.data.dig(:profile_sync) || {}
    social_profile = sync_config[:social_profile]

    unless social_profile&.dig(:platform) && social_profile.dig(:handle)
      Logging.warn("[#{source.id}] RSS profile sync: no social_profile configured, skipping")
      @stats[:skipped] += 1
      return
    end

    platform = social_profile[:platform].to_s
    h        = social_profile[:handle].to_s

    case platform
    when 'twitter'   then sync_twitter(source,   handle: h, sync_config: sync_config)
    when 'bluesky'   then sync_bluesky(source,   handle: h, sync_config: sync_config)
    when 'facebook'  then sync_facebook(source,  handle: h, sync_config: sync_config)
    when 'instagram' then sync_instagram(source, handle: h, sync_config: sync_config)
    when 'threads'   then sync_threads(source,   handle: h, sync_config: sync_config)
    when 'youtube'   then sync_youtube(source,   handle: h, sync_config: sync_config)
    else
      Logging.warn("[#{source.id}] RSS profile sync: unsupported platform '#{platform}', skipping")
      @stats[:skipped] += 1
    end
  end

  # Load + enrich mentions config for a platform. Enrichment doplní `local_handles`
  # / `local_instance` pro Twitter (zpravobot.news local mention transformace).
  def load_mentions_config(platform, default)
    raw = @config_loader.load_platform_config(platform)[:mentions] || default
    @config_loader.enrich_mentions_config(raw, platform: platform)
  end

  # Load Browserless.io token from platform config or BROWSERLESS_TOKEN env var.
  def load_browserless_token(platform_config)
    raw   = platform_config.dig(:source, :browserless_token)
    token = resolve_env_value(raw) || ENV['BROWSERLESS_TOKEN']
    raise 'BROWSERLESS_TOKEN not configured' if token.nil? || token.empty?

    token
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

  def build_instagram_cookies(platform_config)
    cookies_config = platform_config.dig(:source, :instagram_cookies) || []

    cookies_config.map do |cookie|
      {
        name: cookie[:name],
        value: resolve_env_value(cookie[:value]),
        domain: cookie[:domain] || '.instagram.com'
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
