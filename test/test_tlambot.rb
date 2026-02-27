#!/usr/bin/env ruby
# frozen_string_literal: true

# Test TlambotWebhookHandler — payload parsing, signature verification,
# mention-based routing, text cleaning. All offline, no HTTP.
# Run: ruby test/test_tlambot.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/broadcast/tlambot_webhook_handler'
require_relative '../lib/publishers/mastodon_publisher'

puts '=' * 60
puts 'Tlambot Tests (offline)'
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

def test_raises(name, exception_class, &block)
  block.call
  puts "  \e[31m\u2717\e[0m #{name} (no exception raised)"
  $failed += 1
rescue exception_class
  puts "  \e[32m\u2713\e[0m #{name}"
  $passed += 1
rescue StandardError => e
  puts "  \e[31m\u2717\e[0m #{name}"
  puts "    Expected: #{exception_class}"
  puts "    Got:      #{e.class}: #{e.message}"
  $failed += 1
end

def section(title)
  puts
  puts "--- #{title} ---"
end

# ============================================================
# Constants
# ============================================================

handler = Broadcast::TlambotWebhookHandler.new(webhook_secret: 'test_secret_key')

section('Constants')

test('TRIGGER_ACCOUNT', 'tlambot', Broadcast::TlambotWebhookHandler::TRIGGER_ACCOUNT)
test('ZPRAVOBOT_KEYWORD', 'zpravobot', Broadcast::TlambotWebhookHandler::ZPRAVOBOT_KEYWORD)

# ============================================================
# verify_signature
# ============================================================

section('verify_signature')

# Compute a valid signature
require 'openssl'
test_body = '{"event":"status.created"}'
valid_sig = 'sha256=' + OpenSSL::HMAC.hexdigest('SHA256', 'test_secret_key', test_body)

test('valid signature returns true',
     true, handler.verify_signature(test_body, valid_sig))

test('invalid signature returns false',
     false, handler.verify_signature(test_body, 'sha256=0000000000000000000000000000000000000000000000000000000000000000'))

test('missing prefix returns false',
     false, handler.verify_signature(test_body, 'invalid_header'))

test('nil header returns false',
     false, handler.verify_signature(test_body, nil))

test('empty body with valid sig',
     true, handler.verify_signature('', 'sha256=' + OpenSSL::HMAC.hexdigest('SHA256', 'test_secret_key', '')))

# Handler with empty secret should reject
handler_no_secret = Broadcast::TlambotWebhookHandler.new(webhook_secret: '')
test('empty secret rejects all',
     false, handler_no_secret.verify_signature(test_body, valid_sig))

# ============================================================
# extract_targets — mention-based routing
# ============================================================

section('extract_targets')

test('no mentions = broadcast all',
     { target: 'all' },
     handler.extract_targets([]))

test('only tlambot mention = broadcast all',
     { target: 'all' },
     handler.extract_targets([{ username: 'tlambot' }]))

test('@zpravobot = zpravobot target',
     { target: 'zpravobot' },
     handler.extract_targets([
       { username: 'tlambot' },
       { username: 'zpravobot' }
     ]))

test('single account target',
     { target: 'accounts', accounts: ['jedenbot'] },
     handler.extract_targets([
       { username: 'tlambot' },
       { username: 'jedenbot' }
     ]))

test('multiple account targets',
     { target: 'accounts', accounts: ['jedenbot', 'druhy'] },
     handler.extract_targets([
       { username: 'tlambot' },
       { username: 'jedenbot' },
       { username: 'druhy' }
     ]))

test('@zpravobot + specific accounts = accounts win',
     { target: 'accounts', accounts: ['jedenbot'] },
     handler.extract_targets([
       { username: 'tlambot' },
       { username: 'zpravobot' },
       { username: 'jedenbot' }
     ]))

test('case insensitive trigger',
     { target: 'all' },
     handler.extract_targets([{ username: 'Tlambot' }]))

test('nil username is filtered',
     { target: 'all' },
     handler.extract_targets([{ username: nil }]))

# ============================================================
# clean_broadcast_text
# ============================================================

section('clean_broadcast_text')

test('strips tlambot mention from HTML',
     'Hello world',
     handler.clean_broadcast_text(
       '<p><span class="h-card"><a href="https://zpravobot.news/@tlambot" class="u-url mention">@<span>tlambot</span></a></span> Hello world</p>',
       [{ username: 'tlambot' }]
     ))

