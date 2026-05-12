# frozen_string_literal: true

require_relative 'social_text_heuristics'

module Processors
  # Threads Content Processor for Zpravobot Next Generation
  #
  # Rekonstruuje formátování Threads postů ztracené při RSS.app konverzi.
  # RSS.app vrací post jako jeden plochý blok textu bez \n.
  #
  # Threads je text-first platforma (limit 500 znaků) — posty jsou kratší
  # a strukturovanější než IG captiony. Heuristiky jsou identické s IG,
  # ale restore_long_paragraph_breaks se uplatní méně (krátké posty).
  #
  # Sdílené heuristiky (paragraph breaks, hashtag block, long paragraph,
  # whitespace cleanup, RSS.app artefakty) jsou v Processors::SocialTextHeuristics.
  # Threads-specific heuristiky (exclamation title, flag list, dash list,
  # quote breaks) jsou identické s IG — zůstávají tady.
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

    private

    FLAG_EMOJI = /[\u{1F1E0}-\u{1F1FF}]{2}/

    def restore_exclamation_title(text)
      text.sub(/\A([^.!?\n]+!)\s+(?=[[:upper:]])/) { "#{$1}\n\n" }
    end

    def restore_flag_list(text)
      text = text.gsub(/(:[[:space:]]*)(#{FLAG_EMOJI})/) { ":\n\n#{$2}" }
      text.split(/\n\n/).map do |para|
        next para if para.scan(FLAG_EMOJI).length < 2
        para.gsub(/([[:alpha:]])[^\S\n]+(#{FLAG_EMOJI})/) { "#{$1}\n#{$2}" }
      end.join("\n\n")
    end

    def restore_list_breaks(text)
      text = text.split(/\n\n/).map do |para|
        next para if para.scan(/\s+-\s+/).length < 2
        para.gsub(/([^\n])\s+-\s+/, "\\1\n- ")
      end.join("\n\n")
      text.gsub(/((?:^|\n)-[^\n]+)(\n)(?!-)/) { "#{$1}\n\n" }
    end

    def restore_quote_breaks(text)
      text.gsub(/([.!?])\s+(?=[\x22"„][[:upper:]])/) { "#{$1}\n\n" }
    end
  end
end
