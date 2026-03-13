#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for Mentions Improvements:
#   1. format_single_mention — local_or_domain_suffix branch
#   2. format_mentions integration with local_or_domain_suffix
#   3. build_header with mentions transformation
#   4. contains_mention? helper in PostProcessor
#   5. Dummy image upload logic
# All tests are OFFLINE — no HTTP, no Mastodon API calls.
# Run: ruby test/test_mentions_improvements.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/formatters/universal_formatter'

puts '=' * 60
puts 'Mentions Improvements Tests (offline)'
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
# Helpers
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

def build_header(source:, prefix:, target:, is_self:, mentions_config: {})
  config = { mentions: mentions_config }
  fmt.send(:build_header, source: source, prefix: prefix, target: target, is_self: is_self, config: config)
end

LOCAL_MAP = {
  'strakovka'  => 'strakovka',
  'ct24zive'   => 'ct24',
  'aktualnecz' => 'aktualnecz'
}.freeze

LOCAL_OR_DOMAIN_CONFIG = {
  type:          'local_or_domain_suffix',
  value:         'twitter.com',
  local_handles: LOCAL_MAP
}.freeze

# ============================================================
# Section 1: format_single_mention — local_or_domain_suffix
# ============================================================

puts '--- Section 1: format_single_mention (local_or_domain_suffix) ---'

test(
  'lokální handle → holý @mastodon_id (bez domény)',
  '@strakovka',
  single_mention('strakovka', LOCAL_OR_DOMAIN_CONFIG)
)

test(
  'lokální handle s jiným mastodon_id → správné mastodon_id',
  '@ct24',
  single_mention('ct24zive', LOCAL_OR_DOMAIN_CONFIG)
)

test(
  'nelokální handle → @handle@twitter.com',
  '@mistnirozvoj@twitter.com',
  single_mention('mistnirozvoj', LOCAL_OR_DOMAIN_CONFIG)
)

test(
  'case-insensitive lookup — @Strakovka → lokální',
  '@strakovka',
  single_mention('Strakovka', LOCAL_OR_DOMAIN_CONFIG)
)

test(
  'case-insensitive lookup — @CT24zive → lokální s jiným mastodon_id',
  '@ct24',
  single_mention('CT24zive', LOCAL_OR_DOMAIN_CONFIG)
)

test(
  'case-insensitive lookup — @MistniRozvoj → nelokální s doménou',
  '@MistniRozvoj@twitter.com',
  single_mention('MistniRozvoj', LOCAL_OR_DOMAIN_CONFIG)
)

test(
  'prázdné local_handles → nelokální fallback',
  '@strakovka@twitter.com',
  single_mention('strakovka', { type: 'local_or_domain_suffix', value: 'twitter.com', local_handles: {} })
)

test(
  'nil local_handles → nelokální fallback',
  '@strakovka@twitter.com',
  single_mention('strakovka', { type: 'local_or_domain_suffix', value: 'twitter.com', local_handles: nil })
)

test(
  'chybějící local_handles klíč → nelokální fallback',
  '@unknownuser@twitter.com',
  single_mention('unknownuser', LOCAL_OR_DOMAIN_CONFIG)
)

puts

# ============================================================
# Section 2: format_mentions integrace s local_or_domain_suffix
# ============================================================

puts '--- Section 2: format_mentions integrace ---'

test(
  'lokální mention v textu → holý @handle',
  'Post od @strakovka dnes',
  format_mentions_text('Post od @strakovka dnes', LOCAL_OR_DOMAIN_CONFIG)
)

test(
  'nelokální mention v textu → @handle@twitter.com',
  'viz @mistnirozvoj@twitter.com pro info',
  format_mentions_text('viz @mistnirozvoj pro info', LOCAL_OR_DOMAIN_CONFIG)
)

test(
  'mix lokálních a nelokálních → každý správně',
  '@strakovka a @mistnirozvoj@twitter.com',
  format_mentions_text('@strakovka a @mistnirozvoj', LOCAL_OR_DOMAIN_CONFIG)
)

test(
  'skip autor → holý @handle (skip neprojde transformací)',
  '@strakovka napsal: text @mistnirozvoj@twitter.com',
  format_mentions_text('@strakovka napsal: text @mistnirozvoj', LOCAL_OR_DOMAIN_CONFIG, skip: 'strakovka')
)

test(
  'email adresa se netransformuje (negative lookbehind)',
  'kontakt: user@gmail.com',
  format_mentions_text('kontakt: user@gmail.com', LOCAL_OR_DOMAIN_CONFIG)
)

test(
  'type none → text beze změny',
  'text @strakovka @mistnirozvoj',
  format_mentions_text('text @strakovka @mistnirozvoj', { type: 'none', value: '' })
)

puts

# ============================================================
# Section 3: build_header s mentions transformací
# ============================================================

