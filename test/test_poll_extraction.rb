#!/usr/bin/env ruby
# frozen_string_literal: true

# Test: Twitter Poll Extraction from Nitter HTML and Syndication API
# Run: ruby test/test_poll_extraction.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require_relative '../lib/adapters/twitter_adapter'
require_relative '../lib/services/syndication_media_fetcher'
require_relative '../lib/models/post'
require_relative '../lib/formatters/universal_formatter'

$passed = 0
$failed = 0

def test(name, expected, actual)
  if expected == actual
    puts "  ✅ #{name}"
    $passed += 1
  else
    puts "  ❌ #{name}"
    puts "    Expected: #{expected.inspect}"
    puts "    Actual:   #{actual.inspect}"
    $failed += 1
  end
end

def section(title)
  puts "\n--- #{title} ---"
end

# =============================================================================
section("Nitter: extract_poll_from_html")
# =============================================================================

adapter = Adapters::TwitterAdapter.new(
  handle: 'testuser',
  nitter_instance: 'http://xn.zpravobot.news:8080'
)

# Standard poll with 4 choices and a leader
poll_html = <<~HTML
  <div class="poll">
    <div class="poll-meter">
      <span class="poll-choice-bar" style="width: 20%; "></span>
      <span class="poll-choice-value">20%</span>
      <span class="poll-choice-option">India 🇮🇳</span>
    </div>
    <div class="poll-meter">
      <span class="poll-choice-bar" style="width: 27%; "></span>
      <span class="poll-choice-value">27%</span>
      <span class="poll-choice-option">China 🇨🇳</span>
    </div>
    <div class="poll-meter leader">
      <span class="poll-choice-bar" style="width: 28%; "></span>
      <span class="poll-choice-value">28%</span>
      <span class="poll-choice-option">European Union 🇪🇺</span>
    </div>
    <div class="poll-meter">
      <span class="poll-choice-bar" style="width: 26%; "></span>
      <span class="poll-choice-value">26%</span>
      <span class="poll-choice-option">USA 🇺🇸</span>
    </div>
    <span class="poll-info">1,782 votes • 22 hours</span>
  </div>
HTML

poll = adapter.send(:extract_poll_from_html, poll_html)

test("poll is not nil", true, !poll.nil?)
test("4 choices extracted", 4, poll[:choices].length)
test("first choice option", "India 🇮🇳", poll[:choices][0][:option])
test("first choice value", "20%", poll[:choices][0][:value])
test("first choice not leader", false, poll[:choices][0][:leader])
test("third choice is leader", true, poll[:choices][2][:leader])
test("leader option", "European Union 🇪🇺", poll[:choices][2][:option])
test("votes extracted", "1,782 votes", poll[:votes])

# 2-choice poll
poll_2_html = <<~HTML
  <div class="poll">
    <div class="poll-meter leader">
      <span class="poll-choice-bar" style="width: 65%; "></span>
      <span class="poll-choice-value">65%</span>
      <span class="poll-choice-option">Yes</span>
    </div>
    <div class="poll-meter">
      <span class="poll-choice-bar" style="width: 35%; "></span>
      <span class="poll-choice-value">35%</span>
      <span class="poll-choice-option">No</span>
    </div>
    <span class="poll-info">500 votes • Final results</span>
  </div>
HTML

poll_2 = adapter.send(:extract_poll_from_html, poll_2_html)

test("2-choice poll: 2 choices", 2, poll_2[:choices].length)
test("2-choice poll: first is leader", true, poll_2[:choices][0][:leader])
test("2-choice poll: votes", "500 votes", poll_2[:votes])

# No poll / edge cases
test("no poll returns nil", nil, adapter.send(:extract_poll_from_html, '<div class="tweet-content">Just text</div>'))
test("empty string returns nil", nil, adapter.send(:extract_poll_from_html, ''))
test("nil returns nil", nil, adapter.send(:extract_poll_from_html, nil))

# =============================================================================
section("Syndication: extract_poll_data")
# =============================================================================

fetcher = Services::SyndicationMediaFetcher.new('0')

# 4-choice poll from real API response
syndication_data = {
  'card' => {
    'name' => 'poll4choice_text_only',
    'binding_values' => {
      'choice1_label' => { 'string_value' => 'India 🇮🇳', 'type' => 'STRING' },
      'choice1_count' => { 'string_value' => '503', 'type' => 'STRING' },
      'choice2_label' => { 'string_value' => 'China 🇨🇳', 'type' => 'STRING' },
      'choice2_count' => { 'string_value' => '679', 'type' => 'STRING' },
      'choice3_label' => { 'string_value' => 'European Union 🇪🇺', 'type' => 'STRING' },
      'choice3_count' => { 'string_value' => '685', 'type' => 'STRING' },
      'choice4_label' => { 'string_value' => 'USA 🇺🇸', 'type' => 'STRING' },
      'choice4_count' => { 'string_value' => '607', 'type' => 'STRING' },
      'counts_are_final' => { 'boolean_value' => false, 'type' => 'BOOLEAN' }
    }
  }
}

spoll = fetcher.send(:extract_poll_data, syndication_data)

test("syndication poll is not nil", true, !spoll.nil?)
test("syndication 4 choices", 4, spoll[:choices].length)
test("syndication first option", "India 🇮🇳", spoll[:choices][0][:option])

# Total = 503 + 679 + 685 + 607 = 2474
# India: 503/2474 = 20.33% → 20%
test("syndication first value (percentage)", "20%", spoll[:choices][0][:value])
test("syndication first not leader", false, spoll[:choices][0][:leader])

# EU has highest count (685)
test("syndication EU is leader", true, spoll[:choices][2][:leader])
test("syndication EU value", "28%", spoll[:choices][2][:value])

