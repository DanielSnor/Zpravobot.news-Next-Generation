#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Test Suite: Syncers::MastodonProfileUpdater
# ============================================================
#
# Unit testy pro Mastodon profile API client. Žádná síť.
# `HttpClient.get` a `HttpClient.patch_raw` se stubují přes
# `alias_method` + `define_singleton_method`.
#
# Usage:
#   ruby test/test_mastodon_profile_updater.rb
#
# ============================================================

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'json'
require 'net/http'
require 'syncers/mastodon_profile_updater'

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

# ------------------------------------------------------------
# Fake Net::HTTPResponse helpers
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

class FakeErrorResponse < Net::HTTPUnprocessableEntity
  def initialize(body, code = '422')
    super('1.1', code, 'Unprocessable Entity')
    @fake_body = body
  end

  def body
    @fake_body
  end
end

# ------------------------------------------------------------
# Stub helpers — per-method on HttpClient singleton
# ------------------------------------------------------------

def stub_get(response_or_proc)
  unless HttpClient.singleton_class.method_defined?(:__orig_get)
    HttpClient.singleton_class.send(:alias_method, :__orig_get, :get)
  end
  @last_get_args = nil
  outer = self
  HttpClient.define_singleton_method(:get) do |url, **opts|
    outer.instance_variable_set(:@last_get_args, { url: url, opts: opts })
    response_or_proc.is_a?(Proc) ? response_or_proc.call : response_or_proc
  end
end

def restore_get
  return unless HttpClient.singleton_class.method_defined?(:__orig_get)

  HttpClient.singleton_class.send(:alias_method, :get, :__orig_get)
end

def stub_patch_raw(response_or_proc)
  unless HttpClient.singleton_class.method_defined?(:__orig_patch_raw)
    HttpClient.singleton_class.send(:alias_method, :__orig_patch_raw, :patch_raw)
  end
  @last_patch_args = nil
  outer = self
  HttpClient.define_singleton_method(:patch_raw) do |uri, request|
    outer.instance_variable_set(:@last_patch_args, { uri: uri, request: request })
    response_or_proc.is_a?(Proc) ? response_or_proc.call : response_or_proc
  end
end

def restore_patch_raw
  return unless HttpClient.singleton_class.method_defined?(:__orig_patch_raw)

  HttpClient.singleton_class.send(:alias_method, :patch_raw, :__orig_patch_raw)
end

# ------------------------------------------------------------
# Tests
# ------------------------------------------------------------

INSTANCE = 'https://zpravobot.news'
TOKEN    = 'test-token-xyz'

def updater
  Syncers::MastodonProfileUpdater.new(instance_url: INSTANCE, access_token: TOKEN)
end

puts 'Testing Syncers::MastodonProfileUpdater'
puts
puts '--- fetch_fields ---'

test('happy path — returns array of {name, value}') do
  body = JSON.dump('fields' => [
    { 'name' => 'Web',     'value' => '<a href="https://x.cz">x.cz</a>' },
    { 'name' => 'Twitter', 'value' => '@foo' }
  ])
  stub_get(FakeSuccessResponse.new(body))
  fields = updater.fetch_fields
  restore_get

  fields.is_a?(Array) && fields.size == 2 &&
    fields[0][:name] == 'Web' &&
    fields[1][:name] == 'Twitter' && fields[1][:value] == '@foo'
end

test('sanitizes HTML from field values') do
  body = JSON.dump('fields' => [
    { 'name' => 'Bio', 'value' => '<p>Hello <b>world</b></p>' }
  ])
  stub_get(FakeSuccessResponse.new(body))
  fields = updater.fetch_fields
  restore_get

  fields[0][:value] !~ /<[^>]+>/ && fields[0][:value].include?('Hello') && fields[0][:value].include?('world')
end

test('missing fields key → empty array') do
  stub_get(FakeSuccessResponse.new(JSON.dump('note' => 'no fields here')))
  fields = updater.fetch_fields
  restore_get
  fields == []
end

test('empty fields array → empty result') do
  stub_get(FakeSuccessResponse.new(JSON.dump('fields' => [])))
  fields = updater.fetch_fields
  restore_get
  fields == []
end

test('non-2xx response → raises') do
  stub_get(FakeErrorResponse.new('', '401'))
  raised = false
  begin
    updater.fetch_fields
  rescue StandardError => e
    raised = e.message.include?('401')
  end
  restore_get
  raised
end

test('sends Authorization: Bearer header') do
  stub_get(FakeSuccessResponse.new(JSON.dump('fields' => [])))
  updater.fetch_fields
  restore_get
  @last_get_args[:opts][:headers]['Authorization'] == "Bearer #{TOKEN}"
end

test('GET URL is verify_credentials endpoint') do
  stub_get(FakeSuccessResponse.new(JSON.dump('fields' => [])))
  updater.fetch_fields
  restore_get
  @last_get_args[:url] == "#{INSTANCE}/api/v1/accounts/verify_credentials"
