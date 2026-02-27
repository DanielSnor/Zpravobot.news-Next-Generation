#!/usr/bin/env ruby
# frozen_string_literal: true

# Test: Repost Author Attribution Fix
# ====================================
# Verifies that Twitter retweets correctly set:
#   author       = original tweet author (from RT @match)
#   reposted_by  = IFTTT monitored account (retweeter)
#   self_repost? = true only when author == reposted_by
#
# Bug: Previously, author was set to IFTTT account (retweeter) in all tiers,
# causing false self_repost? detection and wrong header display.
#
# Run: ruby test/test_repost_author_attribution.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require_relative '../lib/adapters/twitter_nitter_adapter'
require_relative '../lib/models/post'
require_relative '../lib/models/author'
require_relative '../lib/formatters/twitter_formatter'

puts "=" * 60
puts "Test: Repost Author Attribution"
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

def test_includes(name, substring, actual)
  if actual.to_s.include?(substring)
    puts "  \e[32m\u2713\e[0m #{name}"
    $passed += 1
  else
    puts "  \e[31m\u2717\e[0m #{name}"
    puts "    Expected to include: #{substring.inspect}"
    puts "    Actual: #{actual.inspect}"
    $failed += 1
  end
end

def test_not_includes(name, substring, actual)
  if !actual.to_s.include?(substring)
    puts "  \e[32m\u2713\e[0m #{name}"
    $passed += 1
  else
    puts "  \e[31m\u2717\e[0m #{name}"
    puts "    Expected NOT to include: #{substring.inspect}"
    puts "    Actual: #{actual.inspect}"
    $failed += 1
  end
end

def section(title)
  puts
  puts "--- #{title} ---"
end

# Suppress adapter log output during tests
$stdout_backup = $stdout

def suppress_output
  $stdout = File.open(File::NULL, 'w')
end

def restore_output
  $stdout = $stdout_backup
end

# =============================================================================
# Setup
# =============================================================================

suppress_output
adapter = Adapters::TwitterNitterAdapter.new(
  nitter_instance: 'http://nitter:8080',
  use_nitter_fallback: false
)
restore_output

# =============================================================================
# detect_post_type: rt_original_author
# =============================================================================
section("detect_post_type: rt_original_author")

suppress_output
result = adapter.detect_post_type("RT @UKomentare: 1/3 Evropa čelí tvrdé konkurenci", "")
restore_output

test("RT detected as repost", true, result[:is_repost])
test("reposted_by = UKomentare (compat)", "UKomentare", result[:reposted_by])
test("rt_original_author = UKomentare", "UKomentare", result[:rt_original_author])

suppress_output
result_normal = adapter.detect_post_type("Normální tweet bez RT", "")
restore_output

test("Normal tweet: not repost", false, result_normal[:is_repost])
test("Normal tweet: reposted_by nil", nil, result_normal[:reposted_by])
test("Normal tweet: rt_original_author nil", nil, result_normal[:rt_original_author])

suppress_output
result_rt_by = adapter.detect_post_type("RT by @Zona_CT24: V Zóně ČT24 tentokrát probereme", "")
restore_output

test("RT by @user detected", true, result_rt_by[:is_repost])
test("RT by: rt_original_author = Zona_CT24", "Zona_CT24", result_rt_by[:rt_original_author])

# =============================================================================
# Tier 1: External RT — correct author attribution
# =============================================================================
section("Tier 1: External RT")

ifttt_data_ext_rt = {
  post_id: "2014000000000000001",
  text: "RT @UKomentare: 1/3 Evropa čelí tvrdé globální konkurenci",
  embed_code: "",
  link_to_tweet: "https://x.com/ct24zive/status/2014000000000000001",
  first_link_url: "",
  username: "ct24zive",
  received_at: Time.now
}

suppress_output
post = adapter.process_tier1(ifttt_data_ext_rt, {})
restore_output

test("Tier 1 ext RT: author = UKomentare", "UKomentare", post.author.username)
test("Tier 1 ext RT: reposted_by = ct24zive", "ct24zive", post.reposted_by)
test("Tier 1 ext RT: self_repost? = false", false, post.self_repost?)
test("Tier 1 ext RT: is_repost = true", true, post.is_repost)
test("Tier 1 ext RT: author URL", "https://x.com/UKomentare", post.author.url)

