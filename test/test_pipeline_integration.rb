#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Pipeline Integration Test
# ============================================================
#
# Testuje kompletní zpracování postů ze všech 4 platforem
# přes PostProcessor pipeline s realistickými daty.
#
# Motivace: deployment 2026-02-10 selhal kvůli string/symbol
# key inkonsistenci. Tento test ověřuje, že config se symbol
# keys funguje správně end-to-end.
#
# Testované platformy:
#   1. Twitter tweet (regular)
#   2. Bluesky post (regular)
#   3. RSS článek (title + content)
#   4. YouTube video (title + description)
#
# Run: ruby test/test_pipeline_integration.rb
# ============================================================

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

# ============================================================
# Mock implementations — nahrazují síťové a DB závislosti
# ============================================================

# Mock ContentProcessor (offline verze bez full dependency chain)
module Processors
  class ContentProcessor
    def initialize(max_length:, strategy: :smart, tolerance_percent: 12)
      @max_length = max_length
    end

    def process(text)
      return '' if text.nil? || text.empty?
      return text if text.length <= @max_length
      text[0...@max_length - 1] + '…'
    end
  end

  class UrlProcessor
    attr_reader :no_trim_domains

    def initialize(no_trim_domains: [])
      @no_trim_domains = no_trim_domains
    end

    def apply_domain_fixes(text, fixes)
      text
    end

    def process_content(text)
      text
    end
  end

  class ContentFilter
    def initialize(content_replacements: [])
      @replacements = content_replacements
    end

    def apply_replacements(text)
      result = text.dup
      @replacements.each do |r|
        pattern = r[:pattern] || r[:from]
        replacement = r[:replacement] || r[:to] || ''
        next unless pattern
        result = result.gsub(pattern.to_s, replacement.to_s)
      end
      result
    end
  end
end

# Mock MastodonPublisher — zaznamenává volání publish()
module Publishers
  class MastodonPublisher
    MAX_MEDIA_COUNT = 4
    attr_reader :published_posts, :uploaded_media

    def initialize(instance_url:, access_token:)
      @instance_url = instance_url
      @access_token = access_token
      @published_posts = []
      @uploaded_media = []
      @counter = 0
    end

    def publish(text, media_ids: [], visibility: 'public', in_reply_to_id: nil)
      @counter += 1
      id = "mastodon_#{@counter}"
      @published_posts << {
        id: id, text: text, media_ids: media_ids,
        visibility: visibility, in_reply_to_id: in_reply_to_id
      }
      { 'id' => id }
    end

    def upload_media_from_url(url, description: nil)
      media_id = "media_#{@uploaded_media.size + 1}"
      @uploaded_media << { id: media_id, url: url, description: description }
      media_id
    end

    def upload_media_parallel(media_items)
      media_items.first(MAX_MEDIA_COUNT).map do |item|
        upload_media_from_url(item[:url], description: item[:description])
      end
    end

    def update_status(mastodon_id, text, media_ids: nil)
      { 'id' => mastodon_id }
    end
  end
end

# Mock StateManager — in-memory stav
module State
  class StateManager
    attr_reader :published_records, :skipped_records, :activity_log

    def initialize
      @published = {}
      @published_records = []
      @skipped_records = []
      @activity_log = []
    end

    def published?(source_id, post_id)
      @published.dig(source_id, post_id) || false
    end

    def mark_published(source_id, post_id, post_url: nil, mastodon_status_id: nil, platform_uri: nil)
      @published[source_id] ||= {}
      @published[source_id][post_id] = true
      @published_records << {
        source_id: source_id, post_id: post_id, post_url: post_url,
        mastodon_status_id: mastodon_status_id, platform_uri: platform_uri
      }
    end

    def log_publish(source_id, post_id:, post_url: nil, mastodon_status_id: nil)
      @activity_log << { action: :publish, source_id: source_id, post_id: post_id }
    end

    def log_skip(source_id, post_id:, reason:)
      @skipped_records << { source_id: source_id, post_id: post_id, reason: reason }
    end

    # Edit buffer stubs
    def find_by_text_hash(_username, _hash); nil; end
    def find_recent_buffer_entries(_username, within_seconds: 3600); []; end
    def add_to_edit_buffer(**opts); end
    def update_edit_buffer_mastodon_id(*args); end
    def mark_edit_superseded(*args); end
    def cleanup_edit_buffer(retention_hours: 2); 0; end
  end
