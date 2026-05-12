# frozen_string_literal: true

require_relative 'social_text_heuristics'

module Processors
  # Instagram Content Processor for Zpravobot Next Generation
  #
  # Rekonstruuje formátování Instagram captionů ztracené při RSS.app konverzi.
  # RSS.app vrací caption jako jeden plochý blok textu bez \n.
  #
  # Všechny heuristiky jsou v Processors::SocialTextHeuristics.
  #
  # Pořadí aplikace:
  #
  #   Sanity:
  #   0. RSS.app encoding artefakty (�– → \n–)
  #
  #   Začátek / nadpis:
  #   1. Emoji titulek → odstavec za uzavíracím emoji
  #   2. První věta zakončená ! → nadpis, \n\n za ní
  #
  #   Struktura těla:
  #   3. Vlajkový seznam → oddělit od textu, položky na vlastních řádcích
  #   4. Seznam (- položka) → oddělit od okolního textu
  #   5. Citace v uvozovkách → vlastní odstavec
  #   6. Příliš dlouhý blok → rozdělit na větné hranici po 250 znacích
  #
  #   Konec:
  #   7. Hashtag blok → vlastní odstavec (až nakonec, aby H6 neprocházel hashtage)
  #
  # Usage:
  #   processor = Processors::InstagramProcessor.new
  #   formatted = processor.process("Text. 😁 Další věta. #hashtag")
  #   # => "Text. 😁\n\nDalší věta.\n\n#hashtag"
  #
  class InstagramProcessor
    include SocialTextHeuristics

    def initialize(config = {})
      @config = config
    end

    # Hlavní vstupní bod
    # @param text [String] Plochý text z RSS.app
    # @return [String] Text s rekonstruovanými odstavci
    def process(text)
      return '' if text.nil? || text.empty?

      result = text.dup
      # Sanity
      result = decode_rss_app_artifacts(result)
      # Začátek / nadpis
      result = restore_paragraph_breaks(result)
      result = restore_exclamation_title(result)
      # Struktura těla
      result = restore_flag_list(result)
      result = restore_list_breaks(result)
      result = restore_quote_breaks(result)
      result = restore_long_paragraph_breaks(result)
      # Konec
      result = restore_hashtag_block(result)
      result = cleanup_whitespace(result)
      result.strip
    end

  end
end
