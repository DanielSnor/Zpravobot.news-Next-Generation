#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Test: Smart Truncation for 500-char instances
# ============================================================
# Demonstrace chytrého zkracování tweetů pro instance
# s omezeným limitem znaků.
#
# Spuštění:
#   ruby test_truncation.rb
# ============================================================

# Mock třídy pro testování
module Formatters
  module MentionFormatting
    def format_mentions(text, config, skip_username: nil)
      return text if config.nil? || config[:type] == 'none'
      
      text.gsub(/@(\w+)/) do |match|
        username = $1
        next match if username == skip_username
        "#{config[:value]}#{username}"
      end
    end
  end
end

# Load the formatter
require_relative '../lib/formatters/twitter_formatter'

# Mock Post class
class MockPost
  attr_accessor :text, :url, :author, :is_repost, :is_quote, :is_thread_post,
                :reposted_by, :quoted_post, :media, :title, :raw, :poll_data, :is_reply

  def initialize(attrs = {})
    @text = attrs[:text] || ''
    @url = attrs[:url] || 'https://x.com/user/status/123456789'
    @author = attrs[:author]
    @is_repost = attrs[:is_repost] || false
    @is_quote = attrs[:is_quote] || false
    @is_thread_post = attrs[:is_thread_post] || false
    @is_reply = attrs[:is_reply] || false
    @reposted_by = attrs[:reposted_by]
    @quoted_post = attrs[:quoted_post]
    @media = attrs[:media] || []
    @title = attrs[:title]
    @raw = attrs[:raw]
    @poll_data = attrs[:poll_data]
    @has_video = attrs[:has_video] || false
  end

  def has_video
    @has_video
  end

  def has_video?
    @has_video
  end

  def has_poll?
    false
  end

  def self_repost?
    false
  end

  def self_quote?
    false
  end
end

class MockAuthor
  attr_accessor :username
  
  def initialize(username)
    @username = username
  end
end

# Test cases
puts "=" * 70
puts "🧪 TEST: Smart Truncation for 500-char instances"
puts "=" * 70
puts

# Configuration for 500-char instance
config_500 = {
  max_length: 500,
  url_domain: 'xcancel.com',
  rewrite_domains: %w[twitter.com x.com nitter.net],
  truncation: {
    enabled: true,
    soft_threshold: 475,
    read_more_prefix: "\n📖➡️ ",
    video_read_more_prefix: "\n📺 + 📖➡️ ",
    full_text_domain: 'xcancel.com'
  },
  mentions: {
    type: 'prefix',
    value: 'https://xcancel.com/'
  }
}

# Configuration for aggressive truncation (lower threshold for testing)
config_aggressive = {
  max_length: 500,
  url_domain: 'xcancel.com',
  rewrite_domains: %w[twitter.com x.com nitter.net],
  truncation: {
    enabled: true,
    soft_threshold: 200,  # Very low for testing
    read_more_prefix: "\n📖➡️ ",
    video_read_more_prefix: "\n📺 + 📖➡️ ",
    full_text_domain: 'xcancel.com'
  },
  mentions: {
    type: 'prefix',
    value: 'https://xcancel.com/'
  }
}

# Configuration for 2400-char instance (no truncation needed)
config_2400 = {
  max_length: 2400,
  url_domain: 'xcancel.com',
  rewrite_domains: %w[twitter.com x.com nitter.net],
  truncation: {
    enabled: false
  },
  mentions: {
    type: 'prefix',
    value: 'https://xcancel.com/'
  }
}

formatter_500 = Formatters::TwitterFormatter.new(config_500)
formatter_aggressive = Formatters::TwitterFormatter.new(config_aggressive)
formatter_2400 = Formatters::TwitterFormatter.new(config_2400)

# Test 1: Short tweet (should NOT be truncated)
puts "📝 TEST 1: Krátký tweet (pod limitem)"
puts "-" * 50
short_post = MockPost.new(
  text: "Toto je krátký tweet, který se vejde bez problémů.",
  url: "https://x.com/ct24zive/status/123456789",
  author: MockAuthor.new("ct24zive")
)

result = formatter_500.format(short_post)
puts "Výstup (#{result.length} znaků):"
puts result
puts
puts "✅ Není zkráceno" if result.length <= 500 && !result.include?("📖➡️")
puts

# Test 2: Long tweet (should be truncated on 500-char instance)
puts "📝 TEST 2: Dlouhý tweet (překračuje soft_threshold)"
puts "-" * 50
long_text = "Toto je velmi dlouhý tweet, který obsahuje spoustu informací o aktuální situaci. " \
            "Ministerstvo zahraničních věcí dnes vydalo prohlášení k situaci na Blízkém východě. " \
            "Podle mluvčího ministerstva je situace velmi vážná a vyžaduje okamžitou pozornost " \
            "mezinárodního společenství. Česká republika vyzývá všechny strany konfliktu k okamžitému " \
            "příměří a zahájení mírových jednání. Více informací naleznete na webu ministerstva. " \
            "Situace se nadále vyvíjí a budeme vás informovat o dalším průběhu událostí. " \
            "Ministr zahraničí se zítra setká s velvyslanci dotčených zemí."