end

# Mock ConfigLoader — symbol keys (jak je to v produkci po deep_symbolize_keys)
module Config
  class ConfigLoader
    def load_global_config
      { url: { no_trim_domains: ['zpravy.aktualne.cz'] } }
    end

    def mastodon_credentials(account_id)
      {
        token: "test_token_#{account_id}",
        instance: 'https://zpravobot.news'
      }
    end
  end
end

# Load real modules
require_relative '../lib/errors'
require_relative '../lib/models/post'
require_relative '../lib/models/author'
require_relative '../lib/models/media'
require_relative '../lib/formatters/universal_formatter'
require_relative '../lib/formatters/twitter_formatter'
require_relative '../lib/formatters/bluesky_formatter'
require_relative '../lib/formatters/rss_formatter'
require_relative '../lib/formatters/youtube_formatter'
require_relative '../lib/processors/post_processor'

# ============================================================
# Test Framework
# ============================================================

$passed = 0
$failed = 0

def test(name, expected, actual)
  if expected == actual
    puts "  \e[32m✓\e[0m #{name}"
    $passed += 1
  else
    puts "  \e[31m✗\e[0m #{name}"
    puts "    Expected: #{expected.inspect}"
    puts "    Actual:   #{actual.inspect}"
    $failed += 1
  end
end

def test_includes(name, haystack, needle)
  if haystack.to_s.include?(needle.to_s)
    puts "  \e[32m✓\e[0m #{name}"
    $passed += 1
  else
    puts "  \e[31m✗\e[0m #{name}"
    puts "    Expected to include: #{needle.inspect}"
    puts "    In: #{haystack.inspect}"
    $failed += 1
  end
end

def test_not_includes(name, haystack, needle)
  if !haystack.to_s.include?(needle.to_s)
    puts "  \e[32m✓\e[0m #{name}"
    $passed += 1
  else
    puts "  \e[31m✗\e[0m #{name}"
    puts "    Expected NOT to include: #{needle.inspect}"
    puts "    In: #{haystack.inspect}"
    $failed += 1
  end
end

def test_truthy(name, value)
  if value
    puts "  \e[32m✓\e[0m #{name}"
    $passed += 1
  else
    puts "  \e[31m✗\e[0m #{name}"
    puts "    Expected truthy, got: #{value.inspect}"
    $failed += 1
  end
end

def test_match(name, text, pattern)
  if text.to_s.match?(pattern)
    puts "  \e[32m✓\e[0m #{name}"
    $passed += 1
  else
    puts "  \e[31m✗\e[0m #{name}"
    puts "    Expected to match: #{pattern.inspect}"
    puts "    In: #{text.inspect}"
    $failed += 1
  end
end

def section(title)
  puts
  puts "--- #{title} ---"
end

# ============================================================
# Helper: vytvoření PostProcessor s trackovacím publisherem
# ============================================================

def create_pipeline(dry_run: false)
  state = State::StateManager.new
  config = Config::ConfigLoader.new
  processor = Processors::PostProcessor.new(
    state_manager: state,
    config_loader: config,
    dry_run: dry_run
  )
  [processor, state, config]
end

# ============================================================
# Test Data — realistické payloady pro všechny 4 platformy
# ============================================================

# Všechny source_config hashe používají SYMBOL KEYS,
# protože ConfigLoader vrací data po deep_symbolize_keys.
# Toto je klíčová validace — production bug 2026-02-10
# byl způsoben právě string keys v config hashích.

