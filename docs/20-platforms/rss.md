# RSS

## Platforma (orientace)

RSS v kontextu ZBNW‑NG představuje:

- **Zdroj dat** – RSS 2.0 / Atom feedy (přímé i jako transport pro Facebook a Instagram)
- **Integrační vrstvu** – `RssAdapter` s volitelným platformovým procesorem (`FacebookProcessor`, `InstagramProcessor`)
- **Platform-specific chování** – různé content modes (`text`, `title`, `combined`), URL processing, `rss_source_type` rozlišení
- **Konfigurační jednotku** – definovanou v YAML (`config/sources/*.yml`)

Platforma je vždy vstupní bod systému, izolovaná adapterem a sjednocená do modelu `Post`.

---

Tento dokument popisuje **RSS jako platformu pro získávání obsahu** v systému ZBNW‑NG.
Na rozdíl od jiných dokumentů v této sekci se RSS nechápe jako sociální síť,
ale jako **standardizovaný publikační kanál**, který funguje napříč různými zdroji.

Použité pojmy jsou definovány v [`../00-overview/terminologie.md`](../00-overview/terminologie.md).
Architektonická zdůvodnění jsou popsána v [`../90-meta/decisions.md`](../90-meta/decisions.md).

Dokument popisuje **aktuální chování systému** a záměrně se vyhýbá historickým
incidentům, provozním detailům a privátním integračním podkladům.

---

## 1. Charakteristika RSS

RSS (Really Simple Syndication) je **distribuční formát obsahu**, nikoli
sociální platforma v uživatelském smyslu.

Z pohledu ZBNW‑NG je RSS:

- samostatnou platformou pro získávání obsahu
- zdrojem textu, odkazů a někdy médií
- transportní vrstvou nad různorodými publikačními systémy

RSS sjednocuje obsah z:

- zpravodajských webů
- blogů
- platforem bez veřejného API

---

## 2. Postavení RSS v architektuře

RSS je v architektuře ZBNW‑NG považováno za **plnohodnotnou platformu
pro ingest obsahu**.

To znamená, že:

- RSS není jen fallback mechanismus
- RSS zdroje jsou konfigurovány a spravovány stejně jako jiné platformy
- downstream zpracování je totožné s ostatními vstupy

RSS jako platforma se liší pouze **kvalitou a strukturou vstupních dat**.

> RSS funguje také jako **transportní vrstva** pro platformy bez nativního API — Facebook a Instagram jsou v systému konfigurovány jako `platform: rss` s rozlišením přes `rss_source_type`. Jejich platformně-specifická logika je stále aktivní (viz [`facebook.md`](facebook.md), [`instagram.md`](instagram.md)).

---

## 3. Získávání obsahu

Zpracování RSS obsahu probíhá **periodickým pollingem** feedů.

Z pohledu systému:

- každý feed je samostatný zdroj
- nové položky jsou detekovány pomocí identifikátorů a timestampů
- systém neočekává real‑time chování

Polling model:

- je deterministický
- je odolný vůči výpadkům
- je vhodný pro dávkové zpracování

---

## 4. Charakteristika vstupních dat

RSS vstupní data jsou **heterogenní a nekonzistentní**.

Typické vlastnosti:

- různý rozsah polí mezi feedy
- rozdílná kvalita HTML obsahu
- nejednoznačné nebo chybějící identifikátory

ZBNW‑NG tyto vlastnosti považuje za **normální stav RSS ekosystému**.

---

## 5. Normalizace obsahu

RSS položky procházejí **normalizačním zpracováním** před mapováním na `Post`.

Cíle normalizace:

- získat čitelný text
- odstranit nadbytečné HTML
- stabilizovat výsledný tvar obsahu

Normalizace je:

- best‑effort
- nezávislá na konkrétním vydavateli
- navržena tak, aby nezablokovala pipeline

---

## 6. Mapování na interní model `Post`

RSS položky jsou mapovány na interní model `Post`.

Typické mapování:

- `text` – název + obsah položky
- `url` – canonical link na zdroj
- `author` – identita zdroje (je‑li dostupná)
- `media` – obrázek nebo náhled (je‑li dostupný)

Model `Post` zde slouží jako **sjednocující bod** pro různé typy publikačních
systémů.

---

## 7. Vlákna a návaznosti

RSS **není vláknový formát**.

ZBNW‑NG proto:

- publikuje každou RSS položku jako samostatný post
- nevytváří žádné návaznosti
- neodvozuje vztahy mezi položkami

Každá položka je považována za **samostatnou zprávu**.

---

## 8. Editace obsahu

RSS neobsahuje spolehlivý mechanismus pro detekci editací.

ZBNW‑NG:

- může detekovat změny obsahu heuristicky
- pracuje s editacemi jako s potenciální aktualizací

Chování editací je omezeno kvalitou dat poskytovaných feedem.

