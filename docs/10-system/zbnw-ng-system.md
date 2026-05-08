# ZBNW‑NG System Overview

Tento dokument popisuje **funkční a strukturální přehled systému ZBNW‑NG**.
Slouží jako technický popis toho, **jak systém funguje jako celek**, nikoli proč byl
navržen tímto způsobem.

- Význam použitých pojmů je definován v `docs/00-overview/terminologie.md`.
- Důvody architektonických rozhodnutí jsou popsány v `docs/90-meta/decisions.md`.

Tento dokument je záměrně odvozen **pouze z pozorovatelného stavu systému**
(kód, konfigurace, běhový model) a **nevyžaduje znalost historických diskusí,
incidentů ani soukromých podkladů**.

---

## 1. Scope dokumentu

Dokument se zaměřuje na:

- běhový model systému
- hlavní subsystémy a jejich odpovědnosti
- tok dat systémem od vstupu k publikaci
- hranice odpovědnosti jednotlivých částí

Dokument **nepokrývá**:

- důvody architektonických rozhodnutí (viz `decisions.md`)
- detailní infrastrukturu hostingu
- výkonnostní ladění
- historický vývoj systému

---

## 2. Běhový model systému

ZBNW‑NG je navržen jako **opakovaně spouštěný dávkový systém**.

Základní charakteristiky:

- systém je spouštěn periodicky
- každé spuštění je **krátkožijící** a izolované
- mezi spuštěními se neudržuje žádný dlouhodobý procesní stav

Tento model umožňuje:

- jednoduchý restart bez speciální rekonvalescence
- minimální kumulaci paměťového stavu
- reprodukovatelné zpracování

### Provozní mechanismy

Systém pracuje se dvěma provozními mechanismy:

- **Cron (hlavní)** – orchestrátor je spouštěn periodicky schedulerem; každý běh zpracuje zdroje, které jsou na řadě, a ukončí se
- **Webhook server (doplňkový)** – long-running proces přijímající asynchronní push notifikace z externích systémů; data jsou vložena do fronty a zpracována buď v následujícím cron běhu, nebo samostatným queue processor během

---

## 3. Orchestrátor

**Orchestrátor** je centrální řídicí komponenta systému.

Odpovědnosti orchestrátoru:

- načtení konfigurací zdrojů
- rozhodnutí, které zdroje mají být zpracovány v aktuálním běhu
- vytvoření a inicializace adaptérů
- předání získaných dat do zpracovatelské pipeline
- sběr výsledků běhu

Scheduling logika orchestrátoru vybírá zdroje na základě jejich **priority** a času posledního zpracování (`last_fetched_at`). Zdroje s vyšší prioritou jsou zpracovávány častěji.

Orchestrátor **neobsahuje logiku zpracování obsahu** – jeho rolí je koordinace,
nikoli transformace dat.

---

## 4. Konfigurace a zdroje

Systém pracuje s pojmem **zdroj** (`source`).

Každý zdroj reprezentuje:

- konkrétní sledovaný účet, feed nebo kanál
- jednu kontinuální větev obsahu

Konfigurace zdrojů:

- je deklarativní
- je načítána při startu běhu
- není během běhu dynamicky měněna

Konfigurace má tříúrovňovou hierarchii:

1. **Globální defaults** – výchozí hodnoty pro celý systém
2. **Platform defaults** – výchozí hodnoty pro danou platformu (`config/platforms/*.yml`)
3. **Per-source overrides** – přepisy pro konkrétní zdroj (`config/sources/*.yml`)

Každá úroveň může přepsat hodnoty z úrovně výše. Konfigurace určuje mimo jiné:

- platformu zdroje
- prioritu zpracování
- chování pipeline

---

## 5. Získávání dat (Adaptéry)

Získávání dat může probíhat přes různé technické vrstvy:

- **přímý přístup k platformě** – API nebo RSS feed
- **integrační nástroj** – scraping layer nebo middleware jako prostředník
- **asynchronní vstup** – webhook předávající data do fronty