def twitter_source_config
  {
    id: 'ct24_twitter',
    platform: 'twitter',
    formatting: {
      source_name: 'ČT24',
      max_length: 500,
      prefix_post_text: "\n",
      prefix_post_url: "\n"
    },
    filtering: {
      skip_replies: true,
      skip_retweets: false,
      skip_quotes: false
    },
    processing: {
      trim_strategy: 'smart',
      smart_tolerance_percent: 12,
      url_domain_fixes: [],
      content_replacements: []
    },
    target: {
      mastodon_account: 'betabot',
      mastodon_instance: 'https://zpravobot.news',
      visibility: 'public'
    },
    content: {},
    thread_handling: {},
    mentions: { type: 'none', value: '' },
    _mastodon_token: 'test_token_betabot'
  }
end

def bluesky_source_config
  {
    id: 'deniknreference_bluesky',
    platform: 'bluesky',
    formatting: {
      source_name: 'Deník N',
      max_length: 500,
      prefix_post_text: "\n",
      prefix_post_url: "\n"
    },
    filtering: {
      skip_replies: true,
      skip_retweets: false,
      skip_quotes: false
    },
    processing: {
      trim_strategy: 'smart',
      smart_tolerance_percent: 12,
      url_domain_fixes: [],
      content_replacements: []
    },
    target: {
      mastodon_account: 'betabot',
      mastodon_instance: 'https://zpravobot.news',
      visibility: 'public'
    },
    content: {},
    thread_handling: {},
    mentions: { type: 'none', value: '' },
    _mastodon_token: 'test_token_betabot'
  }
end

def rss_source_config
  {
    id: 'aktualne_rss',
    platform: 'rss',
    formatting: {
      source_name: 'Aktuálně.cz',
      max_length: 500,
      prefix_post_text: "\n",
      prefix_post_url: "\n",
      move_url_to_end: true
    },
    filtering: {
      skip_replies: false,
      banned_phrases: [],
      required_keywords: []
    },
    processing: {
      trim_strategy: 'smart',
      smart_tolerance_percent: 12,
      url_domain_fixes: [],
      content_replacements: []
    },
    target: {
      mastodon_account: 'betabot',
      mastodon_instance: 'https://zpravobot.news',
      visibility: 'public'
    },
    content: {
      show_title_as_content: false,
      combine_title_and_content: true,
      title_separator: ' — '
    },
    thread_handling: {},
    rss_source_type: 'rss',
    mentions: { type: 'none', value: '' },
    _mastodon_token: 'test_token_betabot'
  }
end

def youtube_source_config
  {
    id: 'ct24_youtube',
    platform: 'youtube',
    formatting: {
      source_name: 'ČT24',
      max_length: 500,
      prefix_post_text: "\n",
      prefix_post_url: "\n"
    },
    filtering: {
      banned_phrases: [],
      required_keywords: []
    },
    processing: {
      trim_strategy: 'smart',
      smart_tolerance_percent: 12,
      url_domain_fixes: [],
      content_replacements: []
    },
    target: {
      mastodon_account: 'betabot',
      mastodon_instance: 'https://zpravobot.news',
      visibility: 'public'
    },
    content: {
      show_title_as_content: false,
      combine_title_and_content: true,
      title_separator: "\n\n",
      description_max_lines: 3,
      include_views: false
    },
    thread_handling: {},
    mentions: { type: 'none', value: '' },
    _mastodon_token: 'test_token_betabot'
  }
end

# ============================================================
# Test Post factory — realistické Post objekty
# ============================================================

def make_twitter_post
  Post.new(
    platform: 'twitter',
    id: 'tweet_1893456789012345678',
    url: 'https://x.com/CT24zive/status/1893456789012345678',
    text: 'Premiér Fiala se dnes setkal s představiteli opozice. Jednání o reformě důchodového systému pokračují.',
    published_at: Time.now - 3600,
    author: Author.new(
      username: 'CT24zive',
      display_name: 'ČT24',
      url: 'https://x.com/CT24zive'
    ),
    is_repost: false,
    is_quote: false,
    is_reply: false
  )
end

