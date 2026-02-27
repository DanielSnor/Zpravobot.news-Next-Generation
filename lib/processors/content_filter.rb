
# frozen_string_literal: true

# Content Filter for Zpravobot Next Generation
# ============================================
# Identical implementation to IFTTT filter script v4.0.0
# Supports: string, literal, regex, and, or, not, complex rules
#
# Usage:
#   filter = Processors::ContentFilter.new(
#     banned_phrases: ["spam", {type: "regex", pattern: "\\bad\\b"}],
#     required_keywords: ["news", "breaking"],
#     content_replacements: [{pattern: "old", replacement: "new", flags: "gi"}]
#   )
#   
#   filter.banned?(text)           # => true/false
#   filter.has_required?(text)     # => true/false  
#   filter.apply_replacements(text) # => modified text

module Processors
  class ContentFilter
    # @param banned_phrases [Array<String, Hash>] PHRASES_BANNED equivalent
    # @param required_keywords [Array<String, Hash>] PHRASES_REQUIRED equivalent
    # @param content_replacements [Array<Hash>] CONTENT_REPLACEMENTS equivalent
    def initialize(banned_phrases: [], required_keywords: [], content_replacements: [])
      @banned_phrases = Array(banned_phrases).compact
      @required_keywords = Array(required_keywords).compact
      @content_replacements = Array(content_replacements).compact
    end

    # Check if text contains banned content
    # Identical to IFTTT hasBannedContent()
    # @param str [String] Text to check
    # @return [Boolean] true if ANY banned phrase matches
    def banned?(str)
      return false if str.nil? || str.empty?
      return false if @banned_phrases.empty?

      @banned_phrases.each do |rule|
        next if rule.nil?
        return true if matches_filter_rule?(str, rule)
      end

      false
    end

    # Check if text contains required keywords
    # Identical to IFTTT hasRequiredKeywords()
    # @param str [String] Text to check
    # @return [Boolean] true if no requirements OR ANY keyword matches
    def has_required?(str)
      # IMPORTANT: Empty list = always satisfied (return true)
      return true if @required_keywords.empty?
      return false if str.nil? || str.empty?

      @required_keywords.each do |rule|
        next if rule.nil?
        return true if matches_filter_rule?(str, rule)
      end

      false
    end

    # Apply content replacements
    # Identical to IFTTT applyContentReplacements()
    # @param str [String] Text to process
    # @return [String] Text with replacements applied
    def apply_replacements(str)
      return '' if str.nil?
      return str if str.empty?
      return str if @content_replacements.empty?

      result = str.dup

      @content_replacements.each do |replacement_rule|
        next unless replacement_rule.is_a?(Hash)
        
        begin
          pattern = replacement_rule[:pattern]
          replacement = replacement_rule[:replacement] || ''
          flags = replacement_rule[:flags] || 'gi'
          literal = replacement_rule[:literal]

          next unless pattern

          # If literal, escape regex special characters
          regex_pattern = literal ? Regexp.escape(pattern) : pattern

          # Build regex options from flags
          options = build_regex_options(flags)

          regex = Regexp.new(regex_pattern, options)
          
          # Handle global flag - Ruby gsub is always global
          result = result.gsub(regex, replacement)
        rescue RegexpError => e
          # Skip invalid patterns (same as IFTTT try/catch)
          next
        end
      end

      result
    end

    # Combined check: not banned AND has required (if any)
    # @param str [String] Text to check
    # @return [Hash] {pass: Boolean, reason: String}
    def check(str)
      if banned?(str)
        return { pass: false, reason: 'banned_phrase' }
      end

      unless has_required?(str)
        return { pass: false, reason: 'missing_required_keyword' }
      end

      { pass: true, reason: nil }
    end

    private

    # Check if string matches FilterRule
    # Identical to IFTTT matchesFilterRule()
    # @param str [String] Text to check
    # @param rule [String, Hash] Filter rule
    # @return [Boolean]
    def matches_filter_rule?(str, rule)
      return false if str.nil? || str.empty?

      lower_str = str.downcase

      # SIMPLE STRING - case-insensitive substring match
      if rule.is_a?(String)
        return lower_str.include?(rule.downcase)
      end

      # NATIVE REGEXP
      if rule.is_a?(Regexp)
        return rule.match?(str)
      end

      # Must be a Hash (object)
      return false unless rule.is_a?(Hash)

      type = rule[:type]

      case type&.to_s
      when 'literal'
        # LITERAL: Case-insensitive substring match
        pattern = rule[:pattern]
        return false unless pattern
        lower_str.include?(pattern.to_s.downcase)

      when 'regex'
        # REGEX: Regular expression matching
        pattern = rule[:pattern]
        return false unless pattern

        flags = rule[:flags] || 'i'
        options = build_regex_options(flags)
        
        begin
          regex = Regexp.new(pattern, options)
          regex.match?(str)
        rescue RegexpError
          false
        end

      when 'and'
        # AND: All conditions in unified structure must match
        matches_unified_filter?(str, rule, :and)

      when 'or'
        # OR: At least one condition must match
        matches_unified_filter?(str, rule, :or)

      when 'not'
        # NOT: None should match (inverts result)
        matches_unified_filter?(str, rule, :not)

      when 'complex'
        # COMPLEX: Combines multiple rules using AND/OR operator
        rules = rule[:rules]
        operator = rule[:operator]
        
        return false if rules.nil? || rules.empty?
        return false if operator.nil?

        case operator.to_s
        when 'and'
          # All nested rules must be satisfied
          rules.all? { |r| matches_filter_rule?(str, r) }
        when 'or'
          # At least one nested rule must be satisfied
          rules.any? { |r| matches_filter_rule?(str, r) }
        else
          false
        end

      else
        # Unknown type - try as simple string match if pattern exists
        pattern = rule[:pattern]
        if pattern
          lower_str.include?(pattern.to_s.downcase)
        else
          false
        end
      end
    end

    # Evaluate unified filter (content/username/domain with regex)
    # Identical to IFTTT matchesUnifiedFilter()
    # @param str [String] Text to check
    # @param rule [Hash] Rule with content/contentRegex/username/etc arrays
    # @param match_type [:and, :or, :not] How to combine results
    # @return [Boolean]
    def matches_unified_filter?(str, rule, match_type)
      return false if str.nil? || str.empty?

      lower_str = str.downcase
      results = []

      # Process literal arrays (content, username, domain)
      [:content, :username, :domain].each do |key|
        arr = rule[key] || rule[key.to_s]
        next unless arr.is_a?(Array) && !arr.empty?

        arr.each do |item|
          next if item.nil?
          results << lower_str.include?(item.to_s.downcase)
        end
      end

      # Process regex arrays (contentRegex, usernameRegex, domainRegex)
      [:contentRegex, :usernameRegex, :domainRegex].each do |key|
        # Support both camelCase and snake_case
        arr = rule[key] || rule[key.to_s] || 
              rule[to_snake_case(key)] || rule[to_snake_case(key).to_s]
        next unless arr.is_a?(Array) && !arr.empty?

        arr.each do |pattern|
          next if pattern.nil?
          begin
            regex = Regexp.new(pattern.to_s, Regexp::IGNORECASE)
            results << regex.match?(str)
          rescue RegexpError
            results << false
          end
        end
      end

      return false if results.empty?

      # Evaluate based on match type
      case match_type
      when :or
        results.any?
      when :and
        results.all?
      when :not
        # None should be true
        results.none?
      else
        false
      end
    end

    # Convert camelCase to snake_case
    def to_snake_case(sym)
      sym.to_s
         .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
         .gsub(/([a-z\d])([A-Z])/, '\1_\2')
         .downcase
         .to_sym
    end

    # Build Ruby Regexp options from JavaScript-style flags
    # @param flags [String] Flags like "gi", "gim", etc.
    # @return [Integer] Ruby Regexp options
    def build_regex_options(flags)
      return 0 unless flags

      options = 0
      flags = flags.to_s.downcase

      # i = IGNORECASE
      options |= Regexp::IGNORECASE if flags.include?('i')
      
      # m = MULTILINE (in Ruby, this makes . match newlines)
      # Note: JavaScript 'm' is different from Ruby 'm'
      # JavaScript 'm' makes ^ and $ match line boundaries
      # Ruby MULTILINE makes . match newlines
      # For compatibility, we treat 'm' as MULTILINE
      options |= Regexp::MULTILINE if flags.include?('m')

      # g = global (Ruby gsub is always global, so we ignore this)
      # y = sticky (not supported in Ruby, ignore)
      # u = unicode (Ruby is always unicode-aware, ignore)

      options
    end
  end
end