end

test('strips trailing slash from instance_url') do
  stub_get(FakeSuccessResponse.new(JSON.dump('fields' => [])))
  u = Syncers::MastodonProfileUpdater.new(instance_url: "#{INSTANCE}/", access_token: TOKEN)
  u.fetch_fields
  restore_get
  @last_get_args[:url] == "#{INSTANCE}/api/v1/accounts/verify_credentials"
end

puts
puts '--- update — url-encoded branch (no files) ---'

test('success returns {success: true, account: ...}') do
  stub_patch_raw(FakeSuccessResponse.new(JSON.dump('id' => '123', 'username' => 'bot')))
  result = updater.update({ note: 'hello' }, {})
  restore_patch_raw
  result[:success] == true && result[:account]['id'] == '123'
end

test('uses application/x-www-form-urlencoded when files empty') do
  stub_patch_raw(FakeSuccessResponse.new(JSON.dump({})))
  updater.update({ note: 'x' }, {})
  restore_patch_raw
  @last_patch_args[:request]['Content-Type'] == 'application/x-www-form-urlencoded'
end

test('urlencoded body contains params') do
  stub_patch_raw(FakeSuccessResponse.new(JSON.dump({})))
  updater.update({ note: 'hello world', display_name: 'Bot' }, {})
  restore_patch_raw
  body = @last_patch_args[:request].body
  body.include?('note=hello+world') && body.include?('display_name=Bot')
end

test('sets Authorization header') do
  stub_patch_raw(FakeSuccessResponse.new(JSON.dump({})))
  updater.update({ note: 'x' }, {})
  restore_patch_raw
  @last_patch_args[:request]['Authorization'] == "Bearer #{TOKEN}"
end

test('sets User-Agent header') do
  stub_patch_raw(FakeSuccessResponse.new(JSON.dump({})))
  updater.update({ note: 'x' }, {})
  restore_patch_raw
  @last_patch_args[:request]['User-Agent'] == HttpClient::DEFAULT_UA
end

test('PATCH URI is update_credentials endpoint') do
  stub_patch_raw(FakeSuccessResponse.new(JSON.dump({})))
  updater.update({ note: 'x' }, {})
  restore_patch_raw
  @last_patch_args[:uri].to_s == "#{INSTANCE}/api/v1/accounts/update_credentials"
end

puts
puts '--- update — multipart branch (with files) ---'

test('uses multipart/form-data when files present') do
  stub_patch_raw(FakeSuccessResponse.new(JSON.dump({})))
  files = { avatar: { data: 'BINARY', content_type: 'image/jpeg', filename: 'a.jpg' } }
  updater.update({ note: 'x' }, files)
  restore_patch_raw
  @last_patch_args[:request]['Content-Type'].start_with?('multipart/form-data; boundary=')
end

test('multipart body contains param name, file name, filename, content-type, data') do
  stub_patch_raw(FakeSuccessResponse.new(JSON.dump({})))
  files = { avatar: { data: 'BINARYDATA', content_type: 'image/png', filename: 'pic.png' } }
  updater.update({ note: 'bio text' }, files)
  restore_patch_raw
  body = @last_patch_args[:request].body
  body.include?('name="note"') && body.include?('bio text') &&
    body.include?('name="avatar"') && body.include?('filename="pic.png"') &&
    body.include?('Content-Type: image/png') && body.include?('BINARYDATA')
end

test('multipart body ends with closing boundary') do
  stub_patch_raw(FakeSuccessResponse.new(JSON.dump({})))
  files = { header: { data: 'X', content_type: 'image/jpeg', filename: 'h.jpg' } }
  updater.update({}, files)
  restore_patch_raw
  body = @last_patch_args[:request].body
  ct = @last_patch_args[:request]['Content-Type']
  boundary = ct.sub('multipart/form-data; boundary=', '')
  body.end_with?("--#{boundary}--\r\n")
end

puts
puts '--- update — error responses ---'

test('error with JSON body → parsed error field') do
  stub_patch_raw(FakeErrorResponse.new(JSON.dump('error' => 'Validation failed')))
  result = updater.update({ note: 'x' }, {})
  restore_patch_raw
  result[:success] == false && result[:error] == 'Validation failed'
end

test('error with non-JSON body → raw body as error') do
  stub_patch_raw(FakeErrorResponse.new('<html>500 Internal Server Error</html>', '500'))
  result = updater.update({ note: 'x' }, {})
  restore_patch_raw
  result[:success] == false && result[:error].include?('500 Internal Server Error')
end

test('error with empty body → error is empty string') do
  stub_patch_raw(FakeErrorResponse.new(''))
  result = updater.update({ note: 'x' }, {})
  restore_patch_raw
  result[:success] == false && result[:error] == ''
end

puts
puts '=' * 50
puts "Passed: #{$passed}"
puts "Failed: #{$failed}"
exit($failed.zero? ? 0 : 1)