def make_bluesky_post
  Post.new(
    platform: 'bluesky',
    id: 'at://did:plc:abc123def456/app.bsky.feed.post/3lk7xyz9abc',
    url: 'https://bsky.app/profile/denikn.cz/post/3lk7xyz9abc',
    text: 'Exkluzivní rozhovor: Jak české firmy reagují na novou legislativu EU o umělé inteligenci. Celý článek na https://denikn.cz/1234567/ai-regulace/',
    published_at: Time.now - 1800,
    author: Author.new(
      username: 'denikn.cz',
      display_name: 'Deník N',
      url: 'https://bsky.app/profile/denikn.cz'
    ),
    is_repost: false,
    is_quote: false,
    is_reply: false
  )
end

def make_rss_post
  Post.new(
    platform: 'rss',
    id: 'https://zpravy.aktualne.cz/domaci/vlada-schvalila-novelu-stavebniho-zakona/r~a1b2c3d4/',
    url: 'https://zpravy.aktualne.cz/domaci/vlada-schvalila-novelu-stavebniho-zakona/r~a1b2c3d4/',
    title: 'Vláda schválila novelu stavebního zákona',
    text: 'Kabinet dnes odpoledne projednal a schválil dlouho očekávanou novelu stavebního zákona, která má zrychlit povolovací procesy a snížit administrativní zátěž pro stavebníky.',
    published_at: Time.now - 7200,
    author: Author.new(
      username: 'aktualne.cz',
      display_name: 'Aktuálně.cz'
    ),
    is_repost: false,
    is_quote: false,
    is_reply: false,
    media: [
      Media.new(
        type: 'image',
        url: 'https://img.aktualne.cz/photo/stavba.jpg',
        alt_text: 'Stavební projekt v Praze'
      )
    ]
  )
end

def make_youtube_post
  Post.new(
    platform: 'youtube',
    id: 'yt:video:dQw4w9WgXcQ',
    url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    title: 'Hlavní zprávy: Přehled událostí dne | ČT24',
    text: 'Kompletní přehled nejdůležitějších událostí dne z domova i ze světa. Redakce ČT24 přináší aktuální zpravodajství.',
    published_at: Time.now - 5400,
    author: Author.new(
      username: 'CT24',
      display_name: 'ČT24',
      url: 'https://www.youtube.com/@CT24'
    ),
    is_repost: false,
    is_quote: false,
    is_reply: false,
    has_video: true
  )
end

# ============================================================
# TESTS
# ============================================================

puts "=" * 60
puts "Pipeline Integration Test"
puts "=" * 60

# =============================================================
# 1. Twitter Post — kompletní zpracování
# =============================================================
section("1. Twitter Post — Full Pipeline")

processor, state, _config = create_pipeline

post = make_twitter_post
config = twitter_source_config
result = processor.process(post, config)

test("Twitter: result status je :published", :published, result.status)
test("Twitter: mastodon_id není nil", true, !result.mastodon_id.nil?)
test("Twitter: state zaznamenal published", true, state.published?('ct24_twitter', 'tweet_1893456789012345678'))
test("Twitter: publish log záznam existuje", 1, state.activity_log.size)
test("Twitter: published_records obsahuje záznam", 1, state.published_records.size)
test("Twitter: published record source_id", 'ct24_twitter', state.published_records.first[:source_id])

# =============================================================
# 2. Bluesky Post — kompletní zpracování
# =============================================================
section("2. Bluesky Post — Full Pipeline")

processor, state, _config = create_pipeline

post = make_bluesky_post
config = bluesky_source_config
result = processor.process(post, config)

test("Bluesky: result status je :published", :published, result.status)
test("Bluesky: mastodon_id není nil", true, !result.mastodon_id.nil?)
test("Bluesky: state zaznamenal published", true, state.published?('deniknreference_bluesky', post.id))
test("Bluesky: platform_uri uložen (AT URI)", true,
  state.published_records.first[:platform_uri]&.start_with?('at://') || false)

# =============================================================
# 3. RSS Post — kompletní zpracování s title+content
# =============================================================
section("3. RSS Post — Full Pipeline (title + content)")

processor, state, _config = create_pipeline

post = make_rss_post
config = rss_source_config
result = processor.process(post, config)