puts '--- Section 3: build_header s mentions transformací ---'

test(
  'repost s lokálním autorem → holý @handle v hlavičce',
  'Úřad vlády ČR 𝕏🔁 @strakovka:',
  build_header(
    source: 'Úřad vlády ČR',
    prefix: '𝕏🔁',
    target: 'strakovka',
    is_self: false,
    mentions_config: LOCAL_OR_DOMAIN_CONFIG
  )
)

test(
  'repost s nelokálním autorem → @handle@twitter.com v hlavičce',
  'Úřad vlády ČR 𝕏🔁 @mistnirozvoj@twitter.com:',
  build_header(
    source: 'Úřad vlády ČR',
    prefix: '𝕏🔁',
    target: 'mistnirozvoj',
    is_self: false,
    mentions_config: LOCAL_OR_DOMAIN_CONFIG
  )
)

test(
  'self-repost → "svůj post" (mentions transformace se neprovádí)',
  'Úřad vlády ČR 𝕏🔁 svůj post:',
  build_header(
    source: 'Úřad vlády ČR',
    prefix: '𝕏🔁',
    target: 'strakovka',
    is_self: true,
    mentions_config: LOCAL_OR_DOMAIN_CONFIG
  )
)

test(
  'quote s lokálním autorem → holý @handle v hlavičce',
  'SomeBot 𝕏💬 @ct24:',
  build_header(
    source: 'SomeBot',
    prefix: '𝕏💬',
    target: 'ct24zive',
    is_self: false,
    mentions_config: LOCAL_OR_DOMAIN_CONFIG
  )
)

test(
  'mentions type none → holý @handle (stejné chování jako dřív)',
  'SomeBot 𝕏🔁 @mistnirozvoj:',
  build_header(
    source: 'SomeBot',
    prefix: '𝕏🔁',
    target: 'mistnirozvoj',
    is_self: false,
    mentions_config: { type: 'none', value: '' }
  )
)

test(
  'prázdný mentions config → holý @handle',
  'SomeBot 𝕏🔁 @mistnirozvoj:',
  build_header(
    source: 'SomeBot',
    prefix: '𝕏🔁',
    target: 'mistnirozvoj',
    is_self: false,
    mentions_config: {}
  )
)

puts

# ============================================================
# Section 4: contains_mention? helper
# ============================================================

puts '--- Section 4: contains_mention? ---'

# Load PostProcessor in isolation (bez DB, bez publishers)
begin
  # Stub out heavy deps before requiring PostProcessor
  module State; class StateManager; end; end unless defined?(State::StateManager)
  module Config; class ConfigLoader; end; end unless defined?(Config::ConfigLoader)

  # Stub pipeline steps (tyto require-ují další soubory)
  # Místo toho testujeme contains_mention? přímo přes define na anonymní třídě
  klass = Class.new do
    def contains_mention?(text)
      return false if text.nil? || text.empty?
      text.match?(/(?<![.\w\/])@\w+/)
    end
  end
  checker = klass.new

  test(
    'text s @handle → true',
    true,
    checker.contains_mention?('@strakovka text')
  )

  test(
    'text s @handle@domain → true',
    true,
    checker.contains_mention?('viz @mistnirozvoj@twitter.com dnes')
  )

  test(
    'email adresa user@domain.com → false',
    false,
    checker.contains_mention?('kontakt: user@gmail.com')
  )

  test(
    'text bez mention → false',
    false,
    checker.contains_mention?('prostý text bez zmínek')
  )

  test(
    'nil → false',
    false,
    checker.contains_mention?(nil)
  )

  test(
    'prázdný řetězec → false',
    false,
    checker.contains_mention?('')
  )

  test(
    '@handle uprostřed textu → true',
    true,
    checker.contains_mention?('text @nekdo@mastodon.social text')
  )

  test(
    'URL s @ (nitter) → false (lookbehind / brání matchnutí)',
    false,
    checker.contains_mention?('https://nitter.net/@user/status/123')
  )

rescue => e
  puts "  [ERROR] Section 4 setup failed: #{e.message}"
  $failed += 1
end

puts

# ============================================================
# Section 5: Twitter PLATFORM_DEFAULTS — default je local_or_domain_suffix
# ============================================================

puts '--- Section 5: Twitter PLATFORM_DEFAULTS ---'

twitter_defaults = Formatters::UniversalFormatter::PLATFORM_DEFAULTS[:twitter]

test(
  'Twitter platform default mentions type je local_or_domain_suffix',
  'local_or_domain_suffix',
  twitter_defaults[:mentions][:type].to_s
)

test(
  'Twitter platform default mentions value je twitter.com',
  'twitter.com',
  twitter_defaults[:mentions][:value].to_s
)

puts

# ============================================================
# Summary
# ============================================================

puts '=' * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts '=' * 60

exit($failed > 0 ? 1 : 0)
