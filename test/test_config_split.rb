#!/usr/bin/env ruby
# frozen_string_literal: true

# Test ConfigMerger, CredentialsResolver, SourceFinder (Phase 14.1)
# Run: ruby test/test_config_split.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/config/config_merger'
require_relative '../lib/config/credentials_resolver'
require_relative '../lib/config/source_finder'
require_relative '../lib/utils/hash_helpers'

puts "=" * 60
puts "Config Split Tests (Phase 14.1)"
puts "=" * 60
puts

$passed = 0
$failed = 0

def test(name, expected, actual)
  if expected == actual
    puts "  \e[32m\u2713\e[0m #{name}"
    $passed += 1
  else
    puts "  \e[31m\u2717\e[0m #{name}"
    puts "    Expected: #{expected.inspect}"
    puts "    Actual:   #{actual.inspect}"
    $failed += 1
  end
end

def test_raises(name, exception_class)
  begin
    yield
    puts "  \e[31m\u2717\e[0m #{name}"
    puts "    Expected: #{exception_class} to be raised"
    puts "    Actual:   No exception raised"
    $failed += 1
  rescue exception_class
    puts "  \e[32m\u2713\e[0m #{name}"
    $passed += 1
  rescue => e
    puts "  \e[31m\u2717\e[0m #{name}"
    puts "    Expected: #{exception_class}"
    puts "    Actual:   #{e.class}: #{e.message}"
    $failed += 1
  end
end

def section(title)
  puts
  puts "--- #{title} ---"
end

# ===========================================
# ConfigMerger Tests
# ===========================================

section "ConfigMerger"

merger = Config::ConfigMerger.new

# Basic merging
global = { mastodon: { instance: 'https://example.com' }, filtering: { skip_replies: true } }
platform = { platform: 'twitter', filtering: { skip_retweets: false } }
source = { id: 'ct24', source: { handle: 'ct24' } }

merged = merger.merge(global, platform, source)

test "merge: includes global keys", 'https://example.com', merged.dig(:mastodon, :instance)
test "merge: includes platform keys", 'twitter', merged[:platform]
test "merge: includes source keys", 'ct24', merged[:id]
test "merge: source handle preserved", 'ct24', merged.dig(:source, :handle)

# Deep merge override
test "merge: platform overrides global (deep)", false, merged.dig(:filtering, :skip_retweets)
test "merge: global preserved when not overridden", true, merged.dig(:filtering, :skip_replies)

# Source overrides platform
source_with_override = { id: 'ct24', platform: 'twitter', filtering: { skip_replies: false } }
merged2 = merger.merge(global, platform, source_with_override)
test "merge: source overrides global (deep)", false, merged2.dig(:filtering, :skip_replies)

# Empty hashes
merged3 = merger.merge({}, {}, { id: 'test' })
test "merge: works with empty global/platform", 'test', merged3[:id]

merged4 = merger.merge({ a: 1 }, {}, {})
test "merge: works with empty platform/source", 1, merged4[:a]

# Nested deep merge
global_nested = { target: { visibility: 'public', mastodon_account: 'bot1' } }
source_nested = { target: { visibility: 'unlisted' } }
merged5 = merger.merge(global_nested, {}, source_nested)
test "merge: nested override preserves siblings", 'bot1', merged5.dig(:target, :mastodon_account)
test "merge: nested override replaces value", 'unlisted', merged5.dig(:target, :visibility)

# ===========================================
# CredentialsResolver Tests
# ===========================================

section "CredentialsResolver"

resolver = Config::CredentialsResolver.new

# No mastodon_account → no change
config_no_target = { id: 'test', source: { handle: 'foo' } }
result = resolver.resolve(config_no_target.dup, ->(_) { raise "should not be called" }, {})
test "resolve: no target → unchanged", nil, result.dig(:target, :mastodon_token)

# With mastodon_account → resolves credentials
config_with_target = {
  id: 'test',
  target: { mastodon_account: 'bot1' }
}
creds = { token: 'secret_token', instance: 'https://mastodon.social' }
credentials_loader = ->(account_id) { creds }
global = { mastodon: { instance: 'https://fallback.example.com' } }

result2 = resolver.resolve(config_with_target.dup, credentials_loader, global)
test "resolve: injects token from credentials", 'secret_token', result2.dig(:target, :mastodon_token)
test "resolve: injects instance from credentials", 'https://mastodon.social', result2.dig(:target, :mastodon_instance)

# Instance fallback to global
creds_no_instance = { token: 'token123' }
config3 = { id: 'test', target: { mastodon_account: 'bot2' } }
result3 = resolver.resolve(config3.dup, ->(_) { creds_no_instance }, global)
test "resolve: fallback to global instance", 'https://fallback.example.com', result3.dig(:target, :mastodon_instance)
test "resolve: token from credentials (no instance)", 'token123', result3.dig(:target, :mastodon_token)

# ENV override for token
original_env = ENV['ZBNW_MASTODON_TOKEN_TESTBOT']
begin
  ENV['ZBNW_MASTODON_TOKEN_TESTBOT'] = 'env_override_token'
  config4 = { id: 'test', target: { mastodon_account: 'testbot' } }
  result4 = resolver.resolve(config4.dup, ->(_) { { token: 'yaml_token' } }, {})
  test "resolve: ENV token overrides YAML token", 'env_override_token', result4.dig(:target, :mastodon_token)
