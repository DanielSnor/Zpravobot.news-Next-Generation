
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
    CAMEL_TO_SNAKE = {
      contentRegex: :content_regex,
      usernameRegex: :username_regex,
      domainRegex: :domain_regex
    }.freeze

    RULE_TYPE_HANDLERS = {
      'literal' => :match_rule_literal,
      'regex'   => :match_rule_regex,
      'and'     => :match_rule_and,
      'or'      => :match_rule_or,
      'not'     => :match_rule_not,
      'complex' => :match_rule_complex
    }.freeze
    # @param banned_phrases [Array<String, Hash>] PHRASES_BANNED equivalent
    # @param required_keywords [Array<String, Hash>] PHRASES_REQUIRED equivalent
    # @param content_replacements [Array<Hash>] CONTENT_REPLACEMENTS equivalent
    def initialize(banned_phrases: [], required_keywords: [], content_replacements: [])
      @banned_phrases = precompile_rules(Array(banned_phrases).compact)
      @required_keywords = precompile_rules(Array(required_keywords).compact)
      @content_replacements = precompile_replacements(Array(content_replacements).compact)
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
        regex = replacement_rule[:_compiled]
        next unless regex
        replacement = replacement_rule[:replacement] || ''
        result = result.gsub(regex, replacement)
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

      return lower_str.include?(rule.downcase) if rule.is_a?(String)
      return rule.match?(str)                  if rule.is_a?(Regexp)
      return false                             unless rule.is_a?(Hash)

      handler = RULE_TYPE_HANDLERS[rule[:type]&.to_s]
      return send(handler, str, rule, lower_str) if handler

      # Unknown type — fallback to substring match if pattern exists
      pattern = rule[:pattern]
      pattern ? lower_str.include?(pattern.to_s.downcase) : false
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

      # Process regex arrays (contentRegex, usernameRegex, domainRegex).
      # Použij předkompilované regexy z precompile_rule pokud existují;
      # fallback je kompilace per call (pro volání mimo initialize / testy).
      CAMEL_TO_SNAKE.each_key do |key|
        snake = CAMEL_TO_SNAKE[key]
        compiled = rule["_compiled_#{snake}".to_sym]

        unless compiled
          arr = rule[key] || rule[key.to_s] || rule[snake] || rule[snake.to_s]
          next unless arr.is_a?(Array) && !arr.empty?
          compiled = arr.reject(&:nil?).map { |p| compile_regex(p.to_s, Regexp::IGNORECASE) }
        end

        # nil v compiled = broken pattern → false (zachovává původní semantiku)
        compiled.each { |r| results << (r ? r.match?(str) : false) }
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

    def match_rule_literal(_, rule, lower_str)
      pattern = rule[:pattern]
      return false unless pattern
      lower_str.include?(pattern.to_s.downcase)
    end

    def match_rule_regex(str, rule, _lower_str)
      regex = rule[:_compiled] || begin
        return false unless rule[:pattern]
        compile_regex(rule[:pattern], build_regex_options(rule[:flags] || 'i'))
      end
      return false unless regex
      regex.match?(str)
    end

    def match_rule_and(str, rule, _lower_str) = matches_unified_filter?(str, rule, :and)
    def match_rule_or(str, rule, _lower_str)  = matches_unified_filter?(str, rule, :or)
    def match_rule_not(str, rule, _lower_str) = matches_unified_filter?(str, rule, :not)

    def match_rule_complex(str, rule, _lower_str)
      rules    = rule[:rules]
      operator = rule[:operator]
      return false if rules.nil? || rules.empty? || operator.nil?
      case operator.to_s
      when 'and' then rules.all? { |r| matches_filter_rule?(str, r) }
      when 'or'  then rules.any? { |r| matches_filter_rule?(str, r) }
      else false
      end
    end

    def precompile_replacements(rules)
      rules.map do |rule|
        next rule unless rule.is_a?(Hash) && rule[:pattern]
        regex_pattern = rule[:literal] ? Regexp.escape(rule[:pattern]) : rule[:pattern]
        options = build_regex_options(rule[:flags] || 'gi')
        rule.merge(_compiled: Regexp.new(regex_pattern, options))
      rescue RegexpError
        nil
      end.compact
    end

    # Rekurzivně předkompiluje regex patterny ve filter pravidlech (banned/required).
    # Pro každé pravidlo vrací nový hash obohacený o `_compiled` / `_compiled_<key>`
    # klíče; String pravidla a literal/jiné neregex typy se vracejí beze změny.
    # Cíl: žádný Regexp.new v hot path (per-post evaluace).
    def precompile_rules(rules)
      rules.map { |r| precompile_rule(r) }
    end

    def precompile_rule(rule)
      return rule unless rule.is_a?(Hash)

      result = rule.dup
      type = rule[:type]&.to_s

      case type
      when 'regex'
        if rule[:pattern]
          result[:_compiled] = compile_regex(rule[:pattern], build_regex_options(rule[:flags] || 'i'))
        end
      when 'and', 'or', 'not'
        # Unified filter — předkompiluj contentRegex/usernameRegex/domainRegex pole.
        # nil v poli = invalid pattern; zůstává v compiled jako nil → matchne false.
        CAMEL_TO_SNAKE.each_key do |key|
          snake = CAMEL_TO_SNAKE[key]
          arr = rule[key] || rule[key.to_s] || rule[snake] || rule[snake.to_s]
          next unless arr.is_a?(Array) && !arr.empty?

          result["_compiled_#{snake}".to_sym] = arr.reject(&:nil?).map do |pattern|
            compile_regex(pattern.to_s, Regexp::IGNORECASE)
          end
        end
      when 'complex'
        inner = rule[:rules]
        result[:rules] = inner.map { |r| precompile_rule(r) } if inner.is_a?(Array)
      end

      result
    end

    # Kompiluje pattern → Regexp; nil pokud pattern není validní.
    # Sdíleno mezi precompile (init time) a match fallback (per call).
    def compile_regex(pattern, options)
      Regexp.new(pattern.to_s, options)
    rescue RegexpError
      nil
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

