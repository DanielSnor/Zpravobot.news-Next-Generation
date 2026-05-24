#!/usr/bin/env ruby
# frozen_string_literal: true

# Test BaseProfileSyncer#build_managed_by_value and #build_fields — TASK-2
# Verifies that the SPRAVUJE field contains the platform suffix ("z X", "z Bluesky", etc.)
# Tests ONLY pure-logic methods (no HTTP, no file I/O).
# Run: ruby test/test_profile_syncer_build_fields.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/syncers/twitter_profile_syncer'
require_relative '../lib/syncers/bluesky_profile_syncer'
require_relative '../lib/syncers/facebook_profile_syncer'

puts '=' * 60
puts 'ProfileSyncer build_fields Tests (TASK-2, offline)'
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

# ── Syncer factories ────────────────────────────────────────────────────────

def twitter_syncer(language: 'cs')
  Syncers::TwitterProfileSyncer.new(
    twitter_handle: 'ct24zive',
    nitter_instance: 'http://xn.zpravobot.news:8080',
    mastodon_instance: 'https://zpravobot.news',
    mastodon_token: 'dummy',
    language: language,
    use_cache: false
  )
end

def bluesky_syncer(language: 'cs')
  Syncers::BlueskyProfileSyncer.new(
    bluesky_handle: 'nesestra.bsky.social',
    mastodon_instance: 'https://zpravobot.news',
    mastodon_token: 'dummy',
    language: language,
    use_cache: false
  )
end

def facebook_syncer(language: 'cs')
  Syncers::FacebookProfileSyncer.new(
    facebook_handle: 'headliner.cz',
    mastodon_instance: 'https://zpravobot.news',
    mastodon_token: 'dummy',
    browserless_token: 'dummy',
    facebook_cookies: [{ name: 'c_user', value: 'x', domain: '.facebook.com' }],
    language: language,
    use_cache: false
  )
end

# Fake current Mastodon fields (no web: set)
EMPTY_FIELDS = [].freeze

# ==============================================================================
# build_managed_by_value — platform labels
# ==============================================================================

puts 'build_managed_by_value — platform labels'

test(
  'Twitter syncer → @zpravobot@zpravobot.news z X',
  '@zpravobot@zpravobot.news z X',
  twitter_syncer.send(:build_managed_by_value)
)

test(
  'Bluesky syncer → @zpravobot@zpravobot.news z Bluesky',
  '@zpravobot@zpravobot.news z Bluesky',
  bluesky_syncer.send(:build_managed_by_value)
)

test(
  'Facebook syncer → @zpravobot@zpravobot.news z FB',
  '@zpravobot@zpravobot.news z FB',
  facebook_syncer.send(:build_managed_by_value)
)

puts

# ==============================================================================
# build_managed_by_value — multi-platform (aggregator, TASK-3 ready)
# ==============================================================================

puts 'build_managed_by_value — multi-platform source_platforms'

test(
  'source_platforms [youtube, instagram, rss] → z YT, IG, RSS',
  '@zpravobot@zpravobot.news z YT, IG, RSS',
  twitter_syncer.send(:build_managed_by_value, source_platforms: ['youtube', 'instagram', 'rss'])
)

test(
  'source_platforms [twitter, bluesky] → z X, Bluesky',
  '@zpravobot@zpravobot.news z X, Bluesky',
  twitter_syncer.send(:build_managed_by_value, source_platforms: ['twitter', 'bluesky'])
)

test(
  'Unknown platform key → used as-is (fallback)',
  '@zpravobot@zpravobot.news z unknown_platform',
  twitter_syncer.send(:build_managed_by_value, source_platforms: ['unknown_platform'])
)

puts

# ==============================================================================
# Localization
# ==============================================================================

puts 'build_managed_by_value — localization'

test(
  "language 'cs' → 'z'",
  '@zpravobot@zpravobot.news z X',
  twitter_syncer(language: 'cs').send(:build_managed_by_value)
)

test(
  "language 'sk' → 'z'",
  '@zpravobot@zpravobot.news z X',
  twitter_syncer(language: 'sk').send(:build_managed_by_value)
)

test(
  "language 'en' → 'from'",
  '@zpravobot@zpravobot.news from X',
  twitter_syncer(language: 'en').send(:build_managed_by_value)
)

puts

# ==============================================================================
# build_fields — 3rd field contains platform suffix
# ==============================================================================

puts 'build_fields — SPRAVUJE field value'

twitter_fields = twitter_syncer.send(:build_fields, 'ct24zive', EMPTY_FIELDS)
test(
  'Twitter syncer — 3rd field value ends with "z X"',
  true,
  twitter_fields[2][:value].end_with?('z X')
)

test(
  'Twitter syncer — 3rd field name is "spravuje:"',
  'spravuje:',
  twitter_fields[2][:name]
)

bluesky_fields = bluesky_syncer.send(:build_fields, 'nesestra.bsky.social', EMPTY_FIELDS)
test(
  'Bluesky syncer — 3rd field value ends with "z Bluesky"',
  true,
  bluesky_fields[2][:value].end_with?('z Bluesky')
)

