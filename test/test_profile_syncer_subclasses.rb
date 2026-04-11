#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Test Suite: Profile Syncer Subclasses (Bluesky / Facebook / Instagram / YouTube)
# ============================================================
#
# Unit testy pro 4 platform-specific profile syncery. Žádná síť, žádné DB.
# Stubuje se `HttpClient.get` a `HttpClient.post_json`.
#
# Pokryté oblasti:
#   - Konstruktor + template metody (source_handle, platform_name, field_prefix, ...)
#   - Parse metody (parse_facebook_profile, parse_instagram_profile, parse_youtube_profile)
#   - fetch_platform_profile happy path + chybové stavy
#
# Usage:
#   ruby test/test_profile_syncer_subclasses.rb
#
# ============================================================

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'json'
require 'net/http'
require 'stringio'
require 'syncers/bluesky_profile_syncer'
require 'syncers/facebook_profile_syncer'
require 'syncers/instagram_profile_syncer'
require 'syncers/youtube_profile_syncer'

$passed = 0
$failed = 0

def test(name)
  # Silence logs from syncers during test body
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
    puts "  ✘ #{name} — #{error.class}: #{error.message}"
    puts "    #{error.backtrace.first(3).join("\n    ")}"
  elsif result
    $passed += 1
    puts "  ✔ #{name}"
  else
    $failed += 1
    puts "  ✘ #{name}"
  end
end

# ------------------------------------------------------------
# Fake HTTP responses
# ------------------------------------------------------------

class FakeSuccessResponse < Net::HTTPSuccess
  def initialize(body)
    super('1.1', '200', 'OK')
    @fake_body = body
  end

  def body
    @fake_body
  end
end

class FakeErrorResponse < Net::HTTPInternalServerError
  def initialize(body = '', code = '500')
    super('1.1', code, 'Server Error')
    @fake_body = body
  end

  def body
    @fake_body
  end
end

# ------------------------------------------------------------
# HttpClient stub helpers
# ------------------------------------------------------------

def stub_get(response_or_proc)
  unless HttpClient.singleton_class.method_defined?(:__orig_get)
    HttpClient.singleton_class.send(:alias_method, :__orig_get, :get)
  end
  HttpClient.define_singleton_method(:get) do |_url, **_opts|
    response_or_proc.is_a?(Proc) ? response_or_proc.call : response_or_proc
  end
end

def restore_get
  return unless HttpClient.singleton_class.method_defined?(:__orig_get)

  HttpClient.singleton_class.send(:alias_method, :get, :__orig_get)
end

def stub_post_json(response_or_proc)
  unless HttpClient.singleton_class.method_defined?(:__orig_post_json)
    HttpClient.singleton_class.send(:alias_method, :__orig_post_json, :post_json)
  end
  HttpClient.define_singleton_method(:post_json) do |_url, _body = nil, **_opts|
    response_or_proc.is_a?(Proc) ? response_or_proc.call : response_or_proc
  end
end

def restore_post_json
  return unless HttpClient.singleton_class.method_defined?(:__orig_post_json)

  HttpClient.singleton_class.send(:alias_method, :post_json, :__orig_post_json)
end

BASE_OPTS = {
  mastodon_instance: 'https://zpravobot.news',
  mastodon_token: 'dummy_token',
  use_cache: false
}.freeze

# ============================================================
# BlueskyProfileSyncer
# ============================================================

puts
puts '=== BlueskyProfileSyncer ==='

def build_bluesky(handle: 'nesestra.bsky.social')
  Syncers::BlueskyProfileSyncer.new(bluesky_handle: handle, **BASE_OPTS)
end

puts '--- template methods ---'

test('source_handle returns bluesky_handle') do
  build_bluesky(handle: 'foo.bsky.social').source_handle == 'foo.bsky.social'
end

test('platform_name == "Bluesky"') do
  build_bluesky.platform_name == 'Bluesky'
end

test('platform_key == "bluesky"') do
  build_bluesky.platform_key == 'bluesky'
end

test('field_prefix == "bsky:"') do
  build_bluesky.field_prefix == 'bsky:'
end

test('default_mentions_config has bsky.app prefix') do
  build_bluesky.default_mentions_config['value'].include?('bsky.app')
end

test('validate_image_content_type? == true') do
  build_bluesky.validate_image_content_type? == true
end

test('banner_key == :banner_url (default)') do
  build_bluesky.send(:banner_key) == :banner_url
end

puts '--- fetch_platform_profile ---'

