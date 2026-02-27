#!/usr/bin/env ruby
# frozen_string_literal: true

# Test: TwitterTweetProcessor — Unified Twitter Pipeline (TASK-10)
# ================================================================
# Testuje Tier určení, Nitter fetch + retry, Syndication fallback,
# Tier 3 fallback_post a threading (základní i pokročilé).
# Bez HTTP a DB — všechny závislosti jsou mockované.
#
# Run: ruby test/test_twitter_tweet_processor.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'stringio'

# ============================================================
# Mocks — definovány před načtením reálných souborů,
# aby nebyl načten PG/DB kód.
# ============================================================

module State
  class StateManager
    def find_recent_thread_parent(_source_id); nil; end
    def mark_published(**opts); nil; end
    def published?(_source_id, _post_id); false; end
    def log_publish(**opts); nil; end
    def log_skip(**opts); nil; end
    def add_to_edit_buffer(**opts); nil; end
    def find_by_text_hash(*args); nil; end
    def find_recent_buffer_entries(*args); []; end
    def update_edit_buffer_mastodon_id(*args); nil; end
    def mark_edit_superseded(*args); nil; end
    def cleanup_edit_buffer(**opts); 0; end
  end
end

module Config
  class ConfigLoader
    def load_global_config
      { mastodon: { instance: 'https://test.social' }, url: { no_trim_domains: [] } }
    end

    def mastodon_credentials(_account_id)
      { token: 'test_token' }
    end
  end
end

# MastodonPublisher stub (načítán PostProcessorem)
module Publishers
  class MastodonPublisher
    MAX_MEDIA_COUNT = 4 unless defined?(MAX_MEDIA_COUNT)

    def initialize(instance_url:, access_token:); end

    def publish(text, media_ids: [], visibility: 'public', in_reply_to_id: nil)
      { 'id' => "masto_#{rand(99_999)}" }
    end

    def upload_media_from_url(url, description: nil)
      "media_#{rand(999)}"
    end

    def upload_media_parallel(items)
      items.map { "media_#{rand(999)}" }
    end
  end
end

# ============================================================
# Načtení reálného kódu
# ============================================================
require_relative '../lib/processors/twitter_tweet_processor'
require_relative '../lib/models/post'
require_relative '../lib/models/author'
require_relative '../lib/models/media'

# Zrychlení retry smyček (RETRY_DELAYS je frozen — musíme použít remove_const)
original_verbose = $VERBOSE
$VERBOSE = nil
Processors::TwitterTweetProcessor.send(:remove_const, :RETRY_DELAYS)
Processors::TwitterTweetProcessor.const_set(:RETRY_DELAYS, [0, 0, 0].freeze)
$VERBOSE = original_verbose

# ============================================================
# Test Framework
# ============================================================

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

def quiet
  old = $stdout
  $stdout = StringIO.new
  yield
ensure
  $stdout = old
end

# ============================================================
# Mock PostResult a PostProcessor
# ============================================================

class PostResultMock
  attr_reader :mastodon_id

  def initialize(status, mastodon_id)
    @status = status
    @mastodon_id = mastodon_id
  end

  def published?; @status == :published; end
  def skipped?;   @status == :skipped;   end
  def failed?;    @status == :failed;    end
end

class TrackingPostProcessor
  attr_reader :last_post, :last_in_reply_to, :call_count

  SENTINEL = :not_called

  def initialize(status: :published, mastodon_id: 'masto_test_123')
    @result = PostResultMock.new(status, mastodon_id)
    @last_post = nil
    @last_in_reply_to = SENTINEL
    @call_count = 0
  end

  def process(post, _source_config, extra_options = {})
    @last_post = post
    @last_in_reply_to = extra_options[:in_reply_to_id]
    @call_count += 1
    @result
  end
end

# ============================================================
# Helpers
# ============================================================

def make_processor(post_processor:)
  Processors::TwitterTweetProcessor.new(
    state_manager: State::StateManager.new,
    config_loader: Config::ConfigLoader.new,
    nitter_instance: 'http://nitter.test:8080',
    post_processor: post_processor
  )
end

