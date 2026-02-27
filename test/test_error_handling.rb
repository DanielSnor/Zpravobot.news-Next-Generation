#!/usr/bin/env ruby
# frozen_string_literal: true

# Error Handling Tests (#11)
# Validates graceful handling of nil/empty/malformed inputs across all components
# Run: ruby test/test_error_handling.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/processors/content_processor'
require_relative '../lib/processors/content_filter'
require_relative '../lib/processors/url_processor'
require_relative '../lib/processors/edit_detector'
require_relative '../lib/utils/html_cleaner'
require_relative '../lib/utils/format_helpers'
require_relative '../lib/utils/hash_helpers'
require_relative '../lib/models/post'
require_relative '../lib/models/author'
require_relative '../lib/models/media'

puts "=" * 60
puts "Error Handling Tests (#11)"
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

def test_no_error(name, &block)
  begin
    block.call
    puts "  \e[32m\u2713\e[0m #{name}"
    $passed += 1
  rescue => e
    puts "  \e[31m\u2717\e[0m #{name}"
    puts "    Unexpected error: #{e.class}: #{e.message}"
    $failed += 1
  end
end

def test_raises(name, exception_class, &block)
  begin
    block.call
    puts "  \e[31m\u2717\e[0m #{name} (no exception raised)"
    $failed += 1
  rescue exception_class
    puts "  \e[32m\u2713\e[0m #{name}"
    $passed += 1
  rescue => e
    puts "  \e[31m\u2717\e[0m #{name}"
    puts "    Expected: #{exception_class}"
    puts "    Got:      #{e.class}: #{e.message}"
    $failed += 1
  end
end

def section(title)
  puts
  puts "--- #{title} ---"
end

# =============================================================================
# ContentProcessor: nil/empty
# =============================================================================
section("ContentProcessor: Nil/Empty Input")

cp = Processors::ContentProcessor.new

test("process nil returns empty", '', cp.process(nil))
test("process empty string returns empty", '', cp.process(''))
test("process whitespace only returns empty", '', cp.process('   '))
test("process normal text works", 'hello world', cp.process('hello world'))

section("ContentProcessor: Edge Cases")

test("Very long text gets trimmed", true, cp.process('a' * 1000).length <= 500)
test("Text at exactly max length", true, cp.process('a' * 500).length == 500)
test("Unicode text processed", true, cp.process("Česká zpráva").length > 0)

# =============================================================================
# ContentFilter: Nil/Empty and Invalid Regex
# =============================================================================
section("ContentFilter: Nil/Empty Input")

cf = Processors::ContentFilter.new(
  banned_phrases: ["test"],
  required_keywords: ["required"]
)

test("banned? nil", false, cf.banned?(nil))
test("banned? empty", false, cf.banned?(''))
test("has_required? nil", false, cf.has_required?(nil))
test("has_required? empty", false, cf.has_required?(''))
test("apply_replacements nil", '', cf.apply_replacements(nil))
test("apply_replacements empty", '', cf.apply_replacements(''))

section("ContentFilter: Invalid Regex Handling")

cf_bad = Processors::ContentFilter.new(
  banned_phrases: [
    { type: 'regex', pattern: '[invalid(regex' },
    'valid_phrase'
  ]
)
test_no_error("Invalid regex in banned_phrases doesn't crash") do
  cf_bad.banned?("some text with valid_phrase")
end
test("Valid phrase still detected after invalid regex", true,
     cf_bad.banned?("text with valid_phrase"))
test("Invalid regex returns false", false,
     cf_bad.banned?("text without matching content"))

section("ContentFilter: Invalid Regex in Replacements")

cf_replace = Processors::ContentFilter.new(
  content_replacements: [
    { pattern: '[broken(regex', replacement: 'X' },
    { pattern: 'good', replacement: 'GOOD' }
  ]
)
test_no_error("Invalid regex in replacements doesn't crash") do
  cf_replace.apply_replacements("some good text")
end
test("Valid replacement applied after invalid", 'some GOOD text',
     cf_replace.apply_replacements("some good text"))

section("ContentFilter: Empty Configuration")

cf_empty = Processors::ContentFilter.new
test("Empty banned list: never banned", false, cf_empty.banned?("anything"))
test("Empty required list: always has required", true, cf_empty.has_required?("anything"))
test("Empty replacements: text unchanged", "text", cf_empty.apply_replacements("text"))