Tyto vrstvy jsou abstrahovány adaptérem. Zbytek systému s nimi nepřichází do kontaktu.

### Adaptér

Pro každou podporovanou platformu existuje **adaptér**.

Role adaptéru:

- komunikovat s externí platformou
- získat surová data
- převést je na jednotný interní model `Post`

Adaptéry:

- neřeší deduplikaci
- neřeší publikaci
- neřeší formátování cílového textu

Jejich jediným výstupem je **kolekce objektů `Post`**.

---

## 6. Post a jeho životní cyklus

`Post` je unifikovaný datový model reprezentující jeden publikovatelný příspěvek.

V systému představuje:

- přechodnou, platformně‑agnostickou reprezentaci obsahu
- vstupní bod pro veškeré následné zpracování

Životní cyklus `Post`:

1. vytvoření adaptérem
2. předání do pipeline
3. transformace a validace
4. publikace nebo zamítnutí

`Post` není ekvivalentem výsledného Mastodon statusu – je to **mezikrok pipeline**.

---

## 7. Pipeline zpracování

Zpracování obsahu probíhá v explicitní **pipeline**.

Vlastnosti pipeline:

- deterministické pořadí kroků
- každý krok má jednu odpovědnost
- pipeline může zpracování ukončit předčasně

Kroky pipeline v pořadí:

1. **Deduplikace** – kontrola, zda post nebyl již publikován
2. **Detekce editací** – porovnání s dříve publikovaným obsahem
3. **Filtrování obsahu** – aplikace konfigurovatelných filtrů
4. **Formátování** – převod `Post` na text Mastodon statusu
5. **Content replacement** – úpravy textu dle pravidel
6. **Trimming** – ořez na povolený limit znaků
7. **URL processing** – zpracování odkazů
8. **Media enrichment** – stažení a příprava médií
9. **Publikace** – předání publisheru

Podrobnější poznámky ke klíčovým krokům:

| Krok | Poznámka |
|---|---|
| Deduplikace | Ukončí pipeline pokud post ID existuje v `published_posts` |
| Detekce editací | Jaccard + Containment similarity (práh 80 %); zvládá Twitter edity i Bluesky delete+repost |
| Filtrování obsahu | Konfigurovatelná pravidla: `banned_phrases`, `required_keywords`, `content_replacements`; ukončí pipeline pokud nevyhovuje |
| Formátování | Platformový formatter obaluje sdílenou `UniversalFormatter` (text, trim, URL, vlákna, mentions) |
| Trimming | Tři strategie: `smart` (hledá konec věty v tolerančním okně), `word`, `hard` |
| Media enrichment | pHash video dedup (Hamming distance); OGP image fetch ze zdrojového článku; async upload do Mastodon v2 API |
| OGP fetch — SSRF ochrana | `OgpFetcher` blokuje private IP rozsahy (10/8, 172.16/12, 192.168/16, 127/8, 169.254/16 + IPv6 ekvivalenty) před i po každém redirectu; private IP → tichý skip s warningem |

Pipeline neřeší rozhodnutí *kdy* se má zdroj zpracovat – to je úkol orchestrátoru.

---

## 8. Publikace

Po úspěšném průchodu pipeline je výsledek předán **publisheru**.

Publisher:

- komunikuje s cílovou platformou
- provádí vlastní samotnou publikaci
- vrací identifikátory výsledných publikovaných objektů

Primárním cílem je **Mastodon**. Doplňkové subsystémy mohou publikovat i na **Bluesky**.

Publikace je **posledním krokem pipeline**.

---

## 9. Stav a perzistence

Systém si udržuje stav nezbytný pro korektní běh.

Typy uchovávaného stavu:

| Tabulka | Účel |
|---|---|
| `published_posts` | Historie publikací – základ deduplikace a threading lookupů |
| `source_state` | Runtime stav zdrojů – scheduling, error tracking |
| `edit_detection_buffer` | Krátkodobý buffer pro detekci editací (TTL ~2h) |
| `media_fingerprints` | Otisky médií pro deduplication videí a obrázků |