BLUESKY_JSON = JSON.dump(
  'did'             => 'did:plc:xyz',
  'handle'          => 'nesestra.bsky.social',
  'displayName'     => 'Nesestra',
  'description'     => 'Test bio',
  'avatar'          => 'https://cdn.bsky.app/avatar.jpg',
  'banner'          => 'https://cdn.bsky.app/banner.jpg',
  'followersCount'  => 100,
  'followsCount'    => 50,
  'postsCount'      => 200
)

test('fetch_platform_profile returns mapped hash') do
  stub_get(FakeSuccessResponse.new(BLUESKY_JSON))
  p = build_bluesky.fetch_platform_profile
  restore_get
  p[:did] == 'did:plc:xyz' && p[:handle] == 'nesestra.bsky.social' &&
    p[:display_name] == 'Nesestra' && p[:description] == 'Test bio' &&
    p[:avatar_url] == 'https://cdn.bsky.app/avatar.jpg' &&
    p[:banner_url] == 'https://cdn.bsky.app/banner.jpg' &&
    p[:followers_count] == 100 && p[:posts_count] == 200
end

test('fetch_platform_profile raises on HTTP error') do
  stub_get(FakeErrorResponse.new('', '503'))
  raised = false
  begin
    build_bluesky.fetch_platform_profile
  rescue StandardError => e
    raised = e.message.include?('503') || e.message.include?('Bluesky API error')
  end
  restore_get
  raised
end

# ============================================================
# FacebookProfileSyncer
# ============================================================

puts
puts '=== FacebookProfileSyncer ==='

def build_facebook(handle: 'headliner.cz')
  Syncers::FacebookProfileSyncer.new(
    facebook_handle: handle,
    browserless_token: 'fake-token',
    facebook_cookies: [{ name: 'c_user', value: 'x', domain: '.facebook.com' }],
    **BASE_OPTS
  )
end

puts '--- template methods ---'

test('source_handle returns facebook_handle (strips @ and URL prefix)') do
  build_facebook(handle: '@headliner.cz').source_handle == 'headliner.cz' &&
    build_facebook(handle: 'https://facebook.com/headliner.cz').source_handle == 'headliner.cz'
end

test('platform_name == "Facebook"') do
  build_facebook.platform_name == 'Facebook'
end

test('field_prefix == "fb:"') do
  build_facebook.field_prefix == 'fb:'
end

test('banner_key == :cover_url (Facebook override)') do
  build_facebook.send(:banner_key) == :cover_url
end

test('validate_image_content_type? == true') do
  build_facebook.validate_image_content_type? == true
end

puts '--- parse_facebook_profile ---'

test('extracts og:description as bio') do
  html = '<meta property="og:description" content="Headliner.cz. 1,234 like this. Skvělý zpravodajský web" />'
  p = build_facebook.send(:parse_facebook_profile, html)
  !p[:description].nil? && p[:description].include?('zpravodajský')
end

test('extracts profilePhoto URI as avatar_url') do
  html = '"profilePhoto":{"uri":"https:\/\/scontent.fbcdn.net\/avatar.jpg"}'
  p = build_facebook.send(:parse_facebook_profile, html)
  p[:avatar_url] == 'https://scontent.fbcdn.net/avatar.jpg'
end

test('extracts CoverPhoto src as cover_url') do
  html = '<div class="CoverPhoto"><img src="https://scontent.fbcdn.net/cover.jpg" /></div>'
  p = build_facebook.send(:parse_facebook_profile, html)
  p[:cover_url] == 'https://scontent.fbcdn.net/cover.jpg'
end

test('extracts website from l.facebook.com redirect link') do
  html = '<a href="https://l.facebook.com/l.php?u=https%3A%2F%2Fheadliner.cz%2F&amp;fbclid=xyz">web</a>'
  p = build_facebook.send(:parse_facebook_profile, html)
  p[:website] == 'https://headliner.cz'
end

test('filters out footer domains (messenger.com, meta.com)') do
  html = <<~HTML
    <a href="https://l.facebook.com/l.php?u=https%3A%2F%2Fmessenger.com%2F">Messenger</a>
    <a href="https://l.facebook.com/l.php?u=https%3A%2F%2Fmeta.com%2F">Meta</a>
    <a href="https://l.facebook.com/l.php?u=https%3A%2F%2Fheadliner.cz%2F">Web</a>
  HTML
  p = build_facebook.send(:parse_facebook_profile, html)
  p[:website] == 'https://headliner.cz'
end

test('empty html → all nil fields') do
  p = build_facebook.send(:parse_facebook_profile, '<html></html>')
  p[:description].nil? && p[:avatar_url].nil? && p[:cover_url].nil? && p[:website].nil?
end

puts '--- fetch_platform_profile via Browserless ---'