test('strips tlambot + target mention',
     'Hello world',
     handler.clean_broadcast_text(
       '<p><span class="h-card">@<span>tlambot</span></span> <span class="h-card">@<span>jedenbot</span></span> Hello world</p>',
       [{ username: 'tlambot' }, { username: 'jedenbot' }]
     ))

test('strips zpravobot keyword mention',
     'Hello world',
     handler.clean_broadcast_text(
       '<p><span class="h-card">@<span>tlambot</span></span> <span class="h-card">@<span>zpravobot</span></span> Hello world</p>',
       [{ username: 'tlambot' }, { username: 'zpravobot' }]
     ))

test('preserves text without mentions',
     'Just a message',
     handler.clean_broadcast_text('<p>Just a message</p>', []))

test('handles empty HTML',
     '',
     handler.clean_broadcast_text('', []))

test('normalizes multiple spaces',
     'Hello world',
     handler.clean_broadcast_text('<p>  Hello   world  </p>', []))

# ============================================================
# parse — full payload
# ============================================================

section('parse')

test('ignores non-status.created event',
     nil,
     handler.parse({ event: 'status.deleted', object: {} }))

test('ignores nil object',
     nil,
     handler.parse({ event: 'status.created', object: nil }))

test('ignores non-tlambot account',
     nil,
     handler.parse({
       event: 'status.created',
       object: {
         id: '1', account: { username: 'someoneelse' },
         content: '<p>hi</p>', mentions: [], media_attachments: [],
         reblog: nil, in_reply_to_id: nil
       }
     }))

test('ignores reblogs',
     nil,
     handler.parse({
       event: 'status.created',
       object: {
         id: '1', account: { username: 'tlambot' },
         content: '<p>hi</p>', mentions: [], media_attachments: [],
         reblog: { id: '99' }, in_reply_to_id: nil
       }
     }))

test('ignores replies',
     nil,
     handler.parse({
       event: 'status.created',
       object: {
         id: '1', account: { username: 'tlambot' },
         content: '<p>hi</p>', mentions: [], media_attachments: [],
         reblog: nil, in_reply_to_id: '42'
       }
     }))

test('ignores empty text after mention stripping',
     nil,
     handler.parse({
       event: 'status.created',
       object: {
         id: '1', account: { username: 'tlambot' },
         content: '<p><span class="h-card">@<span>tlambot</span></span></p>',
         visibility: 'public',
         mentions: [{ username: 'tlambot' }],
         media_attachments: [],
         reblog: nil, in_reply_to_id: nil
       }
     }))

# Valid payload — broadcast all
valid_payload = {
  event: 'status.created',
  object: {
    id: '12345',
    account: { username: 'tlambot' },
    content: '<p>Broadcast message</p>',
    visibility: 'public',
    mentions: [],
    media_attachments: [],
    reblog: nil,
    in_reply_to_id: nil,
    created_at: '2026-02-13T10:00:00Z'
  }
}

result = handler.parse(valid_payload)
test('valid payload returns Hash', true, result.is_a?(Hash))
test('status_id extracted', '12345', result&.dig(:status_id))
test('text cleaned', 'Broadcast message', result&.dig(:text))
test('visibility preserved', 'public', result&.dig(:visibility))
test('routing = all (no mentions)', { target: 'all' }, result&.dig(:routing))
test('trigger_account set', 'tlambot', result&.dig(:trigger_account))
test('empty media', [], result&.dig(:media_items))

# Valid payload — with @zpravobot routing
zpravobot_payload = {
  event: 'status.created',
  object: {
    id: '12346',
    account: { username: 'tlambot' },
    content: '<p><span class="h-card">@<span>tlambot</span></span> <span class="h-card">@<span>zpravobot</span></span> Domain only message</p>',
    visibility: 'unlisted',
    mentions: [{ username: 'tlambot' }, { username: 'zpravobot' }],
    media_attachments: [],
    reblog: nil, in_reply_to_id: nil
  }
}

zp_result = handler.parse(zpravobot_payload)
test('zpravobot routing', { target: 'zpravobot' }, zp_result&.dig(:routing))
test('zpravobot text clean', 'Domain only message', zp_result&.dig(:text))
test('visibility from toot preserved in parse', 'unlisted', zp_result&.dig(:visibility))