def source_config(overrides = {})
  base = {
    id: 'test_source',
    platform: 'twitter',
    source: { handle: 'testuser', nitter_instance: nil },
    nitter_processing: { enabled: true },
    thread_handling: { enabled: false },
    target: {
      mastodon_account: 'betabot',
      mastodon_instance: 'https://test.social',
      visibility: 'public'
    },
    filtering: {},
    formatting: { max_length: 500 },
    url: {}
  }
  base.merge(overrides)
end

def make_post(id: '123456789', text: 'Test tweet', is_thread_post: false)
  Post.new(
    id: id,
    platform: 'twitter',
    url: "https://x.com/testuser/status/#{id}",
    text: text,
    author: Author.new(
      username: 'testuser',
      display_name: 'Test User',
      url: 'https://x.com/testuser'
    ),
    published_at: Time.now,
    media: [],
    is_reply: false,
    is_repost: false,
    is_quote: false,
    is_thread_post: is_thread_post
  )
end

# Stubuje fetch metody na instanci procesoru (bez HTTP)
def stub_fetches(processor, nitter_result:, syndication_result: nil)
  processor.define_singleton_method(:fetch_from_nitter_with_retry) do |_post_id, _username, _config|
    nitter_result
  end
  processor.define_singleton_method(:fetch_from_syndication) do |_post_id, _username, _config, _fallback|
    syndication_result
  end
end

# ============================================================
# 1. Tier determination — nitter_processing enabled/disabled
# ============================================================

section "1. Tier determination"

# nitter_processing: enabled → Nitter fetch zavolán, vrátí post
pp1 = TrackingPostProcessor.new
proc1 = make_processor(post_processor: pp1)
nitter_post = make_post
stub_fetches(proc1, nitter_result: nitter_post)

result1 = quiet { proc1.process(post_id: '111', username: 'testuser', source_config: source_config) }
test "nitter enabled: returns :published", :published, result1
test "nitter enabled: PostProcessor dostane Nitter post", nitter_post, pp1.last_post

# nitter_processing: disabled → fallback_post použit přímo
pp2 = TrackingPostProcessor.new
proc2 = make_processor(post_processor: pp2)
fallback = make_post(id: '222', text: 'IFTTT fallback')
cfg_no_nitter = source_config(nitter_processing: { enabled: false })

result2 = quiet { proc2.process(post_id: '222', username: 'testuser', source_config: cfg_no_nitter, fallback_post: fallback) }
test "nitter disabled: returns :published (fallback_post)", :published, result2
test "nitter disabled: PostProcessor dostane fallback_post", fallback, pp2.last_post

# nitter_processing: disabled, bez fallback_post → :skipped
pp3 = TrackingPostProcessor.new
proc3 = make_processor(post_processor: pp3)
result3 = quiet { proc3.process(post_id: '333', username: 'testuser', source_config: cfg_no_nitter) }
test "nitter disabled, no fallback_post: returns :skipped", :skipped, result3
test "nitter disabled, no fallback_post: PostProcessor nevolán", 0, pp3.call_count

# ============================================================
# 2. Syndication fallback (Nitter fail → Syndication OK)
# ============================================================

section "2. Syndication fallback"

syndication_post = make_post(id: '444', text: 'Syndication post')

pp4 = TrackingPostProcessor.new
proc4 = make_processor(post_processor: pp4)
stub_fetches(proc4, nitter_result: nil, syndication_result: syndication_post)

result4 = quiet { proc4.process(post_id: '444', username: 'testuser', source_config: source_config) }
test "syndication fallback: Nitter nil → Syndication použit", :published, result4
test "syndication fallback: PostProcessor dostane Syndication post", syndication_post, pp4.last_post

# Syndication taky nil → fallback_post (Tier 3)
fallback_tier3 = make_post(id: '555', text: 'Tier 3 IFTTT')
pp5 = TrackingPostProcessor.new
proc5 = make_processor(post_processor: pp5)
stub_fetches(proc5, nitter_result: nil, syndication_result: nil)

result5 = quiet { proc5.process(post_id: '555', username: 'testuser', source_config: source_config, fallback_post: fallback_tier3) }
test "Tier 3: Nitter + Syndication nil → fallback_post použit", :published, result5
test "Tier 3: PostProcessor dostane fallback_post", fallback_tier3, pp5.last_post