# Facebook uses its own build_fields override
facebook_fields = facebook_syncer.send(:build_fields, 'headliner.cz', EMPTY_FIELDS, {})
test(
  'Facebook syncer (override) — 3rd field value ends with "z FB"',
  true,
  facebook_fields[2][:value].end_with?('z FB')
)

test(
  'All syncers return exactly 4 fields',
  [4, 4, 4],
  [twitter_fields.size, bluesky_fields.size, facebook_fields.size]
)

puts

# ==============================================================================
# PLATFORM_LABELS constant
# ==============================================================================

puts 'PLATFORM_LABELS constant'

test(
  'PLATFORM_LABELS contains all 7 platforms',
  7,
  Syncers::BaseProfileSyncer::PLATFORM_LABELS.size
)

test(
  "PLATFORM_LABELS['twitter'] == 'X'",
  'X',
  Syncers::BaseProfileSyncer::PLATFORM_LABELS['twitter']
)

test(
  "PLATFORM_LABELS['facebook'] == 'FB'",
  'FB',
  Syncers::BaseProfileSyncer::PLATFORM_LABELS['facebook']
)

# ==============================================================================
# sanitize_field_value — strips HTML, control chars, truncates
# ==============================================================================

puts 'sanitize_field_value'

s = twitter_syncer

test 'plain text unchanged',
  'hello world',
  s.send(:sanitize_field_value, 'hello world')

test 'strips HTML tags',
  'bold text',
  s.send(:sanitize_field_value, '<b>bold</b> text')

test 'strips anchor tags',
  'click here',
  s.send(:sanitize_field_value, '<a href="https://example.com">click here</a>')

test 'strips null bytes',
  'abc',
  s.send(:sanitize_field_value, "abc\x00")

test 'strips ASCII control chars (keeps content)',
  'ab',
  s.send(:sanitize_field_value, "a\x01\x1Fb")

test 'collapses whitespace',
  'a b c',
  s.send(:sanitize_field_value, "a  b\t\tc")

test 'strips leading/trailing whitespace',
  'hello',
  s.send(:sanitize_field_value, '  hello  ')

test 'nil → empty string',
  '',
  s.send(:sanitize_field_value, nil)

test 'empty string → empty string',
  '',
  s.send(:sanitize_field_value, '')

test "truncates at #{Syncers::ProfileFieldsBuilder::MASTODON_FIELD_VALUE_MAX} chars",
  255,
  s.send(:sanitize_field_value, 'x' * 300).length

puts

# ==============================================================================
# sanitize_url_field — validates http/https scheme, rejects dangerous URIs
# ==============================================================================

puts 'sanitize_url_field'

test 'https URL passes through',
  'https://example.com/path',
  s.send(:sanitize_url_field, 'https://example.com/path')

test 'http URL passes through',
  'http://example.com',
  s.send(:sanitize_url_field, 'http://example.com')

test 'javascript: scheme → empty string',
  '',
  s.send(:sanitize_url_field, 'javascript:alert(1)')

test 'data: scheme → empty string',
  '',
  s.send(:sanitize_url_field, 'data:text/html,<script>alert(1)</script>')

test 'vbscript: scheme → empty string',
  '',
  s.send(:sanitize_url_field, 'vbscript:msgbox(1)')

test 'nil → empty string',
  '',
  s.send(:sanitize_url_field, nil)

test 'empty string → empty string',
  '',
  s.send(:sanitize_url_field, '')

test 'whitespace-only → empty string',
  '',
  s.send(:sanitize_url_field, '   ')

test 'invalid URI → empty string',
  '',
  s.send(:sanitize_url_field, "http://invalid uri\x00")

test 'URL with trailing slash kept (chomp is callers responsibility)',
  'https://example.com/',
  s.send(:sanitize_url_field, 'https://example.com/')

puts

# ==============================================================================
# build_fields — website from social network is sanitized
# ==============================================================================

puts 'build_fields — website sanitization'

# Normal website
fields = twitter_syncer.send(:build_fields, 'ct24zive', EMPTY_FIELDS,
  { website: 'https://ct24.cz' })
test 'valid website passed through to web: field',
  'https://ct24.cz',
  fields[1][:value]

# javascript: URI injected as website
fields = twitter_syncer.send(:build_fields, 'ct24zive', EMPTY_FIELDS,
  { website: 'javascript:alert(1)' })
test 'javascript: website → web: field becomes ""',
  '""',
  fields[1][:value]

# HTML in website
fields = twitter_syncer.send(:build_fields, 'ct24zive', EMPTY_FIELDS,
  { website: '<script>alert(1)</script>' })
test 'HTML-only website → sanitized to "" fallback',
  '""',
  fields[1][:value]

# Platform URL (field 0) always http/https
fields = twitter_syncer.send(:build_fields, 'ct24zive', EMPTY_FIELDS)
test 'platform URL field starts with https',
  true,
  fields[0][:value].start_with?('https://')

puts
puts '=' * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts '=' * 60

exit($failed > 0 ? 1 : 0)
