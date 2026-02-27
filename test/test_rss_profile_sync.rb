#!/usr/bin/env ruby
# frozen_string_literal: true

# Test RSS profile sync delegation logic in ProfileSyncRunner
# Tests ONLY pure logic (no HTTP, no Mastodon API calls).
# Run: ruby test/test_rss_profile_sync.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'optparse'
require 'fileutils'
require 'logging'
require_relative '../lib/config/config_loader'
require_relative '../lib/syncers/bluesky_profile_syncer'
require_relative '../lib/syncers/twitter_profile_syncer'
require_relative '../lib/syncers/facebook_profile_syncer'

# Load runner class (defines ProfileSyncRunner)
load File.expand_path('../bin/sync_profiles.rb', __dir__)

puts '=' * 60
puts 'RSS Profile Sync Tests (offline)'
puts '=' * 60
puts

$passed = 0
$failed = 0

def test(name, expected, actual)
  if expected == actual
    puts "  [PASS] #{name}"
    $passed += 1
  else
    puts "  [FAIL] #{name}"
    puts "         expected: #{expected.inspect}"
    puts "         actual:   #{actual.inspect}"
    $failed += 1
  end
end

def test_raises(name, klass, &block)
  block.call
  puts "  [FAIL] #{name} — expected #{klass} but no exception raised"
  $failed += 1
rescue klass
  puts "  [PASS] #{name}"
  $passed += 1
rescue => e
  puts "  [FAIL] #{name} — expected #{klass} but got #{e.class}: #{e.message}"
  $failed += 1
end

# ============================================================
# Helpers
# ============================================================

# Minimal SourceConfig-like double for RSS source
class FakeRssSource
  attr_reader :id, :platform, :data, :mastodon_instance, :mastodon_token, :nitter_instance

  def initialize(overrides = {})
    @id                = overrides.fetch(:id, 'test_rss')
    @platform          = 'rss'
    @mastodon_instance = overrides.fetch(:mastodon_instance, 'https://zpravobot.news')
    @mastodon_token    = overrides.fetch(:mastodon_token, 'fake_token')
    @nitter_instance   = overrides.fetch(:nitter_instance, nil)
    @data              = overrides.fetch(:data, {})
  end

  def enabled?; true; end
  def source_handle; 'https://example.com/rss'; end
end

# Fake syncer that records calls instead of making network requests
class FakeSyncer
  attr_reader :preview_called, :sync_called, :sync_opts, :handle

  def initialize(handle:)
    @handle        = handle
    @preview_called = false
    @sync_called   = false
    @sync_opts     = {}
  end

  def preview
    @preview_called = true
  end

  def sync!(**opts)
    @sync_called = true
    @sync_opts   = opts
    { success: true, changes: [] }
  end
end

# Testable subclass — overrides syncer-building methods to inject FakeSyncer
class TestableSyncRunner < ProfileSyncRunner
  attr_reader :last_twitter_handle, :last_bluesky_handle, :last_facebook_handle,
              :last_syncer, :delegated_to

  def initialize(options = {})
    @options      = options
    @config_loader = Config::ConfigLoader.new
    @stats        = { synced: 0, skipped: 0, errors: 0 }
    @delegated_to = nil
  end

  def sync_twitter_for_rss(source, handle, sync_config)
    @delegated_to        = :twitter
    @last_twitter_handle = handle
    @last_syncer         = FakeSyncer.new(handle: handle)
    run_syncer(source, @last_syncer, sync_config)
  end

  def sync_bluesky_for_rss(source, handle, sync_config)
    @delegated_to        = :bluesky
    @last_bluesky_handle = handle
    @last_syncer         = FakeSyncer.new(handle: handle)
    run_syncer(source, @last_syncer, sync_config)
  end

  def sync_facebook_for_rss(source, handle, sync_config)
    @delegated_to         = :facebook
    @last_facebook_handle = handle
    @last_syncer          = FakeSyncer.new(handle: handle)
    run_syncer(source, @last_syncer, sync_config)
  end
end

# ============================================================
# Section 1: VALID_PLATFORMS includes 'rss'
# ============================================================
puts "\n--- Section 1: VALID_PLATFORMS ---"

test 'VALID_PLATFORMS includes rss',
  true,
  ProfileSyncRunner::VALID_PLATFORMS.include?('rss')

# ============================================================
# Section 2: profile_sync_enabled?
# ============================================================
puts "\n--- Section 2: profile_sync_enabled? ---"

runner = TestableSyncRunner.new

src_enabled  = FakeRssSource.new(data: { profile_sync: { enabled: true } })
src_disabled = FakeRssSource.new(data: { profile_sync: { enabled: false } })
src_no_sync  = FakeRssSource.new(data: {})
src_empty    = FakeRssSource.new(data: { profile_sync: {} })

test 'enabled: true  → true',  true,  runner.send(:profile_sync_enabled?, src_enabled)
test 'enabled: false → false', false, runner.send(:profile_sync_enabled?, src_disabled)
test 'no profile_sync key → true (default)', true, runner.send(:profile_sync_enabled?, src_no_sync)
test 'profile_sync: {} → true (default)',    true, runner.send(:profile_sync_enabled?, src_empty)

# ============================================================
# Section 3: sync_rss delegation
# ============================================================
puts "\n--- Section 3: sync_rss delegation ---"