ensure
  if original_env
    ENV['ZBNW_MASTODON_TOKEN_TESTBOT'] = original_env
  else
    ENV.delete('ZBNW_MASTODON_TOKEN_TESTBOT')
  end
end

# Empty ENV token does not override
original_env2 = ENV['ZBNW_MASTODON_TOKEN_EMPTYBOT']
begin
  ENV['ZBNW_MASTODON_TOKEN_EMPTYBOT'] = ''
  config5 = { id: 'test', target: { mastodon_account: 'emptybot' } }
  result5 = resolver.resolve(config5.dup, ->(_) { { token: 'yaml_token' } }, {})
  test "resolve: empty ENV token → uses YAML token", 'yaml_token', result5.dig(:target, :mastodon_token)
ensure
  if original_env2
    ENV['ZBNW_MASTODON_TOKEN_EMPTYBOT'] = original_env2
  else
    ENV.delete('ZBNW_MASTODON_TOKEN_EMPTYBOT')
  end
end

# Custom token_env name
original_env3 = ENV['MY_CUSTOM_TOKEN']
begin
  ENV['MY_CUSTOM_TOKEN'] = 'custom_env_token'
  config6 = { id: 'test', target: { mastodon_account: 'bot3' } }
  result6 = resolver.resolve(config6.dup, ->(_) { { token: 'yaml', token_env: 'MY_CUSTOM_TOKEN' } }, {})
  test "resolve: custom token_env name", 'custom_env_token', result6.dig(:target, :mastodon_token)
ensure
  if original_env3
    ENV['MY_CUSTOM_TOKEN'] = original_env3
  else
    ENV.delete('MY_CUSTOM_TOKEN')
  end
end

# Returns the mutated hash
config7 = { id: 'test', target: { mastodon_account: 'bot4' } }
result7 = resolver.resolve(config7, ->(_) { { token: 't' } }, {})
test "resolve: returns the same hash object", true, config7.equal?(result7)

# ===========================================
# SourceFinder Tests
# ===========================================

section "SourceFinder"

finder = Config::SourceFinder.new

sources = [
  { id: 'ct24_twitter', platform: 'twitter', source: { handle: 'CT24zive' }, target: { mastodon_account: 'ct24' } },
  { id: 'novinky_twitter', platform: 'twitter', source: { handle: 'noaborovska' }, target: { mastodon_account: 'betabot' } },
  { id: 'denik_rss', platform: 'rss', source: { feed_url: 'https://denik.cz/rss' }, target: { mastodon_account: 'betabot' } },
  { id: 'bsky_test', platform: 'bluesky', source: { handle: 'test.bsky.social' }, target: { mastodon_account: 'ct24' } }
]

# by_platform
twitter_sources = finder.by_platform(sources, 'twitter')
test "by_platform: finds twitter sources", 2, twitter_sources.count
test "by_platform: correct IDs", %w[ct24_twitter novinky_twitter], twitter_sources.map { |s| s[:id] }

rss_sources = finder.by_platform(sources, 'rss')
test "by_platform: finds rss sources", 1, rss_sources.count

youtube_sources = finder.by_platform(sources, 'youtube')
test "by_platform: empty for missing platform", 0, youtube_sources.count

# by_mastodon_account
ct24_sources = finder.by_mastodon_account(sources, 'ct24')
test "by_mastodon_account: finds ct24 sources", 2, ct24_sources.count
test "by_mastodon_account: correct IDs", %w[ct24_twitter bsky_test], ct24_sources.map { |s| s[:id] }

betabot_sources = finder.by_mastodon_account(sources, 'betabot')
test "by_mastodon_account: finds betabot sources", 2, betabot_sources.count

nonexistent = finder.by_mastodon_account(sources, 'nonexistent')
test "by_mastodon_account: empty for missing account", 0, nonexistent.count

# by_handle
found = finder.by_handle(sources, 'twitter', 'CT24zive')
test "by_handle: finds exact match", 'ct24_twitter', found[:id]

found_case = finder.by_handle(sources, 'twitter', 'ct24zive')
test "by_handle: case-insensitive", 'ct24_twitter', found_case[:id]

found_upper = finder.by_handle(sources, 'twitter', 'CT24ZIVE')
test "by_handle: all caps", 'ct24_twitter', found_upper[:id]

not_found = finder.by_handle(sources, 'twitter', 'nonexistent')
test "by_handle: nil for missing handle", nil, not_found

wrong_platform = finder.by_handle(sources, 'rss', 'CT24zive')
test "by_handle: nil for wrong platform", nil, wrong_platform

empty = finder.by_handle([], 'twitter', 'anything')
test "by_handle: nil for empty sources", nil, empty

bsky_found = finder.by_handle(sources, 'bluesky', 'test.bsky.social')
test "by_handle: finds bluesky handle", 'bsky_test', bsky_found[:id]

# ===========================================
# Summary
# ===========================================

puts
puts "=" * 60
if $failed == 0
  puts "\e[32m\u2705 All #{$passed} tests passed!\e[0m"
else
  puts "\e[31m\u274c #{$failed} failed, #{$passed} passed\e[0m"
end
puts "=" * 60

exit($failed > 0 ? 1 : 0)