# Všechny selhaly, bez fallback_post → :skipped
pp6 = TrackingPostProcessor.new
proc6 = make_processor(post_processor: pp6)
stub_fetches(proc6, nitter_result: nil, syndication_result: nil)

result6 = quiet { proc6.process(post_id: '666', username: 'testuser', source_config: source_config) }
test "all fail, no fallback_post: returns :skipped", :skipped, result6
test "all fail, no fallback_post: PostProcessor nevolán", 0, pp6.call_count

# ============================================================
# 3. Nitter retry behavior
# ============================================================

section "3. Nitter retry"

# Nitter vrátí nil 2×, potom post → úspěch (RETRY_ATTEMPTS = 3)
retry_call_count = 0
retry_post = make_post(id: '777', text: 'Retry success')

pp7 = TrackingPostProcessor.new
proc7 = make_processor(post_processor: pp7)
mock_adapter = Object.new
mock_adapter.define_singleton_method(:fetch_single_post) do |_id|
  retry_call_count += 1
  retry_call_count < 3 ? nil : retry_post
end
proc7.define_singleton_method(:get_twitter_adapter) { |_u, _c| mock_adapter }
proc7.define_singleton_method(:fetch_from_syndication) { |_id, _u, _c, _fb| nil }

result7 = quiet { proc7.process(post_id: '777', username: 'testuser', source_config: source_config) }
test "retry: úspěch na 3. pokus", :published, result7
test "retry: adaptér volán 3× (RETRY_ATTEMPTS)", 3, retry_call_count
test "retry: vrácen správný post", retry_post, pp7.last_post

# Nitter vyhazuje výjimku → necrashuje, přejde na Syndication
pp8 = TrackingPostProcessor.new
proc8 = make_processor(post_processor: pp8)
error_adapter = Object.new
error_adapter.define_singleton_method(:fetch_single_post) { |_| raise StandardError, 'Nitter down' }
proc8.define_singleton_method(:get_twitter_adapter) { |_u, _c| error_adapter }
syndication_recovery = make_post(id: '888', text: 'Syndication recovery')
proc8.define_singleton_method(:fetch_from_syndication) { |_id, _u, _c, _fb| syndication_recovery }

result8 = quiet { proc8.process(post_id: '888', username: 'testuser', source_config: source_config) }
test "retry: Nitter raises → přechod na Syndication", :published, result8
test "retry: Syndication recovery post použit", syndication_recovery, pp8.last_post

# ============================================================
# 4. PostProcessor result propagation
# ============================================================

section "4. PostProcessor result propagation"

pp_skip = TrackingPostProcessor.new(status: :skipped)
proc_skip = make_processor(post_processor: pp_skip)
stub_fetches(proc_skip, nitter_result: make_post)

result_skip = quiet { proc_skip.process(post_id: '901', username: 'testuser', source_config: source_config) }
test "PostProcessor :skipped propaguje", :skipped, result_skip

pp_fail = TrackingPostProcessor.new(status: :failed)
proc_fail = make_processor(post_processor: pp_fail)
stub_fetches(proc_fail, nitter_result: make_post)

result_fail = quiet { proc_fail.process(post_id: '902', username: 'testuser', source_config: source_config) }
test "PostProcessor :failed propaguje", :failed, result_fail

# ============================================================
# 5. Základní threading (thread_handling: enabled: false)
# ============================================================

section "5. Základní threading (ThreadingSupport)"

# Non-thread post → in_reply_to_id nil
regular_post = make_post(id: '501', is_thread_post: false)
pp_basic1 = TrackingPostProcessor.new
proc_basic1 = make_processor(post_processor: pp_basic1)
stub_fetches(proc_basic1, nitter_result: regular_post)

quiet { proc_basic1.process(post_id: '501', username: 'testuser', source_config: source_config) }
test "basic threading: non-thread post → in_reply_to nil", nil, pp_basic1.last_in_reply_to

# Thread post, cache prázdná → in_reply_to nil (začátek vlákna)
thread_post_obj = make_post(id: '502', is_thread_post: true)
pp_basic2 = TrackingPostProcessor.new
proc_basic2 = make_processor(post_processor: pp_basic2)
stub_fetches(proc_basic2, nitter_result: thread_post_obj)