long_post = MockPost.new(
  text: long_text,
  url: "https://x.com/ct24zive/status/987654321",
  author: MockAuthor.new("ct24zive")
)

puts "Původní text (#{long_text.length} znaků):"
puts long_text
puts

result_500 = formatter_500.format(long_post)
result_2400 = formatter_2400.format(long_post)

puts "Výstup pro 500-char instanci (#{result_500.length} znaků):"
puts result_500
puts
puts "✅ Zkráceno s 📖➡️" if result_500.include?("📖➡️")
puts

puts "Výstup pro 2400-char instanci (#{result_2400.length} znaků):"
puts result_2400
puts
puts "✅ Není zkráceno" if !result_2400.include?("📖➡️")
puts

# Test 2b: Same text with aggressive threshold
puts "📝 TEST 2b: Stejný text s agresivním threshold (200)"
puts "-" * 50
result_aggressive = formatter_aggressive.format(long_post)
puts "Výstup (#{result_aggressive.length} znaků):"
puts result_aggressive
puts
puts "✅ Zkráceno s 📖➡️" if result_aggressive.include?("📖➡️")
puts

# Test 3: Repost (should have header and be truncated if long)
puts "📝 TEST 3: Dlouhý repost"
puts "-" * 50
repost = MockPost.new(
  text: long_text,
  url: "https://x.com/novinar/status/111222333",
  author: MockAuthor.new("novinar"),
  is_repost: true,
  reposted_by: "ct24zive"
)

result = formatter_500.format(repost)
puts "Výstup pro 500-char (#{result.length} znaků):"
puts result
puts

result_agg = formatter_aggressive.format(repost)
puts "Výstup s agresivním threshold (#{result_agg.length} znaků):"
puts result_agg
puts
puts "✅ Má header 🔁" if result.include?("🔁")
puts "✅ Aggressive má 📖➡️" if result_agg.include?("📖➡️")
puts

# Test 4: Quote tweet
puts "📝 TEST 4: Dlouhý quote tweet"
puts "-" * 50
quote = MockPost.new(
  text: "Souhlasím s tímto prohlášením. Je důležité, abychom jako mezinárodní společenství " \
        "jednali jednotně a rozhodně v této obtížné situaci.",
  url: "https://x.com/ct24zive/status/444555666",
  author: MockAuthor.new("ct24zive"),
  is_quote: true,
  quoted_post: {
    url: "https://x.com/novinar/status/111222333",
    text: long_text,
    author: "novinar"
  }
)

result = formatter_500.format(quote)
puts "Výstup (#{result.length} znaků):"
puts result
puts
puts "✅ Má header 💬 a URL na quoted post" if result.include?("💬")
puts

# Test 5: Video post
puts "📝 TEST 5: Dlouhý tweet s videem"
puts "-" * 50
video_post = MockPost.new(
  text: long_text,
  url: "https://x.com/ct24zive/status/777888999",
  author: MockAuthor.new("ct24zive"),
  has_video: true
)

result = formatter_500.format(video_post)
puts "Výstup pro 500-char (#{result.length} znaků):"
puts result
puts

result_agg = formatter_aggressive.format(video_post)
puts "Výstup s agresivním threshold (#{result_agg.length} znaků):"
puts result_agg
puts
puts "✅ Standard má 🎬" if result.include?("🎬") && !result.include?("📺")
puts "✅ Aggressive má 📺 + 📖➡️" if result_agg.include?("📺") && result_agg.include?("📖➡️")
puts

# Test 6: URL protection
puts "📝 TEST 6: Tweet s URL uprostřed textu"
puts "-" * 50
url_text = "Přečtěte si celý článek na https://example.com/velmi-dlouhy-clanek-o-situaci " \
           "kde najdete více informací o této důležité události která ovlivní celou Evropu " \
           "a možná i celý svět v nadcházejících měsících."

url_post = MockPost.new(
  text: url_text,
  url: "https://x.com/ct24zive/status/123123123",
  author: MockAuthor.new("ct24zive")
)

result = formatter_500.format(url_post)
puts "Výstup (#{result.length} znaků):"
puts result
puts
# Check that URL is not cut in the middle
has_complete_url = result.include?("https://example.com/velmi-dlouhy-clanek-o-situaci") ||
                   !result.include?("https://example.com/velmi")
puts "✅ URL není oříznutá uprostřed" if has_complete_url
puts

puts "=" * 70
puts "🏁 Testy dokončeny"
puts "=" * 70
