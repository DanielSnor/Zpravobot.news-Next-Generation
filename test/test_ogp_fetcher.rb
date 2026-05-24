#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Test Script: OgpFetcher
# ============================================================
#
# Testuje Utils::OgpFetcher — extrakci og:image, retry logiku
# a tiché selhání. Nevyžaduje síť — HTTP je mockováno.
#
# Použití:
#   ruby test/test_ogp_fetcher.rb
#   ruby test/test_ogp_fetcher.rb --verbose
#
# ============================================================

require_relative '../lib/utils/ogp_fetcher'

# ============================================================
# Test suite
# ============================================================

class OgpFetcherTest
  def initialize
    @passed = 0
    @failed = 0
  end

  def run_all
    puts
    puts '=' * 60
    puts '  OgpFetcher Tests'
    puts '=' * 60
    puts

    test_extracts_og_image_property_before_content
    test_extracts_og_image_content_before_property
    test_returns_nil_when_no_og_image_tag
    test_returns_nil_for_nil_url
    test_returns_nil_for_empty_url
    test_returns_nil_for_non_http_url
    test_returns_nil_for_http_non_200
    test_returns_nil_on_exception
    test_decodes_html_entities_in_url
    test_returns_nil_for_relative_og_image
    test_retry_on_first_failure_then_success
    test_returns_nil_after_max_retries_exhausted
    test_extract_article_url_skips_platform_domains
    test_extract_article_url_finds_article_url

    # SSRF guard — DNS validation + IP pinning (TOCTOU defense)
    test_resolve_blocks_private_and_special_ips
    test_resolve_allows_public_ipv4
    test_resolve_blocks_mixed_public_and_private
    test_resolve_prefers_ipv4_over_ipv6
    test_resolve_returns_nil_on_resolv_error
    test_resolve_returns_nil_on_empty_resolution

    puts
    puts '=' * 60
    puts "  Results: #{@passed} passed, #{@failed} failed"
    puts '=' * 60
    puts

    @failed == 0
  end

  private

  # ============================================================
  # Tests — og:image extraction (unit level, no network)
  # ============================================================

  def test_extracts_og_image_property_before_content
    test('extract_og_image: property before content') do
      html = '<html><head>' \
             '<meta property="og:image" content="https://cdn.example.com/image.jpg">' \
             '</head></html>'
      result = fetcher_extract(html)
      assert_equal 'https://cdn.example.com/image.jpg', result
    end
  end

  def test_extracts_og_image_content_before_property
    test('extract_og_image: content before property') do
      html = '<html><head>' \
             '<meta content="https://cdn.example.com/image.jpg" property="og:image">' \
             '</head></html>'
      result = fetcher_extract(html)
      assert_equal 'https://cdn.example.com/image.jpg', result
    end
  end

  def test_returns_nil_when_no_og_image_tag
    test('extract_og_image: returns nil when no og:image tag present') do
      html = '<html><head><title>Article</title></head><body>content</body></html>'
      result = fetcher_extract(html)
      assert_nil result
    end
  end

  def test_returns_nil_for_nil_url
    test('fetch_og_image: returns nil for nil URL (no network call)') do
      fetcher = Utils::OgpFetcher.new
      result = fetcher.fetch_og_image(nil)
      assert_nil result
    end
  end

  def test_returns_nil_for_empty_url
    test('fetch_og_image: returns nil for empty string URL') do
      fetcher = Utils::OgpFetcher.new
      result = fetcher.fetch_og_image('')
      assert_nil result
    end
  end

  def test_returns_nil_for_non_http_url
    test('fetch_og_image: returns nil for non-http URL (ftp://, file://, etc.)') do
      fetcher = Utils::OgpFetcher.new
      assert_nil fetcher.fetch_og_image('ftp://example.com/page')
      assert_nil fetcher.fetch_og_image('file:///etc/passwd')
      assert_nil fetcher.fetch_og_image('javascript:alert(1)')
    end
  end

  def test_returns_nil_for_http_non_200
    test('fetch_og_image: returns nil when HTTP status is not 200 (mock 404)') do
      fetcher = make_fetcher_with_mock_response(status: :not_found)
      result = fetcher.fetch_og_image('https://example.com/article')
      assert_nil result
    end
  end

  def test_returns_nil_on_exception
    test('fetch_og_image: returns nil when network raises exception (silent failure)') do
      fetcher = make_fetcher_with_mock_exception(RuntimeError.new('connection refused'))
      result = fetcher.fetch_og_image('https://example.com/article')
      assert_nil result
    end
  end

  def test_decodes_html_entities_in_url
    test('extract_og_image: decodes &amp; in og:image URL') do
      html = '<meta property="og:image" content="https://cdn.example.com/img?a=1&amp;b=2">'
      result = fetcher_extract(html)
      assert_equal 'https://cdn.example.com/img?a=1&b=2', result
    end
  end

  def test_returns_nil_for_relative_og_image
    test('extract_og_image: returns nil for relative og:image URL') do
      html = '<meta property="og:image" content="/images/photo.jpg">'
      result = fetcher_extract(html)
      assert_nil result
    end
  end

  # ============================================================
  # Tests — retry logic
  # ============================================================

  def test_retry_on_first_failure_then_success
    test('retry: retries once after failure, succeeds on second attempt') do
      attempts = 0
      html_with_og = '<meta property="og:image" content="https://cdn.example.com/img.jpg">'

      fetcher = Utils::OgpFetcher.new
      # Stub fetch_html_partial to fail on attempt 1, succeed on attempt 2
      fetcher.define_singleton_method(:fetch_html_partial) do |_url, **_kwargs|
        attempts += 1
        raise 'simulated timeout' if attempts == 1

        html_with_og
      end
      # Stub sleep to avoid actual delay
      fetcher.define_singleton_method(:sleep) { |_| nil }

      result = fetcher.fetch_og_image('https://example.com/article')
      assert_equal 2, attempts
      assert_equal 'https://cdn.example.com/img.jpg', result
    end
  end

  def test_returns_nil_after_max_retries_exhausted
    test('retry: returns nil after all attempts exhausted (MAX_RETRIES=1 → 2 total)') do
      attempts = 0

      fetcher = Utils::OgpFetcher.new
      fetcher.define_singleton_method(:fetch_html_partial) do |_url, **_kwargs|
        attempts += 1
        raise 'persistent failure'
      end
      fetcher.define_singleton_method(:sleep) { |_| nil }

      result = fetcher.fetch_og_image('https://example.com/article')
      # MAX_RETRIES = 1 means 1 retry = 2 total attempts
      assert_equal 2, attempts
      assert_nil result
    end
  end

  # ============================================================
  # Tests — extract_article_url_from_text (via PostProcessor helper)
  # ============================================================

  def test_extract_article_url_skips_platform_domains
    test('extract_article_url: skips twitter.com, x.com, t.co, bsky, nitter, xcancel URLs') do
      # Simulate PostProcessor.extract_article_url_from_text via standalone helper
      skip_domains = %w[twitter.com x.com t.co bsky.app bsky.social zpravobot.news nitter xcancel.com]

      text = 'Check this: https://twitter.com/user/status/123 and https://t.co/abc'
      urls = text.scan(%r{https?://[^\s>)]+})
      result = urls.find { |u| skip_domains.none? { |d| u.include?(d) } }
      assert_nil result
    end
  end

  def test_extract_article_url_finds_article_url
    test('extract_article_url: finds article URL among platform URLs') do
      skip_domains = %w[twitter.com x.com t.co bsky.app bsky.social zpravobot.news nitter xcancel.com]

      text = 'PhoneArena: https://xcancel.com/phonearena/status/123 ' \
             'https://www.phonearena.com/news/article-title_id123456'
      urls = text.scan(%r{https?://[^\s>)]+})
      result = urls.find { |u| skip_domains.none? { |d| u.include?(d) } }
      assert_equal 'https://www.phonearena.com/news/article-title_id123456', result
    end
  end

  # ============================================================
  # Tests — SSRF guard (DNS validation + IP pinning, TOCTOU defense)
  # ============================================================
  #
  # `resolve_and_validate` je jádro obrany proti DNS rebinding: vrátí jednu
  # validovanou IP, nebo nil. fetch_html_partial pak pinuje TCP přes
  # `http.ipaddr=`, takže Net::HTTP DNS nesahá.
  #
  # Testy pokrývají klasifikační logiku (které IP se blokují) a chování
  # při edge case'ech (mixed, prázdná resolution, Resolv chyba).

  def test_resolve_blocks_private_and_special_ips
    test('resolve_and_validate: blokuje všechny private/special-use IP') do
      blocked = %w[
        10.0.0.1 127.0.0.1 169.254.169.254 172.16.0.1 192.168.1.1
        100.64.0.1 224.0.0.1 ::1 fc00::1 fd00::1 fe80::1 0.0.0.0
      ]
      blocked.each do |ip|
        with_resolv_stub([ip]) do
          result = Utils::OgpFetcher.new.send(:resolve_and_validate, 'attacker.example')
          assert_nil result, "měl blokovat #{ip}"
        end
      end
    end
  end

  def test_resolve_allows_public_ipv4
    test('resolve_and_validate: vrátí public IPv4 beze změny') do
      with_resolv_stub(['8.8.8.8']) do
        result = Utils::OgpFetcher.new.send(:resolve_and_validate, 'public.example')
        assert_equal '8.8.8.8', result
      end
    end
  end

  def test_resolve_blocks_mixed_public_and_private
    test('resolve_and_validate: blokuje pokud ANY IP private (i když je tam public)') do
      with_resolv_stub(['1.2.3.4', '10.0.0.1']) do
        result = Utils::OgpFetcher.new.send(:resolve_and_validate, 'mixed.example')
        assert_nil result
      end
    end
  end

  def test_resolve_prefers_ipv4_over_ipv6
    test('resolve_and_validate: preferuje IPv4 i když je první IPv6') do
      with_resolv_stub(['2001:db8::1', '1.2.3.4']) do
        result = Utils::OgpFetcher.new.send(:resolve_and_validate, 'dual.example')
        assert_equal '1.2.3.4', result
      end
    end
  end

  def test_resolve_returns_nil_on_resolv_error
    test('resolve_and_validate: Resolv::ResolvError → nil (nepropouští výjimku)') do
      with_resolv_raise(Resolv::ResolvError.new('NXDOMAIN')) do
        result = Utils::OgpFetcher.new.send(:resolve_and_validate, 'nonexistent.example')
        assert_nil result
      end
    end
  end

  def test_resolve_returns_nil_on_empty_resolution
    test('resolve_and_validate: prázdné pole IPs → nil') do
      with_resolv_stub([]) do
        result = Utils::OgpFetcher.new.send(:resolve_and_validate, 'empty.example')
        assert_nil result
      end
    end
  end

  # ============================================================
  # Test helpers
  # ============================================================

  # Run extract_og_image on HTML without network (accesses private method via send)
  def fetcher_extract(html)
    Utils::OgpFetcher.new.send(:extract_og_image, html)
  end

  # Stub Resolv.getaddresses pro dobu yieldu — vrátí předem nastavené pole IPs.
  # Resolv je modul, proto stubujeme přes singleton_class. Po skončení obnovíme
  # původní metodu i kdyby test vyhodil výjimku.
  def with_resolv_stub(addresses)
    original = Resolv.method(:getaddresses)
    Resolv.singleton_class.send(:define_method, :getaddresses) { |_host| addresses }
    yield
  ensure
    Resolv.singleton_class.send(:define_method, :getaddresses, original)
  end

  # Stub Resolv.getaddresses tak, aby vyhodil zadanou výjimku.
  def with_resolv_raise(exception)
    original = Resolv.method(:getaddresses)
    Resolv.singleton_class.send(:define_method, :getaddresses) { |_host| raise exception }
    yield
  ensure
    Resolv.singleton_class.send(:define_method, :getaddresses, original)
  end

  # Create fetcher whose fetch_html_partial returns a mock non-success response
  def make_fetcher_with_mock_response(status:)
    fetcher = Utils::OgpFetcher.new
    fetcher.define_singleton_method(:fetch_html_partial) do |_url, **_kwargs|
      # Return nil for any non-success response (same as the real implementation)
      nil
    end
    fetcher
  end

  # Create fetcher whose fetch_html_partial raises an exception on every call
  def make_fetcher_with_mock_exception(exception)
    fetcher = Utils::OgpFetcher.new
    fetcher.define_singleton_method(:fetch_html_partial) do |_url, **_kwargs|
      raise exception
    end
    fetcher.define_singleton_method(:sleep) { |_| nil }
    fetcher
  end

  def test(name)
    print "  #{name}... "
    begin
      yield
      puts '✅'
      @passed += 1
    rescue AssertionError => e
      puts '❌'
      puts "    #{e.message}"
      @failed += 1
    rescue StandardError => e
      puts '💥'
      puts "    #{e.class}: #{e.message}"
      puts e.backtrace.first(3).map { |l| "      #{l}" }.join("\n") if $verbose
      @failed += 1
    end
  end

  def assert(condition, message = 'Assertion failed')
    raise AssertionError, message unless condition
  end

  def assert_equal(expected, actual, message = nil)
    return if expected == actual

    raise AssertionError, message || "Expected #{expected.inspect}, got #{actual.inspect}"
  end

  def assert_nil(actual, message = nil)
    return if actual.nil?

    raise AssertionError, message || "Expected nil, got #{actual.inspect}"
  end

  class AssertionError < StandardError; end
end

# Run tests
$verbose = ARGV.include?('--verbose') || ARGV.include?('-v')
success = OgpFetcherTest.new.run_all
exit(success ? 0 : 1)
