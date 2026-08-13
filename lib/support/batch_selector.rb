#!/usr/bin/env ruby
# frozen_string_literal: true

# Výběr dávky postů pro jeden běh runneru + rozhodnutí o `since` watermarku.
#
# Vytaženo z Orchestrator::Runner#process_source, aby se to dalo otestovat bez
# databáze a bez sítě (viz test/test_batch_selector.rb).
#
# Proč to vůbec existuje: dřív se brala dávka `.last(max_posts)`, tedy NEJNOVĚJŠÍ
# posty, a zbytek se zahodil. U vlákna delšího než limit tím zmizel jeho ZAČÁTEK,
# a protože se zároveň posunul `last_success` (hranice `since` okna), odložené
# posty se už nikdy nevrátily. Naměřeno na produkci: u `vladafoltan_bluesky`
# vlákno o 23 postech, z něhož se publikovalo posledních 10.
#
# Nově se bere NEJSTARŠÍ dávka — vlákno se publikuje odpředu, rodič tedy vzniká
# dřív než odpověď — a zbytek se odloží na příští běh.

module Support
  # Výsledek výběru pro jeden běh.
  #
  # `newest_selected_at` = published_at nejnovějšího VYBRANÉHO postu. Když se
  # dávka odložila, právě sem patří watermark: příští běh pak dostane z API
  # všechno novější, tedy přesně ten odložený zbytek.
  BatchSelection = Struct.new(:selected, :deferred, :already_published, :newest_selected_at,
                              keyword_init: true) do
    # true = dávka pokryla všechno, co bylo k dispozici
    def complete?
      deferred.zero?
    end
  end

  module BatchSelector
    # @param posts [Array<Post>] vše, co adapter vrátil
    # @param max_posts [Integer] max_posts_per_run daného zdroje
    # @yield [post] blok vracející true, pokud je post už publikovaný (dedup)
    # @return [BatchSelection]
    def self.call(posts, max_posts:, &already_published)
      posts = Array(posts)
      known, fresh = if already_published
                       posts.partition { |p| already_published.call(p) }
                     else
                       [[], posts]
                     end

      ordered  = fresh.sort_by { |p| p.published_at || Time.at(0) }
      selected = max_posts.to_i.positive? ? ordered.first(max_posts.to_i) : []

      BatchSelection.new(
        selected: selected,
        deferred: ordered.length - selected.length,
        already_published: known.length,
        newest_selected_at: selected.map(&:published_at).compact.max
      )
    end

    # Kam postavit `last_success`, tedy hranici `since` okna?
    #
    # nil = NOW(), tj. „všechno hotovo, posuň na teď". Když ale něco zbylo,
    # vrací se čas nejnovějšího ZPRACOVANÉHO postu — příští běh tak dostane
    # z API zbytek, místo aby o něj přišel.
    #
    # 🪤 Nestačí příznak „neposouvat" a nechat starou hodnotu: u nového zdroje
    # ještě žádná není a INSERT by nastavil NOW(). Proto se předává HODNOTA.
    #
    # 🪤 `window_used` se odvozuje z PLATFORMY, ne z toho, že `since` vyšlo nil.
    # U ne-RSS zdroje bez state řádku je `since` nil taky, ale tam hranice smysl
    # má. U RSS se `since` nepoužívá vůbec (celý feed + dedup podle GUID), takže
    # držet ji nemá co zachránit a zdroj by jen vypadal jako mrtvý.
    #
    # @param selection [BatchSelection] výsledek call()
    # @param interrupted [Boolean] běh skončil dřív (rate limit)
    # @param shutdown [Boolean] běh skončil dřív (SIGTERM)
    # @param window_used [Boolean] používá tento zdroj `since` okno? (= není RSS)
    # @param previous [Time, nil] dosavadní last_success (fallback, když se nic nevybralo)
    # @return [Time, nil] nil = NOW()
    def self.watermark_for(selection, interrupted: false, shutdown: false, window_used: true,
                           previous: nil)
      return nil unless window_used

      all_done = selection.complete? && !interrupted && !shutdown
      return nil if all_done

      # Zbylo něco: hranice patří na poslední zpracovaný post. Když se nezpracoval
      # žádný, drž dosavadní hodnotu; není-li ani ta, zbývá jen NOW() (degenerovaný
      # případ max_posts_per_run <= 0, tedy chyba konfigurace).
      selection.newest_selected_at || previous
    end
  end
end
