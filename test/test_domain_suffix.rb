#!/usr/bin/env ruby
# Test pro domain_suffix mentions transformaci
# Spustit z kořene projektu: ruby test_domain_suffix.rb
# Nebo: ruby test/test_domain_suffix.rb

# Najdi kořen projektu
script_dir = File.dirname(File.expand_path(__FILE__))
project_root = if File.exist?(File.join(script_dir, 'lib/formatters/universal_formatter.rb'))
  script_dir
elsif File.exist?(File.join(script_dir, '../lib/formatters/universal_formatter.rb'))
  File.join(script_dir, '..')
else
  Dir.pwd
end

$LOAD_PATH.unshift(File.join(project_root, 'lib'))
require 'formatters/universal_formatter'

puts "=" * 60
puts "Test: domain_suffix mentions transformation"
puts "=" * 60
puts

# Test helper
def test(name, expected, actual)
  if expected == actual
    puts "✅ #{name}"
    true
  else
    puts "❌ #{name}"
    puts "   Expected: #{expected.inspect}"
    puts "   Actual:   #{actual.inspect}"
    false
  end
end

# Create formatter with domain_suffix config
formatter = Formatters::UniversalFormatter.new({
  platform: :twitter,
  mentions: {
    type: 'domain_suffix',
    value: 'twitter.com'
  }
})

# Access private method for testing
def formatter.test_format_mention(username)
  format_single_mention(username, @config[:mentions])
end

results = []

# Test cases
results << test(
  "Single mention",
  "@ct24zive@twitter.com",
  formatter.test_format_mention("ct24zive")
)

results << test(
  "Another mention",
  "@elonmusk@twitter.com",
  formatter.test_format_mention("elonmusk")
)

# Test full text transformation
config = { mentions: { type: 'domain_suffix', value: 'twitter.com' } }

# Access private method
text = "Díky @anthropic za pomoc s projektem!"
result = formatter.send(:format_mentions, text, config, skip: nil)

results << test(
  "Full text transformation",
  "Díky @anthropic@twitter.com za pomoc s projektem!",
  result
)

# Test skip author
text_with_author = "Nový článek od @ct24zive o AI"
result_skip = formatter.send(:format_mentions, text_with_author, config, skip: "ct24zive")

results << test(
  "Skip author mention",
  "Nový článek od @ct24zive o AI",
  result_skip
)

puts
puts "=" * 60
passed = results.count(true)
failed = results.count(false)
puts "Results: #{passed} passed, #{failed} failed"
puts "=" * 60