test('fetch_platform_profile calls post_json and parses response') do
  html = '<meta property="og:description" content="Something. 10 likes. Bio text" />' \
         '"profilePhoto":{"uri":"https:\/\/cdn\/pic.jpg"}'
  stub_post_json(FakeSuccessResponse.new(html))
  p = build_facebook.fetch_platform_profile
  restore_post_json
  p[:avatar_url] == 'https://cdn/pic.jpg' && !p[:description].nil?
end

test('fetch_platform_profile raises on Browserless error') do
  stub_post_json(FakeErrorResponse.new('', '502'))
  raised = false
  begin
    build_facebook.fetch_platform_profile
  rescue StandardError => e
    raised = e.message.include?('Browserless')
  end
  restore_post_json
  raised
end

# ============================================================
# InstagramProfileSyncer
# ============================================================

puts
puts '=== InstagramProfileSyncer ==='

def build_instagram(handle: 'formulovy_svet')
  Syncers::InstagramProfileSyncer.new(
    instagram_handle: handle,
    browserless_token: 'fake-token',
    instagram_cookies: [{ name: 'sessionid', value: 'x', domain: '.instagram.com' }],
    **BASE_OPTS
  )
end

puts '--- template methods ---'

test('source_handle strips @ and URL prefix') do
  build_instagram(handle: '@formulovy_svet').source_handle == 'formulovy_svet' &&
    build_instagram(handle: 'https://instagram.com/formulovy_svet').source_handle == 'formulovy_svet'
end

test('platform_name == "Instagram"') do
  build_instagram.platform_name == 'Instagram'
end

test('field_prefix == "ig:"') do
  build_instagram.field_prefix == 'ig:'
end

test('banner_key == :banner_url (IG has no banner)') do
  build_instagram.send(:banner_key) == :banner_url
end

test('validate_image_content_type? == true') do
  build_instagram.validate_image_content_type? == true
end

test('image_download_options includes Referer and Cookie headers') do
  opts = build_instagram.send(:image_download_options)
  opts[:headers]['Referer'] == 'https://www.instagram.com/' &&
    opts[:headers]['Cookie'].include?('sessionid=x')
end

puts '--- parse_instagram_profile ---'

test('extracts bio from JSON biography field') do
  html = '"biography":"Můj F1 web\\nDruhý řádek"'
  p = build_instagram.send(:parse_instagram_profile, html)
  p[:description].include?('F1 web') && p[:description].include?("\n")
end

test('extracts avatar from <img alt="...\'s profile picture">') do
  html = %(<img src="https://scontent.cdninstagram.com/pic.jpg" alt="formulovy_svet's profile picture" />)
  p = build_instagram.send(:parse_instagram_profile, html)
  p[:avatar_url] == 'https://scontent.cdninstagram.com/pic.jpg'
end

test('falls back to og:image (standard HTML with whitespace)') do
  html = '<meta property="og:image" content="https://scontent.cdninstagram.com/og.jpg" />'
  p = build_instagram.send(:parse_instagram_profile, html)
  p[:avatar_url] == 'https://scontent.cdninstagram.com/og.jpg'
end

test('falls back to og:image (content attribute before property)') do
  html = '<meta content="https://scontent.cdninstagram.com/og2.jpg" property="og:image" />'
  p = build_instagram.send(:parse_instagram_profile, html)
  p[:avatar_url] == 'https://scontent.cdninstagram.com/og2.jpg'
end

test('falls back to profile_pic_url_hd from JSON') do
  html = '"profile_pic_url_hd":"https:\/\/scontent\/hd.jpg"'
  p = build_instagram.send(:parse_instagram_profile, html)
  p[:avatar_url] == 'https://scontent/hd.jpg'
end

test('detects placeholder avatar (573323465) and returns nil') do
  html = '<meta property="og:image" content="https://scontent.cdninstagram.com/573323465_placeholder.jpg" />'
  p = build_instagram.send(:parse_instagram_profile, html)
  p[:avatar_url].nil?
end

test('extracts external_url as website') do
  html = '"external_url":"https:\/\/formule1.cz\/"'
  p = build_instagram.send(:parse_instagram_profile, html)
  p[:website] == 'https://formule1.cz/'
end

test('empty html → all nil fields') do
  p = build_instagram.send(:parse_instagram_profile, '<html></html>')
  p[:description].nil? && p[:avatar_url].nil? && p[:website].nil?
end

# ============================================================
# YoutubeProfileSyncer
# ============================================================

puts
puts '=== YoutubeProfileSyncer ==='

def build_youtube(handle: 'Mistrdabingu')
  Syncers::YoutubeProfileSyncer.new(youtube_handle: handle, **BASE_OPTS)
