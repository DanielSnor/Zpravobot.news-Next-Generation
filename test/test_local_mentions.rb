#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for TASK-7: local mention transformation (domain_suffix_with_local)
# Covers:
#   1. UniversalFormatter#format_single_mention — domain_suffix_with_local branch
#   2. UniversalFormatter#format_mentions — integration
#   3. ConfigLoader#twitter_handle_to_mastodon_map — build + cache
# Tests are OFFLINE — no HTTP, no Mastodon API calls.
# Run: ruby test/test_local_mentions.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/formatters/universal_formatter'
require_relative '../lib/config/config_loader'

puts '=' * 60
puts 'Local Mentions Tests (offline)'
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

# ============================================================
# Helper: access private method on formatter
# ============================================================

def fmt
  Formatters::UniversalFormatter.new(platform: :twitter)
end

def single_mention(username, config_hash)
  fmt.send(:format_single_mention, username, config_hash)
end

def format_mentions_text(text, mentions_hash, skip: nil)
  config = { mentions: mentions_hash }
  fmt.send(:format_mentions, text, config, skip: skip)
end

LOCAL_MAP = { 'ct24zive' => 'ct24', 'aktualnecz' => 'aktualnecz', 'seznamzpravy' => 'seznam' }.freeze

LOCAL_MENTIONS_CONFIG = {
  type: 'domain_suffix_with_local',
  value: 'twitter.com',
  local_instance: 'zpravobot.news',
  local_handles: LOCAL_MAP
}.freeze

# ============================================================
# Section 1: format_single_mention — domain_suffix_with_local
# ============================================================

puts '--- Section 1: format_single_mention (domain_suffix_with_local) ---'

test(
  'known handle → local mention',
  '@ct24@zpravobot.news',
  single_mention('ct24zive', LOCAL_MENTIONS_CONFIG)
)

test(
  'unknown handle → domain_suffix fallback',
  '@nokiaofficial@twitter.com',
  single_mention('nokiaofficial', LOCAL_MENTIONS_CONFIG)
)

test(
  'case-insensitive: @CT24zive → local mention',
  '@ct24@zpravobot.news',
  single_mention('CT24zive', LOCAL_MENTIONS_CONFIG)
)

test(
  'empty local_handles → domain_suffix fallback',
  '@ct24zive@twitter.com',
  single_mention('ct24zive', { type: 'domain_suffix_with_local', value: 'twitter.com', local_instance: 'zpravobot.news', local_handles: {} })
)

test(
  'nil local_handles → domain_suffix fallback',
  '@ct24zive@twitter.com',
  single_mention('ct24zive', { type: 'domain_suffix_with_local', value: 'twitter.com', local_instance: 'zpravobot.news', local_handles: nil })
)

test(
  'custom local_instance is used from config',
  '@ct24@myinstance.social',
  single_mention('ct24zive', {
    type: 'domain_suffix_with_local',
    value: 'twitter.com',
    local_instance: 'myinstance.social',
    local_handles: { 'ct24zive' => 'ct24' }
  })
)

puts

# ============================================================
# Section 2: format_mentions — integration
# ============================================================

puts '--- Section 2: format_mentions integration ---'

test(
  'known handle in text → transformed to local',
  'zprávy od @ct24@zpravobot.news dnes',
  format_mentions_text('zprávy od @ct24zive dnes', LOCAL_MENTIONS_CONFIG)
)

test(
  'unknown handle in text → domain_suffix fallback',
  'viz @nokiaofficial@twitter.com pro info',
  format_mentions_text('viz @nokiaofficial pro info', LOCAL_MENTIONS_CONFIG)
)

test(
  'mixed: known + unknown each handled correctly',
  '@ct24@zpravobot.news a @nokiaofficial@twitter.com',
  format_mentions_text('@ct24zive a @nokiaofficial', LOCAL_MENTIONS_CONFIG)
)

test(
  'skip known author handle — stays as @handle',
  '@ct24zive napsal: text',
  format_mentions_text('@ct24zive napsal: text', LOCAL_MENTIONS_CONFIG, skip: 'ct24zive')
)