test("syndication total votes", "2,474 votes", spoll[:votes])

# 2-choice poll
syndication_2 = {
  'card' => {
    'name' => 'poll2choice_text_only',
    'binding_values' => {
      'choice1_label' => { 'string_value' => 'Yes', 'type' => 'STRING' },
      'choice1_count' => { 'string_value' => '750', 'type' => 'STRING' },
      'choice2_label' => { 'string_value' => 'No', 'type' => 'STRING' },
      'choice2_count' => { 'string_value' => '250', 'type' => 'STRING' }
    }
  }
}

spoll_2 = fetcher.send(:extract_poll_data, syndication_2)

test("syndication 2-choice: 2 choices", 2, spoll_2[:choices].length)
test("syndication 2-choice: Yes is leader", true, spoll_2[:choices][0][:leader])
test("syndication 2-choice: Yes = 75%", "75%", spoll_2[:choices][0][:value])
test("syndication 2-choice: total", "1,000 votes", spoll_2[:votes])

# No card
test("no card returns nil", nil, fetcher.send(:extract_poll_data, {}))

# Non-poll card (e.g. link card)
non_poll_card = { 'card' => { 'name' => 'summary_large_image', 'binding_values' => {} } }
test("non-poll card returns nil", nil, fetcher.send(:extract_poll_data, non_poll_card))

# Zero votes edge case
zero_votes = {
  'card' => {
    'name' => 'poll2choice_text_only',
    'binding_values' => {
      'choice1_label' => { 'string_value' => 'A', 'type' => 'STRING' },
      'choice1_count' => { 'string_value' => '0', 'type' => 'STRING' },
      'choice2_label' => { 'string_value' => 'B', 'type' => 'STRING' },
      'choice2_count' => { 'string_value' => '0', 'type' => 'STRING' }
    }
  }
}

spoll_zero = fetcher.send(:extract_poll_data, zero_votes)
test("zero votes: value = 0%", "0%", spoll_zero[:choices][0][:value])
test("zero votes: no leader", false, spoll_zero[:choices][0][:leader])
test("zero votes: total", "0 votes", spoll_zero[:votes])

# =============================================================================
section("Post#has_poll?")
# =============================================================================

post_with_poll = Post.new(
  platform: 'twitter', id: '1', url: 'x', text: 'Question?',
  published_at: Time.now, author: Author.new(username: 'test'),
  poll_data: { choices: [{ option: 'A', value: '50%', leader: true }], votes: '100 votes' }
)
test("has_poll? true with poll_data", true, post_with_poll.has_poll?)

post_no_poll = Post.new(
  platform: 'twitter', id: '2', url: 'x', text: 'Normal tweet',
  published_at: Time.now, author: Author.new(username: 'test')
)
test("has_poll? false without poll_data", false, post_no_poll.has_poll?)

# =============================================================================
section("format_poll (UniversalFormatter)")
# =============================================================================

fmt = Formatters::UniversalFormatter.new(platform: :twitter)

poll_data_full = {
  choices: [
    { option: "India 🇮🇳", value: "20%", leader: false },
    { option: "China 🇨🇳", value: "27%", leader: false },
    { option: "European Union 🇪🇺", value: "28%", leader: true },
    { option: "USA 🇺🇸", value: "26%", leader: false }
  ],
  votes: "1,782 votes"
}

formatted = fmt.send(:format_poll, poll_data_full)

test("formatted starts with double newline", true, formatted.start_with?("\n\n"))
test("formatted contains 📊", true, formatted.include?("📊"))
test("formatted contains ✅ for leader", true, formatted.include?("European Union 🇪🇺 — 28% ✅"))
test("formatted contains 🗳️", true, formatted.include?("🗳️ 1,782 votes"))
test("non-leader has no ✅", false, formatted.include?("India 🇮🇳 — 20% ✅"))

# nil poll_data
test("format_poll nil returns empty", '', fmt.send(:format_poll, nil))

# Empty choices
test("format_poll empty choices returns empty", '', fmt.send(:format_poll, { choices: [] }))

# =============================================================================
section("format (full post output with poll URL)")
# =============================================================================

post_full = Post.new(
  platform: 'twitter',
  id: '1909505876543',
  url: 'https://x.com/someuser/status/1909505876543',
  text: 'Who would you want to be in charge of world order?',
  published_at: Time.now,
  author: Author.new(username: 'someuser'),
  poll_data: {
    choices: [
      { option: 'India 🇮🇳',          value: '20%', leader: false },
      { option: 'China 🇨🇳',          value: '27%', leader: false },
      { option: 'European Union 🇪🇺', value: '28%', leader: true  },
      { option: 'USA 🇺🇸',            value: '26%', leader: false }
    ],
    votes: '2,474 votes'
  }
)

full_output = fmt.format(post_full)

test("full output contains question text", true, full_output.include?('Who would you want'))
test("full output contains poll block", true, full_output.include?('📊'))
test("full output contains post URL (rewritten to xcancel.com)", true, full_output.include?('xcancel.com/someuser/status/1909505876543'))
test("full output does NOT contain x.com URL", false, full_output.include?('x.com/someuser'))

# Normal tweet without poll should NOT get URL appended (Twitter Tier 1/2 behavior unchanged)
post_no_poll_twitter = Post.new(
  platform: 'twitter',
  id: '999',
  url: 'https://x.com/someuser/status/999',
  text: 'Just a regular tweet.',
  published_at: Time.now,
  author: Author.new(username: 'someuser')
)

no_poll_output = fmt.format(post_no_poll_twitter)
test("regular tweet without poll: no URL added", false, no_poll_output.include?('xcancel.com'))

# =============================================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed > 0 ? 1 : 0)
