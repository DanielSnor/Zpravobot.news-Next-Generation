# Zprávobot.news Next Generation (ZBNW-NG)

[![License: Unlicense](https://img.shields.io/badge/license-Unlicense-blue.svg)](https://unlicense.org)
[![Mastodon](https://img.shields.io/badge/Mastodon-Instance-6364FF?logo=mastodon&logoColor=white)](https://zpravobot.news)
[![Ruby](https://img.shields.io/badge/Ruby-Pure_stdlib-CC342D?logo=ruby&logoColor=white)](https://www.ruby-lang.org)

![Maskot Zpravobot.news](https://zpravobot.news/system/site_uploads/files/000/000/002/@2x/49c4aa7df6b81d4a.png 'Maskot Zpravobot.news')

**ZBNW-NG** je serverový motor, který aktuálně začíná pohánět **[Zprávobot.news](https://zpravobot.news)** 📰🤖 — veřejnou Mastodon instanci provozovanou Danielem Šnorem, která zrcadlí 🪞 populární české 🇨🇿 a slovenské 🇸🇰 účty z X/Twitteru 🐦, Bluesky 🦋, Facebooku 🤦‍♂️📘, Instagramu 📸 a Youtube 📺 doplněné o RSS kanály 📡 a přináší na Mastodon 🐘 jinak chybějící zprávy 📰, sport ⚽️🏒🏎️, technologie 📱⌚️💻📡, zábavu 🎞️🎶🎭 a občas i humor 🤣🤪.

Zatímco původní projekt [Zpravobot.news](https://github.com/danielsnor/zpravobot.news) využíval IFTTT filtrové skripty na zpracování obsahu, **ZBNW-NG** tohle celé nahrazuje a rozšiřuje plnohodnotným Ruby pipeline — přidává nativní podporu vláken, publikování více obrázků, detekci editací, deduplikaci postů, chytrý monitoring a plnou kontrolu nad zpracováním bez IFTTT limitu 65 KB na skript.

**🌉 BlueSky Bridge**: Od září 2025 je většina botů dostupná i na BlueSky přes [Brid.gy](https://fed.brid.gy/), takže se český obsah šíří napříč federovanými platformami.

> **Recent highlights (duben 2026):**
> - **Security hardening** — SEC-1..4: 1 MB payload limit, SSRF blocklist v OGP fetcheru, length validation, filename sanitization
> - **Performance** — PERF-1..7: prefetch Nitter HTML, DB/HTTP connection pooling, non-blocking rate limit handling
> - **Reliability** — atomic file writes (RELIABILITY-1), 103 registrovaných testů (77 unit + 18 network + 2 db + 6 e2e)
> - **Feature** — Týdeník `#ZpravobotTOP10` (neděle 20:15), profile card blocker (bílý proužek), OGP image fetcher

## Obsah

- [O projektu](#o-projektu)
- [Mise](#mise)
- [Proč ZBNW-NG?](#proč-zbnw-ng)
- [Podporované platformy](#podporované-platformy)
- [Technická architektura](#technická-architektura)
- [Rychlý start](#rychlý-start)
- [Struktura projektu](#struktura-projektu)
- [Klíčové komponenty](#klíčové-komponenty)
- [Konfigurace](#konfigurace)
- [Cron joby a plánování](#cron-joby-a-plánování)
- [Testování](#testování)
- [Monitoring (Údržbot)](#monitoring-údržbot)
- [Dokumentace](#dokumentace)
- [Jak přispět](#jak-přispět)
- [Podpora](#podpora)
- [Poděkování](#poděkování)
- [English Summary](#english-summary)

---

## O projektu

Česká Mastodon komunita je docela malá a vydavatelé novin i jiné zdroje informací ji většinou přehlížejí. **Zprávobot.news** vznikl proto, aby tuhle mezeru zaplnil a dal českým uživatelům Mastodonu přístup k čerstvým zprávám a informacím z různých platforem.

ZBNW-NG pohání zhruba 500 botích účtů na instanci zpravobot.news a zpracovává obsah z Twitteru/X, Bluesky, Facebooku a Instagramu, RSS feedů a YouTube do nativně vypadajících Mastodon příspěvků se správným vlákněním, médii a formátováním.

Projekt provozuje [Daniel Šnor](https://zpravobot.news/@zpravobot) a funguje jako veřejná služba.

### Dostupnost na více platformách

Od **září 2025** je většina Zpravobot botů přemostěna na **BlueSky** pomocí [Brid.gy](https://fed.brid.gy/), takže je český obsah přístupný uživatelům Mastodonu i BlueSky napříč fediverse a sítí AT Protocolu.

## Mise

ZBNW-NG automatizuje sběr, formátování a publikování obsahu na Mastodon — vytváří jednotný a efektivní systém pro zrcadlení obsahu, který slouží české Mastodon komunitě. Každý příspěvek je navržený tak, aby vypadal nativně, ne jako výstup automatizace.

| Princip | Vysvětlení |
|---------|------------|
| **Nativní vzhled** | Posty nevypadají jako automatizace — správné emoji, formátování, threading |
| **Evidence-based** | Změny na základě reálných problémů, ne teoretických optimalizací |
| **Modularita** | Adaptery, Formattery, Publishery, Procesory — každý má jednu odpovědnost |
| **Robustnost** | Retry logika, graceful degradation, error tracking |
| **Deduplikace** | PostgreSQL state management zabraňuje duplicitním publikacím |

## Proč ZBNW-NG?

ZBNW-NG vznikl, aby překonal omezení původního přístupu přes IFTTT:

| Omezení (IFTTT) | Řešení (ZBNW-NG) |
|---|---|
| Ořezaný text (>257 znaků) | Plný text přes Nitter scraping + Syndication API |
| Max 1 obrázek na post | Až 4 mediální přílohy (limit Mastodonu) |
| Žádný kontext vlákna | Plná podpora vláken s in-memory cache + DB lookup |
| Žádná detekce editací | Detekce editací na bázi podobnosti s aktualizací Mastodon statusů |
| Limit skriptu 65 KB | Bez omezení — plný Ruby codebase (~20K řádků) |
| Žádný monitoring | Údržbot: health checky, alerty, interaktivní příkazy |
| Žádná synchronizace profilů | Automatický sync avataru/banneru/bio ze zdrojových platforem |

## Podporované platformy

Každá platforma může být zdrojem **obsahu** (příspěvky), zdrojem **profilových dat** (avatar, banner, bio), nebo obojím. Profily se synchronizují automaticky přes `sync_profiles.rb` a zapisují zpět na Mastodon přes `MastodonProfileUpdater`.

### Zdroje obsahu

| Platforma | Adapter | Zdroj dat | Funkce |
|---|---|---|---|
| ✅ **Twitter/X** | `TwitterAdapter` + `TwitterNitterAdapter` + `TwitterTweetProcessor` | IFTTT webhooky + Nitter scraping | Unifikovaná pipeline, 5-stupňový Tier fallback, threading, detekce editací |
| ✅ **Bluesky** | `BlueskyAdapter` | AT Protocol API | Feedy + profily, podpora vláken přes AT URI |
| ✅ **Facebook** | `RssAdapter` | RSS feed přes [RSS.app](https://rss.app) | Příspěvky přes RSS.app bridge (Facebook nemá veřejné API) |
| ✅ **Instagram** | `RssAdapter` | RSS feed přes [RSS.app](https://rss.app) | Příspěvky přes RSS.app bridge; profily přes vlastní syncer |
| ✅ **RSS / Atom** | `RssAdapter` | RSS 2.0 / Atom | Univerzální RSS pro ostatní zdroje |
| ✅ **YouTube** | `YouTubeAdapter` | YouTube RSS feed | Filtrování Shorts, práce s miniaturami |

### Synchronizace profilů

| Platforma | Syncer | Jak | Co se synchronizuje |
|---|---|---|---|
| ✅ **Twitter/X** | `TwitterProfileSyncer` | Nitter scraping | Avatar, banner, bio, URL |
| ✅ **Bluesky** | `BlueskyProfileSyncer` | AT Protocol API | Avatar, banner, bio, URL |
| ✅ **Facebook** | `FacebookProfileSyncer` | Browserless.io | Avatar, banner, bio, web |
| ✅ **Instagram** | `InstagramProfileSyncer` | Browserless.io + cookies | Avatar, bio |
| ✅ **YouTube** | `YoutubeProfileSyncer` | Přímý HTTP, `ytInitialData` JSON | Avatar, banner, bio |

### Hybridní architektura Twitter/X

Integrace Twitteru používá pětistupňový systém s postupným fallbackem:

| Tier | Zdroj dat | Média | Plný text | Kdy se použije |
|------|-----------|-------|-----------|----------------|
| **1** | IFTTT | ❌ | ✅ (krátký) | Krátký tweet bez médií a vláken |
| **1.5** | IFTTT + Syndication API | ✅ | ⚠️ možná zkrácený | `nitter_processing: false` v konfiguraci |
| **2** | IFTTT + Nitter | ✅ | ✅ | Média, dlouhý text, RT, vlákna |
| **3.5** | Syndication fallback | ✅ | ⚠️ možná zkrácený | Nitter selhal → stále máme média |
| **3** | IFTTT fallback | ❌ | ⚠️ zkrácený | Finální degradovaný režim |

**Proč IFTTT?** Twitter nemá veřejné API pro sledování nových tweetů. Existují v zásadě dvě cesty — pollovat Nitter RSS feed, nebo nechat IFTTT poslat webhook v momentě, kdy se tweet objeví. IFTTT funguje jako **real-time push trigger** (okamžité notifikace přes oficiální Twitter API), zatímco Nitter slouží jako **obohacovač dat** (doplní plný text, média, vlákna). Bez IFTTT by bylo nutné pollovat Nitter RSS pro všechny sledované zdroje každé cca 2 minuty, což při desítkách účtů rychle naráží na rate limity.

**Pro menší projekty** (nižší desítky zdrojů) je čistý Nitter RSS polling naprosto dostačující a IFTTT není potřeba — `TwitterAdapter.fetch_posts()` tenhle režim podporuje. IFTTT se vyplatí až při větším počtu sledovaných účtů.

**Nitter a burner účty:** Nitter vyžaduje pro scraping Twitteru tzv. burner účty (jednorázové Twitter účty s cookies). Orientačně je potřeba zhruba 1 burner účet na 10 sledovaných zdrojů. Cookies občas expirují a vyžadují ruční obnovu, takže je s Nitterem spojená určitá provozní údržba.

### Distribuce

- 🐘 **Mastodon** — Primární platforma přes zpravobot.news (~500 botích účtů)
- 🦋 **BlueSky** — Od září 2025 přes Brid.gy federaci (kromě zdrojů přebíraných právě z Bluesky nebo tam separátně obsluhovaných)

## Technická architektura

```
┌─────────────────────────────────────────────────────────────────┐
│                          ZDROJE OBSAHU                          │
├─────────────────────────────────────────────────────────────────┤
│  Bluesky API   RSS Feedy   YouTube RSS   Twitter (IFTTT+Nitter) │
└──────┬──────────────┬────────────┬────────────────┬─────────────┘
       │              │            │                │
       ▼              ▼            ▼                ▼
┌─────────────────────────────────────────────────────────────────┐
│                         ADAPTERY                                │
│  BlueskyAdapter  RssAdapter  YouTubeAdapter  TwitterAdapter     │
│                                            TwitterNitterAdapter │
└──────────────────────────┬──────────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                        MODEL PŘÍSPĚVKU                          │
│ Sjednocený: id, url, text, author, media, is_repost, is_quote...│
└──────────────────────────┬──────────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                ORCHESTRÁTOR / PROCESOR FRONTY                   │
│          Plánování · Řešení vláken · Zpracování chyb            │
└──────────────────────────┬──────────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                     PROCESOR PŘÍSPĚVKŮ                          │
│  Kroky pipeline:                                                │
│  1. Dedupe → 2. Detekce editací → 3. Filtrování obsahu →        │
│  4. Formátování → 5. Zpracování obsahu →                        │
│  6a. Čištění URL / 6b. Video dedup (pHash) / 6c. OGP fetch →    │
│  7. Upload médií → 8. Publikace →                               │
│  9a. Aktualizace stavu / 9b. Uložení media fingerprint          │
└──────────────────────────┬──────────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                   MASTODON PUBLISHER                            │
│  Publikování statusů · Upload médií (v2 async) · Threading      │
│  Řešení rate limitů (429) · Retry při server errorech (5xx)     │
└──────────────────────────┬──────────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                SPRÁVCE STAVU (PostgreSQL)                       │
│  published_posts · source_state · activity_log · edit_buffer    │
└─────────────────────────────────────────────────────────────────┘
```

**Stack:** Čisté Ruby (bez Rails/Sinatra), minimální gemy (`pg`, `rss`, `http`, `logger`), PostgreSQL.

### Sdílená infrastruktura

| Komponenta | Soubor | K čemu to je |
|---|---|---|
| **Hierarchie chyb** | `lib/errors.rb` | `Zpravobot::Error` → Network/Config/Publish/Adapter/StateError |
| **HttpClient** | `lib/utils/http_client.rb` | Centralizované HTTP s retry, timeouty, User-Agent |
| **Support::Loggable** | `lib/support/loggable.rb` | Jednotný logging mixin pro všechny třídy |
| **Logování** | `lib/logging.rb` | Denní rotující logy se samočištěním |
| **HashHelpers** | `lib/utils/hash_helpers.rb` | Deep symbolize/merge pro YAML konfigurace |

## Rychlý start

### Co budete potřebovat

- Ruby (s Bundlerem)
- PostgreSQL
- Mastodon instanci s botími účty
- Nitter instanci (pro scraping Twitteru) + burner Twitter účty (~1 na 10 zdrojů)
- volitelně IFTTT PRO+ předplatné (pro Twitter webhook triggery, viz [Hybridní architektura](#hybridní-architektura-twitterx))

### Instalace

```bash
# 1. Klonujte a nainstalujte závislosti
git clone <repo-url>
cd zbnw-ng
bundle install

# 2. Nastavte prostředí
cp env.sh.example env.sh
# Upravte env.sh — zadejte údaje k databázi, Nitteru a Mastodonu
source env.sh

# 3. Inicializujte databázi
psql "$CLOUDRON_POSTGRESQL_URL" -f db/01_setup_database.sql
psql "$CLOUDRON_POSTGRESQL_URL" -f db/02_migrate_schema.sql

# 4. Vytvořte první zdroj
ruby bin/create_source.rb

# 5. Testovací běh (nic se nepublikuje)
bundle exec ruby bin/run_zbnw.rb --dry-run

# 6. Produkční běh
bundle exec ruby bin/run_zbnw.rb
```

### Běžné příkazy

```bash
# Spustit všechny zdroje
bundle exec ruby bin/run_zbnw.rb

# Spustit konkrétní platformu / zdroj
bundle exec ruby bin/run_zbnw.rb --platform bluesky
bundle exec ruby bin/run_zbnw.rb --source ct24_twitter

# Testovací běh (nic se nepublikuje)
bundle exec ruby bin/run_zbnw.rb --dry-run

# První spuštění (jen inicializace stavu)
bundle exec ruby bin/run_zbnw.rb --first-run --source new_source

# Synchronizace profilů
bundle exec ruby bin/sync_profiles.rb --platform bluesky

# Health check
ruby bin/health_monitor.rb --details

# Spustit testy
ruby bin/run_tests.rb
```

## Struktura projektu

```
bin/                          # Vstupní body (17 skriptů)
  run_zbnw.rb                 # Hlavní runner (cron)
  run_tests.rb                # Test runner s generátorem reportů
  ifttt_webhook.rb            # IFTTT webhook HTTP server (~10-15 MB RAM)
  health_monitor.rb           # Údržbot health monitoring
  command_listener.rb         # Údržbot interaktivní příkazy přes Mastodon
  sync_profiles.rb            # Runner pro sync profilů (avatar, banner, bio)
  create_source.rb            # Interaktivní průvodce konfigurací zdrojů
  manage_source.rb            # Správa zdrojů — pause/resume/retire
  force_update_source.rb      # Reset stavu zdroje pro okamžité zpracování
  retry_failed_queue.rb       # Opakování neúspěšných IFTTT webhooků
  source_report.rb            # Týdenní report aktivity zdrojů
  trending_post.rb            # Publikace trending příspěvku
  zpravobot_stats.rb          # Týdenní statistiky (#ZpravobotStats)
  broadcast.rb                # Odeslání zprávy všem/vybraným botům
  process_broadcast_queue.rb  # Zpracování fronty broadcast zpráv
  cleanup_duplicate_posts.rb  # Čištění duplicitních postů z DB
  cleanup_orphaned_accounts.rb # Čištění osiřelých účtů

lib/                          # Zdrojový kód
  orchestrator.rb             # Koordinace systému
  logging.rb                  # Centralizované denní rotující logy
  errors.rb                   # Hierarchie chyb (Zpravobot::Error)
  adapters/                   # Zdrojové adaptery (Bluesky, Twitter, RSS, YouTube)
  broadcast/                  # Broadcast queue (odesílání zpráv botům)
  config/                     # ConfigLoader, SourceConfig
  formatters/                 # Platformově specifické + UniversalFormatter
  health/                     # Health monitor (CheckResult, AlertStateManager)
  models/                     # Post, Author, Media, PostTextWrapper
  monitoring/                 # Command Listener + Handlery
  processors/                 # PostProcessor, ContentProcessor, Pipeline Steps, EditDetector, MediaDedup
  publishers/                 # MastodonPublisher
  reporting/                  # Source report (aktivity, statistiky zdrojů)
  services/                   # SyndicationMediaFetcher
  source_wizard/              # Interaktivní generátor konfigurací (8 modulů)
  state/                      # StateManager facade + 5 repozitářů
  stats/                      # Zpravobot týdeník (SnapshotStore, PublishingStats, SkokanDetector)
  support/                    # Loggable mixin, ThreadingSupport, OptionalProcessors
  syncers/                    # 5 zdrojových syncerů + MastodonProfileUpdater + ImageCacheManager
  test_runner/                # Runner, OutputParser, ReportGenerator
  trending/                   # Trending příspěvky
  utils/                      # HttpClient, HashHelpers, HtmlCleaner, FormatHelpers, OgpFetcher
  webhook/                    # IftttQueueProcessor

config/                       # Konfigurace
  global.yml                  # Globální nastavení
  platforms/                  # Výchozí nastavení platforem (twitter.yml, bluesky.yml, ...)
  sources/                    # Jednotlivé zdroje (ct24_twitter.yml, ...)
  mastodon_accounts.yml       # Přihlašovací údaje k Mastodonu
  health_monitor.yml          # Konfigurace monitoringu
  test_catalog.yml            # Registr testů (kategorie, tagy, timeouty)

test/                         # Testy (71 souborů, 199 assertů)
db/                           # SQL migrace
docs/                         # Dokumentace (9 souborů)
```

## Klíčové komponenty

| Komponenta | Soubor(y) | K čemu to je |
|---|---|---|
| **Orchestrator** | `lib/orchestrator.rb` | Načtení zdrojů → fetch → zpracování → publikace |
| **PostProcessor** | `lib/processors/post_processor.rb` | Sjednocený pipeline (9 hlavních kroků + podkroky 6b/6c/9b) |
| **Pipeline Steps** | `lib/processors/pipeline_steps.rb` | Rozložené kroky (Dedupe, Edit, Filter, URL, ProcessingContext) |
| **StateManager** | `lib/state/state_manager.rb` | Facade → 5 repozitářů (DB, Posts, Sources, Activity, EditBuffer) |
| **MastodonPublisher** | `lib/publishers/mastodon_publisher.rb` | Mastodon API (publikace, async upload médií, threading) |
| **ContentProcessor** | `lib/processors/content_processor.rb` | Chytré zkracování, normalizace výpustek, URL-aware |
| **EditDetector** | `lib/processors/edit_detector.rb` | Detekce editací na základě podobnosti (práh 80 %) |
| **MediaDedup** | `lib/processors/media_dedup.rb` | Perceptuální deduplikace videí přes pHash/aHash (Hamming vzdálenost) |
| **ThumbnailPhash** | `lib/processors/thumbnail_phash.rb` | Výpočet pHash přes ImageMagick (8×8 aHash) |
| **OgpFetcher** | `lib/utils/ogp_fetcher.rb` | Fetch `og:image` z článku jako nativní médium (obchází scraper) |
| **StatsPostFormatter** | `lib/stats/stats_post_formatter.rb` | Formátování týdenního #ZpravobotStats postu |
| **SkokanDetector** | `lib/stats/skokan_detector.rb` | Detekce skokanu (relativní nárůst aktivity nebo followers) |
| **SourceManager** | `lib/source_wizard/source_manager.rb` | Pause/resume/retire zdrojů přes CLI |
| **Údržbot** | `lib/health/`, `lib/monitoring/` | Health monitoring + interaktivní příkazy přes Mastodon |

## Konfigurace

### Hierarchie

```
config/global.yml → config/platforms/{platform}.yml → config/sources/{id}.yml
```

Nastavení se mergují od globálních → platforma → zdroj, přičemž nastavení na úrovni zdroje přepisují vše ostatní.

### Příklad konfigurace zdroje

```yaml
id: ct24_twitter
enabled: true
platform: twitter

source:
  handle: "CT24zive"
  nitter_instance: "http://xn.zpravobot.news:8080"

target:
  mastodon_account: ct24
  visibility: public

formatting:
  source_name: "ČT24"
  url_domain: "nitter.net"
  prefix_repost: "𝕏🔄"
  max_length: 500

filtering:
  skip_replies: true
  skip_retweets: false
  banned_phrases: []

processing:
  trim_strategy: smart
  content_replacements: []

scheduling:
  priority: high

profile_sync:
  enabled: true
  language: cs
  retention_days: 90
```

### Proměnné prostředí

Konfigurují se přes `env.sh`:

| Proměnná | Popis |
|---|---|
| `ZBNW_DIR` | Kořenový adresář projektu |
| `ZBNW_SCHEMA` | DB schéma (`zpravobot` / `zpravobot_test`) |
| `CLOUDRON_POSTGRESQL_URL` | PostgreSQL connection string |
| `NITTER_INSTANCE` | URL Nitter instance |
| `IFTTT_PORT` | Port webhook serveru (výchozí 8089) |
| `ZPRAVOBOT_MONITOR_TOKEN` | Mastodon token pro Údržbota |

## Cron joby a plánování

### IFTTT a synchronizace obsahu

| Interval | Co dělá | Skript |
|---|---|---|
| `* * * * *` | Watchdog webhook serveru | `cron_webhook.sh` |
| `*/2 * * * *` | Zpracování IFTTT fronty (Twitter) | `cron_ifttt.sh` |
| `*/10 * * * *` | Sync obsahu (Bluesky, RSS, YouTube) | `cron_zbnw.sh --exclude-platform twitter` |

### Synchronizace profilů

Týdenní rotace — každá platforma se synchronizuje jeden den v týdnu:

| Den | Co dělá | Skript |
|---|---|---|
| Pondělí | Bluesky profily | `cron_profile_sync.sh --platform bluesky` |
| Úterý | Facebook + Instagram profily | `cron_profile_sync.sh --platform facebook` + `instagram` |
| Středa–Pátek | Twitter/X profily (rotace) | `cron_profile_sync.sh --platform twitter` |
| Sobota | RSS (kontrola zdrojů) | — |
| Neděle | YouTube profily | `cron_profile_sync.sh --platform youtube` |

Sync profilů zahrnuje: avatar, banner, bio, URL, a fields. Syncery zdrojových platforem (BS/FB/IG/TW/YT) → `MastodonProfileUpdater` → Mastodon API.

### Statistiky a reporting

| Interval | Co dělá | Skript |
|---|---|---|
| `0 20 * * 0` | Týdenní #ZpravobotStats | `cron_stats.sh` |
| `0 6 * * 1` | Týdenní source report | `cron_source_report.sh` |
| `0 * * * *` | Retry IFTTT failed fronty | `cron_retry_failed.sh` |
| konfigurovatelně | Trending příspěvek | `cron_trending.sh` |

### Monitoring (Údržbot)

| Interval | Co dělá | Skript |
|---|---|---|
| `*/5 * * * *` | Listener příkazů | `cron_command_listener.sh` |
| `*/10 * * * *` | Health check + alert | `cron_health.sh --alert --save` |
| `0 8 * * *` | Denní heartbeat | `cron_health.sh --heartbeat` |

### Údržba

| Interval | Co dělá |
|---|---|
| `0 3 * * *` | Rotace logů (smazání `*.log` starších než 7 dní) |

Všechny cron wrappery načítají `env.sh` pro konfiguraci prostředí. Testovací prostředí běží s nižší frekvencí (`*/60` pro sync obsahu, `*/60` pro IFTTT frontu).

## Testování

ZBNW-NG používá **vlastní testovací framework** (ne minitest/RSpec) s čítači `$passed`/`$failed`.

```bash
ruby bin/run_tests.rb              # Unit testy (výchozí)
ruby bin/run_tests.rb --all        # Unit + síťové + DB
ruby bin/run_tests.rb --tag bluesky # Testy s tagem
ruby bin/run_tests.rb --file edit  # Testy odpovídající "edit"
ruby bin/run_tests.rb --list       # Výpis testů bez spuštění
```

**Registr testů:** `config/test_catalog.yml` — kategorie (unit/network/e2e/db), tagy, timeouty.

**Aktuální stav:** 68/68 unit testů PASS, 2 032 assertů.

## Monitoring (Údržbot)

**Mastodon účet:** `@udrzbot@zpravobot.news`

### Health Monitor

Automatizované kontroly s chytrým alertováním (nový problém → okamžitý alert, přetrvávající → hodinové/noční připomínky, vyřešený → potvrzení).

```bash
ruby bin/health_monitor.rb              # Zobrazení stavu
ruby bin/health_monitor.rb --alert      # Alert při problémech
ruby bin/health_monitor.rb --heartbeat  # Heartbeat (všechno OK)
ruby bin/health_monitor.rb --details    # Podrobný report s kroky k nápravě
```

### Listener příkazů

Interaktivní příkazy přes zmínky na Mastodonu pro `@udrzbot`:

| Příkaz | Popis |
|---|---|
| `help` | Výpis dostupných příkazů |
| `status` | Kompaktní přehled stavu |
| `detail` | Plný report s kroky k nápravě |
| `sources` | Problematické zdroje |
| `check [název]` | Detail konkrétní kontroly |

### Monitorované služby

Webhook server, Nitter instance, Nitter účty, IFTTT fronta, zpracování databáze, Bluesky API, Mastodon API, trendy aktivity.

## Dokumentace

| Soubor | Obsah |
|---|---|
| [`docs/zbnw-ng_system.md`](docs/zbnw-ng_system.md) | Systémová dokumentace (architektura, pipeline, API) |
| [`docs/technical_debt.md`](docs/technical_debt.md) | Sledování technického dluhu (10 refaktorovacích fází) |
| [`docs/helper_tools.md`](docs/helper_tools.md) | Pomocné nástroje a monitoring |
| [`docs/twitter_platform.md`](docs/twitter_platform.md) | Integrace Twitter/X (IFTTT + Nitter hybrid) |
| [`docs/bluesky_platform.md`](docs/bluesky_platform.md) | Integrace Bluesky AT Protocol |
| [`docs/rss_platform.md`](docs/rss_platform.md) | Integrace RSS/Atom + Facebook |
| [`docs/youtube_platform.md`](docs/youtube_platform.md) | Integrace YouTube RSS |
| [`docs/nitter_platform.md`](docs/nitter_platform.md) | Provoz Nitter instance |
| [`docs/cloudron_infrastructure.md`](docs/cloudron_infrastructure.md) | Infrastruktura Cloudron serveru |

## Jak přispět

Příspěvky jsou vítány! Projekt je vydán pod [Unlicense licencí](https://unlicense.org), takže je kompletně ve veřejné doméně.

### Vývojový workflow

1. **Forkněte** repozitář
2. **Vytvořte** feature branch
3. **Otestujte** své změny: `ruby bin/run_tests.rb`
4. **Ověřte** přes dry run: `ruby bin/run_zbnw.rb --dry-run`
5. **Pošlete** pull request

### Standardy kódu

- Čisté Ruby, minimální gemy: `pg`, `rss`, `http`, `logger`
- `Support::Loggable` mixin pro všechny nové třídy
- `rescue Zpravobot::Error` hierarchie pro zpracování chyb
- `HttpClient` pro všechny HTTP požadavky (žádné přímé `Net::HTTP`)
- Vlastní testovací framework: `def test(name, expected, actual)`
- Nové testy registrujte v `config/test_catalog.yml`

## Podpora

Pokud vám Zprávobot.news přijde užitečný a chtěli byste podpořit jeho provoz:

- 🏦 **Bankovní převod**: IBAN CZ8830300000001001612070
- 💳 **Revolut**: [revolut.me/zpravobot](https://revolut.me/zpravobot)
- ☕ **Ko-fi**: [ko-fi.com/zpravobot](https://ko-fi.com/zpravobot)
- 🖥️ **Forendors**: [forendors.cz/zpravobot](https://forendors.cz/zpravobot)

![QR kód pro bankovní převod](https://zpravobot.news/system/media_attachments/files/113/069/699/996/938/723/original/824504de17667be7.jpeg 'QR kód pro bankovní převod')

## Poděkování

Tenhle projekt by neexistoval bez:

- **Mé rodiny** — Má milovaná manželka [Greticzka](https://mastodon.social/@greticzka) a naše dcery mě neochvějně podporovaly
- **[Marvoqs](https://github.com/marvoqs)** — Naprogramoval základní IFTTT skriptové architektury
- **[Lawondyss](https://github.com/Lawondyss)** — Provedl rozsáhlý vývoj IFTTT filtru a přidával nové funkce
- **Česká Mastodon komunita** — Za to, že tohle všechno má smysl

---

# English Summary

## What is ZBNW-NG?

**ZBNW-NG** (Zprávobot.news Next Generation) is a content aggregation and distribution engine written in pure Ruby. It powers [zpravobot.news](https://zpravobot.news), a public Mastodon instance that mirrors ~500 Czech and Slovak accounts from Twitter/X, Bluesky, Facebook, Instagram, YouTube, and RSS feeds into native-looking Mastodon posts.

The Czech Mastodon community is small and largely ignored by mainstream media. Zprávobot.news bridges this gap by bringing news, sports, tech, entertainment, and other content into the fediverse. Since September 2025, most bots are also bridged to BlueSky via [Brid.gy](https://fed.brid.gy/).

## Tech Stack

- **Pure Ruby** (~20K LOC, 94 lib files) — no Rails, no Sinatra
- **Minimal gems:** `pg`, `rss`, `http`, `logger`, `simpleidn`
- **PostgreSQL** for state management (deduplication, activity log, edit buffer)
- **No external queue/worker system** — cron-driven with disk-based queue for webhooks

## Architecture

```
Sources (Twitter, Bluesky, RSS, YouTube)
    ↓
Adapters (platform-specific fetching)
    ↓
Unified Post Model (id, text, media, author, thread info)
    ↓
Orchestrator (scheduling, thread resolution)
    ↓
PostProcessor (9-step pipeline):
  1. Deduplication    2. Edit detection     3. Content filtering
  4. Formatting       5. Content processing 6. URL cleanup
  7. Media upload     8. Publishing         9. State update
    ↓
MastodonPublisher (API calls, parallel media upload, threading, rate limiting)
    ↓
StateManager → PostgreSQL
```

### Key Design Decisions

- **All config uses symbol keys** — YAML is loaded via `deep_symbolize_keys`. Never use string keys.
- **Hierarchical config merging** — `global.yml` → `platforms/{platform}.yml` → `sources/{id}.yml`, with source-level overrides winning.
- **Facade pattern** — `StateManager` wraps 5 repository classes (posts, sources, activity, edit buffer, DB connection).
- **Custom error hierarchy** — `Zpravobot::Error` → Network/Config/Publish/Adapter/StateError.
- **`Support::Loggable` mixin** — unified logging across all classes.
- **`HttpClient`** — centralized HTTP with retry, timeouts, User-Agent (no direct `Net::HTTP`).

## Source Platforms

| Platform | Adapter | Data Source | Notes |
|----------|---------|-------------|-------|
| **Twitter/X** | `TwitterAdapter` + `TwitterNitterAdapter` + `TwitterTweetProcessor` | IFTTT webhooks + Nitter scraping | Unified pipeline, 5-tier fallback, threading, edit detection |
| **Bluesky** | `BlueskyAdapter` | AT Protocol API | Direct API, feed pagination, thread support |
| **RSS/Atom** | `RssAdapter` | RSS 2.0 / Atom feeds | Also used for Facebook (via RSS.app) |
| **YouTube** | `YouTubeAdapter` | YouTube RSS feed | Shorts filtering, thumbnail handling |

### Twitter/X Hybrid Architecture

Twitter integration uses a 5-tier system with progressive fallback:

| Tier | Source | Full Text | Media | When Used |
|------|--------|-----------|-------|-----------|
| 1 | IFTTT only | Short | No | Simple short tweets |
| 1.5 | IFTTT + Syndication API | Maybe | Yes | `nitter_processing: false` |
| 2 | IFTTT + Nitter | Yes | Yes | Default — best quality |
| 3.5 | Syndication fallback | Maybe | Yes | Nitter failed |
| 3 | IFTTT fallback | Short | No | Final degraded mode |

IFTTT acts as a **real-time push trigger** (instant webhook on new tweet), while Nitter acts as a **data enricher** (full text, media, thread context). For smaller deployments, pure Nitter RSS polling works fine without IFTTT.

## Key Components

| Component | Path | Purpose |
|-----------|------|---------|
| **Orchestrator** | `lib/orchestrator.rb` | Main coordination — load sources, fetch, process, publish |
| **PostProcessor** | `lib/processors/post_processor.rb` | Unified 9-step pipeline |
| **EditDetector** | `lib/processors/edit_detector.rb` | 80% text similarity threshold for edit detection |
| **ContentProcessor** | `lib/processors/content_processor.rb` | Smart text trimming (word/sentence/smart strategies) |
| **MastodonPublisher** | `lib/publishers/mastodon_publisher.rb` | Publishing, parallel media upload (v2 async), threading, rate limit handling |
| **StateManager** | `lib/state/state_manager.rb` | Facade → 5 PostgreSQL repositories |
| **ConfigLoader** | `lib/config/config_loader.rb` | YAML loading with hierarchical merging |
| **Health Monitor** | `lib/health/health_monitor.rb` | 11 automated checks with smart alerting |
| **Command Listener** | `lib/monitoring/command_listener.rb` | Interactive commands via Mastodon mentions |

## Entry Points (bin/)

| Script | Purpose |
|--------|---------|
| `run_zbnw.rb` | Main runner — `--platform`, `--source`, `--dry-run`, `--first-run` |
| `ifttt_webhook.rb` | Lightweight HTTP server for IFTTT webhooks (~10-15 MB RAM) |
| `sync_profiles.rb` | Avatar/banner/bio sync from source platforms (BS/FB/IG/TW/YT) |
| `health_monitor.rb` | Health checks — `--alert`, `--heartbeat`, `--details` |
| `command_listener.rb` | Poll Mastodon mentions for interactive commands |
| `manage_source.rb` | Pause/resume/retire sources via CLI |
| `broadcast.rb` | Send a message to all/selected bot accounts |
| `process_broadcast_queue.rb` | Process broadcast message queue |
| `retry_failed_queue.rb` | Retry failed IFTTT webhooks |
| `source_report.rb` | Weekly source activity report |
| `trending_post.rb` | Publish trending content post |
| `zpravobot_stats.rb` | Weekly #ZpravobotStats digest |
| `create_source.rb` | Interactive source configuration wizard |
| `force_update_source.rb` | Reset source state for immediate reprocessing |
| `cleanup_duplicate_posts.rb` | Clean duplicate posts from DB |
| `cleanup_orphaned_accounts.rb` | Clean orphaned bot accounts |
| `run_tests.rb` | Test runner with HTML report generation |

## Cron Schedule (Production)

| Interval | Job |
|----------|-----|
| Every minute | Webhook server watchdog |
| Every 2 min | IFTTT queue processing (Twitter) |
| Every 8-10 min | Content sync (Bluesky, RSS, YouTube) |
| Every 15 min | Twitter content sync (rate-limited) |
| Every 5 min | Command listener polling |
| Every 10 min | Health check + alerting |
| Hourly | IFTTT failed queue retry |
| Weekly (day rotation) | Profile sync (Mon=BS, Tue=FB+IG, Wed–Fri=TW, Sat=RSS, Sun=YT) |
| Sunday 20:00 | Weekly #ZpravobotStats post |
| Monday 06:00 | Weekly source activity report |
| Daily | Log rotation, heartbeat |

## Monitoring (Údržbot)

The system includes a monitoring bot (`@udrzbot@zpravobot.news`) with:

- **11 health checks:** Mastodon API, Nitter, webhook server, IFTTT queue, runner health, processing rates, server resources, log analysis, problematic sources, recurring warnings, Nitter accounts
- **Smart alerting:** new problem → immediate alert, persisting → hourly/nightly reminders, resolved → confirmation
- **Interactive commands** via Mastodon mentions: `status`, `detail`, `sources`, `check [name]`, `help`

## Configuration

```
config/
  global.yml              # Global defaults
  platforms/              # Platform defaults (twitter.yml, bluesky.yml, rss.yml, youtube.yml)
  sources/                # Per-source config (100+ files)
  mastodon_accounts.yml   # Mastodon credentials
  health_monitor.yml      # Health check thresholds
  test_catalog.yml        # Test registry
```

Example source config:

```yaml
id: ct24_twitter
enabled: true
platform: twitter
source:
  handle: "CT24zive"
target:
  mastodon_account: ct24
  visibility: public
formatting:
  source_name: "ČT24"
  max_length: 500
filtering:
  skip_replies: true
  skip_retweets: false
processing:
  trim_strategy: smart
profile_sync:
  enabled: true
```

Environment variables are configured via `env.sh` — database URL, Nitter instance, IFTTT port, API tokens, etc.

## Database

PostgreSQL with 4 core tables:

| Table | Purpose |
|-------|---------|
| `published_posts` | Deduplication — (source_id, post_id) uniqueness, mastodon_status_id tracking |
| `source_state` | Scheduling — last_check, last_success, posts_today, error_count |
| `activity_log` | Diagnostics — fetch, publish, skip, error events |
| `edit_buffer` | Edit detection — recent post text hashes for similarity comparison |

## Testing

Custom test framework (no minitest/RSpec) using `$passed`/`$failed` counters:

```bash
ruby bin/run_tests.rb              # Unit tests (default)
ruby bin/run_tests.rb --all        # Unit + network + DB
ruby bin/run_tests.rb --tag bluesky # Tests by tag
ruby bin/run_tests.rb --file edit  # Tests matching "edit"
```

- 68 unit tests PASS, 2 032 assertions
- Test catalog: registered by category (unit/network/e2e/db), tags, timeouts

## Project Structure

```
bin/          10 entry point scripts
lib/          98 library files (~20K LOC)
  adapters/     Source adapters (Twitter, Bluesky, RSS, YouTube)
  broadcast/    Broadcast system (multi-account messaging)
  config/       Configuration loading, merging, resolution
  formatters/   Platform-specific + universal formatting
  health/       Health monitor (11 checks, alerting)
  models/       Post, Author, Media, PostTextWrapper
  monitoring/   Command listener + handlers
  processors/   PostProcessor, pipeline steps, edit detection
  publishers/   MastodonPublisher
  services/     SyndicationMediaFetcher
  source_wizard/ Interactive source configuration generator
  state/        StateManager facade + 5 repositories
  support/      Loggable mixin, ThreadingSupport
  syncers/      Profile syncers (Twitter, Bluesky, Facebook, Instagram, YouTube) + MastodonProfileUpdater
  test_runner/  Runner, parser, report generator
  utils/        HttpClient, HashHelpers, HtmlCleaner
  webhook/      IFTTT queue processor + pipeline
config/       YAML configuration (hierarchical)
db/           SQL migrations
test/         85 test files
docs/         9 documentation files
```

## License

[Unlicense](https://unlicense.org) — public domain.

---

**Maintained by Daniel Šnor** | Prague, Czech Republic | [zpravobot.news](https://zpravobot.news)

**Contact:**
- Mastodon: [@zpravobot@zpravobot.news](https://zpravobot.news/@zpravobot)
- BlueSky: [@zpravobot.news](https://bsky.app/profile/zpravobot.news)
- Twitter/X: [@zpravobot](https://twitter.com/zpravobot)
- GitHub: [github.com/danielsnor](https://github.com/danielsnor)

*Last updated: April 4, 2026*