end

puts '--- template methods ---'

test('source_handle strips @ and URL prefix') do
  build_youtube(handle: '@Mistrdabingu').source_handle == 'Mistrdabingu' &&
    build_youtube(handle: 'https://youtube.com/@Mistrdabingu').source_handle == 'Mistrdabingu'
end

test('platform_name == "YouTube"') do
  build_youtube.platform_name == 'YouTube'
end

test('field_prefix == "yt:"') do
  build_youtube.field_prefix == 'yt:'
end

test('default_mentions_config type == "none"') do
  build_youtube.default_mentions_config['type'] == 'none'
end

puts '--- channel_url handle format routing ---'

test('channel_url for @handle uses /@handle') do
  build_youtube(handle: 'Mistrdabingu').send(:channel_url) == 'https://www.youtube.com/@Mistrdabingu'
end

test('channel_url for UC-id uses /channel/UCxxx') do
  build_youtube(handle: 'UCabc123').send(:channel_url) == 'https://www.youtube.com/channel/UCabc123'
end

puts '--- parse_youtube_profile (ytInitialData) ---'

YT_DATA = {
  'metadata' => {
    'channelMetadataRenderer' => {
      'description' => 'Můj YT kanál o dabingu'
    }
  },
  'header' => {
    'c4TabbedHeaderRenderer' => {
      'avatar' => {
        'thumbnails' => [
          { 'url' => 'https://yt.cdn/avatar_small.jpg', 'width' => 48, 'height' => 48 },
          { 'url' => 'https://yt.cdn/avatar_hd.jpg',    'width' => 800, 'height' => 800 }
        ]
      },
      'banner' => {
        'thumbnails' => [
          { 'url' => 'https://yt.cdn/banner_hd.jpg', 'width' => 2560, 'height' => 1440 }
        ]
      }
    }
  }
}.freeze

YT_HTML = "<html><body><script>var ytInitialData = #{JSON.dump(YT_DATA)};</script></body></html>"

test('extracts description from channelMetadataRenderer') do
  p = build_youtube.send(:parse_youtube_profile, YT_HTML)
  p[:description] == 'Můj YT kanál o dabingu'
end

test('picks highest-resolution avatar from thumbnails') do
  p = build_youtube.send(:parse_youtube_profile, YT_HTML)
  p[:avatar_url] == 'https://yt.cdn/avatar_hd.jpg'
end

test('picks highest-resolution banner from thumbnails') do
  p = build_youtube.send(:parse_youtube_profile, YT_HTML)
  p[:banner_url] == 'https://yt.cdn/banner_hd.jpg'
end

test('handle in result matches youtube_handle') do
  p = build_youtube(handle: 'Mistrdabingu').send(:parse_youtube_profile, YT_HTML)
  p[:handle] == 'Mistrdabingu'
end

puts '--- parse_youtube_profile (fallback to meta tags) ---'

test('falls back to meta description when ytInitialData missing') do
  html = '<html><meta name="description" content="Fallback bio text" /></html>'
  p = build_youtube.send(:parse_youtube_profile, html)
  p[:description] == 'Fallback bio text'
end

test('falls back to og:image when no ytInitialData avatar') do
  html = '<html><meta property="og:image" content="https://yt.cdn/og_avatar.jpg" /></html>'
  p = build_youtube.send(:parse_youtube_profile, html)
  p[:avatar_url] == 'https://yt.cdn/og_avatar.jpg'
end

test('empty html → all nil fields (handle still set)') do
  p = build_youtube.send(:parse_youtube_profile, '<html></html>')
  p[:description].nil? && p[:avatar_url].nil? && p[:banner_url].nil? && p[:handle] == 'Mistrdabingu'
end

puts '--- fetch_platform_profile ---'

test('fetch_platform_profile calls http_get and returns parsed profile') do
  stub_get(FakeSuccessResponse.new(YT_HTML))
  p = build_youtube.fetch_platform_profile
  restore_get
  p[:description] == 'Můj YT kanál o dabingu' && p[:avatar_url] == 'https://yt.cdn/avatar_hd.jpg'
end

test('fetch_platform_profile raises on HTTP error') do
  stub_get(FakeErrorResponse.new('', '404'))
  raised = false
  begin
    build_youtube.fetch_platform_profile
  rescue StandardError => e
    raised = e.message.include?('YouTube') || e.message.include?('404')
  end
  restore_get
  raised
end

puts
puts '=' * 50
puts "Passed: #{$passed}"
puts "Failed: #{$failed}"
exit($failed.zero? ? 0 : 1)
