# frozen_string_literal: true

module Processors
  # Instagram Content Processor for Zpravobot Next Generation
  #
  # Rekonstruuje formátování Instagram captionů ztracené při RSS.app konverzi.
  # RSS.app vrací caption jako jeden plochý blok textu bez \n.
  #
  # Heuristiky (v pořadí aplikace):
  #   1. Emoji + velké písmeno → odstavec (jen když emoji předchází text, ne začátek řádku)
  #   2. Vlajkový seznam → oddělit od textu, položky na vlastních řádcích
  #   3. Seznam (- položka) → oddělit od okolního textu
  #   4. Hashtag blok na konci → vlastní odstavec
  #   5. Citace v uvozovkách → vlastní odstavec
  #   6. Příliš dlouhý blok → rozdělit na větné hranici po 250 znacích
  #
  # Usage:
  #   processor = Processors::InstagramProcessor.new
  #   formatted = processor.process("Text. 😁 Další věta. #hashtag")
  #   # => "Text. 😁\n\nDalší věta.\n\n#hashtag"
  #
  class InstagramProcessor
    def initialize(config = {})
      @config = config
    end

    # Hlavní vstupní bod
    # @param text [String] Plochý text z RSS.app
    # @return [String] Text s rekonstruovanými odstavci
    def process(text)
      return '' if text.nil? || text.empty?

      result = text.dup
      result = restore_paragraph_breaks(result)
      result = restore_flag_list(result)
      result = restore_list_breaks(result)
      result = restore_hashtag_block(result)
      result = restore_quote_breaks(result)
      result = restore_long_paragraph_breaks(result)
      result = cleanup_whitespace(result)
      result.strip
    end

    private

    # ---------------------------------------------------------------------------
    # Heuristika 1: Emoji jako oddělovač odstavců
    #
    # Emoji + mezera + velké písmeno → \n\n za emoji
    #   "...realita 😁 Ella..." → "...realita 😁\n\nElla..."
    #
    # Ochrana 1: velké písmeno — emoji uprostřed věty před vlastním jménem
    #   malým písmenem (např. "navštívil 🇨🇿 prahu") se nerozdělí.
    #
    # Ochrana 2: lookbehind (?<=[^\n]) — emoji na začátku řádku/textu nemá
    #   před sebou non-newline znak → nerozdělí se.
    #   "🗓️ TITULEK 🗓️ Text" → první 🗓️ je na začátku = nerozdělí, druhé 🗓️
    #   má před sebou "K" → rozdělí → "🗓️ TITULEK 🗓️\n\nText".
    #
    # Ochrana 3: negative lookahead (?!var_sel) — variační selektor U+FE0x
    #   NENÍ začátek emoji, ale finalizátor předchozího znaku. Bez ochrany by
    #   lookbehind zachytil i "🗓" (base) + FE0F (selektor) jako dvě emoji,
    #   přičemž druhý match by začínal na FE0F → false split.
    #   "☀️ ➡️ ⛈️ Ve hře" → jen ⛈️ před "Ve" → rozdělí správně.
    # ---------------------------------------------------------------------------
    def restore_paragraph_breaks(text)
      emoji_pattern = /[\u{1F300}-\u{1F9FF}\u{2600}-\u{27BF}\u{1F1E0}-\u{1F1FF}\u{FE00}-\u{FE0F}]/
      var_sel       = /[\u{FE00}-\u{FE0F}]/

      # (?<=[^\n])      — předchází non-newline znak (= nejsme na začátku řádku)
      # (?!var_sel)     — match nezačíná variačním selektorem
      # (emoji_pattern+) — jedna nebo více emoji (včetně selektorů v těle sekvence)
      # \s+             — mezery za poslední emoji
      # (?=[[:upper:]]) — následuje velké písmeno
      text.gsub(/(?<=[^\n])(?!#{var_sel})(#{emoji_pattern}+)\s+(?=[[:upper:]])/) do
        "#{$1}\n\n"
      end
    end

    # ---------------------------------------------------------------------------
    # Heuristika 2: Vlajkový seznam
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
      # vyhneme false positivu pro vzor "příměří. 🇱🇧🇮🇱" (o to se stará heuristika 1).
      text = text.split(/\n\n/).map do |para|
        next para if para.scan(FLAG_EMOJI).length < 2

        para.gsub(/([[:alpha:]])[^\S\n]+(#{FLAG_EMOJI})/) { "#{$1}\n#{$2}" }
      end.join("\n\n")

      text
    end

    # ---------------------------------------------------------------------------
    # Heuristika 3: Rekonstrukce seznamu
    #
    # RSS.app někdy zachová "- " odrážky ale odstraní prázdné řádky mezi nimi.
    # Výsledek: "Mezi změny patří: - Bod 1 - Bod 2 - Bod 3"
    # ---------------------------------------------------------------------------
    def restore_list_breaks(text)
      text = text.gsub(/([^\n])\s+-\s+/, "\\1\n- ")
      text = text.gsub(/((?:^|\n)-[^\n]+)(\n)(?!-)/) { "#{$1}\n\n" }
      text
    end

    # ---------------------------------------------------------------------------
    # Heuristika 4: Hashtag blok na konci
    #
    # IG captions typicky končí blokem hashtagů odděleným od textu.
    # Podporuje | jako oddělovač mezi hashtagy (#NovaSport | #NHL).
    # ---------------------------------------------------------------------------
    def restore_hashtag_block(text)
      text.gsub(/([^\n])\s+(#\w+(?:[\s|]+#\w+)*)$/) { "#{$1}\n\n#{$2}" }
    end

    # ---------------------------------------------------------------------------
    # Heuristika 5: Citace v uvozovkách → vlastní odstavec
    #
    # Signál: interpunkce + mezera + otevírací uvozovka + velké písmeno.
    # Podporované uvozovky: " (straight U+0022), " (U+201C), „ (U+201E)
    #
    # Příklad: '...sezóne. "Od fanúšikov!" 🏎️' → '...sezóne.\n\n"Od fanúšikov!" 🏎️'
    # ---------------------------------------------------------------------------
    def restore_quote_breaks(text)
      text.gsub(/([.!?])\s+(?=[\x22“„][[:upper:]])/) { "#{$1}\n\n" }
    end

    # ---------------------------------------------------------------------------
    # Heuristika 6: Příliš dlouhý blok textu → rozdělení na větné hranici
    #
    # Pokud odstavec přesáhne LONG_PARAGRAPH_THRESHOLD znaků, hledá první
    # větnou hranici (. ? !) za prahem a vloží \n\n. Rekurzivní.
    # ---------------------------------------------------------------------------
    LONG_PARAGRAPH_THRESHOLD = 250

    def restore_long_paragraph_breaks(text)
      text.split(/\n\n/).flat_map { |para| split_long_paragraph(para) }.join("\n\n")
    end

    def split_long_paragraph(text)
      return [text] if text.length <= LONG_PARAGRAPH_THRESHOLD

      tail  = text[LONG_PARAGRAPH_THRESHOLD..]
      match = tail.match(/[.!?]\s+(?=[[:upper:]])/)
      return [text] unless match

      split_at = LONG_PARAGRAPH_THRESHOLD + match.begin(0) + 1
      first    = text[0...split_at].strip
      rest     = text[split_at..].strip

      [first] + split_long_paragraph(rest)
    end

    # ---------------------------------------------------------------------------
    # Cleanup: normalizovat whitespace
    # ---------------------------------------------------------------------------
    def cleanup_whitespace(text)
      text.gsub(/[ \t]*\n[ \t]*/, "\n")
          .gsub(/\n{3,}/, "\n\n")
    end
  end
end
