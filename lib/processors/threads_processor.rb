# frozen_string_literal: true

require_relative 'social_text_heuristics'

module Processors
  # Threads Content Processor for Zpravobot Next Generation
  #
  # Rekonstruuje formátování Threads postů ztracené při RSS.app konverzi.
  # RSS.app vrací post jako jeden plochý blok textu bez \n.
  #
  # Threads je text-first platforma (limit 500 znaků) — posty jsou kratší
  # a strukturovanější než IG captiony. restore_long_paragraph_breaks se
  # uplatní méně (krátké posty).
  #
  # Všechny heuristiky jsou v Processors::SocialTextHeuristics.
  #
  # Pořadí aplikace:
  #
  #   Sanity:
  #   0. RSS.app encoding artefakty (U+FFFD → \n–)
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
  #   7. Hashtag blok → vlastní odstavec
  #
  # Usage:
  #   processor = Processors::ThreadsProcessor.new
  #   formatted = processor.process("Drama! Antonelli P1, Norris P2. #f1")
  #   # => "Drama!\n\nAntonelli P1, Norris P2.\n\n#f1"
  #
  class ThreadsProcessor
    include SocialTextHeuristics

    def initialize(config = {})
      @config = config
    end

    def process(text)
      return '' if text.nil? || text.empty?

      result = text.dup
      result = decode_rss_app_artifacts(result)
      result = restore_paragraph_breaks(result)
      result = restore_exclamation_title(result)
      result = restore_flag_list(result)
      result = restore_list_breaks(result)
      result = restore_quote_breaks(result)
      result = restore_long_paragraph_breaks(result)
      result = restore_hashtag_block(result)
      result = cleanup_whitespace(result)
      result.strip
    end
  end
end
