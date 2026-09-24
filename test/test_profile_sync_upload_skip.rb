#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Test Suite: BaseProfileSyncer — upload avataru/banneru jen při změně
# ============================================================
#
# Mastodon při každém uploadu avataru vytvoří nový soubor a starý smaže,
# i když jsou bajty stejné. Syncer proto nahrává obrázek jen tehdy, když se
# jeho SHA256 liší od posledního úspěšného uploadu. Žádná síť, žádná DB:
# `HttpClient.download` i `MastodonProfileUpdater#update` jsou stubované.
#
# Usage:
#   ruby test/test_profile_sync_upload_skip.rb
#
# ============================================================

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'tmpdir'
require 'fileutils'
require 'stringio'
require 'syncers/base_profile_syncer'

$passed = 0
$failed = 0

def test(name)
  result = yield
  if result
    $passed += 1
    puts "  ✔ #{name}"
  else
    $failed += 1
    puts "  ✘ #{name}"
  end
rescue StandardError => e
  $failed += 1
  puts "  ✘ #{name} — #{e.class}: #{e.message}"
  puts "    #{e.backtrace.first(3).join("\n    ")}"
end

def quiet
  orig = $stdout
  $stdout = StringIO.new
  yield
ensure
  $stdout = orig
end

# ------------------------------------------------------------
# Stub HttpClient.download — vrací tělo podle URL
# ------------------------------------------------------------

class FakeSuccessResponse < Net::HTTPSuccess
  def initialize(body:, content_type: 'image/jpeg')
    super('1.1', '200', 'OK')
    @fake_body = body
    @fake_headers = { 'content-type' => content_type }
  end

  def body
    @fake_body
  end

  def [](key)
    @fake_headers[key.downcase]
  end
end

$bodies = {}

HttpClient.singleton_class.send(:alias_method, :__orig_download, :download) unless HttpClient.singleton_class.method_defined?(:__orig_download)
HttpClient.define_singleton_method(:download) do |url, **_opts|
  body = $bodies[url]
  body ? FakeSuccessResponse.new(body: body) : nil
end

# ------------------------------------------------------------
# Minimální syncer: profil je pevně daný, žádná platforma
# ------------------------------------------------------------

class FakeProfileSyncer < Syncers::BaseProfileSyncer
  def initialize(profile:, **opts)
    @profile = profile
    super(mastodon_instance: 'https://mastodon.test', mastodon_token: 'token', **opts)
  end

  def source_handle = 'fake_user'
  def platform_name = 'Fake'
  def platform_key = 'twitter'
  def field_prefix = 'x:'
  def default_mentions_config = {}
  def fetch_platform_profile = @profile
end

# Updater zachytí, co by se poslalo na Mastodon; výsledek lze přepnout na selhání.
class CapturingUpdater
  attr_reader :calls
  attr_accessor :succeed

  def initialize
    @calls = []
    @succeed = true
  end

  def update(params, files)
    @calls << { params: params, files: files }
    if @succeed
      { success: true, account: { 'avatar' => 'https://mastodon.test/system/avatars/new.jpg' } }
    else
      { success: false, error: 'boom' }
    end
  end
end

def make_syncer(cache_dir, avatar_url: 'https://cdn.test/avatar.jpg', banner_url: 'https://cdn.test/banner.jpg', use_cache: true)
  profile = { handle: 'fake_user', description: 'bio', avatar_url: avatar_url, banner_url: banner_url }
  syncer = FakeProfileSyncer.new(profile: profile, cache_dir: cache_dir, use_cache: use_cache)
  updater = CapturingUpdater.new
  syncer.instance_variable_set(:@profile_updater, updater)
  [syncer, updater]
end

# Jen obrázky — bio a pole by přidávaly změny při každém běhu a zastínily by test.
def sync_images(syncer, force: false)
  quiet { syncer.sync!(sync_bio: false, sync_fields: false, force: force) }
end

