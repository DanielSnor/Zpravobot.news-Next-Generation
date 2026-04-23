#!/usr/bin/env ruby
# frozen_string_literal: true

# Test Config::SourceConfig#to_processor_hash (REFACTOR-2 varianta B)
# Verifies that all YAML fields propagate correctly to the processor hash,
# so adding a new field requires only one change in to_processor_hash.
# Run: ruby test/test_source_config_to_processor_hash.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/config/config_loader'

puts '=' * 60
puts 'SourceConfig#to_processor_hash Tests'
puts '=' * 60
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

def section(title)
  puts
  puts "--- #{title} ---"
end

# Minimal source config data covering all fields mapped in to_processor_hash
FULL_DATA = {
  id: 'test_source',
  platform: 'twitter',
  enabled: true,
  source: { handle: 'testhandle', nitter_instance: 'nitter.example.com' },
  formatting: { header: true, footer: false, source_name: 'Test Source' },
  filtering: { skip_replies: true, banned_phrases: ['spam'] },
  processing: {
    trim_strategy: 'smart',
    smart_tolerance_percent: 15,
    url_domain_fixes: [{ from: 'x.com', to: 'twitter.com' }],
    content_replacements: [{ pattern: 'foo', replacement: 'bar' }],
    video_dedup_hours: 72
  },
  target: {
    mastodon_account: 'testbot',
    mastodon_instance: 'zpravobot.news',
    mastodon_token: 'secret_token',
    visibility: 'public'
  },
  content: { combine_title_and_content: true },
  thread_handling: { mode: 'context', show_indicator: true },
  nitter_processing: { enabled: true },
  url: { shorten: false },
  rss_source_type: 'rss',
  mentions: { type: 'local_or_domain_suffix' }
}.freeze

# =============================================================================
# Top-level keys presence
# =============================================================================
section('Top-level keys')

sc = Config::SourceConfig.new(FULL_DATA)
h = sc.to_processor_hash

EXPECTED_KEYS = %i[
  id platform source formatting filtering processing
  target content thread_handling nitter_processing
  url rss_source_type mentions _mastodon_token
].freeze

EXPECTED_KEYS.each do |key|
  test("key :#{key} present", true, h.key?(key))
end

# =============================================================================
# Identity fields
# =============================================================================
section('Identity')

test('id propagates', 'test_source', h[:id])
test('platform propagates', 'twitter', h[:platform])

# =============================================================================
# Source sub-hash
# =============================================================================
section('Source sub-hash')

test('source.handle', 'testhandle', h[:source][:handle])
test('source.nitter_instance', 'nitter.example.com', h[:source][:nitter_instance])

# =============================================================================
# Formatting (merged with source_name + max_length)
# =============================================================================
section('Formatting')

test('formatting.header preserved', true, h[:formatting][:header])
test('formatting.source_name merged in', 'Test Source', h[:formatting][:source_name])
test('formatting.max_length present', true, h[:formatting].key?(:max_length))

# =============================================================================
# Filtering
# =============================================================================
section('Filtering')

test('filtering.skip_replies', true, h[:filtering][:skip_replies])
test('filtering.banned_phrases', ['spam'], h[:filtering][:banned_phrases])

# =============================================================================
# Processing (merged fields)
# =============================================================================
section('Processing')

test('processing.trim_strategy', 'smart', h[:processing][:trim_strategy])
test('processing.smart_tolerance_percent from data', 15, h[:processing][:smart_tolerance_percent])
test('processing.url_domain_fixes', [{ from: 'x.com', to: 'twitter.com' }], h[:processing][:url_domain_fixes])
test('processing.content_replacements', [{ pattern: 'foo', replacement: 'bar' }], h[:processing][:content_replacements])
test('processing.video_dedup_hours preserved', 72, h[:processing][:video_dedup_hours])

# smart_tolerance_percent default when absent
sc_no_tolerance = Config::SourceConfig.new({ id: 'x', platform: 'rss', processing: {} })
test('processing.smart_tolerance_percent default=12', 12, sc_no_tolerance.to_processor_hash[:processing][:smart_tolerance_percent])

# =============================================================================
# Target sub-hash
# =============================================================================
section('Target')

test('target.mastodon_account', 'testbot', h[:target][:mastodon_account])
test('target.mastodon_instance', 'zpravobot.news', h[:target][:mastodon_instance])
test('target.visibility', 'public', h[:target][:visibility])

# =============================================================================
# Misc fields
# =============================================================================
section('Misc fields')

test('content propagates', { combine_title_and_content: true }, h[:content])
test('thread_handling propagates', { mode: 'context', show_indicator: true }, h[:thread_handling])
test('nitter_processing propagates', { enabled: true }, h[:nitter_processing])
test('url propagates', { shorten: false }, h[:url])
test('rss_source_type propagates', 'rss', h[:rss_source_type])
test('_mastodon_token propagates', 'secret_token', h[:_mastodon_token])

# =============================================================================
# Mentions injection
# =============================================================================
section('Mentions injection')

# Without injection — falls back to source mentions
test('mentions: source default when no injection', { type: 'local_or_domain_suffix' }, h[:mentions])

# With injection — caller-provided wins
injected = { type: 'domain_suffix_with_local', local_handles: { 'foo' => 'bar' } }
h_injected = sc.to_processor_hash(mentions: injected)
test('mentions: injected value used when provided', injected, h_injected[:mentions])

# No mentions in data, no injection — empty hash
sc_no_mentions = Config::SourceConfig.new({ id: 'x', platform: 'rss' })
test('mentions: empty hash when neither source nor injection', {}, sc_no_mentions.to_processor_hash[:mentions])

# =============================================================================
# Defaults for absent fields
# =============================================================================
section('Defaults for absent fields')

sc_minimal = Config::SourceConfig.new({ id: 'min', platform: 'rss' })
hm = sc_minimal.to_processor_hash

test('source.handle nil when absent', nil, hm[:source][:handle])
test('target.visibility default public', 'public', hm[:target][:visibility])
test('rss_source_type default rss', 'rss', hm[:rss_source_type])
test('filtering empty hash', {}, hm[:filtering])
test('thread_handling empty hash', {}, hm[:thread_handling])

# =============================================================================
# Summary
# =============================================================================
puts
puts '=' * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts '=' * 60

exit($failed == 0 ? 0 : 1)