---

## 9. Média

RSS položky mohou obsahovat:

- odkazy na obrázky
- inline HTML s médii

Zpracování médií:

- je součástí jednotného mediálního zpracování pipeline
- závisí na kvalitě vstupních dat

Cílem je publikovat **validní, i když ne vždy úplný výstup**.

---

## 10. Content modes

`RssFormatter` podporuje tři content modes, konfigurovatelné per source:

| Mode | Chování |
|---|---|
| `text` (default) | Použije `description` položky |
| `title` | Použije pouze `title` |
| `combined` | Kombinuje `title` a `description` (oddělené odstavcem) |

Combined mode je výchozí pro Facebook a Instagram zdroje.

---

## 11. Profile sync

RSS boti nemají vlastní profily na zdrojové platformě. Profile sync proto **deleguje na platform-specifické syncery** podle skutečné platformy zdroje:

- `rss_source_type: facebook` → `FacebookProfileSyncer`
- `rss_source_type: instagram` → `InstagramProfileSyncer`
- ostatní RSS zdroje → profile sync obvykle deaktivován

Frekvence: 1× týdně v neděli — viz [`../40-tools/runtime.md`](../40-tools/runtime.md).

---

## 12. Konfigurace

### Platform defaults (`config/platforms/rss.yml`)

```yaml
filtering:
  skip_replies: false
  skip_retweets: false

formatting:
  move_url_to_end: true

mentions:
  type: none            # Mentions transformace vypnuta pro RSS
                        # (zabraňuje nežádoucím Mastodon profile card)

processing:
  max_length: 2400
  trim_strategy: smart

scheduling:
  priority: normal
```

### Klíčové per-source parametry

| Parametr | Popis |
|---|---|
| `source.feed_url` | URL RSS/Atom feedu |
| `rss_source_type` | `facebook`, `instagram` nebo prázdné (standardní RSS) |
| `content.show_title_as_content` | Použít title jako text postu |
| `content.combine_title_and_content` | Combined mode |

---

## 13. Limity RSS jako platformy

Známé architektonické limity RSS:

- nekonzistentní struktura dat
- absence standardizované edit logiky
- rozdíly mezi vydavateli

Tyto limity jsou:

- inherentní samotnému RSS formátu
- akceptované návrhem systému

---

## 14. RSS.app — doporučené vzory

Při použití RSS.app jako transportní vrstvy (Facebook, Instagram) vznikají specifické problémy se šumovými posty. ZBNW‑NG je řeší kombinací `content_replacements` a `banned_phrases`.

### Content replacements (noise filtering)

RSS.app feedy ze sociálních sítí obsahují systémové "noise posty" (akce jako změna profilového obrázku, check-in):

```yaml
processing:
  content_replacements:
    # "Page Name Posted" / "Page shared" / "updated status" → smazat
    - pattern: "^.+?\\s+(Posted|shared|updated status)$"
      replacement: ""
      flags: "i"
      literal: false
    # GDPR upozornění vkládané RSS.app → smazat
    - pattern: "(When[^>]+deleted.)"
      replacement: ""
      flags: "gim"
      literal: false
```

### Banned phrases

| Platforma | Fráze |
|---|---|
| Facebook | `updated their cover photo`, `updated their profile picture`, `is with`, `was live` |
| Instagram | `updated their profile picture` |

`create_source.rb` přidává tyto vzory automaticky při zakládání nového Facebook/Instagram zdroje.

---

## 15. RSS jako vzor pro nové platformy

RSS.app je extensibilní vzor — ZBNW‑NG jej lze použít pro libovolnou sociální síť, kde RSS.app generuje RSS feed.

Přidání nové RSS.app-based platformy vyžaduje:

1. Source YAML: `platform: rss`, `rss_source_type: <nová_platforma>`
2. Platform defaults: `config/platforms/<nová_platforma>.yml` (volitelné)
3. Banned phrases: specifické pro danou síť (přidat do `create_source.rb` konstant)
4. Procesor: pokud platforma generuje specifický šum (analogicky k `FacebookProcessor`)
5. Profile syncer: `lib/syncers/<nová_platforma>_profile_syncer.rb` (volitelné)

Samotná `RssAdapter` implementace nevyžaduje žádné změny — RSS.app feedy jsou standardní RSS 2.0.

---

## 16. Shrnutí

RSS jako platforma v ZBNW‑NG:

- slouží jako univerzální zdroj obsahu
- vyžaduje nejvíce normalizační logiky
- poskytuje nižší strukturální kvalitu dat
- umožňuje široký záběr zdrojů

Díky tomu RSS zůstává klíčovou a nenahraditelnou součástí
ingest architektury ZBNW‑NG.

Všechny platformní rozdíly končí na hranici modelu `Post`, který je vstupem do jednotné pipeline.
