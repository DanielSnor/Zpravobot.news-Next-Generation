#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Test Suite: Bio formatting (mention rewriting + t.co expansion)
# ============================================================
#
# Pokrývá:
#   - Utils::TcoExpander.expand (s HttpClient.head stubem)
#   - Config::ConfigLoader#enrich_mentions_config (čistá logika)
#   - BaseProfileSyncer#format_bio_text:
#       * Twitter: t.co expanze + lokální/cizí mention rewrite + skip vlastního handle
#       * non-Twitter (Bluesky): bez t.co expanze
#       * mentions type: 'none' → text beze změny
#
# Usage:
#   ruby test/test_bio_formatting.rb
# ============================================================

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'net/http'
require 'stringio'
require 'utils/tco_expander'
require 'syncers/twitter_profile_syncer'
require 'syncers/bluesky_profile_syncer'

$passed = 0
$failed = 0

def test(name)
  original_stdout = $stdout
  $stdout = StringIO.new
  result = false
  error = nil
  begin
    result = yield
  rescue StandardError => e
    error = e
  ensure
    $stdout = original_stdout
  end
  if error
    $failed += 1
    puts "  \e[31m✘\e[0m #{name} — #{error.class}: #{error.message}"
    puts "    #{error.backtrace.first(3).join("\n    ")}"
  elsif result
    $passed += 1
    puts "  \e[32m✔\e[0m #{name}"
  else
    $failed += 1
    puts "  \e[31m✘\e[0m #{name}"
  end
end

# ------------------------------------------------------------
# Fake HTTP redirect response
# ------------------------------------------------------------

class FakeRedirectResponse < Net::HTTPMovedPermanently
  def initialize(location)
    super('1.1', '301', 'Moved Permanently')
    @headers = { 'location' => location }
  end

  def [](key)
    @headers[key.downcase]
  end
end

# ------------------------------------------------------------
# HttpClient.head stub
# ------------------------------------------------------------

def stub_head(response_map)
  unless HttpClient.singleton_class.method_defined?(:__orig_head)
    HttpClient.singleton_class.send(:alias_method, :__orig_head, :head)
  end
  HttpClient.define_singleton_method(:head) do |url, **_opts|
    response_map.is_a?(Proc) ? response_map.call(url) : response_map[url]
  end
end

def restore_head
  return unless HttpClient.singleton_class.method_defined?(:__orig_head)
  HttpClient.singleton_class.send(:alias_method, :head, :__orig_head)
end

# ============================================================
# 1. Utils::TcoExpander
# ============================================================

puts
puts '=' * 60
puts 'Utils::TcoExpander'
puts '=' * 60

test 'expand → resolves single t.co URL' do
  stub_head('https://t.co/abc' => FakeRedirectResponse.new('https://example.com/article'))
  result = Utils::TcoExpander.expand('Read https://t.co/abc now')
  restore_head
  result == 'Read https://example.com/article now'
end

test 'expand → multiple t.co in one text' do
  stub_head(
    'https://t.co/aaa' => FakeRedirectResponse.new('https://one.example.com'),
    'https://t.co/bbb' => FakeRedirectResponse.new('https://two.example.com')
  )
  result = Utils::TcoExpander.expand('A https://t.co/aaa B https://t.co/bbb C')
  restore_head
  result == 'A https://one.example.com B https://two.example.com C'
end

test 'expand → trailing emoji preserved (path is [A-Za-z0-9] only)' do
  stub_head('https://t.co/abc' => FakeRedirectResponse.new('https://example.com'))
  result = Utils::TcoExpander.expand('check https://t.co/abc👈 here')
  restore_head
  result == 'check https://example.com👈 here'
end

test 'expand → non-redirect response leaves URL unchanged' do
  fake_404 = Net::HTTPNotFound.new('1.1', '404', 'Not Found')
  stub_head('https://t.co/dead' => fake_404)
  result = Utils::TcoExpander.expand('foo https://t.co/dead bar')
  restore_head
  result == 'foo https://t.co/dead bar'
end

test 'expand → network error swallowed, original URL preserved' do
  stub_head(->(_url) { raise StandardError, 'boom' })
  result = Utils::TcoExpander.expand('https://t.co/oops')
  restore_head
  result == 'https://t.co/oops'
end

test 'expand → nil text returns nil' do
  Utils::TcoExpander.expand(nil).nil?
end

test 'expand → text without t.co unchanged (no HTTP call)' do
  # No stub installed — would raise if HEAD were called
  Utils::TcoExpander.expand('plain @mention text https://example.com') ==
    'plain @mention text https://example.com'
end

# ============================================================
# 2. ConfigLoader#enrich_mentions_config
# ============================================================

puts
puts '=' * 60
puts 'ConfigLoader#enrich_mentions_config'
puts '=' * 60

require 'config/config_loader'

# Build a loader stubbed with a fake handle map (no YAML I/O needed for these tests)
loader = Config::ConfigLoader.new
loader.instance_variable_set(:@twitter_handle_map, { 'ct24zive' => 'ct24', 'aktualnecz' => 'aktualnecz' })

test 'twitter + domain_suffix → enriched to domain_suffix_with_local with handle map' do
  result = loader.enrich_mentions_config({ type: 'domain_suffix', value: 'twitter.com' }, platform: 'twitter')
  result[:type] == 'domain_suffix_with_local' &&
    result[:value] == 'twitter.com' &&
    result[:local_instance] == 'zpravobot.news' &&
    result[:local_handles] == { 'ct24zive' => 'ct24', 'aktualnecz' => 'aktualnecz' }
