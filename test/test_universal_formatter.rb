#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script pro UniversalFormatter
# Ověřuje všechny výstupní varianty pro každou platformu

require_relative '../lib/formatters/universal_formatter'

# Mock Post class pro testování
class MockPost
  attr_accessor :text, :url, :author, :is_repost, :is_quote, :reposted_by,
                :quoted_post, :has_video, :is_thread_post, :thread_context,
                :title, :media, :raw

  def initialize(attrs = {})
    @text = attrs[:text] || ''
    @url = attrs[:url] || 'https://example.com/post/123'
    @author = attrs[:author]
    @is_repost = attrs[:is_repost] || false
    @is_quote = attrs[:is_quote] || false
    @reposted_by = attrs[:reposted_by]
    @quoted_post = attrs[:quoted_post]
    @has_video = attrs[:has_video] || false
    @is_thread_post = attrs[:is_thread_post] || false
    @thread_context = attrs[:thread_context]
    @title = attrs[:title]
    @media = attrs[:media] || []
    @raw = attrs[:raw] || {}
  end

  def respond_to?(method, include_all = false)
    [:text, :url, :author, :is_repost, :is_quote, :reposted_by,
     :quoted_post, :has_video, :is_thread_post, :thread_context,
     :title, :media, :raw].include?(method) || super
  end
end

class MockAuthor
  attr_accessor :username
  def initialize(username)
    @username = username
  end
end

def separator(title)
  puts
  puts "=" * 70
  puts " #{title}"
  puts "=" * 70
end

def test_case(name, post, formatter, source_config = {})
  puts
  puts "--- #{name} ---"
  result = formatter.format(post, source_config)
  puts result
  puts "---"
end

# ===========================================
# RSS Tests
# ===========================================
separator("📰 RSS")

rss_formatter = Formatters::UniversalFormatter.new(platform: :rss)

# Regular (text mode)
test_case("Regular (text mode)", MockPost.new(
  text: "Vláda schválila nový zákon o digitalizaci.",
  url: "https://example.com/clanek/123"
), rss_formatter)

# Regular (title mode)
test_case("Regular (title mode)", MockPost.new(
  title: "Vláda schválila zákon",
  text: "Popis článku zde...",
  url: "https://example.com/clanek/123"
), rss_formatter, { show_title_as_content: true })

# Regular (combined mode)
test_case("Regular (combined mode)", MockPost.new(
  title: "Vláda schválila zákon",
  text: "Popis článku zde...",
  url: "https://example.com/clanek/123"
), rss_formatter, { combine_title_and_content: true })

# ===========================================
# YouTube Tests
# ===========================================
separator("🎬 YouTube")

youtube_formatter = Formatters::UniversalFormatter.new(platform: :youtube)

# Video (combined) - s thumbnailem (default)
test_case("Video (combined) - s thumbnailem", MockPost.new(
  title: "Jak programovat v Ruby",
  text: "V tomto videu se naučíte základy Ruby programování...",
  url: "https://youtu.be/abc123"
), youtube_formatter, { combine_title_and_content: true })

# Video (title mode)
test_case("Video (title mode)", MockPost.new(
  title: "Jak programovat v Ruby",
  text: "Popis videa...",
  url: "https://youtu.be/abc123"
), youtube_formatter, { show_title_as_content: true })

# Video bez thumbnailu (URL vytvoří náhled)
test_case("Video bez thumbnailu", MockPost.new(
  title: "Jak programovat v Ruby",
  text: "Popis videa...",
  url: "https://youtu.be/abc123"
), youtube_formatter, { combine_title_and_content: true, prefix_post_url: "\n" })

# ===========================================
# Bluesky Tests
# ===========================================
separator("🦋 Bluesky")

bluesky_formatter = Formatters::UniversalFormatter.new(platform: :bluesky)

# Regular
test_case("Regular", MockPost.new(
  text: "Nový post na Bluesky! Sledujte @novinar pro více info.",
  url: "https://bsky.app/profile/ct24/post/123",
  author: MockAuthor.new("ct24")
), bluesky_formatter)

# Repost
test_case("Repost", MockPost.new(
  text: "Důležitá zpráva o ekonomice.",
  url: "https://bsky.app/profile/ekonom/post/456",
  author: MockAuthor.new("ekonom"),
  is_repost: true,
  reposted_by: "ct24"
), bluesky_formatter, { source_name: "ČT24" })

# Self-repost
test_case("Self-repost", MockPost.new(
  text: "Připomínám svůj včerejší post.",
  url: "https://bsky.app/profile/ct24/post/789",
  author: MockAuthor.new("ct24"),
  is_repost: true,
  reposted_by: "ct24"
), bluesky_formatter, { source_name: "ČT24" })

# Quote
test_case("Quote", MockPost.new(
  text: "Souhlasím s tímto názorem.",
  url: "https://bsky.app/profile/ct24/post/111",
  author: MockAuthor.new("ct24"),
  is_quote: true,
  quoted_post: { author: "politik", url: "https://bsky.app/profile/politik/post/222" }
), bluesky_formatter, { source_name: "ČT24" })

# Self-quote
test_case("Self-quote", MockPost.new(
  text: "Doplňuji svůj předchozí post.",
  url: "https://bsky.app/profile/ct24/post/333",
  author: MockAuthor.new("ct24"),
  is_quote: true,
  quoted_post: { author: "ct24", url: "https://bsky.app/profile/ct24/post/444" }
), bluesky_formatter, { source_name: "ČT24" })