# Valid payload — with specific account
account_payload = {
  event: 'status.created',
  object: {
    id: '12347',
    account: { username: 'tlambot' },
    content: '<p><span class="h-card">@<span>tlambot</span></span> <span class="h-card">@<span>jedenbot</span></span> Targeted message</p>',
    visibility: 'public',
    mentions: [{ username: 'tlambot' }, { username: 'jedenbot' }],
    media_attachments: [],
    reblog: nil, in_reply_to_id: nil
  }
}

acc_result = handler.parse(account_payload)
test('account routing', { target: 'accounts', accounts: ['jedenbot'] }, acc_result&.dig(:routing))
test('account text clean', 'Targeted message', acc_result&.dig(:text))

# Valid payload — with media
media_payload = {
  event: 'status.created',
  object: {
    id: '12348',
    account: { username: 'tlambot' },
    content: '<p>Message with image</p>',
    visibility: 'public',
    mentions: [],
    media_attachments: [
      { url: 'https://zpravobot.news/media/image.jpg', description: 'Alt text', type: 'image' },
      { url: 'https://zpravobot.news/media/video.mp4', description: nil, type: 'video' }
    ],
    reblog: nil, in_reply_to_id: nil
  }
}

media_result = handler.parse(media_payload)
test('media items count', 2, media_result&.dig(:media_items)&.size)
test('media item url', 'https://zpravobot.news/media/image.jpg', media_result&.dig(:media_items, 0, :url))
test('media item description', 'Alt text', media_result&.dig(:media_items, 0, :description))
test('media item type', 'image', media_result&.dig(:media_items, 0, :type))

# Media with nil url is filtered
nil_url_payload = {
  event: 'status.created',
  object: {
    id: '12349',
    account: { username: 'tlambot' },
    content: '<p>Message</p>',
    visibility: 'public',
    mentions: [],
    media_attachments: [
      { url: nil, description: 'No url', type: 'image' },
      { url: 'https://example.com/ok.jpg', description: nil, type: 'image' }
    ],
    reblog: nil, in_reply_to_id: nil
  }
}

nil_result = handler.parse(nil_url_payload)
test('nil url media filtered', 1, nil_result&.dig(:media_items)&.size)

# ============================================================
# broadcast_visibility override
# ============================================================
# The TlambotQueueProcessor reads broadcast_visibility from config
# and overrides the toot's visibility for published broadcasts.
# Here we verify that parse() preserves the original visibility
# (the override happens in the queue processor, not the handler).

section('broadcast_visibility')

# Tlambot toots as unlisted, but broadcast should go as public
unlisted_payload = {
  event: 'status.created',
  object: {
    id: '12350',
    account: { username: 'tlambot' },
    content: '<p>Unlisted toot for broadcast</p>',
    visibility: 'unlisted',
    mentions: [],
    media_attachments: [],
    reblog: nil, in_reply_to_id: nil
  }
}

unlisted_result = handler.parse(unlisted_payload)
test('parse preserves unlisted visibility',
     'unlisted', unlisted_result&.dig(:visibility))

# Private (followers-only) toot
private_payload = {
  event: 'status.created',
  object: {
    id: '12351',
    account: { username: 'tlambot' },
    content: '<p>Private toot for broadcast</p>',
    visibility: 'private',
    mentions: [],
    media_attachments: [],
    reblog: nil, in_reply_to_id: nil
  }
}

private_result = handler.parse(private_payload)
test('parse preserves private visibility',
     'private', private_result&.dig(:visibility))

# Verify config default has broadcast_visibility
# (the override logic is in TlambotQueueProcessor#resolve_broadcast_visibility)
test('broadcast_visibility config key exists in broadcast.yml',
     true, File.read(File.expand_path('../config/broadcast.yml', __dir__)).include?('broadcast_visibility'))

# ============================================================
# favourite_status — ArgumentError validation
# ============================================================

section('favourite_status validation')

# We can't test actual API calls, but we can test argument validation
# This tests the code path in MastodonPublisher
publisher = Publishers::MastodonPublisher.new(
  instance_url: 'https://test.example.com',
  access_token: 'fake_token'
)

test_raises('favourite_status raises on nil', ArgumentError) do
  publisher.favourite_status(nil)
end

test_raises('favourite_status raises on empty string', ArgumentError) do
  publisher.favourite_status('')
end

# ============================================================
# Summary
# ============================================================

puts
puts '=' * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts '=' * 60

exit($failed > 0 ? 1 : 0)
