# frozen_string_literal: true

require 'simpleidn'
require 'uri'

# Punycode/IDN domain decoder
#
# Decodes internationalized domain names from punycode (xn--...) back to Unicode.
# Used to ensure published posts display human-readable domain names.
#
# Usage:
#   PunycodeDecoder.decode_url("https://xn--aktuln-sta08b.cz/article")
#   # => "https://aktuálně.cz/article"
#
#   PunycodeDecoder.decode_domain("xn--aktuln-sta08b.cz")
#   # => "aktuálně.cz"
#
module PunycodeDecoder
  module_function

  # Check if a domain contains punycode-encoded labels
  # @param domain [String] Domain name to check
  # @return [Boolean] true if any label starts with xn--
  def punycode?(domain)
    return false if domain.nil? || domain.empty?

    domain.downcase.split('.').any? { |label| label.start_with?('xn--') }
  end

  # Decode a punycode domain to Unicode
  # @param domain [String] Domain with possible punycode labels
  # @return [String] Domain with Unicode labels
  def decode_domain(domain)
    return domain if domain.nil? || domain.empty?
    return domain unless punycode?(domain)

    SimpleIDN.to_unicode(domain)
  rescue StandardError
    domain
  end

  # Decode punycode domain in a URL
  # @param url [String] URL with possible punycode domain
  # @return [String] URL with Unicode domain
  def decode_url(url)
    return url if url.nil? || url.empty?

    uri = URI.parse(url)
    return url unless uri.host
    return url unless punycode?(uri.host)

    decoded_host = decode_domain(uri.host)
    url.sub(uri.host, decoded_host)
  rescue URI::InvalidURIError, StandardError
    url
  end
end