# Thread
test_case("Thread", MockPost.new(
  text: "Pokračování vlákna o reformě školství.",
  url: "https://bsky.app/profile/ct24/post/555",
  author: MockAuthor.new("ct24"),
  is_thread_post: true,
  thread_context: { position: 2, total: 5 }
), bluesky_formatter, { thread_handling: { show_indicator: true } })

# Video
test_case("Video", MockPost.new(
  text: "Podívejte se na nové video.",
  url: "https://bsky.app/profile/ct24/post/666",
  author: MockAuthor.new("ct24"),
  has_video: true
), bluesky_formatter)

# ===========================================
# Twitter Tests
# ===========================================
separator("🐦 Twitter")

twitter_formatter = Formatters::UniversalFormatter.new(platform: :twitter)

# Regular (Tier 1/2)
test_case("Regular (Tier 1/2)", MockPost.new(
  text: "Breaking: Nová vláda složila slib. Sledujte @premier pro více.",
  url: "https://twitter.com/ct24/status/123",
  author: MockAuthor.new("ct24")
), twitter_formatter)

# Regular (Tier 3 - truncated)
test_case("Regular (Tier 3 - truncated)", MockPost.new(
  text: "Dlouhý tweet, který byl zkrácen IFTTT...",
  url: "https://twitter.com/ct24/status/124",
  author: MockAuthor.new("ct24"),
  raw: { force_read_more: true }
), twitter_formatter)

# Repost (Tier 1/2)
test_case("Repost (Tier 1/2)", MockPost.new(
  text: "Důležitá analýza ekonomické situace.",
  url: "https://twitter.com/ekonom/status/456",
  author: MockAuthor.new("ekonom"),
  is_repost: true,
  reposted_by: "ct24"
), twitter_formatter, { source_name: "ČT24" })

# Repost (Tier 3 - truncated)
test_case("Repost (Tier 3 - truncated)", MockPost.new(
  text: "Zkrácený retweet...",
  url: "https://twitter.com/ekonom/status/457",
  author: MockAuthor.new("ekonom"),
  is_repost: true,
  reposted_by: "ct24",
  raw: { force_read_more: true }
), twitter_formatter, { source_name: "ČT24" })

# Quote (Tier 1/2)
test_case("Quote (Tier 1/2)", MockPost.new(
  text: "Můj komentář k tomuto.",
  url: "https://twitter.com/ct24/status/789",
  author: MockAuthor.new("ct24"),
  is_quote: true,
  quoted_post: { author: "politik", url: "https://twitter.com/politik/status/790" }
), twitter_formatter, { source_name: "ČT24" })

# Quote (Tier 3 - truncated)
test_case("Quote (Tier 3 - truncated)", MockPost.new(
  text: "Zkrácený quote tweet...",
  url: "https://twitter.com/ct24/status/791",
  author: MockAuthor.new("ct24"),
  is_quote: true,
  quoted_post: { author: "politik", url: "https://twitter.com/politik/status/792" },
  raw: { force_read_more: true }
), twitter_formatter, { source_name: "ČT24" })

# Thread (Tier 1/2)
test_case("Thread (Tier 1/2)", MockPost.new(
  text: "Třetí část vlákna.",
  url: "https://twitter.com/ct24/status/900",
  author: MockAuthor.new("ct24"),
  is_thread_post: true,
  thread_context: { position: 3, total: 7 }
), twitter_formatter, { thread_handling: { show_indicator: true } })

# Thread (Tier 3 - truncated)
test_case("Thread (Tier 3 - truncated)", MockPost.new(
  text: "Zkrácená část vlákna...",
  url: "https://twitter.com/ct24/status/901",
  author: MockAuthor.new("ct24"),
  is_thread_post: true,
  thread_context: { position: 3, total: 7 },
  raw: { force_read_more: true }
), twitter_formatter, { thread_handling: { show_indicator: true } })

# Video (Tier 1) - URL vytvoří náhled
test_case("Video (Tier 1)", MockPost.new(
  text: "Podívejte se na toto video.",
  url: "https://twitter.com/ct24/status/1000",
  author: MockAuthor.new("ct24"),
  has_video: true
), twitter_formatter)

# Video (Tier 3 - truncated)
test_case("Video (Tier 3 - truncated)", MockPost.new(
  text: "Zkrácený tweet s videem...",
  url: "https://twitter.com/ct24/status/1001",
  author: MockAuthor.new("ct24"),
  has_video: true,
  raw: { force_read_more: true }
), twitter_formatter)

# ===========================================
# Lokalizace Tests
# ===========================================
separator("🌍 Lokalizace (self-reference)")

# Slovak
test_case("Self-repost (SK)", MockPost.new(
  text: "Moje predchádzajúce vyjadrenie.",
  url: "https://twitter.com/novinky_sk/status/2000",
  author: MockAuthor.new("novinky_sk"),
  is_repost: true,
  reposted_by: "novinky_sk"
), twitter_formatter, { source_name: "Novinky.sk", language: 'sk' })

# English
test_case("Self-quote (EN)", MockPost.new(
  text: "Adding more context to my previous statement.",
  url: "https://twitter.com/bbc/status/3000",
  author: MockAuthor.new("bbc"),
  is_quote: true,
  quoted_post: { author: "bbc", url: "https://twitter.com/bbc/status/3001" }
), twitter_formatter, { source_name: "BBC", language: 'en' })

puts
puts "=" * 70
puts " ✅ Všechny testy dokončeny"
puts "=" * 70
