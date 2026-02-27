#!/usr/bin/env ruby
# frozen_string_literal: true

# Integration tests for mentions in formatters
# Run: ruby test/test_formatter_mentions.rb

require_relative '../lib/formatters/bluesky_formatter'
require_relative '../lib/formatters/twitter_formatter'
require_relative '../lib/formatters/rss_formatter'
require_relative '../lib/formatters/youtube_formatter'

# Mock Post class for testing
class Post
  attr_accessor :text, :title, :url, :author, :is_repost, :is_quote, 
                :reposted_by, :quoted_post, :media, :raw

  def initialize(attrs = {})
    attrs.each { |k, v| send("#{k}=", v) }
  end

  def has_title?
    !title.to_s.empty?
  end

  def has_text?
    !text.to_s.empty?
  end
end

# Mock Author class
class Author
  attr_accessor :username, :display_name

  def initialize(username:, display_name: nil)
    @username = username
    @display_name = display_name || username
  end
end

module FormatterMentionTests
  extend self

  def run_all
    puts "=" * 60
    puts "Formatter Mentions Integration Tests"
    puts "=" * 60
    puts

    test_bluesky_formatter
    test_twitter_formatter
    test_rss_formatter_facebook
    test_rss_formatter_instagram
    test_rss_formatter_standard
    test_youtube_formatter

    puts
    puts "=" * 60
    puts "All integration tests completed!"
    puts "=" * 60
  end

  def test_bluesky_formatter
    puts "Test: BlueskyFormatter with mentions"

    # Mention expansion with suffix format: @user (URL)
    formatter = Formatters::BlueskyFormatter.new(
      mentions: { type: 'suffix', value: 'https://bsky.app/profile/' }
    )

    # Regular post with mentions
    post = Post.new(
      text: "Včera jsem se sešel s @anthropic a @openai. Skvělá diskuze!",
      author: Author.new(username: 'ct24zive')
    )

    result = formatter.format(post)
    assert_contains(result, "@anthropic (https://bsky.app/profile/anthropic)", "Bluesky mention anthropic")
    assert_contains(result, "@openai (https://bsky.app/profile/openai)", "Bluesky mention openai")

    puts
  end

  def test_twitter_formatter
    puts "Test: TwitterFormatter with mentions"

    # Mention expansion with suffix format: @user (URL)
    formatter = Formatters::TwitterFormatter.new(
      mentions: { type: 'suffix', value: 'https://xcancel.com/' }
    )

    # Regular post with mentions
    post = Post.new(
      text: "Breaking: @CNN reports @elonmusk announced new features",
      author: Author.new(username: 'ct24zive')
    )

    result = formatter.format(post)
    assert_contains(result, "@CNN (https://xcancel.com/CNN)", "Twitter mention CNN")
    assert_contains(result, "@elonmusk (https://xcancel.com/elonmusk)", "Twitter mention elonmusk")

    puts
  end

  def test_rss_formatter_facebook
    puts "Test: RSSFormatter with Facebook source type"
    
    formatter = Formatters::RssFormatter.new(rss_source_type: 'facebook')
    
    post = Post.new(
      text: "Nový příspěvek od @Nike o běhání",
      url: "https://facebook.com/example/post/123"
    )
    
    result = formatter.format(post)
    assert_contains(result, "@Nike (https://facebook.com/Nike)", "Facebook mention")
    
    puts
  end

  def test_rss_formatter_instagram
    puts "Test: RSSFormatter with Instagram source type"
    
    formatter = Formatters::RssFormatter.new(rss_source_type: 'instagram')
    
    post = Post.new(
      text: "Fotka od @natgeo",
      url: "https://instagram.com/p/123"
    )
    
    result = formatter.format(post)
    assert_contains(result, "@natgeo (https://instagram.com/natgeo)", "Instagram mention")
    
    puts
  end

  def test_rss_formatter_standard
    puts "Test: RSSFormatter with standard RSS (no mentions)"
    
    formatter = Formatters::RssFormatter.new(rss_source_type: 'rss')
    
    post = Post.new(
      text: "Článek zmiňuje @someone v textu",
      url: "https://example.com/article"
    )
    
    result = formatter.format(post)
    # Should NOT transform mentions for standard RSS
    assert_contains(result, "@someone", "Standard RSS - mention preserved")
    assert_not_contains(result, "(https://", "Standard RSS - no URL added")
    
    puts
  end

  def test_youtube_formatter
    puts "Test: YouTubeFormatter (mentions disabled by default)"
    
    formatter = Formatters::YouTubeFormatter.new
    
    post = Post.new(
      text: "Video od @CT24news",
      title: "Zprávy",
      url: "https://youtube.com/watch?v=123"
    )
    
    result = formatter.format(post)
    # Should NOT transform mentions (disabled by default)
    assert_contains(result, "@CT24news", "YouTube - mention preserved")
    assert_not_contains(result, "(https://youtube.com/@CT24news)", "YouTube - no URL added")
    
    # Test with mentions enabled
    formatter_with_mentions = Formatters::YouTubeFormatter.new(
      mentions: { type: 'suffix', value: 'https://youtube.com/@' }
    )
    
    result2 = formatter_with_mentions.format(post)
    assert_contains(result2, "@CT24news (https://youtube.com/@CT24news)", "YouTube with mentions enabled")
    
    puts
  end

  private

  def assert_contains(result, substring, description)
    if result.include?(substring)
      puts "  ✅ #{description}"
    else
      puts "  ❌ #{description}"
      puts "     Expected to contain: #{substring.inspect}"
      puts "     Actual: #{result.inspect}"
    end
  end

  def assert_not_contains(result, substring, description)
    if !result.include?(substring)
      puts "  ✅ #{description}"
    else
      puts "  ❌ #{description}"
      puts "     Expected NOT to contain: #{substring.inspect}"
      puts "     Actual: #{result.inspect}"
    end
  end
end

# Run tests if executed directly
if __FILE__ == $PROGRAM_NAME
  FormatterMentionTests.run_all
end
