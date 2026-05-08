# Cloudron (produkční nasazení) – ZBNW‑NG

Tento dokument popisuje **aktuální produkční nasazení ZBNW‑NG na Cloudronu**.

⚠️ Je to **implementační dokument**, nikoli normativní požadavek architektury.
ZBNW‑NG lze provozovat i v jiném kompatibilním prostředí.

Tento dokument je záměrně **veřejně bezpečný**:

- neobsahuje IP adresy ani názvy hostitelů,
- neobsahuje tokeny, cookies ani tajné hodnoty,
- neobsahuje privátní topologii.

---

## 1. Co Cloudron poskytuje

V nasazení ZBNW‑NG Cloudron typicky poskytuje:

- managed PostgreSQL (připojení přes `CLOUDRON_POSTGRESQL_URL`)
- perzistentní úložiště pro `/app/data/`
- správu cron jobů přes UI
- aplikační runtime pro Ruby + Bundler

---

## 2. Adresářová struktura

Produkční instalace používá Cloudron persistentní úložiště `/app/data/`.
Standardní struktura aplikace:

```
/app/data/zbnw-ng/
├── bin/                          # Spustitelné skripty (run_zbnw.rb, sync_profiles.rb, …)
├── config/
│   ├── global.yml                # Globální defaults
│   ├── platforms/                # Platform defaults (bluesky.yml, twitter.yml, …)
│   └── sources/                  # Per-source konfigurace jednotlivých botů
├── db/                           # SQL migrace
├── lib/                          # Ruby implementace
│   ├── adapters/                 # Zdrojové adaptery
│   ├── formatters/               # Text formattery
│   ├── models/                   # Post, Author, Media
│   ├── processors/               # Content / platform procesory
│   ├── publishers/               # MastodonPublisher, BlueskyPublisher
│   ├── state/                    # StateManager (DB)
│   ├── syncers/                  # Profile syncery
│   └── webhook/                  # IftttQueueProcessor
├── logs/
│   ├── health/                   # JSON health reporty (7 dní retence)
│   ├── runner_YYYYMMDD.log       # Orchestrator (denní rotace)
│   ├── ifttt_processor.log       # Queue processor
│   ├── ifttt_webhook.log         # Webhook server
│   ├── profile_sync_*.log        # Profile sync per platforma
│   └── health_monitor.log        # Údržbot
├── queue/ifttt/
│   ├── pending/                  # Čekající webhook payloady (JSON)
│   ├── processing/               # Právě zpracovávané
│   └── failed/                   # Neúspěšné (pro debug; DEAD_ prefix = archiv)
├── cache/
│   ├── profiles/                 # Avatar/banner cache (7 dní TTL)
│   └── threads/                  # Thread context cache
├── cron_*.sh                     # Cron wrappery
├── env.sh                        # ⚠️ ENV proměnné — mimo Git
└── Gemfile / Gemfile.lock
```

Test prostředí používá `/app/data/zbnw-ng-test/` se stejnou strukturou a oddělené DB schéma.

> `mastodon_accounts.yml` a `env.sh` musí být v `.gitignore` — obsahují tokeny a cookies.

---

## 3. Konfigurace a ENV proměnné

Konfigurace je rozdělena na globální defaults, platform defaults a per‑source overrides (viz [`../10-system/zbnw-ng-system.md`](../10-system/zbnw-ng-system.md)).

Citlivé části konfigurace (tokeny, cookies, secrets) **nesmí být commitnuty**.

### ENV proměnné (přehled)

| Proměnná | Zdroj | Popis |
|---|---|---|
| `CLOUDRON_POSTGRESQL_URL` | Cloudron (auto) | PostgreSQL connection string |
| `ZPRAVOBOT_SCHEMA` | `env.sh` | DB schéma (`zpravobot` / `zpravobot_test`) |
| `ZBNW_DIR` | `env.sh` | Kořenový adresář aplikace |
| `IFTTT_PORT` | `env.sh` | Port webhook serveru (default 8089) |
| `IFTTT_QUEUE_DIR` | `env.sh` | Cesta k IFTTT queue adresáři |
| `NITTER_INSTANCE` | `env.sh` | URL Nitter instance |
| `BROWSERLESS_TOKEN` | `env.sh` | Token pro Browserless.io (FB + IG profile sync) |
| `FB_COOKIE_*` | `env.sh` | Facebook cookies pro profile sync (4 hodnoty) |
| `IG_COOKIE_*` | `env.sh` | Instagram cookies pro profile sync (4 hodnoty) |
| `ZPRAVOBOT_MONITOR_TOKEN` | `env.sh` | Mastodon token pro Údržbot alerting |
| `ZPRAVOBOT_STATS_ACCOUNT` | `env.sh` | Publisher account pro týdenní digest |
| `DEBUG` | volitelné | Zapne verbose logging |

