# Zprávobot.news Next Generation (ZBNW-NG)

[![License: Unlicense](https://img.shields.io/badge/license-Unlicense-blue.svg)](https://unlicense.org)
[![Mastodon](https://img.shields.io/badge/Mastodon-Instance-6364FF?logo=mastodon&logoColor=white)](https://zpravobot.news)
[![Ruby](https://img.shields.io/badge/Ruby-Pure_stdlib-CC342D?logo=ruby&logoColor=white)](https://www.ruby-lang.org)

![Maskot Zpravobot.news](https://zpravobot.news/system/site_uploads/files/000/000/002/@2x/49c4aa7df6b81d4a.png 'Maskot Zpravobot.news')

**ZBNW-NG** je serverový motor, který pohání **[Zprávobot.news](https://zpravobot.news)** — veřejnou Mastodon instanci provozovanou Danielem Šnorem, která zrcadlí 🪞 populární české 🇨🇿 a slovenské 🇸🇰 účty z X/Twitteru 🐦, Bluesky 🦋, Facebooku 🤦‍♂️📘, Instagramu 📸 a Youtube 📺 doplněné o RSS kanály 📡 a přináší na Mastodon 🐘 jinak chybějící zprávy 📰, sport ⚽️🏒🏎️, technologie 📱⌚️💻📡, zábavu 🎞️🎶🎭 a občas i humor 🤣🤪.

Zatímco původní projekt využíval IFTTT filtrové skripty, ZBNW-NG tohle celé nahrazuje plnohodnotným Ruby pipeline — nativní podpora vláken, publikování více obrázků, detekce editací, deduplikace postů, chytrý monitoring.

---

## Obsah

- [Proč ZBNW-NG?](#proč-zbnw-ng)
- [Podporované platformy](#podporované-platformy)
- [Technická architektura](#technická-architektura)
- [Rychlý start](#rychlý-start)
- [Struktura projektu](#struktura-projektu)
- [Testování](#testování)
- [Monitoring (Údržbot)](#monitoring-údržbot)
- [Dokumentace](#dokumentace)
- [Jak přispět](#jak-přispět)
- [Podpora](#podpora)
- [Poděkování](#poděkování)
- [English Summary](#english-summary)

---

## Proč ZBNW-NG?

| Omezení (původní IFTTT přístup) | Řešení (ZBNW-NG) |
|---|---|
| Ořezaný text (>257 znaků) | Plný text přes Nitter scraping + Syndication API |
| Max 1 obrázek na post | Až 4 mediální přílohy |
| Žádný kontext vlákna | Plná podpora vláken s in-memory cache + DB lookup |
| Žádná detekce editací | Detekce editací na bázi podobnosti, aktualizace Mastodon statusu |
| Limit skriptu 65 KB | Bez omezení — plný Ruby codebase (~20K řádků) |
| Žádný monitoring | Údržbot: health checky, alerty, interaktivní příkazy |
| Žádná synchronizace profilů | Automatický sync avataru/banneru/bio ze zdrojových platforem |

---

## Podporované platformy

| Platforma | Adapter | Zdroj dat | Profil sync |
|---|---|---|---|
| **Twitter/X** | `TwitterAdapter` + `TwitterNitterAdapter` | IFTTT webhooky + Nitter scraping | Nitter scraping |
| **Bluesky** | `BlueskyAdapter` | AT Protocol API | AT Protocol API |
| **Facebook** | `RssAdapter` | [RSS.app](https://rss.app) | Browserless.io |
| **Instagram** | `RssAdapter` | [RSS.app](https://rss.app) | Browserless.io + cookies |
| **YouTube** | `YouTubeAdapter` | YouTube RSS | Browserless.io |
| **RSS / Atom** | `RssAdapter` | RSS 2.0 / Atom | — |

### Hybridní architektura Twitter/X

Twitter integrace používá pětistupňový systém s postupným fallbackem:

| Tier | Zdroj dat | Média | Plný text | Kdy |
|------|-----------|-------|-----------|-----|
| **1** | IFTTT | ❌ | ✅ krátký | Krátký tweet bez médií a vláken |
| **1.5** | IFTTT + Syndication API | ✅ | ⚠️ možná zkrácený | `nitter_processing: false` |
| **2** | IFTTT + Nitter | ✅ | ✅ | Média, dlouhý text, RT, vlákna |
| **3.5** | Syndication fallback | ✅ | ⚠️ možná zkrácený | Nitter selhal |
| **3** | IFTTT fallback | ❌ | ⚠️ zkrácený | Finální degradovaný režim |

IFTTT funguje jako **real-time push trigger** (okamžité notifikace přes oficiální Twitter API), Nitter jako **obohacovač dat** (plný text, média, vlákna). Pro menší projekty (desítky zdrojů) je čistý Nitter RSS polling naprosto dostačující a IFTTT není potřeba.

---

## Technická architektura

```
┌───────────────────────────────────────────────────────────────┐
│                       ZDROJE OBSAHU                           │
│ Bluesky API  RSS Feedy   YouTube RSS   Twitter (IFTTT+Nitter) │
└──────┬───────────┬────────────┬────────────────┬──────────────┘
       ▼           ▼            ▼                ▼
┌───────────────────────────────────────────────────────────────┐
│                         ADAPTERY                              │
│   BlueskyAdapter  RssAdapter  YouTubeAdapter  TwitterAdapter  │
└───────────────────────────┬───────────────────────────────────┘
                            ▼
┌───────────────────────────────────────────────────────────────┐
│                   PROCESOR PŘÍSPĚVKŮ (9 kroků)                │
│  Dedupe → Edit detect → Filter → Format → Trim →              │
│  URL clean / Video dedup / OGP fetch →                        │
│  Media upload → Publish → State update                        │
└───────────────────────────┬───────────────────────────────────┘
                            ▼
┌───────────────────────────────────────────────────────────────┐
│              MASTODON PUBLISHER + STATE (PostgreSQL)          │
└───────────────────────────────────────────────────────────────┘
```

**Stack:** Čisté Ruby (bez Rails/Sinatra), gemy `pg`, `rss`, `http`, `logger`, PostgreSQL.

---

## Rychlý start

### Co budete potřebovat

- Ruby + Bundler, PostgreSQL
- Mastodon instanci s botími účty
- Nitter instanci + burner Twitter účty (~1 na 10 zdrojů) pro scraping
- volitelně IFTTT PRO+ (pro Twitter webhook triggery)

### Instalace

```bash
git clone <repo-url>
cd zbnw-ng
bundle install

cp env.sh.example env.sh
# Upravte env.sh — databáze, Nitter, Mastodon
source env.sh

psql "$CLOUDRON_POSTGRESQL_URL" -f db/01_setup_database.sql
psql "$CLOUDRON_POSTGRESQL_URL" -f db/02_migrate_schema.sql

ruby bin/create_source.rb         # Interaktivní průvodce konfigurací
ruby bin/run_zbnw.rb --dry-run    # Testovací běh
ruby bin/run_zbnw.rb              # Produkční běh
```

### Běžné příkazy

```bash
ruby bin/run_zbnw.rb                        # Všechny zdroje
ruby bin/run_zbnw.rb --platform bluesky     # Konkrétní platforma
ruby bin/run_zbnw.rb --source ct24_twitter  # Konkrétní zdroj
ruby bin/run_zbnw.rb --dry-run              # Bez publikování

ruby bin/sync_profiles.rb --platform bluesky  # Sync profilů
ruby bin/health_monitor.rb --details          # Health check
ruby bin/run_tests.rb                         # Testy
```

---

## Struktura projektu

```
bin/                   # Vstupní body (17 skriptů)
  run_zbnw.rb          # Hlavní runner (cron)
  ifttt_webhook.rb     # IFTTT webhook HTTP server
  health_monitor.rb    # Údržbot health monitoring
  sync_profiles.rb     # Sync profilů (avatar, banner, bio)
  create_source.rb     # Interaktivní průvodce konfigurací zdrojů
  manage_source.rb     # Správa zdrojů — pause/resume/retire
  run_tests.rb         # Test runner s generátorem reportů
  ...                  # broadcast, stats, trending, cleanup

lib/                   # Zdrojový kód (~20K řádků)
  orchestrator.rb      # Koordinace systému
  adapters/            # Zdrojové adaptery
  formatters/          # UniversalFormatter + platformové wrappery
  processors/          # PostProcessor, pipeline kroky, EditDetector, MediaDedup
  publishers/          # MastodonPublisher
  state/               # StateManager facade + 5 repozitářů (PostgreSQL)
  syncers/             # Profile syncery (BS/FB/IG/TW/YT) + MastodonProfileUpdater
  health/              # Health monitor (11 checků, AlertStateManager)
  monitoring/          # Command Listener + handlery
  config/              # ConfigLoader, SourceConfig
  ...                  # broadcast, stats, trending, source_wizard, webhook

config/                # Konfigurace
  global.yml           # Globální nastavení
  platforms/           # Výchozí nastavení platforem
  sources/             # Jednotlivé zdroje (ct24_twitter.yml, ...)
  mastodon_accounts.yml
  health_monitor.yml

test/                  # 103 registrovaných testů (test_catalog.yml)
db/                    # SQL migrace
docs/           # Dokumentace
```

### Konfigurace zdrojů

```
config/global.yml → config/platforms/{platform}.yml → config/sources/{id}.yml
```

Nastavení se mergují od globálního po specifické. Příklad:

```yaml
id: ct24_twitter
enabled: true
platform: twitter

source:
  handle: "CT24zive"

target:
  mastodon_account: ct24

formatting:
  source_name: "ČT24"
  max_length: 500

filtering:
  skip_replies: true

scheduling:
  priority: high

profile_sync:
  enabled: true
  language: cs
  retention_days: 90
```

---

## Testování

```bash
ruby bin/run_tests.rb              # Unit testy (výchozí, 77 testů)
ruby bin/run_tests.rb --all        # Unit + síťové + DB
ruby bin/run_tests.rb --tag bluesky
ruby bin/run_tests.rb --file edit
```

Vlastní testovací framework (bez minitest/RSpec). Registr testů: `config/test_catalog.yml` — kategorie (unit/network/e2e/db), tagy, timeouty. Celkem 103 registrovaných testů.

---

## Monitoring (Údržbot)

**Mastodon účet:** `@udrzbot@zpravobot.news`

Automatizované health checky s chytrým alertováním — nový problém → okamžitý alert, přetrvávající → hodinové připomínky, vyřešený → potvrzení.

```bash
ruby bin/health_monitor.rb --details    # Podrobný report
ruby bin/health_monitor.rb --alert      # Alert při problémech
ruby bin/health_monitor.rb --heartbeat  # Denní heartbeat
```

Monitoruje: webhook server, Nitter, Nitter účty, IFTTT frontu, zpracování, Mastodon API, server resources, log chyby, opakující se warnings, health cron runneru.

Interaktivní příkazy přes Mastodon zmínky: `help`, `status`, `detail`, `sources`, `check [název]`.

---

## Dokumentace

Detailní dokumentace je v [`docs/`](docs/README.md):

| Sekce | Obsah |
|---|---|
| [`00-overview/`](docs/00-overview/) | Architektura, terminologie |
| [`10-system/`](docs/10-system/) | Systémový přehled, pipeline |
| [`20-platforms/`](docs/20-platforms/) | Twitter, Bluesky, Facebook, Instagram, YouTube, RSS |
| [`30-infrastructure/`](docs/30-infrastructure/) | Cloudron, infrastruktura |
| [`40-tools/`](docs/40-tools/) | CLI nástroje, Nitter, monitoring, runtime, testování |
| [`50-operations/`](docs/50-operations/) | Runbook, deployment, troubleshooting, maintenance |
| [`90-meta/`](docs/90-meta/) | Architektonická rozhodnutí, principy |

---

## Jak přispět

Příspěvky jsou vítány. Projekt je vydán pod [Unlicense licencí](https://unlicense.org) — kompletně ve veřejné doméně.

1. Forkněte repozitář
2. Vytvořte feature branch
3. Otestujte: `ruby bin/run_tests.rb`
4. Ověřte: `ruby bin/run_zbnw.rb --dry-run`
5. Pošlete pull request

**Standardy kódu:** `Support::Loggable` mixin pro logging, `rescue Zpravobot::Error` pro chyby, `HttpClient` pro HTTP. Nové testy registrujte v `config/test_catalog.yml`.

---

## Podpora

Pokud vám Zprávobot.news přijde užitečný:

- 🏦 **Bankovní převod:** IBAN CZ8830300000001001612070
- 💳 **Revolut:** [revolut.me/zpravobot](https://revolut.me/zpravobot)
- ☕ **Ko-fi:** [ko-fi.com/zpravobot](https://ko-fi.com/zpravobot)
- 🖥️ **Forendors:** [forendors.cz/zpravobot](https://forendors.cz/zpravobot)

![QR kód pro bankovní převod](https://zpravobot.news/system/media_attachments/files/116/277/172/347/084/632/original/4b7ccad1c5ee6c79.jpeg 'QR kód pro bankovní převod')

---

## Poděkování

Tenhle projekt by neexistoval bez:

- **Mé rodiny** — Má milovaná manželka [Greticzka](https://mastodon.social/@greticzka) a naše dcery mě neochvějně podporovaly
- **[Marvoqs](https://github.com/marvoqs)** — Naprogramoval základní IFTTT skriptové architektury
- **[Lawondyss](https://github.com/Lawondyss)** — Rozsáhlý vývoj IFTTT filtru a přidávání nových funkcí
- **Česká Mastodon komunita** — Za to, že tohle všechno má smysl

---

# English Summary

**ZBNW-NG** (Zprávobot.news Next Generation) is a content aggregation and distribution engine written in pure Ruby. It powers [zpravobot.news](https://zpravobot.news), a public Mastodon instance that mirrors ~500 Czech and Slovak accounts from Twitter/X, Bluesky, Facebook, Instagram, YouTube, and RSS feeds into native-looking Mastodon posts with proper threading, media, and formatting.

Since September 2025, most bots are also bridged to BlueSky via [Brid.gy](https://fed.brid.gy/).

## Tech Stack

- **Pure Ruby** (~20K LOC) — no Rails, no Sinatra
- **Minimal gems:** `pg`, `rss`, `http`, `logger`, `simpleidn`
- **PostgreSQL** — deduplication, scheduling, activity log, edit detection buffer
- **Cron-driven** with disk-based queue for IFTTT webhooks

## Architecture

```
Sources → Adapters → Unified Post Model → Orchestrator → PostProcessor (9 steps) → MastodonPublisher → PostgreSQL
```

**PostProcessor pipeline:** Deduplication → Edit detection → Content filtering → Formatting → Content trimming → URL cleanup / Video dedup (pHash) / OGP fetch → Media upload → Publish → State update

## Source Platforms

| Platform | Adapter | Data Source |
|----------|---------|-------------|
| **Twitter/X** | `TwitterAdapter` + `TwitterNitterAdapter` | IFTTT webhooks + Nitter scraping |
| **Bluesky** | `BlueskyAdapter` | AT Protocol API |
| **Facebook / Instagram** | `RssAdapter` | RSS.app feeds |
| **YouTube** | `YouTubeAdapter` | YouTube RSS |
| **RSS/Atom** | `RssAdapter` | Standard feeds |

Twitter uses a 5-tier fallback: IFTTT only → IFTTT + Syndication API → IFTTT + Nitter → Syndication fallback → IFTTT degraded. IFTTT is a real-time push trigger; Nitter enriches with full text, media, and thread context.

## Key Components

| Component | Path | Purpose |
|-----------|------|---------|
| **Orchestrator** | `lib/orchestrator.rb` | Source loading, scheduling, coordination |
| **PostProcessor** | `lib/processors/post_processor.rb` | Unified 9-step pipeline |
| **EditDetector** | `lib/processors/edit_detector.rb` | 80% similarity threshold for tweet edit detection |
| **MastodonPublisher** | `lib/publishers/mastodon_publisher.rb` | Async media upload (v2), threading, non-blocking rate limit handling |
| **StateManager** | `lib/state/state_manager.rb` | Facade → 5 PostgreSQL repositories |
| **Health Monitor** | `lib/health/` | 11 automated checks with smart deduped alerting |

## Key Design Decisions

- **Symbol keys everywhere** — YAML loaded via `deep_symbolize_keys`
- **Hierarchical config merging** — `global.yml` → `platforms/` → `sources/`, source wins
- **`Support::Loggable` mixin** — unified logging across all classes
- **`HttpClient`** — centralized HTTP with retry, timeouts, User-Agent (no direct `Net::HTTP`)
- **Custom error hierarchy** — `Zpravobot::Error` → Network / Config / Publish / Adapter / StateError

## Cron Schedule

| Interval | Job |
|----------|-----|
| Every minute | Webhook server watchdog |
| Every 2 min | IFTTT queue processing (Twitter) |
| Every 10 min | Content sync (Bluesky, RSS, YouTube) |
| Every 5 min | Command listener polling |
| Every 10 min | Health check + alerting |
| Hourly | IFTTT failed queue retry |
| Weekly (day rotation) | Profile sync (Mon=BS, Tue=FB+IG, Wed–Fri=TW, Sat=RSS, Sun=YT) |
| Daily 08:00 | Heartbeat |

## Testing

Custom test framework, 103 registered tests across unit / network / db / e2e categories. Run with `ruby bin/run_tests.rb`.

## License

[Unlicense](https://unlicense.org) — public domain.

---

**Maintained by Daniel Šnor** | Prague, Czech Republic | [zpravobot.news](https://zpravobot.news)

Mastodon: [@zpravobot@zpravobot.news](https://zpravobot.news/@zpravobot) · BlueSky: [@zpravobot.news](https://bsky.app/profile/zpravobot.news) · GitHub: [github.com/danielsnor](https://github.com/danielsnor)