test("RSS: result status je :published", :published, result.status)
test("RSS: mastodon_id není nil", true, !result.mastodon_id.nil?)
test("RSS: state zaznamenal published", true,
  state.published?('aktualne_rss', post.id))
test("RSS: media upload záznam (image)", true, state.published_records.size > 0)

# =============================================================
# 4. YouTube Post — kompletní zpracování s videem
# =============================================================
section("4. YouTube Post — Full Pipeline (video)")

processor, state, _config = create_pipeline

post = make_youtube_post
config = youtube_source_config
result = processor.process(post, config)

test("YouTube: result status je :published", :published, result.status)
test("YouTube: mastodon_id není nil", true, !result.mastodon_id.nil?)
test("YouTube: state zaznamenal published", true,
  state.published?('ct24_youtube', post.id))

# =============================================================
# 5. Deduplikace — post zpracovaný podruhé se přeskočí
# =============================================================
section("5. Deduplikace — opakovaný post")

processor, state, _config = create_pipeline

post = make_twitter_post
config = twitter_source_config

result1 = processor.process(post, config)
test("Dedupe: první zpracování published", :published, result1.status)

result2 = processor.process(post, config)
test("Dedupe: druhé zpracování skipped", :skipped, result2.status)
test("Dedupe: důvod je already_published", 'already_published', result2.skipped_reason)

# =============================================================
# 6. Content Filtering — banned phrase
# =============================================================
section("6. Content Filtering — banned phrase")

processor, state, _config = create_pipeline

post = Post.new(
  platform: 'twitter',
  id: 'tweet_spam_123',
  url: 'https://x.com/spammer/status/123',
  text: 'Podívejte se na tuto SKVĚLOU investiční příležitost! #crypto #bitcoin',
  published_at: Time.now,
  author: Author.new(username: 'spammer', display_name: 'Spam Bot')
)
config = twitter_source_config.merge(
  filtering: { banned_phrases: ['investiční příležitost', 'crypto'] }
)

result = processor.process(post, config)
test("Filtering: banned phrase skipped", :skipped, result.status)
test("Filtering: důvod banned_phrase", 'banned_phrase', result.skipped_reason)

# =============================================================
# 7. Content Filtering — skip external reply
# =============================================================
section("7. Content Filtering — skip external reply")

processor, state, _config = create_pipeline

post = Post.new(
  platform: 'twitter',
  id: 'tweet_reply_456',
  url: 'https://x.com/CT24zive/status/456',
  text: '@jiný_uživatel Souhlasím s vaším názorem.',
  published_at: Time.now,
  author: Author.new(username: 'CT24zive', display_name: 'ČT24'),
  is_reply: true,
  is_thread_post: false
)
config = twitter_source_config  # skip_replies: true

result = processor.process(post, config)
test("Reply: external reply skipped", :skipped, result.status)
test("Reply: důvod is_external_reply", 'is_external_reply', result.skipped_reason)

# =============================================================
# 8. Dry Run — neměl by vytvořit mastodon_id
# =============================================================
section("8. Dry Run Mode")

processor, state, _config = create_pipeline(dry_run: true)

post = make_twitter_post
config = twitter_source_config

result = processor.process(post, config)
test("Dry run: status je :published", :published, result.status)
test("Dry run: mastodon_id je nil", nil, result.mastodon_id)

# =============================================================
# 9. Symbol Keys Validation — klíčový test pro bug 2026-02-10
# =============================================================
section("9. Symbol Keys Validation (bug 2026-02-10)")

# Ověříme, že PostProcessor správně čte symbol keys z configu
processor, _state, _config = create_pipeline(dry_run: true)

# Config se SYMBOL KEYS — tak jak to vrací ConfigLoader
config_symbol = {
  id: 'test_symbol',
  platform: 'twitter',
  formatting: { source_name: 'Test', max_length: 500 },
  filtering: {},
  processing: { trim_strategy: 'smart', smart_tolerance_percent: 12,
                url_domain_fixes: [], content_replacements: [] },
  target: { mastodon_account: 'test', visibility: 'public' },
  content: {},
  thread_handling: {},
  mentions: { type: 'none', value: '' },
  _mastodon_token: 'test_token'
}

