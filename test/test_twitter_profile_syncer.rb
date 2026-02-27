#!/usr/bin/env ruby
# frozen_string_literal: true

# Test TwitterProfileSyncer — cache key normalization, URL resolution, HTML parsing
# Tests ONLY pure-logic methods (no HTTP, no file I/O).
# Run: ruby test/test_twitter_profile_syncer.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/syncers/twitter_profile_syncer'

puts '=' * 60
puts 'TwitterProfileSyncer Tests (offline)'
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

# Build a syncer instance without HTTP/file side effects
# use_cache: false avoids FileUtils.mkdir_p call
def build_syncer(handle: 'ct24zive', nitter: 'http://xn.zpravobot.news:8080')
  Syncers::TwitterProfileSyncer.new(
    twitter_handle: handle,
    nitter_instance: nitter,
    mastodon_instance: 'https://zpravobot.news',
    mastodon_token: 'dummy_token',
    use_cache: false
  )
end

# ==============================================================================
# normalize_nitter_cache_url
# ==============================================================================

puts 'normalize_nitter_cache_url'

syncer = build_syncer

# Nitter proxy URL → only /pic/... path returned
nitter_url = 'http://xn.zpravobot.news:8080/pic/enc/ABCDEF1234567890'
test(
  'Nitter http URL → extracts /pic/... path',
  '/pic/enc/ABCDEF1234567890',
  syncer.send(:normalize_nitter_cache_url, nitter_url)
)

# Nitter HTTPS with port
nitter_url_https = 'https://nitter.example.com:9090/pic/pbs.twimg.com/profile_images/123/photo.jpg'
test(
  'Nitter https URL with port → extracts /pic/... path',
  '/pic/pbs.twimg.com/profile_images/123/photo.jpg',
  syncer.send(:normalize_nitter_cache_url, nitter_url_https)
)

# Non-Nitter URL (direct CDN) → unchanged
cdn_url = 'https://pbs.twimg.com/profile_images/123/photo.jpg'
test(
  'Non-Nitter CDN URL → returned unchanged',
  cdn_url,
  syncer.send(:normalize_nitter_cache_url, cdn_url)
)

# URL without /pic/ → unchanged (not a Nitter image proxy path)
other_url = 'https://example.com/some/path'
test(
  'URL without /pic/ → returned unchanged',
  other_url,
  syncer.send(:normalize_nitter_cache_url, other_url)
)

puts

# ==============================================================================
# cache_key_for_url — stability across different Nitter instances
# ==============================================================================

puts 'cache_key_for_url — Nitter URL normalization'

syncer1 = build_syncer(nitter: 'http://xn.zpravobot.news:8080')
syncer2 = build_syncer(nitter: 'http://nitter2.example.com:9090')

same_path = '/pic/enc/ABCDEF1234567890'
url_instance1 = "http://xn.zpravobot.news:8080#{same_path}"
url_instance2 = "http://nitter2.example.com:9090#{same_path}"

key1 = syncer1.send(:cache_key_for_url, url_instance1, 'avatar')
key2 = syncer2.send(:cache_key_for_url, url_instance2, 'avatar')

test(
  'Same /pic/ path, different Nitter instances → same cache key',
  key1,
  key2
)

# Different paths → different keys
url_banner = "http://xn.zpravobot.news:8080/pic/enc/BANNER9999"
key_banner = syncer1.send(:cache_key_for_url, url_banner, 'avatar')
test(
  'Different /pic/ paths → different cache keys',
  true,
  key1 != key_banner
)

# Different type prefix → different keys
key_avatar = syncer1.send(:cache_key_for_url, url_instance1, 'avatar')
key_banner2 = syncer1.send(:cache_key_for_url, url_instance1, 'banner')
test(
  'Same URL, different type prefix (avatar vs banner) → different cache keys',
  true,
  key_avatar != key_banner2
)