end

test 'twitter + local_or_domain_suffix → adds local_handles, keeps type' do
  result = loader.enrich_mentions_config({ type: 'local_or_domain_suffix', value: 'twitter.com' }, platform: 'twitter')
  result[:type] == 'local_or_domain_suffix' &&
    result[:local_handles] == { 'ct24zive' => 'ct24', 'aktualnecz' => 'aktualnecz' }
end

test 'twitter + none → no enrichment' do
  result = loader.enrich_mentions_config({ type: 'none', value: '' }, platform: 'twitter')
  result == { type: 'none', value: '' }
end

test 'bluesky → no enrichment regardless of type' do
  raw = { type: 'prefix', value: 'https://bsky.app/profile/' }
  loader.enrich_mentions_config(raw, platform: 'bluesky') == raw
end

test 'nil raw_config → empty hash' do
  loader.enrich_mentions_config(nil, platform: 'twitter') == {}
end

# ============================================================
# 3. BaseProfileSyncer#format_bio_text (via TwitterProfileSyncer)
# ============================================================

puts
puts '=' * 60
puts 'TwitterProfileSyncer bio formatting'
puts '=' * 60

TWITTER_MENTIONS = {
  type: 'local_or_domain_suffix',
  value: 'twitter.com',
  local_handles: { 'ct24zive' => 'ct24', 'aktualnecz' => 'aktualnecz' }
}.freeze

def build_twitter_syncer(handle: 'ct24zive', mentions: TWITTER_MENTIONS)
  Syncers::TwitterProfileSyncer.new(
    twitter_handle: handle,
    nitter_instance: 'http://nitter.local',
    mastodon_instance: 'https://zpravobot.news',
    mastodon_token: 'dummy',
    mentions_config: mentions,
    use_cache: false
  )
end

test 'format_bio_text → known handle → @local (bare), unknown → @handle@twitter.com' do
  syncer = build_twitter_syncer(handle: 'someother')
  result = syncer.send(:format_bio_text, 'Spolupráce s @ct24zive a @nahodny.')
  result == 'Spolupráce s @ct24 a @nahodny@twitter.com.'
end

test 'format_bio_text → vlastní handle se přeskakuje (skip: source_handle)' do
  syncer = build_twitter_syncer(handle: 'ct24zive')
  # @ct24zive should NOT be rewritten (it's the syncer's own handle)
  result = syncer.send(:format_bio_text, 'Účet @ct24zive a @aktualnecz.')
  result == 'Účet @ct24zive a @aktualnecz.'
end

test 'format_bio_text → t.co expanze v bio' do
  stub_head('https://t.co/web' => FakeRedirectResponse.new('https://example.com'))
  syncer = build_twitter_syncer(handle: 'someother')
  result = syncer.send(:format_bio_text, 'Web: https://t.co/web')
  restore_head
  result == 'Web: https://example.com'
end

test 'format_bio_text → t.co + mention v jednom řetězci' do
  stub_head('https://t.co/x' => FakeRedirectResponse.new('https://example.com'))
  syncer = build_twitter_syncer(handle: 'someother')
  result = syncer.send(:format_bio_text, 'Více @aktualnecz a https://t.co/x')
  restore_head
  result == 'Více @aktualnecz a https://example.com'
end

test 'format_bio_text → email se nepřepisuje (regex má negative lookbehind)' do
  syncer = build_twitter_syncer(handle: 'someother')
  result = syncer.send(:format_bio_text, 'Kontakt: foo@bar.com a @ct24zive')
  result == 'Kontakt: foo@bar.com a @ct24'
end

test 'format_bio_text → nil text vrací nil (žádné kroky)' do
  syncer = build_twitter_syncer
  syncer.send(:format_bio_text, nil).nil?
end

test 'format_bio_text → empty text vrací empty (žádné kroky)' do
  syncer = build_twitter_syncer
  syncer.send(:format_bio_text, '') == ''
end

# ============================================================
# 4. BlueskyProfileSyncer — žádná t.co expanze (default no-op)
# ============================================================

puts
puts '=' * 60
puts 'BlueskyProfileSyncer bio formatting'
puts '=' * 60

def build_bluesky_syncer(mentions:)
  Syncers::BlueskyProfileSyncer.new(
    bluesky_handle: 'someone.bsky.social',
    bluesky_api: 'https://public.api.bsky.app',
    bluesky_profile_prefix: 'https://bsky.app/profile/',
    mastodon_instance: 'https://zpravobot.news',
    mastodon_token: 'dummy',
    mentions_config: mentions,
    use_cache: false
  )
end

test 'BlueskyProfileSyncer.expand_short_urls → t.co se NEexpanduje (default no-op)' do
  # No stub → if expand_short_urls tried HTTP it would fail
  syncer = build_bluesky_syncer(mentions: { type: 'prefix', value: 'https://bsky.app/profile/' })
  result = syncer.send(:expand_short_urls, 'foo https://t.co/x bar')
  result == 'foo https://t.co/x bar'
end

test 'BlueskyProfileSyncer + mentions type "none" → bio beze změny' do
  syncer = build_bluesky_syncer(mentions: { type: 'none', value: '' })
  result = syncer.send(:format_bio_text, 'Hello @someone!')
  result == 'Hello @someone!'
end

# ============================================================
# Summary
# ============================================================
puts
puts '=' * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts '=' * 60
exit($failed.zero? ? 0 : 1)