section("ContentFilter: check() Method")

result = cf.check(nil)
test("check(nil) returns pass:false", false, result[:pass])

cf_no_req = Processors::ContentFilter.new(banned_phrases: ["bad"])
result2 = cf_no_req.check("clean text")
test("check clean text passes", true, result2[:pass])

# =============================================================================
# UrlProcessor: Nil/Empty
# =============================================================================
section("UrlProcessor: Nil/Empty Input")

up = Processors::UrlProcessor.new

test("process_url nil", '', up.process_url(nil))
test("process_url empty", '', up.process_url(''))
test("process_url '(none)'", '', up.process_url('(none)'))
test("process_content nil", '', up.process_content(nil))
test("process_content empty", '', up.process_content(''))

section("UrlProcessor: Malformed URLs")

test("process_url plain text (no crash)", 'not-a-url', up.process_url('not-a-url'))
test("process_content with just text", 'hello world', up.process_content('hello world'))

section("UrlProcessor: Truncated URL Detection Edge Cases")

test("has_truncated_url? nil", false, up.has_truncated_url?(nil))
test("has_truncated_url? empty", false, up.has_truncated_url?(''))
test("remove_truncated_urls nil", nil, up.remove_truncated_urls(nil))
test("remove_truncated_urls empty", '', up.remove_truncated_urls(''))

section("UrlProcessor: Incomplete URL Edge Cases")

test("has_incomplete_url_at_end? nil", false, up.has_incomplete_url_at_end?(nil))
test("has_incomplete_url_at_end? empty", false, up.has_incomplete_url_at_end?(''))
test("remove_incomplete_url_from_end nil", '', up.remove_incomplete_url_from_end(nil))
test("remove_incomplete_url_from_end empty", '', up.remove_incomplete_url_from_end(''))

section("UrlProcessor: Deduplication Edge Cases")

test("deduplicate_trailing_urls nil", '', up.deduplicate_trailing_urls(nil))
test("deduplicate_trailing_urls empty", '', up.deduplicate_trailing_urls(''))
test("deduplicate_trailing_urls no URLs", 'just text', up.deduplicate_trailing_urls('just text'))

section("UrlProcessor: Domain Fixes Edge Cases")

test("apply_domain_fixes nil text", nil, up.apply_domain_fixes(nil, ['test.com']))
test("apply_domain_fixes empty text", '', up.apply_domain_fixes('', ['test.com']))
test("apply_domain_fixes nil domains", 'text', up.apply_domain_fixes('text', nil))
test("apply_domain_fixes empty domains", 'text', up.apply_domain_fixes('text', []))

# =============================================================================
# HtmlCleaner: Edge Cases
# =============================================================================
section("HtmlCleaner: Nil/Empty Input")

test("clean nil", '', HtmlCleaner.clean(nil))
test("clean empty", '', HtmlCleaner.clean(''))
test("has_entities? on plain text", false, HtmlCleaner.has_entities?('plain text'))
test("decode_html_entities nil", '', HtmlCleaner.decode_html_entities(nil))
test("sanitize_html nil", '', HtmlCleaner.sanitize_html(nil))
test("sanitize_html empty", '', HtmlCleaner.sanitize_html(''))

section("HtmlCleaner: Malformed HTML")

test_no_error("Unclosed tags don't crash") do
  HtmlCleaner.clean('<div><p>text')
end
test("Unclosed tags: text extracted", true,
     HtmlCleaner.clean('<div><p>text').include?('text'))

test_no_error("Script tags removed safely") do
  HtmlCleaner.clean('<script>alert(1)</script>normal text')
end
test("Script content removed", true,
     !HtmlCleaner.clean('<script>alert(1)</script>normal').include?('alert'))

test_no_error("Invalid entities don't crash") do
  HtmlCleaner.clean('&nonexistent; &also_fake;')
end

section("HtmlCleaner: Entity Decoding")

test("Named entity: &amp;", '&', HtmlCleaner.decode_html_entities('&amp;'))
test("Named entity: &lt;", '<', HtmlCleaner.decode_html_entities('&lt;'))
test("Numeric decimal entity", "\u00E1", HtmlCleaner.decode_html_entities('&#225;'))
test("Numeric hex entity", "\u00E1", HtmlCleaner.decode_html_entities('&#xE1;'))
test("Unknown entity preserved", '&foobar;', HtmlCleaner.decode_html_entities('&foobar;'))