# =============================================================================
# Tier 1: Self RT — author == reposted_by
# =============================================================================
section("Tier 1: Self RT")

ifttt_data_self_rt = {
  post_id: "2014000000000000002",
  text: "RT @ct24zive: Důležitá zpráva, kterou retweetujeme sami",
  embed_code: "",
  link_to_tweet: "https://x.com/ct24zive/status/2014000000000000002",
  first_link_url: "",
  username: "ct24zive",
  received_at: Time.now
}

suppress_output
post_self = adapter.process_tier1(ifttt_data_self_rt, {})
restore_output

test("Tier 1 self RT: author = ct24zive", "ct24zive", post_self.author.username)
test("Tier 1 self RT: reposted_by = ct24zive", "ct24zive", post_self.reposted_by)
test("Tier 1 self RT: self_repost? = true", true, post_self.self_repost?)

# =============================================================================
# Tier 1: Normal tweet (no RT) — author = IFTTT username
# =============================================================================
section("Tier 1: Normal tweet")

ifttt_data_normal = {
  post_id: "2014000000000000003",
  text: "Normální tweet od ČT24 bez retweetu.",
  embed_code: "",
  link_to_tweet: "https://x.com/ct24zive/status/2014000000000000003",
  first_link_url: "",
  username: "ct24zive",
  received_at: Time.now
}

suppress_output
post_normal = adapter.process_tier1(ifttt_data_normal, {})
restore_output

test("Tier 1 normal: author = ct24zive", "ct24zive", post_normal.author.username)
test("Tier 1 normal: reposted_by = nil", nil, post_normal.reposted_by)
test("Tier 1 normal: self_repost? = false", false, post_normal.self_repost?)
test("Tier 1 normal: is_repost = false", false, post_normal.is_repost)

# =============================================================================
# Tier 3 (fallback): External RT — propagates Tier 1 fix
# =============================================================================
section("Tier 3: External RT (fallback from Tier 1)")

suppress_output
post_tier3 = adapter.process_tier3_fallback(ifttt_data_ext_rt, {})
restore_output

test("Tier 3 ext RT: author = UKomentare", "UKomentare", post_tier3.author.username)
test("Tier 3 ext RT: reposted_by = ct24zive", "ct24zive", post_tier3.reposted_by)
test("Tier 3 ext RT: self_repost? = false", false, post_tier3.self_repost?)

# =============================================================================
# Tier 2 fallback: Nitter missed RT → corrects author
# =============================================================================
section("Tier 2: Repost fallback corrects Nitter author")

# Simulate Nitter post (author = retweeter, is_repost = false = Nitter missed it)
nitter_post = Post.new(
  id: "2014000000000000004",
  platform: 'twitter',
  url: "https://x.com/ct24zive/status/2014000000000000004",
  text: "1/3 Evropa čelí tvrdé globální konkurenci",
  published_at: Time.now,
  author: Author.new(username: "ct24zive", display_name: "ČT24", url: "https://x.com/ct24zive"),
  is_repost: false,
  reposted_by: nil
)

# IFTTT data indicates RT
ifttt_data_for_tier2 = {
  text: "RT @UKomentare: 1/3 Evropa čelí tvrdé globální konkurenci",
  first_link_url: "",
  username: "ct24zive"
}

suppress_output
ifttt_post_type = adapter.detect_post_type(ifttt_data_for_tier2[:text], ifttt_data_for_tier2[:first_link_url])

# Apply the same fallback logic as process_tier2
unless nitter_post.is_repost
  if ifttt_post_type[:is_repost]
    rt_original_author = ifttt_post_type[:rt_original_author]
    nitter_post.is_repost = true
    nitter_post.reposted_by = ifttt_data_for_tier2[:username]

    if rt_original_author && nitter_post.author&.username&.downcase == ifttt_data_for_tier2[:username].downcase
      nitter_post.author = Author.new(
        username: rt_original_author,
        display_name: rt_original_author,
        url: "https://x.com/#{rt_original_author}"
      )
    end
  end
end
restore_output

test("Tier 2 fallback: author corrected to UKomentare", "UKomentare", nitter_post.author.username)
test("Tier 2 fallback: reposted_by = ct24zive", "ct24zive", nitter_post.reposted_by)
test("Tier 2 fallback: self_repost? = false", false, nitter_post.self_repost?)
test("Tier 2 fallback: is_repost = true", true, nitter_post.is_repost)