quiet { proc_basic2.process(post_id: '502', username: 'testuser', source_config: source_config) }
test "basic threading: thread_post, prázdná cache → in_reply_to nil", nil, pp_basic2.last_in_reply_to

# Thread post, parent v cache → in_reply_to z cache
thread_post_cached = make_post(id: '503', is_thread_post: true)
pp_basic3 = TrackingPostProcessor.new(mastodon_id: 'masto_cached_503')
proc_basic3 = make_processor(post_processor: pp_basic3)
stub_fetches(proc_basic3, nitter_result: thread_post_cached)
# Naseed thread_cache: test_source → testuser → masto_parent_456
proc_basic3.instance_variable_get(:@thread_cache)['test_source'] = { 'testuser' => 'masto_parent_456' }

quiet { proc_basic3.process(post_id: '503', username: 'testuser', source_config: source_config) }
test "basic threading: thread_post, parent v cache → in_reply_to z cache", 'masto_parent_456', pp_basic3.last_in_reply_to

# ============================================================
# 6. Pokročilé threading (thread_handling: enabled: true)
# ============================================================

section "6. Pokročilé threading (TwitterThreadProcessor)"

cfg_advanced = source_config(thread_handling: { enabled: true })
advanced_post = make_post(id: '601')
pp_adv = TrackingPostProcessor.new

proc_adv = make_processor(post_processor: pp_adv)
stub_fetches(proc_adv, nitter_result: advanced_post)

mock_thread_proc = Object.new
mock_thread_proc.define_singleton_method(:process) do |_source_id, _post_id, _username|
  { in_reply_to_id: 'masto_thread_parent', is_thread: true, chain_length: 2 }
end
proc_adv.define_singleton_method(:get_thread_processor) { |_| mock_thread_proc }

quiet { proc_adv.process(post_id: '601', username: 'testuser', source_config: cfg_advanced) }
test "advanced threading: in_reply_to_id z TwitterThreadProcessor", 'masto_thread_parent', pp_adv.last_in_reply_to

# Pokročilé threading: Nitter fail + fallback_post → in_reply_to_id zachován
fallback_adv = make_post(id: '602')
pp_adv2 = TrackingPostProcessor.new
proc_adv2 = make_processor(post_processor: pp_adv2)
stub_fetches(proc_adv2, nitter_result: nil, syndication_result: nil)
mock_thread_proc2 = Object.new
mock_thread_proc2.define_singleton_method(:process) do |_s, _p, _u|
  { in_reply_to_id: 'masto_thread_fallback', is_thread: true }
end
proc_adv2.define_singleton_method(:get_thread_processor) { |_| mock_thread_proc2 }

result_adv2 = quiet { proc_adv2.process(post_id: '602', username: 'testuser', source_config: cfg_advanced, fallback_post: fallback_adv) }
test "advanced threading: Nitter fail + fallback_post → published", :published, result_adv2
test "advanced threading: Nitter fail + fallback_post zachovává in_reply_to_id", 'masto_thread_fallback', pp_adv2.last_in_reply_to

# ============================================================
# 7. Error handling
# ============================================================

section "7. Error handling"

pp_err = TrackingPostProcessor.new
proc_err = make_processor(post_processor: pp_err)
proc_err.define_singleton_method(:fetch_from_nitter_with_retry) { |_, _, _| raise StandardError, 'Unexpected crash' }
proc_err.define_singleton_method(:fetch_from_syndication) { |_, _, _, _| raise StandardError, 'Also crashed' }

result_err = quiet { proc_err.process(post_id: '999', username: 'testuser', source_config: source_config) }
test "StandardError v fetch cascade: returns :failed", :failed, result_err

# ============================================================
# Summary
# ============================================================

puts
puts "=" * 60
if $failed == 0
  puts "\e[32m\u2705 All #{$passed} tests passed!\e[0m"
else
  puts "\e[31m\u274c #{$failed} failed, #{$passed} passed\e[0m"
end
puts "=" * 60

exit($failed > 0 ? 1 : 0)