Stav je:

- persistován mezi běhy
- čten a aktualizován během pipeline

Bez tohoto stavu by nebylo možné zaručit deduplikaci a konzistentní publikaci.

---

## 10. Doplňkové subsystémy

Vedle hlavní publikační pipeline systém obsahuje doplňkové subsystémy:

| Subsystém | Funkce |
|---|---|
| Stats / Reporting | Týdenní TOP 10 postů instance; vlákno publikované na Mastodon i Bluesky |
| Profile Sync | Synchronizace avatarů, bannerů, bio a metadata polí botů ze zdrojových platforem; každá platforma má vlastní frekvenci (viz [`../40-tools/runtime.md`](../40-tools/runtime.md)) |
| Trending | Automatický quote-post trendujícího obsahu instance; AI komentář přes Claude API (Hrubot) |
| Friendly Follow | Pravidelná rotace doporučení sledovaných účtů; vlákno na Mastodon i Bluesky |
| Údržbot | Dva provozní režimy: (1) **Health Monitor** — automatické kontroly systému a alerting přes Mastodon; (2) **Command Listener** — interaktivní diagnostika přes mentions (`status`, `check`, `sources`, …) |
| Tlambot | Dva provozní režimy: (1) **CLI broadcast** — ruční hromadná zpráva na všechny nebo vybrané boty; (2) **Webhook mode** — broadcast spouštěný postem z Mastodon účtu `@tlambot`; fronta + HMAC verifikace podpisu |

Tyto subsystémy:

- využívají stejnou základní infrastrukturu (HTTP, DB, publisher)
- nenarušují hlavní tok publikační pipeline
- jsou logicky oddělené a mohou být vypnuty bez dopadu na ingest/publish flow

---

## 11. Sdílená infrastruktura

### Error hierarchy

Centralizovaná hierarchie výjimek v `lib/errors.rb`:

```
Zpravobot::Error (base)
├── NetworkError          # Síťové/HTTP chyby
│   ├── RateLimitError    # 429 (attr: retry_after)
│   └── ServerError       # 5xx (attr: status_code)
├── ConfigError           # Chybná konfigurace
├── PublishError          # Mastodon publish/update/delete
│   ├── StatusNotFoundError   # 404
│   ├── EditNotAllowedError   # 403
│   └── ValidationError       # 422
├── AdapterError          # Selhání zdrojového adaptéru
└── StateError            # Databáze/persistence
```

Všechny komponenty zachytávají `Zpravobot::Error` nebo jeho podtřídy. Typický vzor pro rate limiting:

```ruby
rescue Zpravobot::RateLimitError => e
  sleep e.retry_after   # počká dle Retry-After headeru
```

### HttpClient

`lib/utils/http_client.rb` je centralizovaný HTTP klient eliminující duplicitní `Net::HTTP` boilerplate.
Poskytuje: jednotný User-Agent, sdílené timeouty, connection pooling s per-host cache a 30s TTL,
retry na `Errno::EPIPE`/`IOError`.

Používají ho: `MastodonPublisher`, `CommandListener`, `BaseProfileSyncer`, všechny adaptéry.

---

## 12. Hranice systému

ZBNW‑NG **není**:

- obecný CMS
- event‑driven streaming systém
- realtime publikační nástroj

Je to:

- deterministický dávkový zpracovatelský systém
- navržený pro dlouhodobý provoz
- optimalizovaný na čitelnost a reprodukovatelnost

---

## 13. Co dokument záměrně nepokrývá

Tento dokument se vyhýbá:

- popisu historických incidentů
- interním provozním detailům
- citlivým konfiguracím
- soukromým podkladům a diskusím

Tyto informace **nejsou nutné pro pochopení fungování systému** a nejsou
součástí veřejné dokumentace.
