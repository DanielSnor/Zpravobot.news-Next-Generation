#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Test Suite: Zpravobot Týdeník — ZpravobotStats
# ============================================================
#
# Covers: SkokanDetector, StatsPostFormatter
# No DB, no network — pure unit tests.
#
# Usage:
#   ruby test/test_zpravobot_stats.rb
#   ruby test/test_zpravobot_stats.rb --verbose
#
# ============================================================

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
$verbose = ARGV.include?('--verbose')

require 'date'
require_relative '../lib/stats/skokan_detector'
require_relative '../lib/stats/stats_post_formatter'

puts "=" * 60
puts "  ZpravobotStats Tests"
puts "=" * 60
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

def test_nil(name, actual)
  test(name, nil, actual)
end

def test_not_nil(name, actual)
  if !actual.nil?
    puts "  \e[32m\u2713\e[0m #{name}"
    $passed += 1
  else
    puts "  \e[31m\u2717\e[0m #{name} — expected non-nil, got nil"
    $failed += 1
  end
end

def test_includes(name, substring, actual)
  if actual.to_s.include?(substring)
    puts "  \e[32m\u2713\e[0m #{name}"
    $passed += 1
  else
    puts "  \e[31m\u2717\e[0m #{name}"
    puts "    Expected to include: #{substring.inspect}"
    puts "    Actual (excerpt): #{actual.to_s[0, 300].inspect}"
    $failed += 1
  end
end

def test_excludes(name, substring, actual)
  if !actual.to_s.include?(substring)
    puts "  \e[32m\u2713\e[0m #{name}"
    $passed += 1
  else
    puts "  \e[31m\u2717\e[0m #{name}"
    puts "    Expected NOT to include: #{substring.inspect}"
    puts "    Actual (excerpt): #{actual.to_s[0, 300].inspect}"
    $failed += 1
  end
end

def section(title)
  puts
  puts "--- #{title} ---"
end

# ============================================================
# SkokanDetector — returns Hash { activity:, followers: }
# ============================================================
section("SkokanDetector — return structure")

detector = Stats::SkokanDetector.new
posts = { 'ct24' => { this_week: 80, last_week: 40 } }
result = detector.detect(posts, nil, {})
test("returns Hash", Hash, result.class)
test("has :activity key", true, result.key?(:activity))
test("has :followers key", true, result.key?(:followers))

section("SkokanDetector — activity skokan (MIN_POSTS_PREV = 20)")

posts_qualify = {
  'ct24'  => { this_week: 80, last_week: 40 },   # 40 >= 20, +100% — winner
  'idnes' => { this_week: 50, last_week: 30 }    # 30 >= 20, +67%
}
r = detector.detect(posts_qualify, nil, {})
test_not_nil("activity detected when last_week >= MIN", r[:activity])
test("picks account with highest relative gain", 'ct24', r.dig(:activity, :account))
test("type is :activity", :activity, r.dig(:activity, :type))
test("description has arrow", true, r.dig(:activity, :description)&.include?('→'))

section("SkokanDetector — newcomer filter (last_week < MIN_POSTS_PREV=20)")

posts_new = {
  'newcomer' => { this_week: 100, last_week: 18 },  # 18 < 20 → filtered
  'veteran'  => { this_week: 40,  last_week: 20 }   # 20 >= 20, +100%
}
r = detector.detect(posts_new, nil, {})
test("newcomer filtered (last_week=18 < MIN=20)", 'veteran', r.dig(:activity, :account))

section("SkokanDetector — activity nil when no qualifiers")

posts_down = { 'bot' => { this_week: 5, last_week: 25 } }  # declining
r = detector.detect(posts_down, nil, {})
test_nil("activity nil when declining", r[:activity])

posts_small = { 'tiny' => { this_week: 30, last_week: 15 } }  # 15 < 20
r = detector.detect(posts_small, nil, {})
test_nil("activity nil when all below MIN", r[:activity])

section("SkokanDetector — followers skokan (with previous snapshot)")

