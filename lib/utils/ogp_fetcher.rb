# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'ipaddr'
require 'resolv'
require_relative '../support/loggable'

module Utils
  # Fetches og:image meta tag from article URLs using a browser-like User-Agent.
  # Used to attach OGP preview images to Mastodon posts when the article URL is
  # linked in the post text — bypassing Mastodon's own scraper which many news
  # sites block.
  #
  # Usage:
  #   fetcher = Utils::OgpFetcher.new
  #   url = fetcher.fetch_og_image('https://www.phonearena.com/news/...')
  #   # => "https://cdn.phonearena.com/images/article/123456-wide-two_1200x630.jpg"
  #   # => nil if not found or on any error
  #
  class OgpFetcher
    include Support::Loggable

    USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' \
                 '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    TIMEOUT_SECONDS = 5
    MAX_RETRIES = 1        # 1 retry = celkem 2 pokusy
    RETRY_DELAY = 1        # sekunda před retry
    MAX_BODY_BYTES = 32_768 # číst prvních 32KB — moderní <head> bývá větší kvůli inline stylům
    MAX_REDIRECTS = 5       # více redirectů pro www↔non-www, http→https apod.

    # SSRF protection — block requests to private/internal networks
    PRIVATE_RANGES = [
      IPAddr.new('127.0.0.0/8'),
      IPAddr.new('10.0.0.0/8'),
      IPAddr.new('172.16.0.0/12'),
      IPAddr.new('192.168.0.0/16'),
      IPAddr.new('169.254.0.0/16'),
      IPAddr.new('fd00::/8'),
    ].freeze

    # Fetch og:image URL from given article URL.
    # Returns absolute og:image URL or nil on any failure (silent degradation).
    #
    # @param url [String] Article URL
    # @return [String, nil] og:image URL or nil on failure
    def fetch_og_image(url)
      return nil unless url.to_s.start_with?('http://', 'https://')

      attempts = 0
      begin
        attempts += 1
        html = fetch_html_partial(url)
        return nil if html.nil?

        extract_og_image(html)
      rescue StandardError => e
        if attempts <= MAX_RETRIES
          log_warn "OGP fetch failed (attempt #{attempts}), retrying in #{RETRY_DELAY}s: #{e.message}"
          sleep RETRY_DELAY
          retry
        else
          log_warn "OGP fetch failed after #{attempts} attempts: #{e.message}"
          nil
        end
      end
    end

    private

    # Fetch first MAX_BODY_BYTES of HTML from URL with redirect following.
    # Uses streaming read_body to avoid downloading full page.
    #
    # @param url [String] URL to fetch
    # @param redirects_left [Integer] Remaining redirect budget
    # @return [String, nil] Partial HTML body or nil on failure
    def fetch_html_partial(url, redirects_left: MAX_REDIRECTS)
      uri = URI(url)
      return nil unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
      return nil if private_address?(uri.host)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.open_timeout = TIMEOUT_SECONDS
      http.read_timeout = TIMEOUT_SECONDS

      request = Net::HTTP::Get.new(uri.request_uri)
      request['User-Agent'] = USER_AGENT
      request['Accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
      request['Accept-Language'] = 'en-US,en;q=0.9'
      request['Accept-Encoding'] = 'identity'  # Zakázat gzip — chceme čitelný text bez dekomprese
      request['Cache-Control'] = 'no-cache'

      partial_body = +''

      http.request(request) do |response|
        case response
        when Net::HTTPRedirection
          return nil if redirects_left <= 0

          location = response['location']
          return nil unless location

          # Make absolute URL if relative
          location = URI.join(url, location).to_s unless location.start_with?('http')
          redirect_uri = URI(location)
          return nil if private_address?(redirect_uri.host)
          return fetch_html_partial(location, redirects_left: redirects_left - 1)

        when Net::HTTPSuccess
          response.read_body do |chunk|
            partial_body += chunk
            break if partial_body.bytesize > MAX_BODY_BYTES
          end
          return partial_body.empty? ? nil : partial_body[0, MAX_BODY_BYTES]

        else
          log_warn "OGP: HTTP #{response.code} pro #{url}"
          return nil
        end
      end

      nil
    end

    # Check if hostname resolves to a private/internal IP address (SSRF protection).
    def private_address?(host)
      ips = Resolv.getaddresses(host)
      ips.any? { |ip| private_ip?(ip) }
    rescue Resolv::ResolvError
      true # Unresolvable host = block
    end

    def private_ip?(ip_str)
      return true if ip_str == '::1'
      ip = IPAddr.new(ip_str)
      PRIVATE_RANGES.any? { |range| range.include?(ip) }
    rescue IPAddr::InvalidAddressError
      true
    end

    # Extract og:image URL from HTML snippet.
    # Handles both attribute orderings and HTML entity encoding.
    # Returns only absolute http(s) URLs (ignores relative paths).
    #
    # @param html [String] HTML content (may be partial)
    # @return [String, nil] Absolute og:image URL or nil
    def extract_og_image(html)
      return nil if html.nil? || html.empty?

      # Try property-before-content, then content-before-property
      m = html.match(/<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']/i)
      m ||= html.match(/<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']/i)
      return nil unless m

      url = m[1].strip
      url = url.gsub('&amp;', '&')

      # Ignore relative URLs — better no image than a broken URL
      return nil unless url.start_with?('http://', 'https://')

      url
    end
  end
end