Dir.mktmpdir('upload_skip') do |tmpdir|
  $bodies['https://cdn.test/avatar.jpg'] = 'AVATAR-V1'
  $bodies['https://cdn.test/banner.jpg'] = 'BANNER-V1'

  puts '--- první sync nahraje oba obrázky ---'
  dir1 = File.join(tmpdir, 'c1')
  syncer, updater = make_syncer(dir1)
  r1 = sync_images(syncer)

  test('první běh: changes obsahuje avatar i banner') { r1[:changes].sort == %w[avatar banner] }
  test('první běh: updater dostal avatar i header') do
    updater.calls.size == 1 && updater.calls[0][:files].keys.sort == %i[avatar header]
  end
  test('po úspěchu existuje záznam o uploadu avataru i banneru') do
    File.exist?(File.join(dir1, 'avatar_fake_user.twitter.uploaded')) && File.exist?(File.join(dir1, 'banner_fake_user.twitter.uploaded'))
  end

  puts
  puts '--- druhý sync se stejnými bajty nic nenahrává ---'
  r2 = sync_images(syncer)
  test('druhý běh: changes prázdné') { r2[:changes] == [] }
  test('druhý běh: updater nebyl volán') { updater.calls.size == 1 }

  puts
  puts '--- force nahraje i nezměněný obrázek ---'
  r3 = sync_images(syncer, force: true)
  test('force: changes obsahuje avatar i banner') { r3[:changes].sort == %w[avatar banner] }
  test('force: updater volán podruhé') { updater.calls.size == 2 }

  puts
  puts '--- změna bajtů avataru (nová URL) nahraje jen avatar ---'
  $bodies['https://cdn.test/avatar-v2.jpg'] = 'AVATAR-V2'
  syncer.instance_variable_get(:@profile)[:avatar_url] = 'https://cdn.test/avatar-v2.jpg'
  r4 = sync_images(syncer)
  test('změna: changes == [avatar]') { r4[:changes] == %w[avatar] }
  test('změna: updater dostal jen avatar') { updater.calls.last[:files].keys == %i[avatar] }
  test('změna: záznam avataru nese digest nové verze') do
    File.read(File.join(dir1, 'avatar_fake_user.twitter.uploaded')) == Syncers::ImageCacheManager.digest('AVATAR-V2')
  end

  puts
  puts '--- stejné bajty pod jinou URL se nenahrávají (digest nezávisí na URL) ---'
  $bodies['https://cdn.test/avatar-v2-copy.jpg'] = 'AVATAR-V2'
  syncer.instance_variable_get(:@profile)[:avatar_url] = 'https://cdn.test/avatar-v2-copy.jpg'
  r5 = sync_images(syncer)
  test('kopie: changes prázdné') { r5[:changes] == [] }

  puts
  puts '--- neúspěšný upload záznam nezapíše, další běh zkusí znovu ---'
  dir2 = File.join(tmpdir, 'c2')
  syncer2, updater2 = make_syncer(dir2)
  updater2.succeed = false
  sync_images(syncer2)
  test('po selhání žádný záznam o uploadu') { !File.exist?(File.join(dir2, 'avatar_fake_user.twitter.uploaded')) }
  updater2.succeed = true
  r6 = sync_images(syncer2)
  test('další běh po selhání nahrává znovu') { r6[:changes].sort == %w[avatar banner] && updater2.calls.size == 2 }

  puts
  puts '--- bez cache se nahrává vždy ---'
  dir3 = File.join(tmpdir, 'c3')
  syncer3, updater3 = make_syncer(dir3, use_cache: false)
  sync_images(syncer3)
  r7 = sync_images(syncer3)
  test('use_cache: false → druhý běh nahrává') { r7[:changes].sort == %w[avatar banner] && updater3.calls.size == 2 }

  puts
  puts '--- přechod: cache soubor ze starého kódu (před UPLOAD_RECORDS_SINCE) platí za nahraný ---'
  dir4 = File.join(tmpdir, 'c4')
  syncer4, updater4 = make_syncer(dir4)
  # naplnit cache bez uploadu a antedatovat ji před zavedení záznamů
  syncer4.instance_variable_get(:@image_cache).download_image_cached('https://cdn.test/avatar.jpg', 'avatar')
  syncer4.instance_variable_get(:@image_cache).download_image_cached('https://cdn.test/banner.jpg', 'banner')
  old = Syncers::ImageCacheManager::UPLOAD_RECORDS_SINCE - 3600
  Dir.glob(File.join(dir4, '*')).each { |f| File.utime(old, old, f) }
  r9 = sync_images(syncer4)
  test('starý cache soubor bez záznamu: nic se nenahrává') { r9[:changes] == [] && updater4.calls.empty? }
  test('starý cache soubor bez záznamu: záznam se dopíše') { File.exist?(File.join(dir4, 'avatar_fake_user.twitter.uploaded')) }

  puts
  puts '--- nový cache soubor bez záznamu (selhaný upload) se nahrává ---'
  dir5 = File.join(tmpdir, 'c5')
  syncer5, updater5 = make_syncer(dir5)
  syncer5.instance_variable_get(:@image_cache).download_image_cached('https://cdn.test/avatar.jpg', 'avatar')
  syncer5.instance_variable_get(:@image_cache).download_image_cached('https://cdn.test/banner.jpg', 'banner')
  r10 = sync_images(syncer5)
  test('nový cache soubor bez záznamu: nahrává se') { r10[:changes].sort == %w[avatar banner] && updater5.calls.size == 1 }

  puts
  puts '--- záznam nese platformu: jiný scope pro stejný handle se nesdílí ---'
  other = Syncers::ImageCacheManager.new(source_handle: 'fake_user', cache_dir: dir1, use_cache: true, upload_scope: 'bluesky')
  test('scope bluesky nevidí záznam scope twitter') { other.uploaded_digest('avatar').nil? }

  puts
  puts '--- clear_cache zahodí i záznam o uploadu ---'
  Syncers::ImageCacheManager.clear_cache('fake_user', cache_dir: dir1)
  test('záznamy smazány') { Dir.glob(File.join(dir1, '*.uploaded')).empty? }
  r8 = sync_images(syncer)
  test('po clear_cache se nahrává znovu') { r8[:changes].sort == %w[avatar banner] }
end

puts
puts '=' * 50
puts "Passed: #{$passed}"
puts "Failed: #{$failed}"
exit($failed.zero? ? 0 : 1)