mastodon = {
  'ct24'  => { followers: 1500, statuses: 0 },
  'idnes' => { followers:  810, statuses: 0 }
}
snapshot = {
  'ct24'  => { followers: 1200 },  # +300
  'idnes' => { followers:  800 }   # +10
}
r = detector.detect({}, snapshot, mastodon)
test_not_nil("followers detected with snapshot", r[:followers])
test("picks account with highest absolute gain", 'ct24', r.dig(:followers, :account))
test("type is :followers", :followers, r.dig(:followers, :type))
test("description includes sledujících", true, r.dig(:followers, :description)&.include?('sledujících'))

section("SkokanDetector — followers nil without snapshot")

r = detector.detect({}, nil, mastodon)
test_nil("followers nil when no previous snapshot", r[:followers])

r = detector.detect({}, {}, mastodon)
test_nil("followers nil when empty previous snapshot", r[:followers])

section("SkokanDetector — both active simultaneously")

posts_both = { 'ct24' => { this_week: 80, last_week: 40 } }
r = detector.detect(posts_both, snapshot, mastodon)
test_not_nil("both activity present", r[:activity])
test_not_nil("both followers present", r[:followers])

section("SkokanDetector — empty inputs")

r = detector.detect({}, nil, {})
test_nil("activity nil on empty", r[:activity])
test_nil("followers nil on empty", r[:followers])

# ============================================================
# StatsPostFormatter
# ============================================================

def sample_data(lang: 'cz', skokan: nil)
  skokan ||= {
    activity:  { type: :activity, account: 'ct24', this_week: 80, last_week: 40, relative_pct: 100, description: '40 → 80 postů (+100%)' },
    followers: { type: :followers, account: 'enkocz', current: 1000, previous: 900, gain: 100, relative_pct: 11, description: '900 → 1000 sledujících (+100)' }
  }
  {
    lang:    lang,
    week_number: 13,
    date_from:   Date.new(2026, 3, 23),
    date_to:     Date.new(2026, 3, 29),
    posts_per_account: {
      'ct24'      => { this_week: 80, last_week: 40 },
      'idnescz'   => { this_week: 63, last_week: 58 },
      'aktualne'  => { this_week: 51, last_week: 49 },
      'novinky'   => { this_week: 38, last_week: 36 },
      'ihned'     => { this_week: 22, last_week: 20 },
      'denik'     => { this_week: 18, last_week: 15 },
      'ct1'       => { this_week: 15, last_week: 14 },
      'ct24sport' => { this_week: 12, last_week: 11 },
      'forbes'    => { this_week:  9, last_week:  8 },
      'e15'       => { this_week:  7, last_week:  6 }
    },
    mastodon_stats: {
      'ct24'      => { followers: 4821, statuses: 52300 },
      'idnescz'   => { followers: 3102, statuses: 31000 },
      'aktualne'  => { followers: 2450, statuses: 24500 },
      'novinky'   => { followers: 1890, statuses: 18900 },
      'ihned'     => { followers:  987, statuses:  9870 },
      'denik'     => { followers:  800, statuses:  8000 },
      'ct1'       => { followers:  650, statuses:  6500 },
      'ct24sport' => { followers:  500, statuses:  5000 },
      'forbes'    => { followers:  400, statuses:  4000 },
      'e15'       => { followers:  300, statuses:  3000 }
    },
    category_stats: [
      { category: 'news',     posts: 487, accounts: 28 },
      { category: 'politics', posts: 312, accounts: 19 },
      { category: 'sport',    posts: 198, accounts: 14 },
      { category: 'science',  posts: 102, accounts:  9 },
      { category: 'tech',     posts:  84, accounts:  7 },
      { category: 'economy',  posts:  70, accounts:  5 },
      { category: 'culture',  posts:  55, accounts:  4 }
    ],
    skokan: skokan
  }
end

formatter = Stats::StatsPostFormatter.new

section("StatsPostFormatter — header")

post = formatter.format(sample_data(lang: 'cs'))
test_includes("header has #ZpravobotTOP10", '#ZpravobotTOP10', post)
test_includes("header has CZ flag", '🇨🇿', post)
test_includes("header has week number", 'týden 13', post)
test_includes("header has year", '2026', post)

post_sk = formatter.format(sample_data(lang: 'sk'))
test_includes("SK header has SK flag", '🇸🇰', post_sk)

