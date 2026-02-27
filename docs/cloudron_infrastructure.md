# Cloudron Infrastructure - ZBNW-NG

> **Poslední aktualizace:** 2026-02-13
> **Stav:** Produkční  
> **Platforma:** Cloudron na zpravobot.news

---

## Obsah

1. [Přehled infrastruktury](#přehled-infrastruktury)
2. [Serverová architektura](#serverová-architektura)
3. [Adresářová struktura](#adresářová-struktura)
4. [Environment Variables](#environment-variables)
5. [Databáze PostgreSQL](#databáze-postgresql)
6. [Cron Jobs](#cron-jobs)
7. [Shell skripty](#shell-skripty)
8. [Konfigurace](#konfigurace)
9. [Logging](#logging)
10. [Migrace databáze](#migrace-databáze)
11. [Údržba a diagnostika](#údržba-a-diagnostika)
12. [Troubleshooting](#troubleshooting)

---

## Přehled infrastruktury

ZBNW-NG běží v Cloudron prostředí, které poskytuje:

- **Managed PostgreSQL** - databáze přístupná přes `CLOUDRON_POSTGRESQL_URL`
- **Persistent storage** - `/app/data/` pro aplikační data
- **Cron management** - přes Cloudron Dashboard
- **Ruby runtime** - Ruby >= 3.0.0 s Bundler

---

## Serverová architektura

> **Poznámka:** Reálné IP adresy jsou v `cloudron_infrastructure.private.md`.

### Servery

| Server | IP adresa | IPv6 | Doména | Role |
|--------|-----------|------|--------|------|
| **Cloudron (ZBNW-NG)** | `<zbnw-server-ip>` | - | zpravobot.news | Hlavní aplikace, Mastodon |
| **Nitter VPS** | `<nitter-server-ip>` | `<nitter-server-ipv6>` | xn.zpravobot.news | Twitter scraping |

### Síťová komunikace

```
┌─────────────────────────────┐          HTTP/8080          ┌─────────────────────────────┐
│     Cloudron Server         │ ◄─────────────────────────► │     Nitter VPS              │
│   (<zbnw-server-ip>)        │                             │   (<nitter-server-ip>)      │
│   zpravobot.news            │                             │   xn.zpravobot.news         │
│                             │                             │                             │
│   ┌─────────────────────┐   │                             │   ┌─────────────────────┐   │
│   │ ZBNW-NG             │   │                             │   │ Nitter              │   │
│   │ - Orchestrator      │   │                             │   │ - Docker container  │   │
│   │ - Webhook :8089     │   │                             │   │ - Port 8082 intern  │   │
│   │ - PostgreSQL        │   │                             │   │ - Nginx :8080 ext   │   │
│   └─────────────────────┘   │                             │   │ - Redis             │   │
│                             │                             │   └─────────────────────┘   │
│   ┌─────────────────────┐   │                             │                             │
│   │ Mastodon            │   │                             │   IP whitelist:             │
│   │ - zpravobot.news    │   │                             │   allow <zbnw-server-ip>;   │
│   └─────────────────────┘   │                             │   deny all;                 │
└─────────────────────────────┘                             └─────────────────────────────┘
```

### Porty a služby

| Služba | Port | Přístup | Popis |
|--------|------|---------|-------|
| **IFTTT Webhook** | 8089 | localhost | HTTP server pro IFTTT webhooky |
| **Nitter (nginx)** | 8080 | z <zbnw-server-ip> | Twitter scraping endpoint |
| **Nitter (interní)** | 8082 | localhost na VPS | Nitter container |
| **PostgreSQL** | - | Cloudron managed | `$CLOUDRON_POSTGRESQL_URL` |
| **Mastodon** | 443 | public | https://zpravobot.news |

---

## Adresářová struktura

### Produkce: `/app/data/zbnw-ng/`

```
/app/data/zbnw-ng/
├── bin/                          # Spustitelné skripty
│   ├── create_source.rb          # Interaktivní generátor zdrojů
│   ├── force_update_source.rb    # Reset source state v DB
│   ├── health_monitor.rb         # Údržbot monitoring
│   ├── ifttt_webhook.rb          # IFTTT webhook HTTP server
│   ├── run_zbnw.rb               # Hlavní orchestrator runner
│   └── sync_profiles.rb          # Profile synchronizace
│
├── config/                       # Konfigurace
│   ├── global.yml                # Globální defaults
│   ├── health_monitor.yml        # Údržbot konfigurace
│   ├── mastodon_accounts.yml     # ⚠️ Tokeny - CITLIVÉ!
│   ├── platforms/                # Platform defaults
│   │   ├── bluesky.yml
│   │   ├── rss.yml
│   │   ├── twitter.yml
│   │   └── youtube.yml
│   └── sources/                  # Konfigurace jednotlivých botů
│       ├── ct24_twitter.yml
│       ├── demagogcz_bluesky.yml
│       └── ...
│
├── db/                           # Databázové migrace
│   ├── 01_setup_database.sql     # Standalone setup (nepoužívá se v Cloudron)
│   ├── 02_migrate_schema.sql     # Standalone migrace (nepoužívá se v Cloudron)
│   ├── migrate_cloudron.sql      # ⭐ CLOUDRON produkční migrace
│   ├── migrate_test_schema.sql   # Test schema migrace
│   └── patch_add_platform_uri.sql # Patch pro platform_uri sloupec
│
├── lib/                          # Ruby kód
│   ├── adapters/                 # Zdrojové adaptery (Bluesky, Twitter, RSS, YouTube)
│   ├── config/                   # ConfigLoader
│   ├── formatters/               # Text formattery
│   ├── models/                   # Post, Author, Media
│   ├── processors/               # Content/URL/Facebook processing
│   ├── publishers/               # MastodonPublisher
│   ├── state/                    # StateManager (DB operace)
│   ├── support/                  # ThreadingSupport a helpers
│   ├── syncers/                  # Profile syncery
│   ├── utils/                    # HtmlCleaner a utilities
│   └── webhook/                  # IftttQueueProcessor
│
├── logs/                         # Logy (denní rotace)
│   ├── health/                   # Health check reporty
│   │   ├── alert_state.json      # Stav alertů pro deduplikaci
│   │   └── health_*.json         # JSON reporty (7 dní retention)
│   ├── runner_YYYYMMDD.log       # Orchestrator logy (denní)
│   ├── ifttt_processor.log       # Queue processor logy
│   ├── ifttt_webhook.log         # Webhook server logy
│   ├── profile_sync_*.log        # Profile sync logy
│   └── health_monitor.log        # Údržbot logy
│
├── queue/                        # IFTTT webhook queue
│   └── ifttt/
│       ├── pending/              # Čekající webhooky (JSON soubory)
│       ├── processing/           # Právě zpracovávané
│       └── failed/               # Neúspěšné (pro debug)
│
├── cache/                        # Cache adresáře
│   ├── profiles/                 # Avatar/banner cache (7 dní TTL)
│   └── threads/                  # Thread context cache
│
├── cron_health.sh                # Wrapper pro health_monitor.rb
├── cron_ifttt.sh                 # Wrapper pro IFTTT queue processor
├── cron_profile_sync.sh          # Wrapper pro profile sync
├── cron_webhook.sh               # Webhook server watchdog
├── cron_zbnw.sh                  # Wrapper pro orchestrator
├── env.sh                        # ⭐ Environment proměnné
├── Gemfile                       # Ruby dependencies
└── Gemfile.lock
```

### Test: `/app/data/zbnw-ng-test/`

Identická struktura, používá `zpravobot_test` schema v databázi.

---

## Environment Variables

### env.sh - NUTNÉ VYTVOŘIT

Tento soubor **NENÍ součástí exportu** a musí být vytvořen manuálně:

```bash
#!/bin/bash
# ============================================================
# ZBNW-NG Environment Variables
# ============================================================
# Location: /app/data/zbnw-ng/env.sh
# Usage: source /app/data/zbnw-ng/env.sh
# ============================================================

# Timezone - server běží v UTC, chceme lokální čas v logách
export TZ="Europe/Prague"

# Základní cesty
export ZBNW_DIR="/app/data/zbnw-ng"
export ZBNW_LOG_DIR="${ZBNW_DIR}/logs"
export ZBNW_CONFIG_DIR="${ZBNW_DIR}/config"

# Database schema
export ZPRAVOBOT_SCHEMA="zpravobot"

# IFTTT webhook
export IFTTT_QUEUE_DIR="${ZBNW_DIR}/queue/ifttt"
export IFTTT_PORT="8089"

# Nitter instance
export NITTER_INSTANCE="http://xn.zpravobot.news:8080"

# Cloudron poskytuje automaticky:
# CLOUDRON_POSTGRESQL_URL - connection string pro PostgreSQL

# ============================================================
# Pro TEST environment použít:
# ============================================================
# export ZBNW_DIR="/app/data/zbnw-ng-test"
# export ZBNW_LOG_DIR="${ZBNW_DIR}/logs"
# export ZBNW_CONFIG_DIR="${ZBNW_DIR}/config"
# export ZPRAVOBOT_SCHEMA="zpravobot_test"
# export IFTTT_QUEUE_DIR="${ZBNW_DIR}/queue/ifttt"
```

### Proměnné a jejich význam

| Proměnná | Default v kódu | Popis |
|----------|----------------|-------|
| `TZ` | `Europe/Prague` | Timezone pro logy a cron (auto CET↔CEST) |
| `CLOUDRON_POSTGRESQL_URL` | - | **Cloudron poskytuje** - PostgreSQL connection string |
| `ZPRAVOBOT_SCHEMA` | `zpravobot` | Database schema name |
| `ZBNW_DIR` | - | Kořenový adresář aplikace (pro shell skripty) |
| `ZBNW_LOG_DIR` | - | Adresář pro logy (pro shell skripty) |
| `ZBNW_CONFIG_DIR` | `/app/data/zbnw-ng/config` | Adresář s konfigurací |
| `IFTTT_QUEUE_DIR` | `/app/data/zbnw-ng/queue/ifttt` | IFTTT queue adresář |
| `IFTTT_QUEUE_DIR_TEST` | `/app/data/zbnw-ng-test/queue/ifttt` | Testovací IFTTT queue |
| `IFTTT_PORT` | `8089` | Port webhook serveru |
| `NITTER_INSTANCE` | `http://xn.zpravobot.news:8080` | Nitter URL |
| `ZPRAVOBOT_MONITOR_TOKEN` | - | Mastodon token pro Údržbot alerting |
| `DEBUG` | - | Zapne verbose logging (jakákoli hodnota) |

### Priorita DB připojení (StateManager)

```ruby
# 1. Explicitní URL parametr
StateManager.new(url: 'postgres://...')

# 2. CLOUDRON_POSTGRESQL_URL (Cloudron environment)
ENV['CLOUDRON_POSTGRESQL_URL']

# 3. DATABASE_URL (standard)
ENV['DATABASE_URL']

# 4. Jednotlivé proměnné
ENV['ZPRAVOBOT_DB_HOST']     # default: localhost
ENV['ZPRAVOBOT_DB_PORT']     # default: 5432
ENV['ZPRAVOBOT_DB_NAME']     # default: zpravobot
ENV['ZPRAVOBOT_DB_USER']     # default: zpravobot_app
ENV['ZPRAVOBOT_DB_PASSWORD']
```

---

## Databáze PostgreSQL

### Schémata

| Schema | Účel | Používá |
|--------|------|---------|
| `zpravobot` | **Produkce** | Produkční cron jobs |
| `zpravobot_test` | **Vývoj/Test** | `--test` flag, test environment |

### Tabulky

#### published_posts

Hlavní tabulka pro deduplikaci - tracking publikovaných postů.

```sql
CREATE TABLE published_posts (
    id                  BIGSERIAL PRIMARY KEY,
    source_id           VARCHAR(100) NOT NULL,      -- např. "ct24_twitter"
    post_id             VARCHAR(255) NOT NULL,      -- ID z platformy
    post_url            TEXT,                       -- URL původního postu
    mastodon_status_id  TEXT,                       -- Mastodon status ID
    platform_uri        TEXT,                       -- AT URI pro threading (Bluesky)
    published_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    CONSTRAINT uq_source_post UNIQUE (source_id, post_id)
);
```

**Indexy:**
```sql
-- Rychlé hledání podle source a času
CREATE INDEX idx_published_source_time ON published_posts (source_id, published_at DESC);

-- BRIN index pro časový rozsah (efektivní pro append-only)
CREATE INDEX brin_published_at ON published_posts USING brin (published_at);

-- Unikátní Mastodon status
CREATE UNIQUE INDEX uq_published_mastodon_status ON published_posts (mastodon_status_id) 
    WHERE mastodon_status_id IS NOT NULL;

-- Thread lookup podle platform_uri (Bluesky AT URI)
CREATE INDEX idx_published_platform_uri ON published_posts (platform_uri) 
    WHERE platform_uri IS NOT NULL;

-- Source + platform_uri composite
CREATE INDEX idx_published_source_platform_uri ON published_posts (source_id, platform_uri) 
    WHERE platform_uri IS NOT NULL;
```

#### source_state

Stav zdrojů - scheduling a error tracking.

```sql
CREATE TABLE source_state (
    source_id       VARCHAR(100) PRIMARY KEY,   -- např. "ct24_twitter"
    last_check      TIMESTAMPTZ,                -- Kdy naposledy kontrolováno
    last_success    TIMESTAMPTZ,                -- Kdy naposledy úspěšně
    posts_today     INTEGER NOT NULL DEFAULT 0, -- Počet postů dnes (auto-reset)
    last_reset      DATE NOT NULL DEFAULT CURRENT_DATE, -- Datum resetu posts_today
    error_count     INTEGER NOT NULL DEFAULT 0, -- Počet po sobě jdoucích chyb
    last_error      TEXT,                       -- Poslední chybová zpráva
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

**Trigger:** `updated_at` se automaticky aktualizuje při UPDATE.

**Index:**
```sql
-- Rychlé hledání zdrojů s chybami
CREATE INDEX idx_sources_with_errors ON source_state (error_count) WHERE error_count > 0;
```

#### activity_log

Diagnostický log - append-only.

```sql
CREATE TABLE activity_log (
    id          BIGSERIAL PRIMARY KEY,
    source_id   VARCHAR(100),
    action      VARCHAR(50) NOT NULL,           -- fetch, publish, skip, error, profile_sync, media_upload, transient_error
    details     JSONB,                          -- JSON s detaily
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    CONSTRAINT chk_action_valid CHECK (action IN (
        'fetch', 'publish', 'skip', 'error', 'profile_sync', 'media_upload', 'transient_error'
    ))
);
```

**Indexy:**
```sql
CREATE INDEX idx_activity_source_time ON activity_log (source_id, created_at DESC);
CREATE INDEX idx_activity_created ON activity_log (created_at DESC);
```

### Připojení v Ruby

```ruby
require_relative 'lib/state/state_manager'

# Auto-detect Cloudron
state_manager = State::StateManager.new
state_manager.connect

# Explicitní test schema
state_manager = State::StateManager.new(schema: 'zpravobot_test')
state_manager.connect

# Explicitní URL
state_manager = State::StateManager.new(url: ENV['CLOUDRON_POSTGRESQL_URL'])
```

---

## Cron Jobs

### Aktuální konfigurace (2026-02-27)

Cron jobs se konfigurují přes **Cloudron Dashboard → Cron**, ne přes `crontab -e`.

```cron
# ==================================
# IFTTT Webhook Server (watchdog) - prod & test
# ==================================
# Kontroluje každou minutu, zda webhook server běží
* * * * * /app/data/zbnw-ng/cron_webhook.sh

# ==================================
# IFTTT Queue Processor (Twitter) - prod & test
# ==================================
# Zpracovává příchozí prod webhooky každé 2 minuty
*/2 * * * * /app/data/zbnw-ng/cron_ifttt.sh

# Zpracovává failed webhooky každou hodinu (v :00)
0 * * * * /app/data/zbnw-ng/cron_retry_failed.sh

# ==================================
# Content Sync (Bluesky, RSS, YouTube) - prod & test
# ==================================
# Twitter se zpracovává přes IFTTT pipeline výše
*/10 * * * * /app/data/zbnw-ng/cron_zbnw.sh --verbose --exclude-platform twitter

# Test: Twitter RSS polling (TwitterTweetProcessor)
*/5 * * * * /app/data/zbnw-ng-test/cron_zbnw.sh --verbose --platform twitter

# Test: ostatní platformy
0 * * * * /app/data/zbnw-ng-test/cron_zbnw.sh --verbose --exclude-platform twitter

# ==================================
# Profile Sync - prod
# ==================================
# Bluesky profily - 1x denně v 1:00 (má nativní API)
0 1 * * * /app/data/zbnw-ng/cron_profile_sync.sh --platform bluesky

# Facebook profily - 1x za 3 dny ve 2:00 (Facebook scraping, šetříme)
0 2 */3 * * /app/data/zbnw-ng/cron_profile_sync.sh --platform facebook

# Twitter profily - 3 skupiny rotující po dnech týdne, ve 3:00 (Nitter scraping, šetříme)
# Po,Čt = skupina 0 | Út,Pá = skupina 1 | St,So = skupina 2 | Ne = volno
0 3 * * 1,4  /app/data/zbnw-ng/cron_profile_sync.sh --platform twitter --group 0
0 3 * * 2,5  /app/data/zbnw-ng/cron_profile_sync.sh --platform twitter --group 1
0 3 * * 3,6  /app/data/zbnw-ng/cron_profile_sync.sh --platform twitter --group 2

# RSS profily - 1x týdně v neděli ve 3:00 (deleguje na BS/FB/TW syncery)
0 3 * * 0    /app/data/zbnw-ng/cron_profile_sync.sh --platform rss

# ==================================
# Údržbot + Tlambot - prod
# ==================================
# Naslouchač každých 5 minut: udrzbot (Mastodon mentions) + tlambot (broadcast queue)
*/5 * * * * /app/data/zbnw-ng/cron_command_listener.sh

# Health check každých 10 minut - alert jen při problému
*/10 * * * * /app/data/zbnw-ng/cron_health.sh --alert --save

# Heartbeat jednou denně v 8:00 - pošle se jen když je vše OK
0 8 * * * /app/data/zbnw-ng/cron_health.sh --heartbeat

# ==================================
# Maintenance - prod & test
# ==================================
# Log rotation - denně v 04:00 (mazat *.log starší než 7 dní)
0 4 * * * find /app/data/zbnw-ng/logs -name "*.log" -mtime +7 -delete 2>/dev/null
0 4 * * * find /app/data/zbnw-ng-test/logs -name "*.log" -mtime +7 -delete 2>/dev/null

# Processed Queue clean-up - denně v 04:00 (mazat *.json starší než 7 dní)
0 4 * * * find /app/data/zbnw-ng/queue/ifttt/processed -name "*.json" -mtime +7 -delete 2>/dev/null
0 4 * * * find /app/data/zbnw-ng-test/queue/ifttt/processed -name "*.json" -mtime +7 -delete 2>/dev/null
```

### Přehled intervalů

| Job | Interval | Prostředí | Účel |
|-----|----------|-----------|------|
| Webhook watchdog | `* * * * *` | prod | Auto-restart serveru (1 server pro prod+test) |
| IFTTT Queue (prod) | `*/2 * * * *` | prod | Zpracování Twitter webhooků |
| IFTTT Failed Retry | `0 * * * *` | prod | Opakování failed webhooků (mimo DEAD_) |
| Content sync (prod) | `*/10 * * * *` | prod | Bluesky, RSS, YouTube |
| Content sync Twitter (test) | `*/5 * * * *` | test | Twitter via TwitterTweetProcessor |
| Content sync ostatní (test) | `0 * * * *` | test | Bluesky, RSS, YouTube |
| Profile sync (Bluesky) | `0 1 * * *` | prod | Denně v 1:00 |
| Profile sync (Facebook) | `0 2 */3 * *` | prod | Každé 3 dny ve 2:00 |
| Profile sync (Twitter gr. 0) | `0 3 * * 1,4` | prod | Po a Čt ve 3:00 |
| Profile sync (Twitter gr. 1) | `0 3 * * 2,5` | prod | Út a Pá ve 3:00 |
| Profile sync (Twitter gr. 2) | `0 3 * * 3,6` | prod | St a So ve 3:00 |
| Profile sync (RSS) | `0 3 * * 0` | prod | Neděle ve 3:00 |
| Command listener + broadcast | `*/5 * * * *` | prod | Polling mentions + broadcast queue |
| Údržbot health | `*/10 * * * *` | prod | Smart alerting |
| Údržbot heartbeat | `0 8 * * *` | prod | Denní "vše OK" |
| Log + queue rotation | `0 4 * * *` | oba | Čištění starých logů a processed queue |

### Poznámky

- **Webhook server** běží v `/app/data/zbnw-ng/` ale obsluhuje **obě prostředí** (prod na `/api/ifttt/twitter`, test na `/api/ifttt/twitter?env=test`)
- **IFTTT Queue** pouze prod; test environment zpracovává Twitter přes RSS polling (`cron_zbnw.sh --platform twitter`)
- **IFTTT Failed Retry** (`cron_retry_failed.sh`) běží jen když existují kandidáti (skrip exituje hned bez souborů); DEAD_ soubory se přeskakují
- **Profile sync Twitter** používá skupiny zdrojů rotující po dnech týdne — šetří Nitter kapacitu; RSS platforma deleguje na BS/FB/TW syncery podle source type
- **Broadcast queue** (`process_broadcast_queue.rb`) je spouštěn jako součást `cron_command_listener.sh`, ne jako samostatný cron

---

## Shell skripty

### cron_zbnw.sh

Hlavní runner pro orchestrator:

```bash
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

# Argumenty: --platform X | --exclude-platform X
# --test se přidá automaticky pokud ZBNW_SCHEMA=zpravobot_test

cd "$ZBNW_DIR" || exit 1

if [ "$ZBNW_SCHEMA" = "zpravobot_test" ]; then
    SCHEMA_ARG="--test"
else
    SCHEMA_ARG=""
fi

bundle exec ruby bin/run_zbnw.rb $PLATFORM_ARG $SCHEMA_ARG >> "$LOG_FILE" 2>&1
```

### cron_ifttt.sh

IFTTT queue processor - spouští se jen když jsou pending webhooky:

```bash
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

PENDING_DIR="${IFTTT_QUEUE_DIR}/pending"
PENDING_COUNT=$(find "$PENDING_DIR" -name "*.json" 2>/dev/null | wc -l)

if [ "$PENDING_COUNT" -eq 0 ]; then
    exit 0  # Nic ke zpracování
fi

cd "$ZBNW_DIR" || exit 1
ruby lib/webhook/ifttt_queue_processor.rb >> "${ZBNW_LOG_DIR}/ifttt_processor.log" 2>&1
```

### cron_webhook.sh

Webhook server watchdog - automaticky restartuje pokud neběží:

```bash
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

is_running() {
    curl -s --max-time 2 "http://localhost:${IFTTT_PORT}/health" | grep -q "healthy"
}

if ! is_running; then
    cd "$ZBNW_DIR" || exit 1
    nohup ruby bin/ifttt_webhook.rb >> "${ZBNW_LOG_DIR}/webhook_server.log" 2>&1 &
fi
```

### cron_profile_sync.sh

Profile synchronizace s platform filtrací:

```bash
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

# Argumenty: --platform twitter | --platform bluesky
cd "$ZBNW_DIR" || exit 1
bundle exec ruby bin/sync_profiles.rb $PLATFORM_ARG >> "$LOG_FILE" 2>&1
```

### cron_health.sh

Údržbot monitoring wrapper:

```bash
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

cd "$ZBNW_DIR" || exit 1
ruby bin/health_monitor.rb "$@" >> "${ZBNW_LOG_DIR}/health_monitor.log" 2>&1
```

---

## Konfigurace

### global.yml

Globální defaults pro všechny boty:

```yaml
mastodon:
  instance: https://zpravobot.news

scheduling:
  priority: normal          # high=5min | normal=20min | low=55min
  max_posts_per_run: 10

processing:
  post_length: 500
  trim_strategy: smart      # smart | sentence | word
  smart_tolerance_percent: 12

url:
  no_trim_domains:
    - facebook.com
    - instagram.com
    - bit.ly
    - t.co
    - youtu.be

formatting:
  show_platform_emoji: true
  show_real_name: true
  prefix_post_url: "\n"

target:
  visibility: public        # public | unlisted | private | direct
```

### health_monitor.yml

Konfigurace Údržbota:

```yaml
webhook_url: 'http://localhost:8089/health'
nitter_url: 'http://xn.zpravobot.news:8080'
mastodon_instance: 'https://zpravobot.news'
alert_visibility: 'private'  # followers-only

thresholds:
  webhook_timeout: 5              # sekundy
  nitter_timeout: 10              # sekundy
  ifttt_no_webhook_minutes: 120   # 2 hodiny
  queue_stale_minutes: 30
  queue_max_pending: 100
  no_publish_minutes: 60          # 1 hodina
  error_threshold: 5

# Paths - POZOR: v exportu jsou test cesty!
queue_dir: '/app/data/zbnw-ng/queue/ifttt'
log_dir: '/app/data/zbnw-ng/logs'
health_log_dir: '/app/data/zbnw-ng/logs/health'
```

### mastodon_accounts.yml

**⚠️ CITLIVÉ ÚDAJE - přidat do .gitignore!**

```yaml
account_id:
  token: "mastodon_access_token"
  aggregator: false           # true = sdílený účet
  categories: [news]          # volitelné
  description: "Popis účtu"   # volitelné
```

---

## Logging

### Log soubory a rotace

| Soubor | Rotace | Obsah |
|--------|--------|-------|
| `runner_YYYYMMDD.log` | Denní (datum v názvu) | Orchestrator |
| `ifttt_processor.log` | Kontinuální | Queue processing |
| `ifttt_webhook.log` | Kontinuální | Webhook server |
| `profile_sync_*.log` | Per-platform | Profile sync |
| `health_monitor.log` | Kontinuální | Údržbot |
| `health/*.json` | 7 dní auto-delete | Health reporty |

### Formát logu

```
[2026-01-30 10:30:00] [INFO] Processing source: ct24_twitter
[2026-01-30 10:30:01] [SUCCESS] Published post 123456789 -> status 987654321
[2026-01-30 10:30:02] [SKIP] Already published: 123456788
[2026-01-30 10:30:03] [ERROR] Fetch failed: Connection timeout
```

---

## Migrace databáze

### Cloudron - první nasazení

```bash
# 1. SSH na Cloudron server
ssh cloudron@zpravobot.news

# 2. Přepnout do ZBNW adresáře
cd /app/data/zbnw-ng

# 3. Spustit Cloudron migraci (idempotentní - lze spouštět opakovaně)
psql "$CLOUDRON_POSTGRESQL_URL" -f db/migrate_cloudron.sql

# 4. (Volitelně) Vytvořit test schema
psql "$CLOUDRON_POSTGRESQL_URL" -f db/migrate_test_schema.sql
```

### Patch - přidání platform_uri

Pro existující databáze bez sloupce `platform_uri`:

```bash
psql "$CLOUDRON_POSTGRESQL_URL" -f db/patch_add_platform_uri.sql
```

### Ověření migrace

```bash
psql "$CLOUDRON_POSTGRESQL_URL" -c "
SELECT column_name, data_type 
FROM information_schema.columns 
WHERE table_schema = 'zpravobot' 
AND table_name = 'published_posts'
ORDER BY ordinal_position;"
```

**Očekávaný výstup:**
```
    column_name     |        data_type
--------------------+-------------------------
 id                 | bigint
 source_id          | character varying
 post_id            | character varying
 post_url           | text
 mastodon_status_id | text
 platform_uri       | text
 published_at       | timestamp with time zone
```

---

## Údržba a diagnostika

### Denní kontroly

```bash
# SSH na server
cd /app/data/zbnw-ng

# Health status
ruby bin/health_monitor.rb --details

# Zdroje s chybami
psql "$CLOUDRON_POSTGRESQL_URL" -c "
SET search_path TO zpravobot;
SELECT source_id, error_count, last_error, last_check 
FROM source_state 
WHERE error_count > 0 
ORDER BY error_count DESC;"

# Posledních 10 publikací
psql "$CLOUDRON_POSTGRESQL_URL" -c "
SET search_path TO zpravobot;
SELECT source_id, post_id, published_at 
FROM published_posts 
ORDER BY published_at DESC 
LIMIT 10;"
```

### Manuální operace

```bash
# Force update zdroje (bude zpracován při příštím cron run)
ruby bin/force_update_source.rb ct24_twitter

# Dry run (bez publikace)
ruby bin/run_zbnw.rb --source ct24_twitter --dry-run

# Test schema
ruby bin/run_zbnw.rb --source ct24_twitter --test

# Profile sync preview
ruby bin/sync_profiles.rb --platform bluesky --dry-run
```

### Webhook server

```bash
# Kontrola stavu
curl http://localhost:8089/health

# Manuální restart
pkill -f ifttt_webhook.rb
cd /app/data/zbnw-ng
nohup ruby bin/ifttt_webhook.rb >> logs/ifttt_webhook.log 2>&1 &
```

### Čištění starých dat

```sql
-- Smazat activity_log starší 30 dní
DELETE FROM activity_log WHERE created_at < NOW() - INTERVAL '30 days';

-- Smazat published_posts starší 6 měsíců (OPATRNĚ!)
DELETE FROM published_posts WHERE published_at < NOW() - INTERVAL '6 months';
```

---

## Troubleshooting

### Databáze nepřipojuje

**Příznaky:** `PG::ConnectionBad`

```bash
# Ověřit proměnnou
echo $CLOUDRON_POSTGRESQL_URL

# Test připojení
psql "$CLOUDRON_POSTGRESQL_URL" -c "SELECT 1"
```

### Webhook server neběží

**Příznaky:** IFTTT webhooky se nezpracovávají

```bash
# Health check
curl http://localhost:8089/health

# Logy
tail -f /app/data/zbnw-ng/logs/ifttt_webhook.log

# Restart
/app/data/zbnw-ng/cron_webhook.sh
```

### Queue se hromadí

**Příznaky:** Mnoho souborů v pending/

```bash
# Počet čekajících
find /app/data/zbnw-ng/queue/ifttt/pending -name "*.json" | wc -l

# Manuální zpracování
cd /app/data/zbnw-ng
ruby lib/webhook/ifttt_queue_processor.rb
```

### Schema neexistuje

**Příznaky:** `ERROR: schema "zpravobot" does not exist`

```bash
psql "$CLOUDRON_POSTGRESQL_URL" -f /app/data/zbnw-ng/db/migrate_cloudron.sql
```

### Cron neběží

**Příznaky:** Žádná aktivita v logu

```bash
# Zkontrolovat v Cloudron Dashboard
# Nebo manuálně spustit
/app/data/zbnw-ng/cron_zbnw.sh --exclude-platform twitter
```

---

## Checklist pro změny

### Při změně DB schématu

- [ ] Vytvořit migrační SQL v `db/`
- [ ] Otestovat na `zpravobot_test`
- [ ] Aplikovat na `zpravobot`
- [ ] Aktualizovat StateManager pokud potřeba
- [ ] Aktualizovat tuto dokumentaci

### Při přidání cron jobu

- [ ] Vytvořit shell wrapper (pokud potřeba)
- [ ] Přidat do Cloudron Dashboard
- [ ] Otestovat manuálním spuštěním
- [ ] Aktualizovat tuto dokumentaci

### Při změně environment proměnných

- [ ] Aktualizovat env.sh šablonu
- [ ] Aktualizovat Cloudron Dashboard
- [ ] Aktualizovat tuto dokumentaci

---

## Související dokumenty

- **ZBNW_NG_SYSTEM.md** - Celková systémová dokumentace
- **HELPER_TOOLS.md** - CLI nástroje a Údržbot
- **NITTER_PLATFORM.md** - Nitter server infrastruktura
- **TWITTER_PLATFORM.md** - Twitter/IFTTT hybrid architektura