# =============================================================================
# Post Model: Edge Cases
# =============================================================================
section("Post Model: Edge Cases")

test_no_error("Post with nil media") do
  Post.new(platform: 'rss', id: '1', url: 'x', text: 't',
           published_at: Time.now, author: Author.new(username: 'u'), media: nil)
end

p_nil_media = Post.new(platform: 'rss', id: '1', url: 'x', text: 't',
                       published_at: Time.now, author: Author.new(username: 'u'), media: nil)
test("Nil media becomes empty array", [], p_nil_media.media)

test_no_error("Post with empty text") do
  Post.new(platform: 'rss', id: '1', url: 'x', text: '',
           published_at: Time.now, author: Author.new(username: 'u'))
end

test_no_error("Post to_h with minimal fields") do
  Post.new(platform: 'rss', id: '1', url: 'x', text: 't',
           published_at: Time.now, author: Author.new(username: 'u')).to_h
end

test_no_error("Post inspect with minimal fields") do
  Post.new(platform: 'rss', id: '1', url: 'x', text: 't',
           published_at: Time.now, author: Author.new(username: 'u')).inspect
end

# =============================================================================
# Media Model: Type Validation
# =============================================================================
section("Media Model: Type Validation")

test_raises("Invalid media type raises ArgumentError", ArgumentError) do
  Media.new(type: 'podcast', url: 'x')
end

test_raises("Empty string type raises ArgumentError", ArgumentError) do
  Media.new(type: '', url: 'x')
end

test_no_error("Symbol type accepted") do
  Media.new(type: :image, url: 'x')
end

# =============================================================================
# EditDetector: Similarity Edge Cases
# =============================================================================
section("EditDetector: Similarity Edge Cases")

# Mock state manager
class MockStateManager
  def find_by_text_hash(_, _); nil; end
  def find_recent_buffer_entries(_, within_seconds:); []; end
  def add_to_edit_buffer(**_); end
  def update_edit_buffer_mastodon_id(_, _, _); end
  def cleanup_edit_buffer(retention_hours:); 0; end
  def mark_edit_superseded(_, _); end
end

ed = Processors::EditDetector.new(MockStateManager.new)

# Empty texts
test("Similarity: both empty (equal strings = 1.0)", 1.0, ed.send(:calculate_similarity, '', ''))
test("Similarity: one empty", 0.0, ed.send(:calculate_similarity, 'text', ''))
test("Similarity: identical", 1.0, ed.send(:calculate_similarity, 'hello world', 'hello world'))
test("Similarity: very different", true,
     ed.send(:calculate_similarity, 'hello world', 'completely different text') < 0.5)

# Normalize for comparison
test("Normalize nil", '', ed.send(:normalize_for_comparison, nil))
test("Normalize empty", '', ed.send(:normalize_for_comparison, ''))
test("Normalize removes URLs", true,
     !ed.send(:normalize_for_comparison, 'text https://example.com').include?('http'))
test("Normalize removes mentions", true,
     !ed.send(:normalize_for_comparison, 'hello @user').include?('@'))

# Compare post IDs
test("Compare numeric IDs", true, ed.send(:compare_post_ids, '200', '100') > 0)
test("Compare numeric IDs reverse", true, ed.send(:compare_post_ids, '100', '200') < 0)
test("Compare string IDs", true, ed.send(:compare_post_ids, 'b', 'a') > 0)

# check_for_edit with empty buffer (no match)
result = ed.check_for_edit('src1', '12345', 'user1', 'Some text')
test("check_for_edit: no match returns publish_new", :publish_new, result[:action])

# =============================================================================
# FormatHelpers: Edge Cases
# =============================================================================
section("FormatHelpers: Edge Cases")

test("clean_text with non-string", '', FormatHelpers.clean_text(nil))
test("format_bytes with 0", '0 B', FormatHelpers.format_bytes(0))

# =============================================================================
# HashHelpers: Edge Cases
# =============================================================================
section("HashHelpers: Edge Cases")

test("symbolize_keys nil", {}, HashHelpers.symbolize_keys(nil))
test("symbolize_keys string", {}, HashHelpers.symbolize_keys("string"))
test("symbolize_keys array", {}, HashHelpers.symbolize_keys([1, 2, 3]))

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