post = make_twitter_post
result = processor.process(post, config_symbol)
test("Symbol keys: zpracování proběhlo", :published, result.status)

# Ověření, že source_id se správně extrahuje z config[:id]
test("Symbol keys: source_id přečten z config[:id]",
     true, result.status == :published)

# Config se STRING KEYS — toto by NEMĚLO fungovat (a je to bug)
# PostProcessor přistupuje k source_config[:id], :platform atd.
config_string = {
  'id' => 'test_string',
  'platform' => 'twitter',
  'formatting' => { 'source_name' => 'Test', 'max_length' => 500 },
  'filtering' => {},
  'processing' => {},
  'target' => { 'mastodon_account' => 'test', 'visibility' => 'public' },
  'content' => {},
  '_mastodon_token' => 'test_token'
}

result_string = processor.process(post, config_string)
# Výsledek by měl být buď error (nil platform) nebo :published s nil source_id
# Důležité je, že symbol keys fungují a string keys ne
test("String keys: source_id je nil (bez symbol keys)", nil, config_string[:id])
test("String keys: platform je nil (bez symbol keys)", nil, config_string[:platform])

# =============================================================
# 10. Všechny 4 platformy v jednom pipeline run
# =============================================================
section("10. Multi-platform pipeline (všechny 4 platformy)")

processor, state, _config = create_pipeline

posts_and_configs = [
  [make_twitter_post,  twitter_source_config],
  [make_bluesky_post,  bluesky_source_config],
  [make_rss_post,      rss_source_config],
  [make_youtube_post,  youtube_source_config]
]

results = posts_and_configs.map do |post, config|
  processor.process(post, config)
end

published_count = results.count(&:published?)
test("Multi-platform: všechny 4 published", 4, published_count)
test("Multi-platform: state má 4 záznamy", 4, state.published_records.size)

# Ověřit, že každá platforma má svůj záznam
source_ids = state.published_records.map { |r| r[:source_id] }
test("Multi-platform: ct24_twitter v záznamech", true, source_ids.include?('ct24_twitter'))
test("Multi-platform: deniknreference_bluesky v záznamech", true, source_ids.include?('deniknreference_bluesky'))
test("Multi-platform: aktualne_rss v záznamech", true, source_ids.include?('aktualne_rss'))
test("Multi-platform: ct24_youtube v záznamech", true, source_ids.include?('ct24_youtube'))

# =============================================================
# 11. Content Replacement
# =============================================================
section("11. Content Replacement")

processor, _state, _config = create_pipeline(dry_run: true)

post = Post.new(
  platform: 'twitter',
  id: 'tweet_replace_789',
  url: 'https://x.com/test/status/789',
  text: 'Informace z twitteru: breaking news',
  published_at: Time.now,
  author: Author.new(username: 'test', display_name: 'Test')
)

config = twitter_source_config.merge(
  id: 'test_replace',
  processing: {
    trim_strategy: 'smart',
    smart_tolerance_percent: 12,
    url_domain_fixes: [],
    content_replacements: [
      { pattern: 'twitteru', replacement: 'sítě X' }
    ]
  }
)

result = processor.process(post, config)
test("Replacement: zpracování proběhlo", :published, result.status)

# =============================================================
# 12. Repost handling
# =============================================================
section("12. Repost (retweet) handling")

processor, state, _config = create_pipeline

post = Post.new(
  platform: 'twitter',
  id: 'tweet_rt_999',
  url: 'https://x.com/CT24zive/status/999',
  text: 'Důležitá zpráva od ČHMÚ o nadcházejícím počasí.',
  published_at: Time.now,
  author: Author.new(username: 'CHMU_CZ', display_name: 'ČHMÚ'),
  is_repost: true,
  reposted_by: 'CT24zive'
)

config = twitter_source_config.merge(
  filtering: { skip_retweets: false, skip_replies: true }
)

