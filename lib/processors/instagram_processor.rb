# frozen_string_literal: true

require_relative 'social_text_heuristics'

module Processors
  # Instagram Content Processor for Zpravobot Next Generation
  #
  # Rekonstruuje formátování Instagram captionů ztracené při RSS.app konverzi.
  # RSS.app vrací caption jako jeden plochý blok textu bez \n.
  #
  # Sdílené heuristiky (paragraph breaks, hashtag block, long paragraph,
  # whitespace cleanup, RSS.app artefakty) jsou v Processors::SocialTextHeuristics.
  # IG-specific heuristiky (exclamation title, flag list, dash list, quote breaks)
  # zůstávají tady.
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

    private

    # ---------------------------------------------------------------------------
    # Heuristika: První věta zakončená vykřičníkem = nadpis
    #
    # Pokud první věta celého textu (před jakýmkoli \n\n) končí !, je to nadpis
    # a za ní patří \n\n.
    #   "Kimi získává pole position! Max hlásí comeback..." →
    #   "Kimi získává pole position!\n\nMax hlásí comeback..."
    #
    # Implementováno přes sub (ne gsub) s \A — matchuje výhradně od začátku
    # celého textu, takže se neuplatní na ! uvnitř odstavců.
    # ---------------------------------------------------------------------------
    def restore_exclamation_title(text)
      text.sub(/\A([^.!?\n]+!)\s+(?=[[:upper:]])/) { "#{$1}\n\n" }
    end

    # ---------------------------------------------------------------------------
    # Heuristika: Vlajkový seznam
    #
    # IG posty často obsahují výčet míst/závodů s vlajkovými emoji jako bulety.
    # RSS.app předá celý výčet jako jeden blok.
    #
    # Pravidlo A: text končící ":" + vlajka → \n\n před vlajkovým blokem
    #   "...úvod sezóny: 🇧🇭 14. marec..." → "...sezóny:\n\n🇧🇭 14. marec..."
    #
    # Pravidlo B: vlajka → vlajka → \n mezi položkami (kompaktní seznam)
    #   "...cena Bahrajnu 🇸🇦 21...." → "...cena Bahrajnu\n🇸🇦 21...."
    # ---------------------------------------------------------------------------
    FLAG_EMOJI = /[\u{1F1E0}-\u{1F1FF}]{2}/  # dvojice regional indicators = jedna vlajka

    def restore_flag_list(text)
      # Pravidlo A: dvojtečka + vlajka → odstavec před vlajkovým blokem
      text = text.gsub(/(:[[:space:]]*)(#{FLAG_EMOJI})/) { ":\n\n#{$2}" }

      # Pravidlo B: separovat vlajkové položky pomocí \n — ale POUZE v odstavcích
      # s 2+ vlajkami (jinak se plete s emoji uprostřed věty nebo emoji-separátory).
      # Navíc vyžadujeme písmeno (ne interpunkci) těsně před vlajkou — tím se
      # vyhneme false positivu pro vzor "příměří. 🇱🇧🇮🇱" (o to se stará paragraph_breaks).
      text.split(/\n\n/).map do |para|
        next para if para.scan(FLAG_EMOJI).length < 2

        para.gsub(/([[:alpha:]])[^\S\n]+(#{FLAG_EMOJI})/) { "#{$1}\n#{$2}" }
      end.join("\n\n")
    end

    # ---------------------------------------------------------------------------
    # Heuristika: Rekonstrukce dash-seznamu
    #
    # RSS.app někdy zachová "- " odrážky ale odstraní prázdné řádky mezi nimi.
    # Výsledek: "Mezi změny patří: - Bod 1 - Bod 2 - Bod 3"
    #
    # Podmínka: odstavec musí mít 2+ výskytů "\s+-\s+" — jinak jde o dash
    # v nadpisu nebo textu (např. "🇺🇸 POLE POSITION - 4/22 🇺🇸"), ne o seznam.
    # ---------------------------------------------------------------------------
    def restore_list_breaks(text)
      text = text.split(/\n\n/).map do |para|
        next para if para.scan(/\s+-\s+/).length < 2

        para.gsub(/([^\n])\s+-\s+/, "\\1\n- ")
      end.join("\n\n")

      text.gsub(/((?:^|\n)-[^\n]+)(\n)(?!-)/) { "#{$1}\n\n" }
    end

    # ---------------------------------------------------------------------------
    # Heuristika: Citace v uvozovkách → vlastní odstavec
    #
    # Signál: interpunkce + mezera + otevírací uvozovka + velké písmeno.
    # Podporované uvozovky: " (straight U+0022), " (U+201C), „ (U+201E)
    #
    # Příklad: '...sezóne. "Od fanúšikov!" 🏎️' → '...sezóne.\n\n"Od fanúšikov!" 🏎️'
    # ---------------------------------------------------------------------------
    def restore_quote_breaks(text)
      text.gsub(/([.!?])\s+(?=[\x22“„][[:upper:]])/) { "#{$1}\n\n" }
    end
  end
end