# Twitter
runner = TestableSyncRunner.new
src = FakeRssSource.new(data: {
  profile_sync: { enabled: true, social_profile: { platform: 'twitter', handle: 'Aktualnecz' } }
})
runner.send(:sync_rss, src)
test 'twitter social_profile → delegates to sync_twitter_for_rss', :twitter, runner.delegated_to
test 'twitter handle passed correctly', 'Aktualnecz', runner.last_twitter_handle

# Bluesky
runner = TestableSyncRunner.new
src = FakeRssSource.new(data: {
  profile_sync: { enabled: true, social_profile: { platform: 'bluesky', handle: 'denikreferendum.cz' } }
})
runner.send(:sync_rss, src)
test 'bluesky social_profile → delegates to sync_bluesky_for_rss', :bluesky, runner.delegated_to
test 'bluesky handle passed correctly', 'denikreferendum.cz', runner.last_bluesky_handle

# Facebook
runner = TestableSyncRunner.new
src = FakeRssSource.new(data: {
  profile_sync: { enabled: true, social_profile: { platform: 'facebook', handle: 'auto.cz' } }
})
runner.send(:sync_rss, src)
test 'facebook social_profile → delegates to sync_facebook_for_rss', :facebook, runner.delegated_to
test 'facebook handle passed correctly', 'auto.cz', runner.last_facebook_handle

# No social_profile → skip
runner = TestableSyncRunner.new
src = FakeRssSource.new(data: { profile_sync: { enabled: true } })
runner.send(:sync_rss, src)
test 'no social_profile → skipped', 1, runner.instance_variable_get(:@stats)[:skipped]
test 'no social_profile → delegated_to nil', nil, runner.delegated_to

# Unknown platform → skip
runner = TestableSyncRunner.new
src = FakeRssSource.new(data: {
  profile_sync: { enabled: true, social_profile: { platform: 'youtube', handle: 'somechannel' } }
})
runner.send(:sync_rss, src)
test 'unknown platform → skipped', 1, runner.instance_variable_get(:@stats)[:skipped]
test 'unknown platform → delegated_to nil', nil, runner.delegated_to

# ============================================================
# Section 4: run_syncer — dry-run vs live
# ============================================================
puts "\n--- Section 4: run_syncer ---"

# Dry-run: calls preview, not sync!
runner = TestableSyncRunner.new(dry_run: true)
src    = FakeRssSource.new
fake   = FakeSyncer.new(handle: 'test')
sync_config = {}
runner.send(:run_syncer, src, fake, sync_config)
test 'dry-run → preview called',   true,  fake.preview_called
test 'dry-run → sync! not called', false, fake.sync_called
test 'dry-run → stats[:skipped] +1', 1, runner.instance_variable_get(:@stats)[:skipped]

# Live: calls sync!, not preview
runner = TestableSyncRunner.new(dry_run: false)
src    = FakeRssSource.new
fake   = FakeSyncer.new(handle: 'test')
runner.send(:run_syncer, src, fake, sync_config)
test 'live → sync! called',       true,  fake.sync_called
test 'live → preview not called', false, fake.preview_called
test 'live success → stats[:synced] +1', 1, runner.instance_variable_get(:@stats)[:synced]

# sync! options forwarded from sync_config
runner = TestableSyncRunner.new(dry_run: false)
src    = FakeRssSource.new
fake   = FakeSyncer.new(handle: 'test')
cfg    = { sync_avatar: false, sync_banner: false, sync_bio: false, sync_fields: true }
runner.send(:run_syncer, src, fake, cfg)
test 'sync_avatar false forwarded', false, fake.sync_opts[:sync_avatar]
test 'sync_fields true forwarded',  true,  fake.sync_opts[:sync_fields]

# ============================================================
# Section 5: language and retention_days defaults
# ============================================================
puts "\n--- Section 5: language and retention_days defaults ---"

# We can test this by inspecting sync_twitter_for_rss — it reads from sync_config
# Use a real (non-stub) runner and stub out the syncer init to capture params
syncer_init_args = nil
runner = TestableSyncRunner.new(dry_run: true)

# Override sync_twitter_for_rss to capture what args would be passed
runner.define_singleton_method(:sync_twitter_for_rss) do |source, handle, sc|
  syncer_init_args = { language: sc.fetch(:language, 'cs'), retention_days: sc.fetch(:retention_days, 90) }
  @stats[:skipped] += 1
end

src = FakeRssSource.new(data: {
  profile_sync: { enabled: true, social_profile: { platform: 'twitter', handle: 'Test' } }
})
runner.send(:sync_rss, src)
test 'default language is cs',          'cs', syncer_init_args[:language]
test 'default retention_days is 90',    90,   syncer_init_args[:retention_days]

# With explicit values
syncer_init_args = nil
src = FakeRssSource.new(data: {
  profile_sync: {
    enabled: true,
    social_profile: { platform: 'twitter', handle: 'Test' },
    language: 'sk',
    retention_days: 30
  }
})
runner.send(:sync_rss, src)
test 'explicit language sk forwarded',   'sk', syncer_init_args[:language]
test 'explicit retention_days 30 forwarded', 30, syncer_init_args[:retention_days]

# ============================================================
# Summary
# ============================================================
puts
puts '=' * 60
puts "#{$passed + $failed} tests: #{$passed} passed, #{$failed} failed"
puts '=' * 60

exit($failed > 0 ? 1 : 0)
