# frozen_string_literal: true

module Processors
  # Instagram Content Processor for Zpravobot Next Generation
  #
  # Rekonstruuje formátování Instagram captionů ztracené při RSS.app konverzi.
  # RSS.app vrací caption jako jeden plochý blok textu bez \n.
  #
  # Heuristiky (v pořadí aplikace):
  #   1. Emoji + velké písmeno → odstavec (nejsilnější signál)
  #   2. Seznam (- položka) → oddělit od okolního textu
  #   3. Hashtag blok na konci → vlastní odstavec
  #   4. Příliš dlouhý blok → rozdělit na větné hranici po 250 znacích
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
      result = restore_list_breaks(result)
      result = restore_hashtag_block(result)
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
    #   "...se? 🧐 Více..." → "...se? 🧐\n\nVíce..."
    #   "...příměří. 🇱🇧🇮🇱 Dohoda..." → "...příměří. 🇱🇧🇮🇱\n\nDohoda..."
    #
    # Velké písmeno jako ochrana proti emoji uprostřed věty před vlastním jménem
    # (např. "navštívil 🇨🇿 Prahu").
    # ---------------------------------------------------------------------------
    def restore_paragraph_breaks(text)
      emoji_pattern = /[\u{1F300}-\u{1F9FF}\u{2600}-\u{27BF}\u{1F1E0}-\u{1F1FF}\u{FE00}-\u{FE0F}]/

      # Emoji + mezera + velké písmeno → \n\n za emoji
      text.gsub(/(#{emoji_pattern}+)\s+(?=[[:upper:]])/) do
        "#{$1}\n\n"
      end
    end

    # ---------------------------------------------------------------------------
    # Heuristika 3: Rekonstrukce seznamu
    #
    # RSS.app někdy zachová "- " odrážky ale odstraní prázdné řádky mezi nimi.
    # Výsledek: "Mezi změny patří: - Bod 1 - Bod 2 - Bod 3"
    #
    # Pravidla:
    #   - Text před první odrážkou → odstavec (pokud nekončí \n)
    #   - Mezi odrážkami → \n (jednoduchý, ne dvojitý — seznam je kompaktní)
    #   - Za posledním bodem seznamu → \n\n před dalším odstavcem
    # ---------------------------------------------------------------------------
    def restore_list_breaks(text)
      # Oddělit text před prvním "- " od samotného seznamu
      text = text.gsub(/([^\n])\s+-\s+/, "\\1\n- ")

      # Přidat \n\n za posledním listem pokud následuje text bez "-"
      text = text.gsub(/((?:^|\n)-[^\n]+)(\n)(?!-)/) do
        "#{$1}\n\n"
      end

      text
    end

    # ---------------------------------------------------------------------------
    # Heuristika 4: Hashtag blok na konci
    #
    # IG captions typicky končí blokem hashtagů odděleným od textu.
    # RSS.app je připojí za text bez odřádkování.
    #
    # Příklad: "...najdete na YouTube. #hakkinen #f1academy #eisking"
    # → "...najdete na YouTube.\n\n#hakkinen #f1academy #eisking"
    # ---------------------------------------------------------------------------
    def restore_hashtag_block(text)
      # Najít první hashtag který začíná blok a není na začátku řádku
      text.gsub(/([^\n])\s+(#\w+(?:[\s|]+#\w+)*)$/) do
        "#{$1}\n\n#{$2}"
      end
    end

    # ---------------------------------------------------------------------------
    # Heuristika 4: Příliš dlouhý blok textu → rozdělení na větné hranici
    #
    # Pokud odstavec přesáhne LONG_PARAGRAPH_THRESHOLD znaků, hledá první
    # větnou hranici (. ? !) následovanou mezerou a velkým písmenem za prahem
    # a vloží \n\n. Aplikuje se rekurzivně dokud délka klesne pod práh.
    #
    # Záměrně toleruje false positives (zkratky jako "M. Verstappen") —
    # lepší občasné špatné rozdělení než jeden masivní blok textu.
    #
    # Příklad:
    #   "Věta jedna, která je dost dlouhá. Věta dvě pokračuje dál." (>250 znaků)
    #   → "Věta jedna, která je dost dlouhá.\n\nVěta dvě pokračuje dál."
    # ---------------------------------------------------------------------------
    LONG_PARAGRAPH_THRESHOLD = 250

    def restore_long_paragraph_breaks(text)
      # Zpracuj každý existující odstavec zvlášť
      text.split(/\n\n/).flat_map do |para|
        split_long_paragraph(para)
      end.join("\n\n")
    end

    def split_long_paragraph(text)
      return [text] if text.length <= LONG_PARAGRAPH_THRESHOLD

      # Hledej větnou hranici v části textu za prahem
      tail = text[LONG_PARAGRAPH_THRESHOLD..]
      match = tail.match(/[.!?]\s+(?=[[:upper:]])/)
      return [text] unless match

      # Rozděl za interpunkcí (velké písmeno začne nový odstavec)
      split_at = LONG_PARAGRAPH_THRESHOLD + match.begin(0) + 1
      first = text[0...split_at].strip
      rest  = text[split_at..].strip

      [first] + split_long_paragraph(rest)
    end

    # ---------------------------------------------------------------------------
    # Cleanup: normalizovat whitespace
    #
    # - Mezery před/za \n → odstranit
    # - Více než 2 za sebou jdoucí \n → max \n\n
    # ---------------------------------------------------------------------------
    def cleanup_whitespace(text)
      text.gsub(/[ \t]*\n[ \t]*/, "\n")
          .gsub(/\n{3,}/, "\n\n")
    end
  end
end
