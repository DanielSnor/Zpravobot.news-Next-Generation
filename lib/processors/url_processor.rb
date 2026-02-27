# frozen_string_literal: true

module Processors
  # URL Processor for cleaning and normalizing URLs in content
  #
  # Features:
  # - Removes query parameters from URLs (tracking params like utm_*)
  # - Preserves query params for configured domains (shorteners, social media)
  # - Detects and removes truncated/incomplete URLs (including FB-style with "...")
  # - Detects and removes orphan URL path fragments (after smart trim splits URL)
  # - Deduplicates URLs at end of posts
  #
  # Usage:
  #   processor = Processors::UrlProcessor.new(no_trim_domains: ['youtu.be', 'bit.ly'])
  #   cleaned = processor.process_content("Check this https://example.com?utm=xyz …")
  #   clean_url = processor.process_url("https://example.com/page?tracking=123")
  #
  class UrlProcessor
	attr_reader :no_trim_domains

	# Default domains where query params should NOT be trimmed
	# (shorteners need params, social media URLs break without them)
	DEFAULT_NO_TRIM_DOMAINS = %w[
	  facebook.com www.facebook.com
	  instagram.com www.instagram.com
	  bit.ly buff.ly brnw.ch cutt.ly dub.co goo.gl ift.tt is.gd j.mp
	  ow.ly rb.gy short.io shorturl.at smarturl.it snip.ly surl.li
	  t.co t.ly tiny.cc tinyurl.com v.gd
	  amzn.to fb.me lnkd.in on.fb.me pin.it redd.it wp.me
	  youtu.be youtube.com www.youtube.com
	  apne.ws bbc.in bloom.bg cnn.it econ.st nyti.ms politi.co reut.rs tcrn.ch wapo.st
	  flashsco.re piped.video
	  1url.cz jdem.cz sdu.sk sqzr.cz
	].freeze

	# URL detection regex - matches http/https URLs
	URL_REGEX = %r{https?://[^\s<>"']+}i.freeze

	# ==========================================================================
	# TRUNCATED URL PATTERNS
	# ==========================================================================
	# These patterns detect URLs that have been visually truncated by platforms
	# like Facebook, which display "https://domain/.../page..." in their UI.
	# RSS.app then captures these truncated visual representations.
	#
	# We match both:
	# - Unicode ellipsis: … (U+2026)
	# - ASCII dots: .. or ... (two or more consecutive dots)
	# ==========================================================================

	# Pattern for ellipsis (Unicode or ASCII dots)
	ELLIPSIS_PATTERN = '(?:\u2026|\.{2,})'

	# Truncated URL patterns (URL containing ellipsis anywhere)
	# Matches: "https://domain/path…" or "https://domain/.../page..."
	TRUNCATED_URL_REGEX = %r{https?://[^\s]*#{ELLIPSIS_PATTERN}[^\s]*}i.freeze

	# URL without protocol but with ellipsis (e.g., "www.example.c…" or "www.example.c...")
	TRUNCATED_URL_NO_PROTO_REGEX = /(?:www\.)?[a-zA-Z0-9][a-zA-Z0-9-]*\.[a-zA-Z0-9][^\s]*#{ELLIPSIS_PATTERN}[^\s]*/i.freeze

	# Protocol fragment patterns (partial URLs like "http…" or "https...")
	PROTOCOL_FRAGMENT_REGEX = /\bhttps?(?:\u2026|\.{2,})/i.freeze

	# Facebook-style path ellipsis: URLs where FB replaced part of path with /.../ or /…/
	# Example: "https://www.noviny.sk/.../1158124-article-title..."
	FB_PATH_ELLIPSIS_REGEX = %r{https?://[^\s]*/#{ELLIPSIS_PATTERN}/[^\s]*}i.freeze

	# ==========================================================================
	# ORPHAN URL FRAGMENT PATTERNS
	# ==========================================================================
	# These patterns detect URL fragments that remain after smart trim splits
	# a truncated URL in the middle. The protocol and domain are gone, leaving
	# only a path fragment that looks like "/1158226-article-slug…"
	#
	# Example flow:
	#   1. Original: "Text https://www.noviny.sk/.../1158226-trump-chce-od-krajin..."
	#   2. After smart trim: "Text /1158226-trump-chce-od-krajin-miliar…"
	#   3. After this fix: "Text …"
	# ==========================================================================

	# Orphan URL path fragment - starts with / + digit, has slug pattern, ends with ellipsis
	# Minimum 10 chars after digit to avoid false positives
	ORPHAN_PATH_FRAGMENT_REGEX = %r{/\d+[a-zA-Z0-9-]{10,}#{ELLIPSIS_PATTERN}}i.freeze

	# Orphan slug fragment without leading slash (word boundary)
	# Pattern: digit + multiple hyphenated words + ellipsis
	# Example: "1158226-trump-chce-od-krajin-miliar…"
	ORPHAN_SLUG_FRAGMENT_REGEX = /(?<=\s|^)\d+(?:-[a-zA-Z0-9]+){2,}[a-zA-Z0-9-]*#{ELLIPSIS_PATTERN}/i.freeze

	def initialize(no_trim_domains: nil, config: nil)
	  @no_trim_domains = no_trim_domains || load_from_config(config) || DEFAULT_NO_TRIM_DOMAINS
	  @no_trim_domains = @no_trim_domains.map(&:downcase)
	end

	# Process all URLs in content text
	# @param text [String] Text containing URLs
	# @return [String] Text with processed URLs
	def process_content(text)
	  return '' if text.nil? || text.empty?

	  result = text.dup

	  # 0. Normalize ellipsis variants FIRST (before any URL processing)
	  #    This converts "..." to "…" for consistent processing
	  result = normalize_ellipsis(result)

	  # 1. Remove truncated URLs (must be before URL encoding)
	  result = remove_truncated_urls(result) if has_truncated_url?(result)

	  # 2. Process remaining URLs (trim query params)
	  result = process_urls_in_text(result)

	  # 3. Remove incomplete URLs at end (after trimming)
	  result = remove_incomplete_url_from_end(result) if has_incomplete_url_at_end?(result)

	  # 4. Deduplicate URLs at end
	  result = deduplicate_trailing_urls(result)

	  # 5. Normalize multiple ellipses to single
	  result = result.gsub(/\u2026+/, '…')

	  # 6. Clean up whitespace before ellipsis (e.g., "text  …" -> "text …")
	  result = result.gsub(/\s+…/, ' …')

	  # 7. Clean up trailing ellipsis with only whitespace before it
	  result = result.sub(/\s{2,}…\s*$/, ' …')

	  result.strip
	end

	# Process a single URL
	# @param url [String] URL to process
	# @return [String] Processed URL
	def process_url(url)
	  return '' if url.nil? || url.empty?

	  url = url.strip
	  return '' if url == '(none)'

	  # Check if URL contains ellipsis - if so, it's truncated and invalid
	  return '' if url.match?(/#{ELLIPSIS_PATTERN}/)

	  # Check if domain should skip trimming
	  if should_preserve_query?(url)
		# Just encode ampersands for these domains
		encode_ampersands(url)
	  else
		# Remove query params and encode
		trimmed = trim_query_params(url)
		encode_ampersands(trimmed)
	  end
	end

	# Check if text contains truncated URLs or orphan URL fragments
	# @param text [String] Text to check
	# @return [Boolean] True if truncated URL or fragment found
	def has_truncated_url?(text)
	  return false if text.nil? || text.empty?

	  # URL with ellipsis anywhere: "https://domain/…" or "https://domain/path…"
	  # Also catches: "https://domain/..." or "https://domain/.../path"
	  return true if text.match?(TRUNCATED_URL_REGEX)

	  # URL without protocol with ellipsis: "www.example.c…"
	  return true if text.match?(TRUNCATED_URL_NO_PROTO_REGEX)

	  # Facebook-style path ellipsis: "https://domain/.../page"
	  return true if text.match?(FB_PATH_ELLIPSIS_REGEX)

	  # Orphan path fragment (URL split by trimming): "/1158226-article-slug…"
	  return true if text.match?(ORPHAN_PATH_FRAGMENT_REGEX)

	  # Orphan slug fragment without slash: "1158226-article-slug…"
	  return true if text.match?(ORPHAN_SLUG_FRAGMENT_REGEX)

	  false
	end

	# Remove truncated URLs and orphan fragments from text
	# @param text [String] Text containing truncated URLs
	# @return [String] Text with truncated URLs removed (replaced by single ellipsis)
	def remove_truncated_urls(text)
	  return text if text.nil? || text.empty?

	  result = text.dup

	  # Remove Facebook-style URLs with ellipsis in path first
	  # (more specific pattern, should be matched before general truncated URL)
	  result = result.gsub(FB_PATH_ELLIPSIS_REGEX, '…')

	  # Remove complete URLs with ellipsis anywhere
	  result = result.gsub(TRUNCATED_URL_REGEX, '…')

	  # Remove incomplete URLs without protocol
	  result = result.gsub(TRUNCATED_URL_NO_PROTO_REGEX, '…')

	  # Remove orphan path fragments (remains after URL split by trimming)
	  result = result.gsub(ORPHAN_PATH_FRAGMENT_REGEX, '…')

	  # Remove orphan slug fragments (without leading slash)
	  result = result.gsub(ORPHAN_SLUG_FRAGMENT_REGEX, '…')

	  # Normalize multiple ellipses to single
	  result = result.gsub(/\u2026+/, '…')

	  # Clean up double spaces that may result from URL removal
	  result = result.gsub(/\s+/, ' ')

	  result.strip
	end

	# Check if text has incomplete URL at end (from truncation)
	# @param text [String] Text to check
	# @return [Boolean] True if incomplete URL at end
	def has_incomplete_url_at_end?(text)
	  return false if text.nil? || text.empty?

	  # URL ending with dot: "https://www.instagram."
	  return true if text.match?(%r{https?://[^\s]*\.$})

	  # Very short domain: "https://www" or "https://in"
	  return true if text.match?(%r{https?://[a-zA-Z]{1,4}$})

	  # Incomplete TLD (1-2 chars): "https://instagram.c"
	  return true if text.match?(%r{https?://[a-zA-Z0-9-]+\.[a-zA-Z]{1,2}$})

	  # Incomplete after www: "https://www.inst"
	  return true if text.match?(%r{https?://www\.[a-zA-Z0-9-]{1,10}$})

	  # Short path segment: "https://domain.com/ab"
	  return true if text.match?(%r{https?://[^\s]+/[a-zA-Z]{1,2}$})

	  # Protocol fragments: "http…" "https…" "http..." "https..."
	  return true if text.match?(PROTOCOL_FRAGMENT_REGEX)

	  false
	end

	# Remove incomplete URL from end of text
	# @param text [String] Text with potential incomplete URL at end
	# @return [String] Text with incomplete URL removed
	def remove_incomplete_url_from_end(text)
	  return '' if text.nil? || text.empty?

	  result = text.dup

	  # Remove protocol fragments with ellipsis first
	  result = result.gsub(PROTOCOL_FRAGMENT_REGEX, '')

	  # Find last URL protocol
	  http_index = result.rindex('http://')
	  https_index = result.rindex('https://')
	  url_start_index = [http_index || -1, https_index || -1].max

	  # If no URL protocol found, return original
	  return result.strip if url_start_index == -1

	  # Check if URL is preceded by space or is at start
	  has_space_before = url_start_index.zero? || result[url_start_index - 1].match?(/\s/)
	  return result.strip unless has_space_before

	  # Extract potential URL
	  potential_url = result[url_start_index..]

	  # Check if URL looks complete (ends properly)
	  is_complete = potential_url.match?(%r{https?://[a-zA-Z0-9-]+\.[a-zA-Z]{3,}(?:/[^\s]*)?[a-zA-Z0-9/_\-~]$})
	  return result.strip if is_complete

	  # Remove incomplete URL
	  result[0...url_start_index].strip
	end

	# Remove duplicate URLs at end of text
	# Prevents: "Some text with https://url.com\nhttps://url.com"
	# @param text [String] Text to deduplicate
	# @return [String] Text with duplicate trailing URLs removed
	def deduplicate_trailing_urls(text)
	  return '' if text.nil? || text.empty?
	
	  # Find URL at the very end of text (with optional preceding newlines)
	  # This ensures we're working with the actual trailing URL, not using rindex
	  trailing_match = text.match(/([\r\n]+)(https?:\/\/[^\s]+)\s*$/)
	  return text unless trailing_match
	  
	  trailing_newlines = trailing_match[1]
	  trailing_url = trailing_match[2]
	  
	  # Get text before the trailing URL
	  text_before_trailing = text[0...trailing_match.begin(0)]
	  
	  # Normalize for comparison
	  normalized_trailing = normalize_url_for_comparison(trailing_url)
	  
	  # Find all URLs in the text BEFORE the trailing URL
	  earlier_urls = text_before_trailing.scan(URL_REGEX)
	  return text if earlier_urls.empty?
	  
	  # Check if any earlier URL matches the trailing URL
	  has_earlier_match = earlier_urls.any? do |url|
		normalize_url_for_comparison(url) == normalized_trailing
	  end
	  
	  return text unless has_earlier_match
	  
	  # Remove the trailing URL (it's a duplicate)
	  # Also remove the preceding newlines
	  text_before_trailing.rstrip
	end

	# Apply domain fixes - prepend https:// to bare domain URLs (including subdomains)
	# @param text [String] Text containing potential bare domain URLs
	# @param domains [Array<String>] List of domains to fix (e.g., ["idnes.cz", "chmi.cz"])
	# @return [String] Text with https:// prepended to matching domains (including subdomains)
	#
	# Examples:
	#   apply_domain_fixes("Článek na idnes.cz/zpravy/test", ["idnes.cz"])
	#   # => "Článek na https://idnes.cz/zpravy/test"
	#
	#   apply_domain_fixes("Výstrahy na vystrahy-cr.chmi.cz", ["chmi.cz"])
	#   # => "Výstrahy na https://vystrahy-cr.chmi.cz"
	#
	def apply_domain_fixes(text, domains)
	  return text if text.nil? || text.empty?
	  return text if domains.nil? || domains.empty?
	  
	  result = text.dup
	  
	  # 1. Protect existing URLs with placeholders
	  url_pattern = /https?:\/\/[^\s]+/i
	  urls = result.scan(url_pattern)
	  urls.each_with_index do |url, i|
		result = result.sub(url, "___URL_PLACEHOLDER_#{i}___")
	  end
	  
	  # 2. Apply domain fixes to text WITHOUT URLs
	  domains.each do |domain|
		next if domain.nil? || domain.strip.empty?
		domain = domain.strip.downcase
		
		# Match domain + any subdomains (e.g., "chmi.cz" matches "vystrahy-cr.chmi.cz")
		# Negative lookbehind excludes: alphanumeric, slash, colon, at sign
		subdomain_pattern = '(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?\.)*'
		pattern = /(?<![a-zA-Z0-9\/\/:@])(#{subdomain_pattern}#{Regexp.escape(domain)})(\/[^\s]*|(?=[\s,;:.!?\)\]"]|$))/i
		result = result.gsub(pattern) do |_match|
		  matched_domain = Regexp.last_match(1)
		  path = Regexp.last_match(2) || ''
		  "https://#{matched_domain.downcase}#{path}"
		end
	  end
	  
	  # 3. Restore URLs from placeholders
	  urls.each_with_index do |url, i|
		result = result.sub("___URL_PLACEHOLDER_#{i}___", url)
	  end
	  
	  result
	end

	private

	# Normalize various ellipsis representations to Unicode ellipsis
	# @param text [String] Text with potential ASCII ellipsis (...)
	# @return [String] Text with normalized Unicode ellipsis (…)
	def normalize_ellipsis(text)
	  return '' if text.nil? || text.empty?

	  # Replace 2+ consecutive dots with Unicode ellipsis
	  # This handles: "..", "...", "....", etc.
	  text.gsub(/\.{2,}/, '…')
	end

	def load_from_config(config)
	  return nil unless config

	  config.dig('url', 'no_trim_domains')
	end

	# Check if URL domain should preserve query params
	def should_preserve_query?(url)
	  return false if url.nil? || url.empty?

	  url_lower = url.downcase
	  @no_trim_domains.any? { |domain| url_lower.include?(domain) }
	end

	# Remove query string from URL
	# @param url [String] URL with potential query params
	# @return [String] URL without query params
	def trim_query_params(url)
	  return '' if url.nil? || url.empty?

	  # Find query string start
	  query_index = url.index('?')
	  return url unless query_index

	  url[0...query_index]
	end

	# Encode ampersands in URL for safe use
	def encode_ampersands(url)
	  return '' if url.nil? || url.empty?

	  url.gsub('&', '%26')
	end

	# Process all URLs in text
	def process_urls_in_text(text)
	  text.gsub(URL_REGEX) do |url|
		process_url(url)
	  end
	end

	# Normalize URL for comparison (deduplication)
	def normalize_url_for_comparison(url)
	  return '' if url.nil? || url.empty?

	  normalized = url.downcase
	  # Remove trailing punctuation
	  normalized = normalized.sub(/[.,;:!?]+$/, '')
	  # Remove query params
	  normalized = trim_query_params(normalized)
	  # Remove trailing slash
	  normalized = normalized.sub(%r{/+$}, '')
	  # Remove protocol for comparison
	  normalized = normalized.sub(%r{^https?://}, '')
	  normalized
	end
  end
end
