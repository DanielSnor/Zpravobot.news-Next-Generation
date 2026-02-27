#!/usr/bin/env ruby
# test/test_with_real_posts.rb

require_relative '../lib/formatters/universal_formatter'
require_relative '../lib/adapters/bluesky_adapter'
require_relative '../lib/config/config_loader'

config_loader = Config::ConfigLoader.new

# Najdi Bluesky source
bluesky_sources = config_loader.load_sources_by_platform('bluesky')
source = bluesky_sources.find { |s| s.dig('source', 'handle') }

if source.nil?
  puts "Žádný Bluesky source nenalezen"
  exit 1
end

handle = source.dig('source', 'handle')
source_name = source.dig('formatting', 'source_name') || handle

puts "Using source: #{source['id']}"
puts "Handle: #{handle}"
puts "Source name: #{source_name}"

# Adapter
adapter = Adapters::BlueskyAdapter.new(handle: handle)

posts = adapter.fetch rescue []
puts "Fetched #{posts.length} posts"

if posts.empty?
  puts "No posts fetched"
  exit 1
end

# Formatter
formatter = Formatters::UniversalFormatter.new(
  platform: :bluesky,
  source_name: source_name
)

# Zobraz
posts.first(5).each do |post|
  puts "=" * 60
  type = post.is_repost ? 'REPOST' : post.is_quote ? 'QUOTE' : 'POST'
  puts "#{type} | #{post.author&.username} | #{post.id}"
  puts "=" * 60
  puts formatter.format(post)
  puts
end