# Different handles → different keys
syncer_a = build_syncer(handle: 'ct24zive')
syncer_b = build_syncer(handle: 'ihned')
key_a = syncer_a.send(:cache_key_for_url, url_instance1, 'avatar')
key_b = syncer_b.send(:cache_key_for_url, url_instance1, 'avatar')
test(
  'Same URL, different handles → different cache keys',
  true,
  key_a != key_b
)

puts

# ==============================================================================
# resolve_nitter_url
# ==============================================================================

puts 'resolve_nitter_url'

syncer = build_syncer(nitter: 'http://xn.zpravobot.news:8080')

# Absolute http URL → unchanged
test(
  'Absolute http URL → returned unchanged',
  'http://cdn.example.com/avatar.jpg',
  syncer.send(:resolve_nitter_url, 'http://cdn.example.com/avatar.jpg')
)

# Absolute https URL → unchanged
test(
  'Absolute https URL → returned unchanged',
  'https://pbs.twimg.com/profile_images/123/photo.jpg',
  syncer.send(:resolve_nitter_url, 'https://pbs.twimg.com/profile_images/123/photo.jpg')
)

# Relative /pic/ path → prepend nitter_instance
test(
  'Relative /pic/... path → prepend nitter_instance',
  'http://xn.zpravobot.news:8080/pic/enc/ABCDEF',
  syncer.send(:resolve_nitter_url, '/pic/enc/ABCDEF')
)

# Relative non-/pic/ path → prepend nitter_instance (with leading slash handling)
test(
  'Relative /other/path → prepend nitter_instance',
  'http://xn.zpravobot.news:8080/other/path',
  syncer.send(:resolve_nitter_url, '/other/path')
)

# nil → nil
test(
  'nil → nil',
  nil,
  syncer.send(:resolve_nitter_url, nil)
)

# empty string → nil
test(
  'empty string → nil',
  nil,
  syncer.send(:resolve_nitter_url, '')
)

puts

# ==============================================================================
# parse_nitter_profile — HTML parsing
# ==============================================================================

puts 'parse_nitter_profile'

syncer = build_syncer

# Minimal Nitter HTML fixture with avatar and banner
nitter_html_full = <<~HTML
  <html>
  <body>
    <a class="profile-card-fullname" href="/ct24zive">ČT24 živě</a>
    <div class="profile-bio"><p>Televizní zprávy</p></div>
    <a class="profile-card-avatar" href="/pic/enc/AVATAR123">
      <img src="/pic/enc/AVATAR123" />
    </a>
    <div class="profile-banner">
      <a href="/pic/enc/BANNER456">
        <img src="/pic/enc/BANNER456" />
      </a>
    </div>
  </body>
  </html>
HTML

profile = syncer.send(:parse_nitter_profile, nitter_html_full)

test(
  'parse_nitter_profile — extracts avatar_url',
  'http://xn.zpravobot.news:8080/pic/enc/AVATAR123',
  profile[:avatar_url]
)

test(
  'parse_nitter_profile — extracts banner_url',
  'http://xn.zpravobot.news:8080/pic/enc/BANNER456',
  profile[:banner_url]
)

test(
  'parse_nitter_profile — extracts display_name',
  'ČT24 živě',
  profile[:display_name]
)

# HTML without banner → banner_url is nil
nitter_html_no_banner = <<~HTML
  <html>
  <body>
    <a class="profile-card-fullname" href="/ct24zive">ČT24 živě</a>
    <a class="profile-card-avatar" href="/pic/enc/AVATAR123">
      <img src="/pic/enc/AVATAR123" />
    </a>
  </body>
  </html>
HTML

profile_no_banner = syncer.send(:parse_nitter_profile, nitter_html_no_banner)

test(
  'parse_nitter_profile — HTML without banner → banner_url is nil',
  nil,
  profile_no_banner[:banner_url]
)

test(
  'parse_nitter_profile — HTML without banner still extracts avatar_url',
  'http://xn.zpravobot.news:8080/pic/enc/AVATAR123',
  profile_no_banner[:avatar_url]
)

puts
puts '=' * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts '=' * 60

exit($failed > 0 ? 1 : 0)
