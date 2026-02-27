# frozen_string_literal: true

# Production-grade HTML cleaning and entity decoding
# Handles 100+ HTML entities with Unicode safety and proper typograpy
class HtmlCleaner
  # Pre-compiled regex patterns for performance
  NAMED_ENTITY_REGEX   = /&([A-Za-z][A-Za-z0-9]*);/.freeze
  NUM_DEC_ENTITY_REGEX = /&#(\d+);/.freeze
  NUM_HEX_ENTITY_REGEX = /&#x([0-9A-Fa-f]+);/.freeze

  # Common HTML entities (most frequently used)
  COMMON_ENTITIES = {
    'amp'    => '&',
    'lt'     => '<',
    'gt'     => '>',
    'quot'   => '"',
    'apos'   => "'",
    'nbsp'   => ' '
  }.freeze

  # Czech and European language entities (Unicode escapes for encoding safety)
  CZECH_ENTITIES = {
    # Czech vowels with acute accent
    'aacute' => "\u00E1", 'eacute' => "\u00E9", 'iacute' => "\u00ED", 'oacute' => "\u00F3", 'uacute' => "\u00FA", 'yacute' => "\u00FD",
    'Aacute' => "\u00C1", 'Eacute' => "\u00C9", 'Iacute' => "\u00CD", 'Oacute' => "\u00D3", 'Uacute' => "\u00DA", 'Yacute' => "\u00DD",

    # Czech consonants with caron
    'ccaron' => "\u010D", 'dcaron' => "\u010F", 'ecaron' => "\u011B", 'ncaron' => "\u0148", 'rcaron' => "\u0159", 'scaron' => "\u0161", 'tcaron' => "\u0165", 'zcaron' => "\u017E",
    'Ccaron' => "\u010C", 'Dcaron' => "\u010E", 'Ecaron' => "\u011A", 'Ncaron' => "\u0147", 'Rcaron' => "\u0158", 'Scaron' => "\u0160", 'Tcaron' => "\u0164", 'Zcaron' => "\u017D",

    # Ring above
    'uring'  => "\u016F", 'Uring'  => "\u016E"
  }.freeze

  # Extended European entities (Unicode escapes for encoding safety)
  EXTENDED_ENTITIES = {
    # Grave accent
    'agrave' => "\u00E0", 'egrave' => "\u00E8", 'igrave' => "\u00EC", 'ograve' => "\u00F2", 'ugrave' => "\u00F9",
    'Agrave' => "\u00C0", 'Egrave' => "\u00C8", 'Igrave' => "\u00CC", 'Ograve' => "\u00D2", 'Ugrave' => "\u00D9",

    # Circumflex
    'acirc' => "\u00E2", 'ecirc' => "\u00EA", 'icirc' => "\u00EE", 'ocirc' => "\u00F4", 'ucirc' => "\u00FB",
    'Acirc' => "\u00C2", 'Ecirc' => "\u00CA", 'Icirc' => "\u00CE", 'Ocirc' => "\u00D4", 'Ucirc' => "\u00DB",

    # Umlaut/diaeresis
    'auml' => "\u00E4", 'euml' => "\u00EB", 'iuml' => "\u00EF", 'ouml' => "\u00F6", 'uuml' => "\u00FC", 'yuml' => "\u00FF",
    'Auml' => "\u00C4", 'Euml' => "\u00CB", 'Iuml' => "\u00CF", 'Ouml' => "\u00D6", 'Uuml' => "\u00DC",

    # Tilde
    'atilde' => "\u00E3", 'ntilde' => "\u00F1", 'otilde' => "\u00F5",
    'Atilde' => "\u00C3", 'Ntilde' => "\u00D1", 'Otilde' => "\u00D5",

    # Other special characters
    'aring' => "\u00E5", 'Aring' => "\u00C5",
    'aelig' => "\u00E6", 'AElig' => "\u00C6",
    'ccedil' => "\u00E7", 'Ccedil' => "\u00C7",
    'oslash' => "\u00F8", 'Oslash' => "\u00D8",
    'szlig' => "\u00DF",
    'thorn' => "\u00FE", 'Thorn' => "\u00DE",
    'eth' => "\u00F0", 'ETH' => "\u00D0"
  }.freeze

  # Punctuation and symbols (Unicode escapes for safety)
  PUNCTUATION_ENTITIES = {
    'ndash'  => "\u2013",  # en dash
    'mdash'  => "\u2014",  # em dash
    'hellip' => "\u2026",  # horizontal ellipsis
    'lsquo'  => "\u2018",  # left single quote
    'rsquo'  => "\u2019",  # right single quote
    'ldquo'  => "\u201C",  # left double quote
    'rdquo'  => "\u201D",  # right double quote
    'bdquo'  => "\u201E",  # German opening quote
    'sbquo'  => "\u201A",  # single low-9 quote
    'laquo'  => "\u00AB",  # left angle quote
    'raquo'  => "\u00BB",  # right angle quote
    'bull'   => "\u2022",  # bullet
    'middot' => "\u00B7",  # middle dot
    'copy'   => "\u00A9",  # copyright
    'reg'    => "\u00AE",  # registered
    'trade'  => "\u2122",  # trademark
    'euro'   => "\u20AC",  # euro sign
    'pound'  => "\u00A3",  # pound sign
    'yen'    => "\u00A5",  # yen sign
    'sect'   => "\u00A7",  # section sign
    'para'   => "\u00B6",  # paragraph sign
    'deg'    => "\u00B0",  # degree sign
    'plusmn' => "\u00B1",  # plus-minus
    'times'  => "\u00D7",  # multiplication
    'divide' => "\u00F7",  # division
    'frac14' => "\u00BC",  # quarter
    'frac12' => "\u00BD",  # half
    'frac34' => "\u00BE",  # three quarters
    'shy'    => "\u00AD"   # soft hyphen (will be removed in normalization)
  }.freeze

  # Combine all entity maps
  ALL_ENTITIES = COMMON_ENTITIES
    .merge(CZECH_ENTITIES)
    .merge(EXTENDED_ENTITIES)
    .merge(PUNCTUATION_ENTITIES)
    .freeze

  class << self
    # Clean HTML text - remove tags and decode entities
    # @param text [String] HTML text to clean
    # @return [String] Plain text with entities decoded
    def clean(text)
      return '' if text.nil? || text.empty?

      # Force UTF-8 encoding and remove invalid bytes
      text = text.to_s
      text = text.dup.force_encoding('UTF-8')
      text = text.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')

      # 1. Remove HTML tags (with typography preservation)
      text = strip_tags(text)

      # 2. Decode HTML entities
      text = decode_entities(text)

      # 3. Normalize whitespace
      normalize_whitespace(text)
    end

    # Remove HTML tags while preserving typography
    # Keeps line breaks from <br>, <p> and removes <script>/<style> blocks
    def strip_tags(text)
      # 1. Remove script/style blocks first (they contain noise)
      text = text.gsub(/<script\b[^>]*>.*?<\/script>/im, ' ')
      text = text.gsub(/<style\b[^>]*>.*?<\/style>/im, ' ')

      # 2. Convert line-breaking tags to newlines
      text = text.gsub(/<(?:br|BR)\s*\/?>/, "\n")         # <br> -> newline
      text = text.gsub(/<\/(?:p|P)\s*>/i, "\n\n")        # </p> -> double newline
      text = text.gsub(/<p\b[^>]*>/i, '')                # <p> -> nothing (avoid extra space)

      # 3. Remove all remaining tags
      text.gsub(/<[^>]+>/, ' ')
    end

    # Decode all HTML entities (named and numeric)
    def decode_entities(text)
      # First decode named entities
      text = decode_named_entities(text)

      # Then decode numeric entities (&#123; and &#xAB;)
      text = decode_numeric_entities(text)

      text
    end

    # Decode named HTML entities (&amp;, &eacute;, etc.)
    def decode_named_entities(text)
      text.gsub(NAMED_ENTITY_REGEX) do |match|
        entity_name = Regexp.last_match(1)
        ALL_ENTITIES[entity_name] || match
      end
    end

    # Decode numeric HTML entities (&#225; and &#x00E1;)
    # With safe handling of out-of-range codepoints
    def decode_numeric_entities(text)
      # Decimal: &#225;
      text = text.gsub(NUM_DEC_ENTITY_REGEX) do
        code = Regexp.last_match(1).to_i
        if (0..0x10FFFF).cover?(code)
          code.chr(Encoding::UTF_8)
        else
          Regexp.last_match(0)  # Keep original if out of range
        end
      rescue RangeError
        Regexp.last_match(0)
      end

      # Hexadecimal: &#x00E1; or &#xE1;
      text = text.gsub(NUM_HEX_ENTITY_REGEX) do
        code = Regexp.last_match(1).to_i(16)
        if (0..0x10FFFF).cover?(code)
          code.chr(Encoding::UTF_8)
        else
          Regexp.last_match(0)  # Keep original if out of range
        end
      rescue RangeError
        Regexp.last_match(0)
      end

      text
    end

    # Normalize whitespace and remove soft hyphens
    def normalize_whitespace(text)
      text
        .gsub("\u00AD", '')              # Remove soft hyphen (causes artifacts)
        .gsub(/[ \t\u00A0]+/, ' ')       # Multiple spaces/tabs/nbsp to single space
        .gsub(/(\r?\n){3,}/, "\n\n")     # Multiple newlines to double newline
        .strip
    end

    # Check if text contains any HTML entities
    # @return [Boolean] Explicit boolean for clarity
    def has_entities?(text)
      !!(text =~ NAMED_ENTITY_REGEX || text =~ /&#x?[0-9A-Fa-f]+;/)
    end

    # Convenience alias used by adapters/syncers that only need entity decoding
    # Uses the full decode pipeline (named + numeric entities)
    # @param text [String] Text with HTML entities
    # @return [String] Text with entities decoded
    def decode_html_entities(text)
      return '' if text.nil?

      decode_entities(text.to_s)
    end

    # Convert HTML to plain text, preserving URLs from <a> tags
    # Used by profile syncers for Mastodon field sanitization
    # @param html [String] HTML content
    # @return [String] Plain text with URLs preserved
    def sanitize_html(html)
      return '' if html.nil? || html.empty?

      text = html.dup

      # Extract href from links and replace <a> tags with just the URL
      text.gsub!(/<a[^>]+href="([^"]*)"[^>]*>[^<]*<\/a>/) { $1 }

      # Remove any remaining HTML tags
      text.gsub!(/<[^>]+>/, '')

      # Decode HTML entities (full pipeline)
      text = decode_entities(text)

      text.strip
    end
  end
end