test(
  'skip unknown author handle — stays as @handle',
  '@nokiaofficial napsal: text',
  format_mentions_text('@nokiaofficial napsal: text', LOCAL_MENTIONS_CONFIG, skip: 'nokiaofficial')
)

puts

# ============================================================
# Section 3: ConfigLoader#twitter_handle_to_mastodon_map
# ============================================================

puts '--- Section 3: ConfigLoader#twitter_handle_to_mastodon_map ---'

# Build a minimal in-memory config loader using a temp dir with fake sources
require 'tmpdir'
require 'yaml'
require 'fileutils'

config_dir = Dir.mktmpdir('test_local_mentions_')

begin
  # global.yml
  File.write(File.join(config_dir, 'global.yml'), "---\nenabled: true\n")

  # mastodon_accounts.yml — required for credentials resolution
  File.write(File.join(config_dir, 'mastodon_accounts.yml'), <<~YAML)
    ---
    ct24:
      token: fake_token_ct24
      instance: https://zpravobot.news
    seznam:
      token: fake_token_seznam
      instance: https://zpravobot.news
    external_account:
      token: fake_token_ext
      instance: https://mastodon.social
  YAML

  # platforms/twitter.yml
  FileUtils.mkdir_p(File.join(config_dir, 'platforms'))
  File.write(File.join(config_dir, 'platforms', 'twitter.yml'), <<~YAML)
    ---
    platform: twitter
    enabled: true
    mentions:
      type: domain_suffix
      value: twitter.com
  YAML

  # sources/
  FileUtils.mkdir_p(File.join(config_dir, 'sources'))

  # zpravobot.news source
  File.write(File.join(config_dir, 'sources', 'ct24_twitter.yml'), <<~YAML)
    ---
    id: ct24_twitter
    platform: twitter
    enabled: true
    source:
      handle: CT24zive
    target:
      mastodon_account: ct24
      mastodon_instance: https://zpravobot.news
      mastodon_token: fake_token
  YAML

  # Another zpravobot.news source
  File.write(File.join(config_dir, 'sources', 'seznam_twitter.yml'), <<~YAML)
    ---
    id: seznam_twitter
    platform: twitter
    enabled: true
    source:
      handle: SeznamZpravy
    target:
      mastodon_account: seznam
      mastodon_instance: https://zpravobot.news
      mastodon_token: fake_token
  YAML

  # Non-zpravobot instance — should be excluded
  File.write(File.join(config_dir, 'sources', 'external_twitter.yml'), <<~YAML)
    ---
    id: external_twitter
    platform: twitter
    enabled: true
    source:
      handle: SomeExternalHandle
    target:
      mastodon_account: external_account
      mastodon_instance: https://mastodon.social
      mastodon_token: fake_token
  YAML

  loader = Config::ConfigLoader.new(config_dir)
  map = loader.twitter_handle_to_mastodon_map

  test(
    'map returns hash with lowercase keys',
    true,
    map.keys.all? { |k| k == k.downcase }
  )

  test(
    'includes zpravobot.news sources',
    true,
    map.key?('ct24zive') && map.key?('seznamzpravy')
  )

  test(
    'excludes non-zpravobot instances',
    false,
    map.key?('someexternalhandle')
  )

  test(
    'caches result — same object on second call',
    true,
    loader.twitter_handle_to_mastodon_map.equal?(map)
  )

  # Empty loader
  empty_dir = Dir.mktmpdir('test_local_mentions_empty_')
  begin
    File.write(File.join(empty_dir, 'global.yml'), "---\nenabled: true\n")
    FileUtils.mkdir_p(File.join(empty_dir, 'platforms'))
    File.write(File.join(empty_dir, 'platforms', 'twitter.yml'), "---\nplatform: twitter\nenabled: true\n")
    FileUtils.mkdir_p(File.join(empty_dir, 'sources'))
    empty_loader = Config::ConfigLoader.new(empty_dir)
    test(
      'empty hash when no Twitter sources',
      {},
      empty_loader.twitter_handle_to_mastodon_map
    )
  ensure
    FileUtils.rm_rf(empty_dir)
  end

ensure
  FileUtils.rm_rf(config_dir)
end

puts
puts '=' * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts '=' * 60

exit($failed > 0 ? 1 : 0)
