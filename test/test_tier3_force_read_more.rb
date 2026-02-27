# test/test_tier3_force_read_more.rb
require_relative '../lib/formatters/twitter_formatter'
require_relative '../lib/models/post'
require_relative '../lib/models/author'

formatter = Formatters::TwitterFormatter.new(
  url_domain: 'xcancel.com',
  truncation: { enabled: true, soft_threshold: 400 }
)

# Test 1: Short text WITH force_read_more (Tier 3)
post1 = Post.new(
  platform: 'twitter',
  id: '123',
  url: 'https://x.com/test/status/123',
  text: 'Short text under threshold',
  published_at: Time.now,
  author: Author.new(username: 'test', display_name: 'Test'),
  raw: { tier: 3, force_read_more: true }
)

result1 = formatter.format(post1)
puts "Test 1 - Tier 3 (force_read_more: true):"
puts result1
puts "Contains 📖➡️: #{result1.include?('📖➡️')}"
puts ""

# Test 2: Short text WITHOUT force_read_more (Tier 1)
post2 = Post.new(
  platform: 'twitter',
  id: '456',
  url: 'https://x.com/test/status/456',
  text: 'Short text under threshold',
  published_at: Time.now,
  author: Author.new(username: 'test', display_name: 'Test'),
  raw: { tier: 1, force_read_more: false }
)

result2 = formatter.format(post2)
puts "Test 2 - Tier 1 (force_read_more: false):"
puts result2
puts "Contains 📖➡️: #{result2.include?('📖➡️')}"
puts ""

# Test 3: Verify difference
puts "=== Summary ==="
puts "Tier 3 has 📖➡️: #{result1.include?('📖➡️') ? '✅' : '❌'}"
puts "Tier 1 has 📖➡️: #{result2.include?('📖➡️') ? '❌ (unexpected!)' : '✅ (correctly absent)'}"
