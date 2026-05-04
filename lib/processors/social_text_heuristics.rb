# frozen_string_literal: true

module Processors
  # Sdílené heuristiky pro rekonstrukci formátování ztraceného při RSS.app
  # konverzi z Facebook / Instagram / (do budoucna) Threads captionů.
  #
  # Každý platformový procesor (FacebookProcessor, InstagramProcessor, …)
  # tento modul mixne (`include`) a v `process` volá metody v pořadí, které
  # dává smysl pro daný typ obsahu. Sdílení tady zaručuje, že fix jedné
  # heuristiky se okamžitě projeví všude.
  #
  # Metody jsou idempotentní vůči `\n\n` separátorům — opakovaná aplikace
  # nepřidává další newliny.
  #
  # Heuristiky:
  #   - decode_rss_app_artifacts:    �–  → \n– (RSS.app encoding bug)
  #   - restore_paragraph_breaks:    emoji + space + uppercase → \n\n
  #   - restore_hashtag_block:       trailing #-blok → \n\n#tags\n@mentions
  #   - restore_long_paragraph_breaks: dlouhé odstavce na větné hranici
  #   - cleanup_whitespace:          normalizace mezer kolem newlinů
  module SocialTextHeuristics
    LONG_PARAGRAPH_THRESHOLD = 250

    # ---------------------------------------------------------------------------
    # Heuristika: dekódování RSS.app encoding artefaktů
    #
    # RSS.app někdy emituje U+FFFD (REPLACEMENT CHARACTER) v místech, kde
    # zdrojový post obsahoval newline + dash bullet. Příklad (IG post o Íránu):
    #   "...mimo jiné:�– stažení amerických sil;�– konec americké blokády;..."
    #
    # Konverzi: `�\s*–` → `\n– ` (newline + dash bullet s mezerou).
    # Osamocené `�` (bez navazujícího dashe) odstraníme — jsou to nepoužitelné
    # zbytky encoding errors.
    # ---------------------------------------------------------------------------
    def decode_rss_app_artifacts(text)
      text
        .gsub(/�\s*[–-]\s*/, "\n– ")
        .gsub(/�/, '')
    end

    # ---------------------------------------------------------------------------
    # Heuristika: emoji jako oddělovač odstavců
    #
    # Emoji + mezera + velké písmeno → \n\n za emoji
    #   "...realita 😁 Ella..." → "...realita 😁\n\nElla..."
    #
    # Ochrany:
    #   1. velké písmeno za emoji (?=[[:upper:]])    — emoji uprostřed věty
    #      před vlastním jménem malým písmenem se nerozdělí.
    #   2. lookbehind (?<=[^\n])                      — emoji na začátku
    #      řádku/textu nemá před sebou non-newline znak → nerozdělí se.
    #   3. negative lookahead (?!var_sel)             — variační selektor U+FE0x
    #      NENÍ začátek emoji, ale finalizátor předchozího znaku.
    #   4. negative lookbehind (?<!regional)          — vlajková emoji jsou PÁRY
    #      regional indicatorů (U+1F1E0–U+1F1FF). Bez ochrany by regex začal
    #      matchovat od DRUHÉHO regional indicatoru a rozsekl vlajku v půlce.
    # ---------------------------------------------------------------------------
    EMOJI_PATTERN = /[\u{1F300}-\u{1F9FF}\u{2600}-\u{27BF}\u{1F1E0}-\u{1F1FF}\u{FE00}-\u{FE0F}]/
    VAR_SEL       = /[\u{FE00}-\u{FE0F}]/
    REGIONAL      = /[\u{1F1E0}-\u{1F1FF}]/

    def restore_paragraph_breaks(text)
      text.gsub(/(?<=[^\n])(?<!#{REGIONAL})(?!#{VAR_SEL})(#{EMOJI_PATTERN}+)\s+(?=[[:upper:]])/) do
        "#{$1}\n\n"
      end
    end

    # ---------------------------------------------------------------------------
    # Heuristika: trailing tag block (hashtags + @mentions)
    #
    # Caption typicky končí blokem tagů odděleným od textu.
    # Blok MUSÍ ZAČÍNAT `#hashtagem` — `@mention` na začátku indikuje, že jde
    # spíš o atribuci v prose ("photos by @user") než o tag block.
    # Po prvním hashtagu mohou následovat další `#` i `@` tokeny.
    # Podporuje `|` jako oddělovač (#NovaSport | #NHL).
    #
    # Příklady:
    #   "text. #f1 #miami @driver"     → "text.\n\n#f1 #miami\n@driver"
    #   "photos by @user #foo"         → "photos by @user\n\n#foo"     ✓ @user zůstává v prose
    #   "Sponsored by : @a @b #x #y"   → "Sponsored by : @a @b\n\n#x #y"
    #
    # Output formát: hashtags na prvním řádku, mentions na druhém řádku
    # (oddělené single \n uvnitř bloku). Před blokem dvojitý \n\n.
    # ---------------------------------------------------------------------------
    HASHTAG_TOKEN = /\#[\w.]+/.freeze
    MENTION_TOKEN = /@[\w.]+/.freeze
    TAG_TOKEN     = /[#@][\w.]+/.freeze

    def restore_hashtag_block(text)
      # Match: pre-char + whitespace + #hashtag (+ další #/@tokeny) až do konce.
      # První tag MUSÍ být hashtag (#…), aby @-mention v prose nebyl falešně
      # zařazen do bloku.
      text.gsub(/([^\n])\s+(#{HASHTAG_TOKEN}(?:[\s|]+#{TAG_TOKEN})*)$/) do
        pre   = $1
        block = $2

        hashtags = block.scan(HASHTAG_TOKEN).join(' ')
        mentions = block.scan(MENTION_TOKEN).join(' ')

        tag_lines = [hashtags, mentions].reject(&:empty?).join("\n")
        "#{pre}\n\n#{tag_lines}"
      end
    end

    # ---------------------------------------------------------------------------
    # Heuristika: dlouhé odstavce → split na větné hranici
    #
    # Pokud odstavec přesáhne LONG_PARAGRAPH_THRESHOLD znaků, hledáme první
    # větnou hranici (. ? !) za prahem a vložíme \n\n. Rekurzivní.
    # ---------------------------------------------------------------------------
    def restore_long_paragraph_breaks(text)
      text.split(/\n\n/).flat_map { |para| split_long_paragraph(para) }.join("\n\n")
    end

    # ---------------------------------------------------------------------------
    # Cleanup: normalizovat whitespace
    # - Mezery/taby těsně před/za newlinem → odstranit
    # - 3+ newliny → maximálně 2
    # ---------------------------------------------------------------------------
    def cleanup_whitespace(text)
      text.gsub(/[ \t]*\n[ \t]*/, "\n").gsub(/\n{3,}/, "\n\n")
    end

    private

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
  end
end
