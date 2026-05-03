# frozen_string_literal: true

module Processors
  # Instagram Content Processor for Zpravobot Next Generation
  #
  # Rekonstruuje formátování Instagram captionů ztracené při RSS.app konverzi.
  # RSS.app vrací caption jako jeden plochý blok textu bez \n.
  #
  # Heuristiky (v pořadí aplikace):
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
    def initialize(config = {})
      @config = config
    end

    # Hlavní vstupní bod
    # @param text [String] Plochý text z RSS.app
    # @return [String] Text s rekonstruovanými odstavci
    def process(text)
      return '' if text.nil? || text.empty?

      result = text.dup
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
    #
    # Ochrana 4: negative lookbehind (?<!regional) — vlajkové emoji jsou PÁRY
    #   regional indicatorů (U+1F1E0–U+1F1FF). Bez ochrany by regex začal matchovat
    #   od DRUHÉHO regional indicatoru (předchází mu první, který je non-newline),
    #   čímž by 🇺🇸 POLE rozsekal na 🇺🇸 + \n\n + POLE.
    # ---------------------------------------------------------------------------
    def restore_paragraph_breaks(text)
      emoji_pattern = /[\u{1F300}-\u{1F9FF}\u{2600}-\u{27BF}\u{1F1E0}-\u{1F1FF}\u{FE00}-\u{FE0F}]/
      var_sel       = /[\u{FE00}-\u{FE0F}]/
      regional      = /[\u{1F1E0}-\u{1F1FF}]/

      # (?<=[^\n])       — předchází non-newline znak (= nejsme na začátku řádku)
      # (?<!regional)    — předchozí znak NENÍ regional indicator (= nezačínáme
      #                    uprostřed vlajkového páru)
      # (?!var_sel)      — match nezačíná variačním selektorem
      # (emoji_pattern+) — jedna nebo více emoji (včetně selektorů v těle sekvence)
      # \s+              — mezery za poslední emoji
      # (?=[[:upper:]])  — následuje velké písmeno
      text.gsub(/(?<=[^\n])(?<!#{regional})(?!#{var_sel})(#{emoji_pattern}+)\s+(?=[[:upper:]])/) do
        "#{$1}\n\n"
      end
    end

    # ---------------------------------------------------------------------------
    # Heuristika 2: První věta zakončená vykřičníkem = nadpis
    #
    # Pokud první věta celého textu (před jakýmkoli \n\n) končí !, je to nadpis
    # a za ní patří \n\n.
    #   "Kimi získává pole position! Max hlásí comeback..." →
    #   "Kimi získává pole position!\n\nMax hlásí comeback..."
    #
    # Implementováno přes sub (ne gsub) s \A — matchuje výhradně od začátku
    # celého textu, takže se neuplatní na ! uvnitř odstavců ani na texty,
    # které začínají emoji titulkem (ten neobsahuje ! před \n).
    # ---------------------------------------------------------------------------
    def restore_exclamation_title(text)
      # \A([^.!?\n]+!) — od začátku textu, žádná .!?\n před !, pak !
      #   Tím zajistíme, že jde opravdu o PRVNÍ větu — kdyby před ! byla
      #   tečka nebo otazník, šlo by o druhou/třetí větu, ne o nadpis.
      # \s+             — mezera(y) za !
      # (?=[[:upper:]]) — následuje velké písmeno (= pokračuje další věta)
      text.sub(/\A([^.!?\n]+!)\s+(?=[[:upper:]])/) { "#{$1}\n\n" }
    end

    # ---------------------------------------------------------------------------
    # Heuristika 3: Vlajkový seznam
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
    #
    # Podmínka: odstavec musí mít 2+ výskytů "\s+-\s+" — jinak jde o dash
    # v nadpisu nebo textu (např. "🇺🇸 POLE POSITION - 4/22 🇺🇸"), ne o seznam.
    # ---------------------------------------------------------------------------
    def restore_list_breaks(text)
      text = text.split(/\n\n/).map do |para|
        next para if para.scan(/\s+-\s+/).length < 2

        para.gsub(/([^\n])\s+-\s+/, "\\1\n- ")
      end.join("\n\n")

      text = text.gsub(/((?:^|\n)-[^\n]+)(\n)(?!-)/) { "#{$1}\n\n" }
      text
    end

    # ---------------------------------------------------------------------------
    # Heuristika 4: Tag blok na konci (hashtags + @mentions)
    #
    # IG captions typicky končí blokem tagů odděleným od textu.
    # Blok může obsahovat kombinaci #hashtag a @mention tokenů.
    #   "#F1 #Formula1 #MiamiGP @kimi.antonelli @mercedesamgf1"
    # Podporuje | jako oddělovač (#NovaSport | #NHL).
    # @mentions mohou mít tečku (@kimi.antonelli).
    # ---------------------------------------------------------------------------
    def restore_hashtag_block(text)
      tag = /[#@][\w.]+/
      text.gsub(/([^\n])\s+(#{tag}(?:[\s|]+#{tag})*)$/) { "#{$1}\n\n#{$2}" }
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