section("StatsPostFormatter — skokan section")

post = formatter.format(sample_data(lang: 'cs'))
test_includes("activity skokan label present",  'Skokan aktivity', post)
test_includes("followers skokan label present", 'Skokan followers', post)
test_includes("activity account handle",  '@ct24', post)
test_includes("followers account handle", '@enkocz', post)

no_skokan = sample_data(skokan: { activity: nil, followers: nil })
post_ns = formatter.format(no_skokan)
test_excludes("no skokan lines when both nil", 'Skokan', post_ns)

only_activity = sample_data(skokan: {
  activity:  { type: :activity, account: 'ct24', description: '40 → 80 postů (+100%)' },
  followers: nil
})
post_oa = formatter.format(only_activity)
test_includes("activity-only skokan shows",     'Skokan aktivity', post_oa)
test_excludes("no followers skokan when nil",   'Skokan followers', post_oa)

section("StatsPostFormatter — top accounts section")

post = formatter.format(sample_data)
test_includes("top accounts header", '🏆', post)
test_includes("gold medal first",    '🥇', post)
test_includes("silver medal",        '🥈', post)
test_includes("bronze medal",        '🥉', post)
test_includes("top account handle",  '@ct24', post)
test_includes("post count present",  '80 postů', post)
test_includes("trend arrow up",      '↑', post)

section("StatsPostFormatter — top followers section")

test_includes("followers header",     '👥', post)
test_includes("top follower handle",  '@ct24', post)
test_includes("follower count",       '4821 sledujících', post)

section("StatsPostFormatter — top categories section")

test_includes("categories header",   '🏷', post)
test_includes("top category",        'news', post)
test_includes("botů suffix",         'botů', post)

section("StatsPostFormatter — footer")

test_includes("footer has zpravobot.news", 'zpravobot.news', post)

section("StatsPostFormatter — post length under 2500")

post = formatter.format(sample_data(lang: 'cs'))
test("CS post under 2500 chars", true, post.length <= 2500)
puts "    (actual: #{post.length} znaků)"

post_sk = formatter.format(sample_data(lang: 'sk'))
test("SK post under 2500 chars", true, post_sk.length <= 2500)

section("StatsPostFormatter — auto-truncate when too long")

long_accts = {}
50.times { |i| long_accts["longaccountname_bot_#{i}"] = { this_week: 100 - i, last_week: 80 - i } }
long_masto = long_accts.transform_values { |_| { followers: rand(1000), statuses: 0 } }
long_cats  = 20.times.map { |i| { category: "category_#{i}", posts: 100 - i, accounts: 5 } }

data_long = sample_data.merge(
  posts_per_account: long_accts,
  mastodon_stats:    long_masto,
  category_stats:    long_cats
)
post_long = formatter.format(data_long)
test("auto-truncated post under 2500", true, post_long.length <= 2500)
test_includes("auto-truncated still has header", '#ZpravobotTOP10', post_long)
test_includes("auto-truncated still has footer", 'zpravobot.news', post_long)

section("StatsPostFormatter — empty inputs graceful")

empty_data = sample_data.merge(
  posts_per_account: {},
  mastodon_stats:    {},
  category_stats:    [],
  skokan:            { activity: nil, followers: nil }
)
post_empty = formatter.format(empty_data)
test_includes("empty still produces header",   '#ZpravobotTOP10', post_empty)
test_includes("empty still produces footer",   'zpravobot.news', post_empty)
test("empty post under 2500", true, post_empty.length <= 2500)

section("StatsPostFormatter — trend arrows")

data_up = sample_data.merge(
  posts_per_account: { 'bot' => { this_week: 120, last_week: 100 } },
  mastodon_stats:    { 'bot' => { followers: 500, statuses: 0 } }
)
test_includes("positive trend ↑", '↑', formatter.format(data_up))

data_down = sample_data.merge(
  posts_per_account: { 'bot' => { this_week: 80, last_week: 100 } },
  mastodon_stats:    { 'bot' => { followers: 500, statuses: 0 } }
)
test_includes("negative trend ↓", '↓', formatter.format(data_down))

# ============================================================
# Summary
# ============================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
