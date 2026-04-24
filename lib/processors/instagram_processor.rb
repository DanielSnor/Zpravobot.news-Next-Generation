# frozen_string_literal: true

module Processors
  # Instagram Content Processor for Zpravobot Next Generation
  #
  # Rekonstruuje formátování Instagram captionů ztracené při RSS.app konverzi.
  # RSS.app vrací caption jako jeden plochý blok textu bez \n.
  #
  # Heuristiky (v pořadí aplikace):
  #   1. Emoji + velké písmeno → odstavec (nejsilnější signál)
  #   2. Emoji na začátku věty (po textu) → odstavec před ním
  #   3. Seznam (- položka) → oddělit od okolního textu
  #   4. Hashtag blok na konci → vlastní odstavec
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
      text.gsub(/([^\n])\s+(#\w+(?:\s+#\w+)*)$/) do
        "#{$1}\n\n#{$2}"
      end
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
