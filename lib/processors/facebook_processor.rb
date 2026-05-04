# frozen_string_literal: true

require 'set'
require_relative 'social_text_heuristics'

module Processors
  # Facebook Content Processor for Zpravobot Next Generation
  #
  # Stejně jako IG procesor rekonstruuje formátování ztracené při RSS.app
  # konverzi: emoji jako oddělovač odstavců, hashtag blok na konci, dlouhé
  # stěny textu. Plus FB-specific:
  #   - em-dash duplikáty (Reels: "Text… — Text…")
  #   - rozdělení před hashtagem v "tag-line" smíchané s názvy stránek
  #     (FB konvence: "...na Beksu! #MaxaNBL Sršni Photomate Písek BK Pardubice")
  #
  # Sdílené heuristiky jsou v Processors::SocialTextHeuristics.
  #
  # Pořadí aplikace:
  #
  #   Sanity:
  #   0. RSS.app encoding artefakty (�– → \n–)
  #
  #   Struktura odstavců:
  #   1. Emoji jako oddělovač odstavců
  #   2. Split před hashtagem v tag-line (FB-specific)
  #   3. Hashtag blok na konci
  #   4. Příliš dlouhý odstavec
  #
  #   FB-specific cleanup:
  #   5. Em-dash duplikát (Reels)
  #
  #   Konec:
  #   6. Whitespace cleanup
  #
  # Usage:
  #   processor = Processors::FacebookProcessor.new
  #   cleaned = processor.process("…na Beksu! #MaxaNBL Sršni Photomate")
  #
  class FacebookProcessor
    include SocialTextHeuristics

    # Em-dash separator used by RSS.app to join title and description
    EM_DASH_SEPARATOR = ' — '

    # Minimum similarity ratio to consider as duplicate (0.0-1.0)
    SIMILARITY_THRESHOLD = 0.6

    def initialize(config = {})
      @config = config
    end

    # Hlavní vstupní bod
    # @param text [String] Plochý text z RSS.app (z FB feedu)
    # @return [String] Text s rekonstruovanými odstavci
    def process(text)
      return '' if text.nil? || text.empty?

      result = text.dup
      # Sanity
      result = decode_rss_app_artifacts(result)
      # Struktura odstavců
      result = restore_paragraph_breaks(result)
      result = split_before_hashtag_line(result)
      result = restore_hashtag_block(result)
      result = restore_long_paragraph_breaks(result)
      # FB-specific
      result = remove_emdash_duplicate(result)
      # Konec
      result = cleanup_whitespace(result)
      result.strip
    end

    # ---------------------------------------------------------------------------
    # Heuristika: split před hashtag-line (FB-specific)
    #
    # FB feedy často končí "tag-line", kde po sentence-ending punct následuje
    # první #hashtag, ale pak pokračuje běžný text (názvy FB stránek bez @):
    #   "...na Beksu! #MaxaNBL Sršni Photomate Písek BK Pardubice ČT sport"
    #
    # `restore_hashtag_block` z modulu nezachytí (vyžaduje, aby celý zbytek byl
    # tagy). Tahle heuristika je volnější — split před prvním #-tagem, který
    # následuje po `.!?` + mezera. Tag pak může pokračovat čímkoli.
    #
    # Idempotentní vůči `restore_hashtag_block` (pokud zbytek jsou jen tagy,
    # block heuristika to formatuje finálně; tahle jen vloží \n\n).
    # ---------------------------------------------------------------------------
    def split_before_hashtag_line(text)
      text.gsub(/([.!?])\s+(?=#\w)/) { "#{$1}\n\n" }
    end

    # Detect and remove duplicate content after em-dash separator
    # RSS.app často spojuje title a description s " — "
    # U Reels obě části obsahují stejný (nebo podobný) obsah.
    #
    # Examples:
    #   "Čo ďalšie odznelo? bit.ly/xxx — Čo ďalšie odznelo? bit.ly/xxx"
    #   => "Čo ďalšie odznelo? bit.ly/xxx"
    #
    # @param text [String] Text with potential em-dash duplicate
    # @return [String] Text with duplicate removed (if detected)
    def remove_emdash_duplicate(text)
      return text unless text.include?(EM_DASH_SEPARATOR)

      parts = text.split(EM_DASH_SEPARATOR, 2)
      return text if parts.length < 2

      first_part = parts[0].strip
      second_part = parts[1].strip

      return text if first_part.empty? || second_part.empty?

      if duplicate_content?(first_part, second_part)
        longer_part = first_part.length >= second_part.length ? first_part : second_part
        return remove_emdash_duplicate(longer_part)
      end

      text
    end

    # Check if two parts are duplicates or near-duplicates
    def duplicate_content?(first, second)
      first_norm = normalize_for_comparison(first)
      second_norm = normalize_for_comparison(second)

      return true if first_norm == second_norm
      return true if prefix_match?(first_norm, second_norm)
      return true if similarity_score(first_norm, second_norm) >= SIMILARITY_THRESHOLD

      false
    end

    # Check if one string is a prefix of the other (truncated duplicate)
    def prefix_match?(first, second)
      shorter, longer = [first, second].sort_by(&:length)

      min_match_length = (shorter.length * 0.8).to_i
      return false if min_match_length < 10

      longer.start_with?(shorter[0...min_match_length])
    end

    # Calculate similarity score (Jaccard) between two strings (0.0-1.0)
    def similarity_score(first, second)
      first_words = first.split(/\s+/).to_set
      second_words = second.split(/\s+/).to_set

      return 0.0 if first_words.empty? || second_words.empty?

      intersection = (first_words & second_words).size
      union = (first_words | second_words).size

      return 0.0 if union.zero?

      intersection.to_f / union
    end

    private

    # Normalize text for em-dash duplicate comparison
    def normalize_for_comparison(text)
      normalized = text.dup
      normalized = normalized.gsub(/[…]|\.{2,}/, '')
      normalized = normalized.gsub(%r{https?://\S+}, '')
      normalized = normalized.gsub(/bit\.ly\/\S+/, '')
      normalized = normalized.gsub(/#\S+/, '')
      normalized = normalized.downcase
      normalized = normalized.gsub(/\s+/, ' ')
      normalized.strip
    end
  end
end