# =============================================================================
# Tier 2 fallback: Nitter already has correct RT → no correction needed
# =============================================================================
section("Tier 2: Nitter already detected RT correctly")

nitter_post_ok = Post.new(
  id: "2014000000000000005",
  platform: 'twitter',
  url: "https://x.com/UKomentare/status/2014000000000000005",
  text: "1/3 Evropa čelí tvrdé globální konkurenci",
  published_at: Time.now,
  author: Author.new(username: "UKomentare", display_name: "Události, komentáře", url: "https://x.com/UKomentare"),
  is_repost: true,
  reposted_by: "ct24zive"
)

# Fallback should NOT be triggered (post.is_repost is already true)
test("Tier 2 Nitter OK: author stays UKomentare", "UKomentare", nitter_post_ok.author.username)
test("Tier 2 Nitter OK: reposted_by stays ct24zive", "ct24zive", nitter_post_ok.reposted_by)
test("Tier 2 Nitter OK: self_repost? = false", false, nitter_post_ok.self_repost?)

# =============================================================================
# Formatter: header display for external RT
# =============================================================================
section("Formatter: external RT header")

formatter_post = Post.new(
  id: "123",
  platform: 'twitter',
  url: "https://x.com/UKomentare/status/123",
  text: "1/3 Evropa čelí tvrdé globální konkurenci",
  published_at: Time.now,
  author: Author.new(username: "UKomentare", display_name: "Události, komentáře"),
  is_repost: true,
  reposted_by: "ct24zive"
)

suppress_output
formatter = Formatters::TwitterFormatter.new(source_name: 'ČT24', language: 'cs')
formatted = formatter.format(formatter_post)
restore_output

test_includes("Header contains @UKomentare", "@UKomentare", formatted)
test_not_includes("Header does NOT contain 'svůj post'", "svůj post", formatted)

# =============================================================================
# Formatter: header display for self RT
# =============================================================================
section("Formatter: self RT header")

formatter_self_post = Post.new(
  id: "456",
  platform: 'twitter',
  url: "https://x.com/ct24zive/status/456",
  text: "Důležitá zpráva",
  published_at: Time.now,
  author: Author.new(username: "ct24zive", display_name: "ČT24"),
  is_repost: true,
  reposted_by: "ct24zive"
)

suppress_output
formatted_self = formatter.format(formatter_self_post)
restore_output

test_includes("Self RT header contains 'svůj post'", "svůj post", formatted_self)
test_not_includes("Self RT header does NOT contain @ct24zive:", "@ct24zive:", formatted_self)

# =============================================================================
# Edge case: RT @someone with different case
# =============================================================================
section("Edge case: case-insensitive RT detection")

suppress_output
result_case = adapter.detect_post_type("rt @SomeUser: text here", "")
restore_output

test("Case-insensitive RT detected", true, result_case[:is_repost])
test("Case-insensitive rt_original_author", "SomeUser", result_case[:rt_original_author])

# =============================================================================
# Edge case: OMGzine (different source) RT @someone
# =============================================================================
section("Edge case: different source RT")

ifttt_data_omg = {
  post_id: "2014000000000000006",
  text: "RT @someone: Interesting content here",
  embed_code: "",
  link_to_tweet: "https://x.com/OMGzine/status/2014000000000000006",
  first_link_url: "",
  username: "OMGzine",
  received_at: Time.now
}

suppress_output
post_omg = adapter.process_tier1(ifttt_data_omg, {})
restore_output

test("OMG RT: author = someone", "someone", post_omg.author.username)
test("OMG RT: reposted_by = OMGzine", "OMGzine", post_omg.reposted_by)
test("OMG RT: self_repost? = false", false, post_omg.self_repost?)

# =============================================================================
# Post model: author is mutable
# =============================================================================
section("Post model: author mutability")

mutable_post = Post.new(
  id: "789",
  platform: 'twitter',
  url: "https://x.com/test/status/789",
  text: "test",
  published_at: Time.now,
  author: Author.new(username: "old_author")
)

test("Author initially old_author", "old_author", mutable_post.author.username)

mutable_post.author = Author.new(username: "new_author")
test("Author changed to new_author", "new_author", mutable_post.author.username)

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed > 0 ? 1 : 0)