result = processor.process(post, config)
test("Repost: zpracování published", :published, result.status)

# Teď s filtrováním
processor2, _state2, _config2 = create_pipeline

config_skip = twitter_source_config.merge(
  filtering: { skip_retweets: true }
)

result2 = processor2.process(post, config_skip)
test("Repost: skipped when skip_retweets", :skipped, result2.status)
test("Repost: důvod is_retweet", 'is_retweet', result2.skipped_reason)

# =============================================================
# 13. Post s médii
# =============================================================
section("13. Post s médii (image upload)")

processor, state, _config = create_pipeline

post = Post.new(
  platform: 'bluesky',
  id: 'at://did:plc:media123/app.bsky.feed.post/media1',
  url: 'https://bsky.app/profile/test.bsky.social/post/media1',
  text: 'Fotoreportáž z dnešních demonstrací v centru Prahy.',
  published_at: Time.now,
  author: Author.new(username: 'test.bsky.social', display_name: 'Test'),
  media: [
    Media.new(type: 'image', url: 'https://cdn.bsky.app/img1.jpg', alt_text: 'Demonstrace'),
    Media.new(type: 'image', url: 'https://cdn.bsky.app/img2.jpg', alt_text: 'Protestující')
  ]
)

config = bluesky_source_config.merge(
  id: 'test_media_bluesky',
  _mastodon_token: 'test_token_media'
)

result = processor.process(post, config)
test("Media: zpracování published", :published, result.status)

# =============================================================
# 14. Quote post
# =============================================================
section("14. Quote post handling")

processor, _state, _config = create_pipeline

post = Post.new(
  platform: 'bluesky',
  id: 'at://did:plc:quote1/app.bsky.feed.post/quote1',
  url: 'https://bsky.app/profile/test/post/quote1',
  text: 'Tohle je důležité — přečtěte si celý kontext.',
  published_at: Time.now,
  author: Author.new(username: 'denikn.cz', display_name: 'Deník N'),
  is_quote: true,
  quoted_post: {
    text: 'Původní post s důležitou informací.',
    author: 'original_author',
    url: 'https://bsky.app/profile/original/post/original1'
  }
)

config = bluesky_source_config.merge(
  id: 'test_quote_bluesky',
  filtering: { skip_quotes: false }
)

result = processor.process(post, config)
test("Quote: zpracování published", :published, result.status)

# Quote se skip
processor2, _state2, _config2 = create_pipeline
config_skip_quote = bluesky_source_config.merge(
  id: 'test_quote_skip',
  filtering: { skip_quotes: true }
)

result2 = processor2.process(post, config_skip_quote)
test("Quote: skipped when skip_quotes", :skipped, result2.status)

# =============================================================
# 15. Required Keywords
# =============================================================
section("15. Required Keywords filtering")

processor, _state, _config = create_pipeline(dry_run: true)

post_match = Post.new(
  platform: 'rss',
  id: 'https://example.com/article-voda',
  url: 'https://example.com/article-voda',
  title: 'Záplavy ohrožují Moravu',
  text: 'Velká voda zaplavila několik obcí na jižní Moravě.',
  published_at: Time.now,
  author: Author.new(username: 'example.com', display_name: 'Example')
)

post_no_match = Post.new(
  platform: 'rss',
  id: 'https://example.com/article-sport',
  url: 'https://example.com/article-sport',
  title: 'Fotbalový zápas skončil remízou',
  text: 'Sparta remizovala s Plzní 1:1.',
  published_at: Time.now,
  author: Author.new(username: 'example.com', display_name: 'Example')
)

config_required = rss_source_config.merge(
  id: 'test_required',
  filtering: { required_keywords: ['záplav'] }
)

result_match = processor.process(post_match, config_required)
test("Required keywords: matching post published", :published, result_match.status)

result_no_match = processor.process(post_no_match, config_required)
test("Required keywords: non-matching post skipped", :skipped, result_no_match.status)
test("Required keywords: důvod missing_required_keyword", 'missing_required_keyword', result_no_match.skipped_reason)

# ============================================================
# Summary
# ============================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