`env.sh` musí být vytvořen manuálně a nesmí být commitnut do Gitu.

---

## 4. Cron jobs

Cron joby se konfigurují přes **Cloudron Dashboard → Cron**, ne přes `crontab -e`.

### Skupiny cron jobů

| Skupina | Interval | Shell wrapper |
|---|---|---|
| Webhook watchdog | `* * * * *` | `cron_webhook.sh` |
| IFTTT queue processor | `*/2 * * * *` | `cron_ifttt.sh` |
| IFTTT failed queue retry | `0 * * * *` | `cron_retry_failed.sh` |
| Content sync (Bluesky, RSS, YT) | `*/10 * * * *` | `cron_zbnw.sh --exclude-platform twitter` |
| Trending / reporting | různé | `cron_trending.sh`, `cron_stats.sh`, … |
| Health monitoring | `*/5 * * * *` | `cron_health.sh`, `cron_command_listener.sh` |
| Maintenance | `0 4 * * *` | inline `find … -delete` |

### Profile sync — weekly rotation

Každá platforma má přiřazený den v týdnu (šetří rate limity):

| Den | Platforma | Poznámka |
|---|---|---|
| Pondělí | Bluesky | Nativní AT Protocol API |
| Úterý | Facebook | Browserless.io scraping |
| Úterý +1h | Instagram | Sdílí Browserless.io token, vlastní IG cookies |
| Středa | Twitter skupina 0 | Nitter, 3 skupiny rotují dle `source_id % 3` |
| Čtvrtek | Twitter skupina 1 | |
| Pátek | Twitter skupina 2 | |
| Sobota | RSS | Deleguje na platform-specific syncery |
| Neděle | YouTube | Opt-in (jen zdroje s vyplněným `source.handle`) |

Intervaly a celkový přehled schedulingu viz [`../40-tools/runtime.md`](../40-tools/runtime.md).

**Webhook server** je výjimkou — nejde o cron job, ale o **long-running proces**. `cron_webhook.sh` funguje jako watchdog: při každém spuštění ověří dostupnost přes `/health` endpoint a v případě potřeby server restartuje přes `nohup`.

---

## 5. Logging

| Soubor | Rotace | Obsah |
|---|---|---|
| `runner_YYYYMMDD.log` | Denní (datum v názvu) | Orchestrator — hlavní pipeline |
| `ifttt_processor.log` | Kontinuální | IFTTT queue processing |
| `ifttt_webhook.log` | Kontinuální | Webhook server |
| `profile_sync_PLATFORM.log` | Per-platforma | Profile sync |
| `health_monitor.log` | Kontinuální | Údržbot monitoring |
| `health/health_*.json` | 7 dní auto-delete | JSON health reporty |

Formát záznamu: `[YYYY-MM-DD HH:MM:SS] [LEVEL] zpráva`

Údržba logů probíhá automaticky cron jobem (`0 4 * * *`): soubory `*.log` starší 7 dní a `processed/*.json` starší 3 dny jsou mazány.

---

## 6. Databáze

V Cloudron prostředí se používá managed PostgreSQL (connection string `CLOUDRON_POSTGRESQL_URL`).

Produkce a test jsou odděleny DB schématy (`zpravobot` / `zpravobot_test`).

### Tabulky

| Tabulka | Účel | Klíčové sloupce |
|---|---|---|
| `published_posts` | Deduplikace — tracking publikovaných postů | `source_id`, `post_id` (UNIQUE), `mastodon_status_id`, `platform_uri` |
| `source_state` | Scheduling, error tracking | `source_id` (PK), `last_check`, `posts_today`, `error_count`, `last_error` |
| `activity_log` | Diagnostický append-only log | `source_id`, `action` (fetch/publish/skip/error/…), `details` (JSONB) |

Migrace jsou v `db/` — pro Cloudron produkci se používá `migrate_cloudron.sql` (idempotentní).

Detailní schéma patří do SQL migrací, nikoli do tohoto souboru.

---

## 7. Co sem nepatří (a proč)

Následující informace zůstávají mimo veřejnou dokumentaci:

- IP adresy, konkrétní domény interních služeb
- tokeny, cookies, secrets
- detailní síťová topologie
- detailní incident logy

Důvod: nejde o informace nutné pro pochopení systému, a jsou citlivé.
