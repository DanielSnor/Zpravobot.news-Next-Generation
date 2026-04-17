# ZBNW-NG Helper Tools & Monitoring

Dokumentace helper aplikací a monitoring systému pro ZBNW-NG.

> **Poslední aktualizace:** 2026-04-17
> **Změny (2026-04):** Test katalog rozšířen na 103 registrovaných testů (77 unit + 18 network + 2 db + 6 e2e) po dokončení TEST-1 (profile syncer unit testy). Přidán `log_report.rb` — strukturovaný JSON report z logů prod serveru pro on-demand analýzu.

---

## Obsah

- [run_tests.rb](#run_testsrb) - Centrální test runner s report generátorem
- [create_source.rb](#create_sourcerb) - Interaktivní generátor konfigurací
- [manage_source.rb](#manage_sourcerb) - Správa životního cyklu zdrojů (pause/resume/retire)
- [force_update_source.rb](#force_update_sourcerb) - Nástroj pro reset source state
- [retry_failed_queue.rb](#retry_failed_queuerb) - Opakování selhavších IFTTT webhooků
- [health_monitor.rb (Údržbot)](#health_monitorrb-údržbot) - Komplexní monitoring systém
- [command_listener.rb (Údržbot)](#command_listenerrb-údržbot) - Interaktivní příkazy přes Mastodon mentions
- [broadcast.rb](#broadcastrb) - Hromadné publikování zpráv na Mastodon účty
- [process_broadcast_queue.rb](#process_broadcast_queuerb) - Cron processor pro tlambot broadcast
- [analyze_domain_fixes.rb](#analyze_domain_fixesrb) - Analýza a aktualizace url_domain_fixes u Twitter/Bluesky zdrojů
- [zpravobot_stats.rb](#zpravobot_statsrb) - Týdenní hitparáda #ZpravobotTOP10 (CZ+SK thread)
- [trending_post.rb](#trending_postrb) - Automatické quote posty pro trendující statusy
- [log_report.rb](#log_reportrb) - Strukturovaný JSON report z logů prod serveru

---

## run_tests.rb

### Umístění
`bin/run_tests.rb`

### Účel

Centrální test runner pro ZBNW-NG. Spouští testovací skripty jako subprocesy, parsuje jejich výstup (heuristicky — různé testy mají různé output formáty) a generuje strukturovaný Markdown report.

### Použití

```bash
# Výchozí: offline unit testy
ruby bin/run_tests.rb

# Konkrétní kategorie
ruby bin/run_tests.rb --unit       # Offline unit testy (56 testů)
ruby bin/run_tests.rb --network    # Síťové testy (API, Nitter, RSS, YouTube)
ruby bin/run_tests.rb --db         # Databázové testy (PostgreSQL)
ruby bin/run_tests.rb --e2e        # E2E / publish testy (interaktivní)

# Kombinace
ruby bin/run_tests.rb --all        # unit + network + db (bez interactive)
ruby bin/run_tests.rb --everything # Úplně vše včetně interactive a visual

# Filtrování
ruby bin/run_tests.rb --file edit        # Testy matchující "edit" v názvu
ruby bin/run_tests.rb --tag bluesky      # Testy s tagem "bluesky"
ruby bin/run_tests.rb --visual           # Zahrnout visual/diagnostic testy

# Ostatní
ruby bin/run_tests.rb --list       # Jen vypsat testy, nespouštět
ruby bin/run_tests.rb -h           # Nápověda
```

### Přepínače

| Přepínač | Popis |
|----------|-------|
| `--unit` | Offline unit testy (default) |
| `--network` | Síťové testy (vyžadují internet) |
| `--db` | Databázové testy (vyžadují PostgreSQL) |
| `--e2e` | E2E publish testy (interaktivní) |
| `--all` | unit + network + db (bez interactive) |
| `--everything` | Vše včetně interactive a visual |
| `--file PATTERN` | Testy matchující pattern v názvu |
| `--tag TAG` | Testy s daným tagem |
| `--visual` | Zahrnout visual/diagnostic testy |
| `--list` | Jen vypsat, nespouštět |
| `-h, --help` | Nápověda |

### Exit code

- `0` — všechny testy prošly
- `1` — alespoň jeden test selhal, chyba nebo timeout

### Architektura

Test runner se skládá ze 4 souborů:

```
bin/run_tests.rb                    # CLI entry point (OptionParser)
lib/test_runner/runner.rb           # Orchestrátor (spouštění, timeout, sběr výsledků)
lib/test_runner/output_parser.rb    # Heuristický parser výstupu testů
lib/test_runner/report_generator.rb # Markdown report generátor
config/test_catalog.yml             # Katalog všech testů s metadaty
```

Žádné externí gem závislosti — pouze Ruby stdlib (`open3`, `yaml`, `optparse`, `timeout`, `fileutils`).

### Katalog testů (`config/test_catalog.yml`)

YAML soubor s metadaty pro každý test:

```yaml
tests:
  test_content_processor:
    file: test/test_content_processor.rb     # Cesta k souboru
    category: unit                            # unit / network / e2e / db
    tags: [offline, processor]                # Tagy pro filtrování
    exit_code_reliable: true                  # Test správně vrací exit 1 při selhání
    description: "ContentProcessor trimming"  # Popis
    # interactive: false                      # (volitelné) čte ze stdin
    # args: ["--offline"]                     # (volitelné) CLI argumenty
    # timeout: 45                             # (volitelné) custom timeout v sekundách
```

#### Kategorie testů

| Kategorie | Počet | Popis | Default timeout |
|-----------|-------|-------|-----------------|
| `unit` | 56 | Offline, bez sítě a DB | 30s |
| `network` | 18 | Vyžadují internet (API, Nitter, RSS, YouTube) | 60s |
| `db` | 2 | Vyžadují PostgreSQL | 60s |
| `e2e` | 6 | Publikují na Mastodon, interaktivní | 120s |

#### Dostupné tagy

`offline`, `bluesky`, `twitter`, `rss`, `youtube`, `facebook`, `nitter`, `syndication`, `mastodon`, `interactive`, `visual`, `diagnostic`, `publish`, `processor`, `formatter`, `config`, `ifttt`

### Jak přidat nový test

1. Vytvořit testovací soubor v `test/`
2. Přidat záznam do `config/test_catalog.yml`:
   ```yaml
   test_my_new_feature:
     file: test/test_my_new_feature.rb
     category: unit
     tags: [offline, processor]
     exit_code_reliable: true
     description: "Popis testu"
   ```
3. Ověřit: `ruby bin/run_tests.rb --file my_new_feature`

### Runner (`lib/test_runner/runner.rb`)

Orchestrátor provádí:

1. Načte katalog z YAML
2. Filtruje testy podle CLI přepínačů
3. Pro každý test:
   - Spustí jako subprocess přes `Open3.popen3` s `Timeout.timeout(N)`
   - Ihned zavře stdin (prevence záseku interaktivních testů)
   - Zachytí stdout, stderr, exit code, dobu běhu
4. Předá výstup do `OutputParser`
5. Uloží `TestResult` struct
6. Vypisuje barevný průběh na terminál
7. Na konci zavolá `ReportGenerator`

Stavy výsledku: `:pass`, `:fail`, `:error`, `:timeout`, `:skip`

### Output Parser (`lib/test_runner/output_parser.rb`)

Heuristický parser zvládající 7 různých output patternů nalezených v testech:

**Strategie (v pořadí priority):**

1. **Detekce LoadError** — missing dependency → `:skip`
2. **Detekce crashe** — stderr obsahuje Traceback, NameError, SyntaxError, ...
3. **Extrakce summary řádku** — regex patterny:
   - `N/M tests passed`
   - `N passed, M failed`
   - `Passed: N` + `Failed: M`
4. **Počítání indikátorů per řádek** (fallback) — `✅`/`❌`, `✓`/`✗`, `PASS`/`FAIL`, `💥`
5. **Rozhodnutí o statusu:**
   - fail_count > 0 → `:fail`
   - exit_code_reliable + exit != 0 → `:fail`
   - pass_count > 0 + fail_count == 0 → `:pass`
   - žádné aserce + exit 0 → `:pass` (visual/diagnostic)

### Report (`lib/test_runner/report_generator.rb`)

Generuje Markdown do `tmp/test_report_YYYYMMDD_HHMMSS.md`:

- Hlavička (datum, doba běhu, filtry)
- Summary tabulka (passed/failed/errors/timeouts/skipped)
- Tabulka výsledků per kategorie (test, status, čas, assertions, detail)
- Sekce "Failed Test Details" — pro každý selhavší test: soubor, status, exit code, stderr (prvních 20 řádků), stdout (posledních 50 řádků v collapsible `<details>`)

### Příklad výstupu (terminál)

```
  ZBNW-NG Test Runner
  22 tests selected: 22 unit
  2026-02-08 14:30:00
  ============================================================

  [PASS]  1/22 test_content_processor            0.8s (6/10)
  [PASS]  2/22 test_html_cleaner                 0.3s (8/8)
  [FAIL]  3/22 test_some_broken_test             0.5s (3/5)  2 assertion(s) failed
  ...

  ============================================================
  21 passed, 1 failed in 12.3s
  ============================================================

  Report: tmp/test_report_20260208_143000.md
```

### Aktuální stav testů (2026-04-11)

| Kategorie | Počet | Stav |
|-----------|-------|------|
| unit | 77 | PASS (nezávisí na síti/DB) |
| network | 18 | Závisí na dostupnosti externích služeb (Nitter, Twitter, Bluesky, RSS…) |
| db | 2 | Vyžaduje PostgreSQL (`zpravobot_test` schema) |
| e2e | 6 | Interaktivní, vyžaduje Mastodon credentials |

Celkem 103 registrovaných testů v `config/test_catalog.yml`, 103 test souborů v `test/`.

**Recent additions (2026-04-11, TEST-1):**
- `test_image_cache_manager.rb` — 23 testů (TTL, cache hit/miss, content-type validation, key stability)
- `test_mastodon_profile_updater.rb` — 20 testů (fetch_fields, update urlencoded/multipart, error parsing)
- `test_profile_syncer_subclasses.rb` — 51 testů (Bluesky 9, FB 13, IG 13, YT 15)

---

## create_source.rb

### Umístění
`bin/create_source.rb` (entry point) → `lib/source_wizard/` (8 modulů)

### Architektura

`bin/create_source.rb` je wrapper, logika je v `lib/source_wizard/`:

| Soubor | Účel |
|--------|------|
| `source_generator.rb` | Hlavní orchestrace wizard flow |
| `data_collection.rb` | Sběr dat od uživatele (handle, platforma, ...) |
| `ui_helpers.rb` | Interaktivní UI (`ask`, `ask_choice`, `ask_yes_no`) |
| `helpers.rb` | Utility (`sanitize_handle`, `parse_categories`, `sanitize_id`, ...) |
| `yaml_generator.rb` | Generování YAML konfigurací |
| `persistence.rb` | Ukládání do souborů + DB inicializace |
| `display_name_fetcher.rb` | Fetch display name z platformy |
| `constants.rb` | Sdílené konstanty (platformy, init options) |

### Účel

Interaktivní průvodce pro vytváření konfiguračních souborů (YAML) pro nové zdroje (boty) v systému ZBNW-NG. **Automaticky inicializuje source_state v databázi** - není potřeba `--first-run`.

### Použití

```bash
# Plný průvodce (všechna nastavení)
ruby bin/create_source.rb

# Rychlý režim (pouze povinné údaje)
ruby bin/create_source.rb --quick

# Testovací prostředí
ruby bin/create_source.rb --test

# Kombinace
ruby bin/create_source.rb --quick --test

# Nápověda
ruby bin/create_source.rb --help
```

### Přepínače

| Přepínač | Popis |
|----------|-------|
| `--quick` | Pouze povinné údaje, přeskočí rozšířená nastavení |
| `--test` | Použije testovací prostředí a databázi |
| `--help` | Zobrazí nápovědu |

### Prostředí

| Režim | Config adresář | DB schéma |
|-------|----------------|-----------|
| Produkce (default) | `/app/data/zbnw-ng/config` | `zpravobot` |
| Test (`--test`) | `/app/data/zbnw-ng-test/config` | `zpravobot_test` |

### Výstup

- `config/sources/{id}.yml` - Konfigurační soubor zdroje
- `config/mastodon_accounts.yml` - Aktualizováno, pokud je vytvořen nový účet
- **`source_state` záznam v databázi** - Automatická inicializace s vybraným časem

### Workflow průvodce

1. **Platforma** - Výběr twitter/bluesky/rss/youtube
2. **Source data** - Handle, feed_url nebo channel_id
3. **RSS source type** - (pouze RSS) rss/facebook/instagram/other
4. **Mastodon účet** - Nový (ID předvyplněno z handle) nebo existující agregátor
5. **Source name** - (Twitter/Bluesky) Display name pro reposty/quotes
6. **Source ID** - Automaticky generované, možnost upravit
7. **Rozšířená nastavení** - (volitelné) scheduling, filtering, nitter, threads, profile sync, URL fixes
8. **Inicializační čas** - Od kdy zpracovávat příspěvky

### UX vzory wizard flow

Všechny výběry z možností používají sdílený `ask_choice` helper s konzistentním formátem:

```
  Platforma:
    1. twitter
    2. bluesky (default)
    3. rss
    4. youtube
  Vyber číslo [2]:
```

Textové vstupy používají sdílený `ask()` helper:
```
  Twitter handle (bez @) *: f1newscz
  Mastodon account ID (např. denikn, idnes) * [f1newscz]:
```

Ano/Ne otázky používají sdílený `ask_yes_no` helper:
```
  Povolit sync profilu? [A/n]:
```

### Předvyplnění Mastodon account ID

Při vytváření nového Mastodon účtu se ID automaticky předvyplní z handle zdroje:

| Platforma | Předvyplněno z | Příklad |
|-----------|----------------|---------|
| Twitter | `handle` | `f1newscz` → `[f1newscz]` |
| Bluesky (handle) | `handle` | `nesestra.bsky.social` → `[nesestra]` |
| RSS/Facebook | `page handle` | `headliner.cz` → `[headliner_cz]` |
| Ostatní | - | Bez předvyplnění |

Uživatel potvrdí Enterem nebo přepíše vlastní hodnotou.

### Twitter-specific: Nitter Processing

Pro Twitter zdroje je možné povolit Nitter processing (Tier 2). **Výchozí hodnota je `false` (zakázáno).**

```
Povolit Nitter processing (Tier 2)? [a/N]: a
```

| `nitter_processing` | Výsledek |
|---------------------|----------|
| `enabled: false` (default) | Pouze Tier 1 - IFTTT data only, max 1 obrázek, bez threading |
| `enabled: true` | Plný Tier 1/2/3 - full text, multiple images, threading |

**Pozn.:** Když je `nitter_processing: false`, automaticky se nastaví `thread_handling: false`.

Vhodné zakázat pro:
- Sportovní boty (vysoký volume, nízké nároky)
- Test sources
- Zdroje kde stačí základní formátování

### Filtering

V rozšířeném nastavení se u filtrování ptá pouze na **zakázané fráze**. Hodnoty `skip_replies` a `skip_retweets` jsou pevné výchozí:

| Nastavení | Hodnota | Popis |
|-----------|---------|-------|
| `skip_replies` | `true` (pevné) | Vždy přeskakovat replies |
| `skip_retweets` | `false` (pevné) | Nikdy nepřeskakovat retweety |
| `banned_phrases` | uživatelský vstup | Oddělené čárkou |

### Profile Sync

Synchronizace profilu funguje jako vše-nebo-nic. Pokud je povolena, automaticky se synchronizuje vše:

```
Povolit sync profilu? [A/n]: a
```

| `profile_sync_enabled` | Výsledek |
|------------------------|----------|
| `true` | `sync_avatar`, `sync_banner`, `sync_bio`, `sync_fields` = `true` + prompt na `language` a `retention_days` |
| `false` | Žádná synchronizace |

Při povolení se automaticky zapnou avatar/banner/bio/fields a poté se zeptá na jazyk a retenci:
```
Jazyk pro metadata:
  1. cs (default)
  2. sk
  3. en
Vyber číslo [1]:

Retence (dní):
  1. 7
  2. 30
  3. 90 (default)
  4. 180
Vyber číslo [3]:
```

### Inicializační čas (INIT_TIME_OPTIONS)

Nová funkce - uživatel vybere, od kdy má systém zpracovávat příspěvky:

```
Od kdy zpracovávat příspěvky?

  1. Nyní (nezpracuje staré posty) (default)
  2. Před 1 hodinou
  3. Před 6 hodinami
  4. Před 24 hodinami
  5. Vlastní datum/čas
```

| Volba | Offset | Použití |
|-------|--------|---------|
| `now` (default) | 0 | Nové zdroje - začít od teď |
| `1h` | 1 hodina | Zachytit nedávné příspěvky |
| `6h` | 6 hodin | Pokrýt několik hodin zpět |
| `24h` | 24 hodin | Celý předchozí den |
| `custom` | uživatelský | Specifický datum/čas (formát: YYYY-MM-DD HH:MM) |

### Automatická DB inicializace

Po uložení konfigurace se automaticky vytvoří záznam v `source_state`:

```ruby
INSERT INTO source_state (source_id, last_check, last_success, posts_today, error_count)
VALUES ($1, $2, $2, 0, 0)
ON CONFLICT (source_id) DO UPDATE SET
  last_check = EXCLUDED.last_check,
  last_success = EXCLUDED.last_success,
  error_count = 0,
  last_error = NULL,
  updated_at = NOW()
```

**Graceful degradation:** Pokud PostgreSQL není dostupný, zobrazí varování a navrhne manuální `--first-run`.

### Podporované platformy

| Platforma | Vyžadované údaje |
|-----------|------------------|
| Twitter | handle (bez @) |
| Bluesky | handle (např. user.bsky.social) |
| RSS | feed_url |
| YouTube | channel_id (začíná UC...) |

### Konstanty a výchozí hodnoty

```ruby
PLATFORMS = %w[twitter bluesky rss youtube]
PRIORITIES = %w[high normal low]
VISIBILITIES = %w[public unlisted private]
LANGUAGES = %w[cs sk en]
RETENTION_OPTIONS = [7, 30, 90, 180]
DEFAULT_INSTANCE = 'https://zpravobot.news'

# Inicializační časy
INIT_TIME_OPTIONS = {
  'now' => { label: 'Nyní (nezpracuje staré posty)', offset: 0 },
  '1h' => { label: 'Před 1 hodinou', offset: 3600 },
  '6h' => { label: 'Před 6 hodinami', offset: 6 * 3600 },
  '24h' => { label: 'Před 24 hodinami', offset: 24 * 3600 },
  'custom' => { label: 'Vlastní datum/čas', offset: nil }
}
```

### Priority systém

Priority mají **dva různé účely** v ZBNW-NG systému:

#### 1. Scheduling interval (Orchestrátor)

Priority určuje **interval** kontroly zdroje:

| Priority | Interval | Použití |
|----------|----------|---------|
| `high` | 5 minut | Hot news, breaking alerts, důležité zdroje |
| `normal` | 20 minut | Standardní zpravodajské zdroje |
| `low` | 55 minut | Low-priority obsah, archivní zdroje, YouTube |

```ruby
# V SourceConfig (lib/config/config_loader.rb)
PRIORITY_INTERVALS = {
  'high'   => 5,
  'normal' => 20,
  'low'    => 55
}

def interval_minutes
  # Legacy: explicitní hodnota v configu má přednost (nepoužívat v nových YAML)
  explicit = @data.dig('scheduling', 'interval_minutes')
  return explicit if explicit

  # Odvozeno z priority
  PRIORITY_INTERVALS.fetch(priority, 20)
end
```

**Příklad:** Zdroj s `priority: high` bude kontrolován každých 5 minut.

> ⚠️ **Poznámka:** `interval_minutes` v YAML je **obsolete** — nové zdroje ho nemají. Starší YAML soubory ho mohou stále obsahovat (zpětná kompatibilita), ale při úpravách se doporučuje odebrat a řídit interval pouze přes `priority`.

#### 2. IFTTT Queue Processing (Twitter webhooks)

Priority ovlivňuje **způsob zpracování** Twitter webhooků v IftttQueueProcessor:

| Priority | Chování | Thread detection | Batch delay |
|----------|---------|------------------|-------------|
| `high` | Okamžité zpracování | Ne | Ne |
| `normal` | Batch zpracování | Ano | 2 minuty |
| `low` | Batch zpracování (po normal) | Ano | 2 minuty |

```ruby
# V IftttQueueProcessor (lib/webhook/ifttt_queue_processor.rb)
BATCH_DELAY = 120   # 2 min - čas na nahromadění batche
MAX_AGE = 1800      # 30 min - force publish (anti-hromadění)

def process_queue
  high, normal, low = partition_by_priority(files)

  # 1. HIGH = okamžitě, bez batch logiky
  high.each { |f| process_webhook_file(f, force_tier2: false) }

  # 2. NORMAL + LOW = batch s delay, thread-aware
  batch_candidates = normal + low  # Normal first, then low
  ready = batch_candidates.select { |f| ready_for_processing?(f) }
  process_batch(ready) if ready.any?

  # 3. Update source_state pro všechny úspěšné source_ids
  @published_sources.each do |source_id, count|
    @state_manager.mark_check_success(source_id, posts_published: count)
  end
end
```

**Proč batch delay?**
- Dává čas na nahromadění threadů (vláken) od stejného autora
- Umožňuje správnou detekci a řazení thread posts
- `high` priority toto přeskakuje pro rychlost

**Lookup priority:**
```ruby
def get_file_priority(filepath)
  username = extract_username_from_filename(filepath)
  config = find_config_for_username(username)
  config&.dig('scheduling', 'priority') || 'normal'
end
```

#### Doporučení pro nastavení priority

| Typ zdroje | Doporučená priority | Důvod |
|------------|---------------------|-------|
| Breaking news (ČT24, iDNES) | `high` | Rychlost je kritická |
| Běžné zpravodajství | `normal` | Standardní zpracování |
| Komentáře, magazíny | `low` | Není časově kritické |
| Vlákna/threads | `normal` nebo `low` | Batch delay pomáhá správnému řazení |

#### Non-blocking rate limit handling (PERF-3, 2026-04-10)

Při zpracování fronty (~3 500–4 000 JSONů/den, ~470 účtů) jeden rate-limitovaný Mastodon účet **neblokuje zpracování ostatních zdrojů**. Dříve pipeline při HTTP 429 spala (`sleep retry_after`) — nyní se rate limit propaguje jako `AccountRateLimitedError` a soubory se zpracovávají paralelně pro různé účty:

```
Fronta:      account_a_111.json → account_b_222.json → account_c_333.json
                                       ↑ 429!

Staré chování:  A=publish → B=429 → sleep 60s → C čeká…
Nové chování:   A=publish → B=429 → B odložen → C=publish (okamžitě)
```

**Mechanismus:**

1. **`MastodonPublisher`** při 429 nastaví `@rate_limited_until` a vyhodí `AccountRateLimitedError` (žádný `sleep`)
2. **Pre-flight check** `raise_if_rate_limited!` — před každým publish/upload zkontroluje stav; pokud je účet limitovaný, ani nepošle HTTP požadavek
3. **`IftttQueueProcessor`** udržuje `rate_limited_accounts` (Set) — další JSONy pro stejný účet se v daném runu přeskočí (`next`)
4. **Deferral** — soubor zůstane v `pending/` (nepřesunut do `processed/` ani `failed/`), zpracuje se příštím cron runem
5. **Parallel media upload** — `upload_media_parallel` používá `Thread.new` per médium; pokud jeden thread dostane 429, ostatní doběhnou a rate limit se re-raise na konci

```ruby
# V IftttQueueProcessor — tracking per-run
rate_limited_accounts = Set.new

high.each do |filepath|
  username = extract_username_from_filename(filepath)
  if username && rate_limited_accounts.include?(username)
    next  # skip — účet je rate-limited, JSON zůstane v pending/
  end
  result = process_webhook_file(filepath, force_tier2: false)
  rate_limited_accounts.add(username) if result == :rate_limited
end
```

**Dopad:** Jeden rate-limitovaný účet nezpomalí ostatních ~469 účtů. Odložené soubory se zpracují v dalším cron runu (*/2 min).

### RSS Source Types

Pro RSS.app feedy z Facebooku/Instagramu:

```ruby
RSS_SOURCE_TYPES = {
  'rss'       => { label: 'RSS', suffix: 'rss' },
  'facebook'  => { label: 'Facebook', suffix: 'facebook' },
  'instagram' => { label: 'Instagram', suffix: 'instagram' },
  'other'     => { label: nil, suffix: nil }  # Custom
}
```

### Content Modes (RSS/YouTube)

```ruby
CONTENT_MODES = {
  'text'     => { show_title_as_content: false, combine_title_and_content: false },
  'title'    => { show_title_as_content: true, combine_title_and_content: false },
  'combined' => { show_title_as_content: false, combine_title_and_content: true }
}
```

### RSS.app Content Replacements

Automaticky přidáno pro Facebook/Instagram zdroje:

```ruby
RSSAPP_CONTENT_REPLACEMENTS = [
  { pattern: "^.+?\\s+(Posted|shared|updated status)$", replacement: "", flags: "i", literal: false },
  { pattern: "(See more|Continue reading|Read more)$", replacement: "", flags: "i", literal: false }
]
```

---

## manage_source.rb

### Umístění
`bin/manage_source.rb` (entry point) → `lib/source_wizard/source_manager.rb` (logika)

### Účel

Správa životního cyklu zdrojů — dočasné pozastavení, reaktivace a trvalé vyřazení. Operátoři nemusí ručně editovat YAML ani databázi.

### Použití

```bash
# Interaktivní menu (výběr zdroje + akce)
ruby bin/manage_source.rb

# Přímé příkazy
ruby bin/manage_source.rb pause  ct24_twitter
ruby bin/manage_source.rb pause  ct24_twitter --reason "Nefunkční Nitter"
ruby bin/manage_source.rb resume ct24_twitter
ruby bin/manage_source.rb retire ct24_twitter

# Přehled pauzovaných zdrojů
ruby bin/manage_source.rb status

# Dry-run probe pauzovaného zdroje (ověří, zda vrací příspěvky)
ruby bin/manage_source.rb probe ct24_twitter
ruby bin/manage_source.rb probe   # probe VŠECH pauzovaných zdrojů

# Testovací prostředí
ruby bin/manage_source.rb pause  ct24_twitter --test

# Nápověda
ruby bin/manage_source.rb --help
```

### Přepínače

| Přepínač | Popis |
|----------|-------|
| `--test` | Testovací prostředí (schema: `zpravobot_test`) |
| `--reason "TEXT"` | Důvod pauzy (volitelný, pouze pro `pause`) |
| `--help` | Zobrazí nápovědu |

### Akce

#### pause

Dočasně pozastaví zdroj. Orchestrátor ho přeskočí, dokud není reaktivován.

- **YAML**: `enabled: true` → `enabled: false` + komentáře hned pod ním:
  ```yaml
  enabled: false
  # paused_at: 2026-02-25 14:30
  # paused_reason: Nefunkční Nitter
  ```
- **DB**: `source_state.disabled_at = NOW()`
- **ProblematicSourcesCheck**: pauznuté zdroje jsou automaticky filtrovány

#### resume

Reaktivuje pozastavený zdroj. Spustí interaktivní init time wizard (od kdy zpracovávat příspěvky).

- **YAML**: `enabled: false` → `enabled: true`, odstraní `# paused_at` a `# paused_reason`
- **DB**: `disabled_at = NULL`, `error_count = 0`, `last_error = NULL`, `last_check = <init_time>`

#### retire

Trvale vyřadí zdroj. **Vždy vyžaduje interaktivní potvrzení** (i při přímém příkazu).

- **YAML**: přesunut do `config/sources/retired/`
- **DB**: smazán `source_state` + `published_posts`; `activity_log` zůstane zachován (historická data)

#### status

Zobrazí přehled **všech aktuálně pauzovaných** zdrojů v tabulkové formě.

- Sloupce: zdroj, datum pozastavení, důvod, poslední chyba (je-li)
- Kombinuje YAML stav (`enabled: false`) i DB stav (`disabled_at`)
- Žádné argumenty navíc — prostě `ruby bin/manage_source.rb status`

#### probe

Dry-run ověření pauzovaného zdroje — **spustí orchestrátor v dry-run režimu** a ukáže, zda zdroj vrací příspěvky. Pokud ano, nabídne okamžitou reaktivaci (resume).

- **S argumentem**: `probe SOURCE_ID` — prověří jeden konkrétní zdroj, zobrazí jeho `disabled_at`, `last_error`, `error_count`, `last_check` a `last_success`
- **Bez argumentu**: `probe` — prověří **všechny pauzované** zdroje postupně
- Volá `bin/run_zbnw.rb --source SOURCE_ID --dry-run --once` v subprocesu
- Pokud dry-run najde příspěvky, nabídne interaktivní resume

### DB migrace

Před prvním použitím spustit migraci v obou schématech:

```bash
psql -U zpravobot_owner -d zpravobot -c "SET search_path TO zpravobot;" -f db/patch_add_disabled_at.sql
psql -U zpravobot_owner -d zpravobot -c "SET search_path TO zpravobot_test;" -f db/patch_add_disabled_at.sql
```

Migrace je idempotentní (`ADD COLUMN IF NOT EXISTS`). Pokud nebyla aplikována, `ProblematicSourcesCheck` automaticky padne zpět na query bez `disabled_at`.

### Architektura

| Soubor | Účel |
|--------|------|
| `bin/manage_source.rb` | CLI entry point, parsování argumentů, interaktivní menu |
| `lib/source_wizard/source_manager.rb` | Logika pause/resume/retire/status/probe |
| `lib/source_wizard/init_time_helpers.rb` | Sdílený init time wizard (i s `create_source.rb`) |
| `db/patch_add_disabled_at.sql` | DB migrace — `disabled_at` sloupec v `source_state` |

---

## force_update_source.rb

### Umístění
`bin/force_update_source.rb`

### Účel

Resetuje `last_check` čas pro konkrétní zdroj v databázi, čímž přinutí systém okamžitě zpracovat daný zdroj při dalším běhu orchestrátoru.

### Použití

```bash
# Interaktivní výběr
ruby bin/force_update_source.rb

# Přímé zadání source_id
ruby bin/force_update_source.rb ct24_twitter

# Testovací prostředí
ruby bin/force_update_source.rb --test
ruby bin/force_update_source.rb ct24_twitter --test
```

### Funkce

1. Zobrazí seznam všech source_state záznamů
2. Umožní vybrat nebo zadat source_id
3. Nastaví `last_check = NOW() - 1 hour`
4. Zdroj bude zpracován při dalším běhu orchestrátoru

### SQL operace

```sql
UPDATE source_state 
SET last_check = NOW() - INTERVAL '1 hour',
    updated_at = NOW()
WHERE source_id = $1
```

---

## retry_failed_queue.rb

### Umístění
`bin/retry_failed_queue.rb` (cron entry point)

### Účel

Opakuje zpracování IFTTT webhooků, které selhaly a čekají ve `queue/ifttt/failed/`. Klasifikuje soubory jako **DEAD** (trvalá chyba / příliš staré / vyčerpány pokusy) nebo jako **retryable** (přesun zpět do `pending/`).

Navrženo pro cron invokaci 1× za hodinu. Skript okamžitě exituje, pokud nejsou žádné kandidáty (soubory bez prefixu `DEAD_`).

### Použití

```bash
# Normální běh (cron)
ruby bin/retry_failed_queue.rb

# Dry-run — zobrazí co by udělal, nic nezmění
ruby bin/retry_failed_queue.rb --dry-run

# Verbose výpis
ruby bin/retry_failed_queue.rb --verbose

# Testovací prostředí
ZPRAVOBOT_SCHEMA=zpravobot_test ruby bin/retry_failed_queue.rb
```

### Konstanty

| Konstanta | Hodnota | Popis |
|-----------|---------|-------|
| `MAX_RETRIES` | 1 | Maximální počet pokusů o opakování |
| `MAX_RETRY_AGE` | 6h | Maximální stáří souboru pro retry |

### Logika klasifikace

```
permanent_error?(reason)   →  DEAD_  (chyba, která se neopraví sama)
stáří > MAX_RETRY_AGE      →  DEAD_  (příliš staré)
retry_count >= MAX_RETRIES →  DEAD_  (vyčerpány pokusy)
jinak                      →  pending/  (znovu zpracovat)
```

### DEAD_ soubory

Soubory s prefixem `DEAD_` jsou **archiv** — zůstávají v `failed/`, nikdy se znovu nezpracovávají. `QueueCheck` je ze `failed_count` vylučuje (zobrazuje je jako `dead_count` v detailech alertu).

### PERMANENT_ERRORS

Chyby, kde by opakování nikdy nepomohlo (regex seznam v `bin/retry_failed_queue.rb`):

| Pattern | Důvod |
|---------|-------|
| `Invalid JSON` | Malformovaný payload z IFTTT |
| `tweet likely deleted` | Tweet byl smazán |
| `No config found` | Neznámé `bot_id` |
| `unknown bot_id` | Chybí konfigurace bota |
| `Text cannot be empty` | Prázdný text — neopravitelné |

### Cron

```cron
# 1× za hodinu — cron_retry_failed.sh navíc zkontroluje počet kandidátů
0 * * * * /app/data/zbnw-ng/cron_retry_failed.sh
```

Wrapper `cron_retry_failed.sh` sám zkontroluje počet souborů v `failed/` (bez `DEAD_` prefixu) a spouští Ruby skript jen když existují kandidáti.

### Architektura

```
cron_retry_failed.sh  →  kandidáti == 0? → exit
                      →  ruby bin/retry_failed_queue.rb
                               ↓
           pro každý *.json v failed/ (bez DEAD_ prefixu):
             ├── permanent_error? nebo příliš staré nebo max_retries?
             │     → přejmenovat na DEAD_{filename}
             │     → uložit dead_reason + dead_at do JSON
             └── jinak
                   → přesunout do pending/
                   → inkrementovat retry_count v JSON
```

### Vazby

- `lib/webhook/ifttt_queue_processor.rb` — `move_to_failed()` přidává `retry_count: 0` do sekce `_failure` v JSON
- `lib/health/checks/queue_check.rb` — `failed_count` ignoruje `DEAD_` soubory; `dead_count` zobrazen v detailech
- `cron_retry_failed.sh` — cron wrapper s early-exit optimalizací
- `test/test_retry_failed_queue.rb` — 41 testů

---

## health_monitor.rb (Údržbot)

### Umístění
`bin/health_monitor.rb`

### Účel

Komplexní monitoring systém pro ZBNW-NG infrastrukturu. Kontroluje zdraví všech komponent a posílá inteligentní alerty na Mastodon.

### Použití

```bash
# Základní kontrola
ruby bin/health_monitor.rb

# Detailní výpis
ruby bin/health_monitor.rb --details

# JSON výstup
ruby bin/health_monitor.rb --json

# Uložit report
ruby bin/health_monitor.rb --save

# Poslat alert na Mastodon (pouze při problémech)
ruby bin/health_monitor.rb --alert

# Denní heartbeat (pouze při OK stavu)
ruby bin/health_monitor.rb --heartbeat

# Vlastní config
ruby bin/health_monitor.rb -c /path/to/config.yml
```

### Cron konfigurace

```bash
# cron_health.sh - wrapper pro cron
#!/bin/bash
cd /app/data/zbnw-ng-test
source env.sh
ruby bin/health_monitor.rb "$@" >> logs/health_monitor.log 2>&1
```

```cron
# Kontrola každých 10 minut
*/10 * * * * /app/data/zbnw-ng-test/cron_health.sh --alert --save

# Denní heartbeat v 8:00
0 8 * * * /app/data/zbnw-ng-test/cron_health.sh --heartbeat
```

### Konfigurace (health_monitor.yml)

```yaml
# Webhook server
webhook_url: 'http://localhost:8080'

# Nitter instance
nitter_url: 'https://xn.zpravobot.news'

# Mastodon
mastodon_instance: 'https://zpravobot.news'

# Queue directories
queue_dir: '/app/data/zbnw-ng-test/queue/ifttt'

# Database
database:
  host: localhost
  name: zpravobot
  user: zpravobot_app
  schema: zpravobot_test

# Logs
log_dir: '/app/data/zbnw-ng-test/logs'
health_log_dir: '/app/data/zbnw-ng-test/logs/health'

# Thresholds
thresholds:
  webhook_timeout: 5              # sekundy
  nitter_timeout: 10              # sekundy
  ifttt_no_webhook_minutes: 120   # 2h bez webhooku = warning
  queue_stale_minutes: 30         # pending starší než 30min
  queue_max_pending: 100          # max ve frontě
  no_publish_minutes: 60          # bez publikování = warning
  error_threshold: 5              # chyb pro warning
  activity_baseline_variance: 0.8 # 80% baseline = warning
```

### Health Checks

Monitor provádí **11 health checků** v tomto pořadí:

#### 1. ServerResourcesCheck (NEW)
Kontroluje serverové zdroje: CPU, Disk, RAM, Swap.

```ruby
# Pořadí sub-checků: CPU → Disk → RAM → Swap

# CPU Load (z /proc/loadavg)
# OK: Load < 2.0
# WARNING: Load >= 2.0
# CRITICAL: Load >= 4.0

# Disk (z df /app/data)
# OK: < 80%
# WARNING: >= 80%
# CRITICAL: >= 95%

# RAM - Available Memory (z free -m, sloupec 'available')
# OK: >= 500 MB available
# WARNING: < 500 MB available
# CRITICAL: < 200 MB available

# Swap I/O Activity (z vmstat 1 2)
# OK: si + so = 0
# WARNING: si + so >= 100/s
# CRITICAL: si + so >= 500/s
```

**Proč available RAM místo used %:**
PostgreSQL a další DB systémy alokují paměť do cache a drží ji - vysoké "used %" je normální. `available` ukazuje skutečně dostupnou paměť pro nové procesy.

**Proč Swap I/O místo Swap %:**
Swap může být plný, ale pokud systém aktivně neswapuje (I/O = 0), není to problém. Aktivní swapping (vysoké si/so) indikuje skutečný memory pressure.

**OK formát:**
```
Server: CPU 0.49 | Disk 35% | RAM 1212MB free | Swap OK
```

**Remediation:**
```bash
# CPU vysoké
ps aux --sort=-%cpu | head -10

# Disk plný
du -sh /app/data/* | sort -hr | head -10
find /app/data -name '*.log' -mtime +7 -delete

# RAM nízká / Swap aktivní
ps aux --sort=-%mem | head -10
```

#### 2. LogAnalysisCheck (NEW)
Kontroluje chyby v log souborech za poslední hodinu.

```ruby
# Skenované logy:
# - runner_YYYYMMDD.log (denně rotovaný)
# - ifttt_processor.log (nerotovaný - jen posledních 2000 řádků)
# - webhook_server.log (nerotovaný - jen posledních 2000 řádků)

# Error patterns:
ERROR_PATTERNS = [
  /\berror:/i,
  /\bfailed to\b/i,
  /\bexception:/i,
  /\btimeout:/i,
  /\bcrash/i,
  /\bfatal/i,
  /❌/
]

# Vyloučené false positives:
EXCLUDE_PATTERNS = [
  /failed: 0/i,
  /errors: 0/i,
  /error_count: 0/i,
  /Queue processing complete/i
]

# OK: < 20 chyb/h
# WARNING: >= 20 chyb/h
# CRITICAL: >= 50 chyb/h
```

**Timestamp handling:**
- Denní logy (`runner_*.log`): Timestamp `[HH:MM:SS]` = dnešní datum
- Nerotované logy: Vyžaduje plný timestamp `[YYYY-MM-DD HH:MM:SS]`, jinak řádek přeskočen

**Remediation:**
```bash
tail -100 logs/runner_20260203.log | grep -i error
grep -i error logs/ifttt_processor.log | tail -20
```

#### 3. WebhookCheck
Kontroluje dostupnost IFTTT webhook serveru.

```ruby
# HTTP GET na webhook_url/health
# OK: HTTP 200 + "healthy" v response
# WARNING: HTTP != 200
# CRITICAL: Connection refused, timeout
```

**Remediation:**
```bash
cd /app/data/zbnw-ng
pkill -f ifttt_webhook.rb
nohup ruby bin/ifttt_webhook.rb >> logs/webhook_server.log 2>&1 &
```

#### 4. NitterCheck
Kontroluje dostupnost Nitter instance.

```ruby
# HTTP GET na nitter_url/settings
# Hledá v HTML: rate_limit, suspended

# OK: HTTP 200, žádné problémy
# WARNING: Degraded (rate_limit, suspended v HTML)
# CRITICAL: Connection refused, timeout
```

**Remediation:**
```bash
ssh admin@xn.zpravobot.news
cd /opt/nitter && docker-compose restart
```

#### 5. NitterAccountsCheck
Kontroluje error patterns související s burner účty.

```ruby
# Hledá v activity_log za poslední hodinu chyby obsahující:
# - rate_limit, guest_account, unauthorized, suspended

# OK: Žádné account-related chyby
# WARNING: > 3 account-related chyb
# CRITICAL: > 10 account-related chyb
```

#### 6. QueueCheck
Kontroluje stav IFTTT queue.

```ruby
# Počítá soubory v queue_dir/pending, processed, failed
# Kontroluje stáří nejstaršího pending souboru

# OK: Prázdná nebo normální
# WARNING: stale_count > 0 (pending > queue_stale_minutes)
# WARNING: failed_count > 10   ← DEAD_ soubory se nezapočítávají
# CRITICAL: pending_count > queue_max_pending (100)
# Details: dead_count (DEAD_ soubory) — informativní, nespouští alert
```

**Remediation:**
```bash
ruby lib/webhook/ifttt_queue_processor.rb
ls -la /app/data/zbnw-ng/queue/ifttt/pending
```

#### 7. ProcessingCheck
Kontroluje databázi a processing pipeline. Agreguje 4 sub-checky:

##### check_last_publish
```ruby
# Hledá poslední publish v activity_log za 24h
# WARNING: Žádné publikování za 24h
# WARNING: Poslední publikování > no_publish_minutes (60)
# OK: Publikování v normálu
```

##### check_error_sources
```ruby
# Hledá zdroje s error_count >= error_threshold (5)
# WARNING: Zdroje s opakovanými chybami
# OK: Žádné zdroje s opakovanými chybami
```

##### check_ifttt_activity
```ruby
# Hledá poslední webhook v activity_log nebo processed directory
# WARNING: Poslední webhook > ifttt_no_webhook_minutes (120)
# OK: Webhook aktivita v normálu
```

##### check_activity_trend
```ruby
# Porovnává dnešní aktivitu s 7-denním průměrem ve stejnou hodinu
# WARNING: Aktivita < baseline * activity_baseline_variance (80%)
# OK: Aktivita v normálu
```

#### 8. MastodonCheck
Kontroluje Mastodon API dostupnost.

```ruby
# HTTP GET na mastodon_instance/api/v1/instance
# HTTPS, timeout 5s/10s

# OK: HTTP 200
# WARNING: HTTP != 200
# CRITICAL: Error (connection, timeout)
```

#### 9. ProblematicSourcesCheck
Zobrazuje top 10 problematických zdrojů s prokliknutelnými @mentions.

> **Pozn.:** Check 9 je poslední check s vlastní logikou. Checky 10–11 (RecurringWarningsCheck a RunnerHealthCheck) byly přidány v Fázi 15 a monitorují opakující se warnings a zdraví cron runnerů.

#### 10. RecurringWarningsCheck
Detekuje opakující se WARN patterny v logách za poslední hodinu.

```ruby
# Skenuje stejné logy jako LogAnalysisCheck, ale hledá WARN místo ERROR
# Normalizuje a seskupí warnings (odstraní timestampy, ID, URL)
# Filtruje nad threshold (default: 10 opakování)

# OK: < 10 opakujících se warnings/h
# WARNING: >= 10 opakujících se warnings/h
```

#### 11. RunnerHealthCheck
Detekuje stav cron runneru — staleness a po sobě jdoucí crashe.

```ruby
# Analyzuje runner_YYYYMMDD.log:
# 1. Staleness — jak dlouho od posledního "Run complete"
# 2. Consecutive crashes — trailing "exit code: N" (N != 0)

# OK: Poslední úspěch < 30 min
# WARNING: Staleness > 30 min NEBO >= 3 po sobě jdoucí crashe
# CRITICAL: Staleness > 60 min NEBO crashe bez jediného úspěchu
```

```ruby
# Hledá zdroje kde:
# - error_count > 0
# - last_success < NOW() - 24 hours

# WARNING: Zdroj s error_count >= 5
# OK: Jinak (informativní výpis)
```

**Formát výstupu:** Každý zdroj se zobrazuje s Mastodon @mention místo surového `source_id`:

```
@chmuchmi (twitter): 0 chyb, 80.8h od úspěchu
@vystrahy (chmuchmi_twitter): 0 chyb, 80.4h od úspěchu
@chmu_hydrologie (twitter): 0 chyb, 80.3h od úspěchu
```

Formát: `@{mastodon_account} ({suffix}): {error_count} chyb, {hours}h od úspěchu`
- `mastodon_account` se načítá z YAML configu zdroje (`target.mastodon_account`) přes `Config::ConfigLoader`
- `suffix` = `source_id` bez prefixu `{account}_` (case-insensitive)
- Pokud config zdroje neexistuje (smazaný zdroj), použije se fallback na původní `source_id`
- @mention na zpravobot.news se automaticky prolinkuje na profil bota

> **Poznámka:** Twitter sources se aktualizují přes `IftttQueueProcessor`, který po každém úspěšném publish/update volá `mark_check_success()`. Tím se `last_success` správně aktualizuje i pro webhook-based zdroje.

### CheckResult

```ruby
class CheckResult
  LEVELS = { ok: 0, warning: 1, critical: 2 }
  
  attr_reader :name, :level, :message, :details, :remediation
  
  def ok?      # level == :ok
  def warning? # level == :warning
  def critical? # level == :critical
  
  def icon
    # :ok => '✅', :warning => '⚠️', :critical => '❌'
  end
end
```

### AlertStateManager

Inteligentní správa alertů pro deduplikaci a intervaly.

```ruby
class AlertStateManager
  # Intervaly pro opakované alerty
  DAY_INTERVAL = 30     # 7:00 - 23:00: každých 30 min
  NIGHT_INTERVAL = 60   # 23:00 - 7:00: každých 60 min
  DAY_START = 7
  DAY_END = 23
  
  # Stabilizační doba pro "vyřešeno" (NEW)
  RESOLVED_STABILIZATION = 20  # 2 cykly po 10 min
  
  # State file: health_log_dir/alert_state.json
  # Struktura:
  # {
  #   "problems": {
  #     "Webhook Server": {
  #       "first_seen_at": "2026-01-30T10:00:00+01:00",
  #       "last_alert_at": "2026-01-30T10:00:00+01:00",
  #       "level": "critical",
  #       "message": "Connection refused"
  #     }
  #   },
  #   "pending_resolved": {
  #     "Nitter Instance": {
  #       "first_seen_at": "2026-01-30T08:00:00+01:00",
  #       "last_alert_at": "2026-01-30T10:00:00+01:00",
  #       "disappeared_at": "2026-01-30T10:30:00+01:00",
  #       "level": "warning",
  #       "message": "Degraded"
  #     }
  #   },
  #   "last_check_at": "2026-01-30T10:30:00+01:00"
  # }
  
  def analyze(results)
    # Vrací:
    # {
    #   new: [],           # Nové problémy
    #   persisting: [],    # Přetrvávající (s duration_minutes)
    #   resolved: [],      # Vyřešené po stabilizační době (s duration_minutes)
    #   should_alert: bool # Má se poslat alert?
    # }
  end
  
  def update_state(results, analysis)  # Po odeslání alertu
  def clear_state                       # Po vyřešení všech problémů
  def has_previous_problems?
end
```

#### Stabilizační doba (NEW)

Problém zmizí → přesune se do `pending_resolved` → čeká 20 min:
- Pokud stále OK po 20 min → hlásí se jako "vyřešeno"
- Pokud se problém vrátí během 20 min → pokračuje jako "přetrvávající" (nehlásí se jako nový)

Toto zabraňuje false positive alertům při "blikajících" problémech.

### HealthMonitor hlavní třída

```ruby
class HealthMonitor
  def initialize(config)
    @checks = [
      HealthChecks::ServerResourcesCheck.new(config),  # NEW
      HealthChecks::LogAnalysisCheck.new(config),      # NEW
      HealthChecks::WebhookCheck.new(config),
      HealthChecks::NitterCheck.new(config),
      HealthChecks::NitterAccountsCheck.new(config),
      HealthChecks::QueueCheck.new(config),
      HealthChecks::ProcessingCheck.new(config),
      HealthChecks::MastodonCheck.new(config),
      HealthChecks::ProblematicSourcesCheck.new(config),
      HealthChecks::RecurringWarningsCheck.new(config),
      HealthChecks::RunnerHealthCheck.new(config)
    ]
  end
  
  def run_all                           # Spustí všechny checky
  def overall_status(results)           # :ok, :warning, :critical
  
  # Formátování
  def format_console(results, detailed:)
  def format_json(results)
  def format_mastodon_alert(results)
  def format_smart_alert(results, analysis)
  def format_all_resolved(analysis)
  def format_heartbeat(results)
  
  # Akce
  def post_to_mastodon(content, visibility:)
  def save_report(results, format:)
end
```

### Mastodon Alert Formáty

#### Smart Alert (nové/přetrvávající problémy)

```
🔧 Údržbot hlásí [2026-01-30 10:30]

🚨 Nové problémy:
❌ Server: Disk 96% (25G/26G)
   → Disk kriticky plný!
   → du -sh /app/data/* | sort -hr | head -10

⏳ Přetrvávající problémy:
⚠️ Log Errors (2h 30min): 35 chyb/h (runner:28, ifttt:7)
   → Zvýšený počet chyb.
   → grep -i error logs/runner_20260130.log | tail -20

✅ OK: WebhookServer, Nitter, IFTTT, Processing, Mastodon

#údržbot #zpravobot
```

#### All Resolved

```
🔧 Údržbot hlásí [2026-01-30 11:00]

✅ Všechny problémy vyřešeny!

• Server/Disk (trval 5h 30min)
• Log Errors (trval 2h 45min)

Systém opět běží normálně.

#údržbot #zpravobot
```

#### Heartbeat

```
🔧 Údržbot hlásí [2026-01-30 08:00]

✅ Všechny systémy běží normálně.

• Server: CPU 0.49 | Disk 35% | RAM 1212MB free | Swap OK
• Log Errors: Žádné chyby/h
• Webhook Server: OK (uptime 5d 3h, 1234 requests)
• Nitter Instance: OK (Dostupný)
• Nitter Accounts: Žádné account-related chyby
• IFTTT Queue: Prázdná (0 failed)
• Processing: Všechny subsystémy OK
• Mastodon API: OK (Zprávobot.news)

📋 Zdroje vyžadující pozornost:
   • @nesestra (bluesky): 0 chyb, 498h od úspěchu
   • @idnes (rss): 0 chyb, 498h od úspěchu

📎 Všechny: psql "$CLOUDRON_POSTGRESQL_URL" -c "..."

#údržbot #zpravobot
```

### Environment Variables

| Proměnná | Výchozí | Popis |
|----------|---------|-------|
| `ZPRAVOBOT_MONITOR_TOKEN` | - | Mastodon access token pro alert bot |
| `CLOUDRON_POSTGRESQL_URL` | - | PostgreSQL connection string |
| `DATABASE_URL` | - | Alternativní connection string |
| `ZPRAVOBOT_DB_HOST` | localhost | Database host |
| `ZPRAVOBOT_DB_NAME` | zpravobot | Database name |
| `ZPRAVOBOT_DB_USER` | zpravobot_app | Database user |
| `ZPRAVOBOT_DB_PASSWORD` | - | Database password |
| `ZPRAVOBOT_SCHEMA` | zpravobot | Database schema |

### Report Files

```
logs/health/
├── alert_state.json           # Stav alertů pro deduplikaci
├── health_20260130_103000.json  # JSON reporty
└── health_20260130_103000.txt   # Text reporty (při --details --save)
```

Reporty starší než 7 dní jsou automaticky mazány.

---

## command_listener.rb (Údržbot)

### Umístění
`bin/command_listener.rb`

### Účel

Interaktivní rozšíření Údržbotu — polluje Mastodon mentions, parsuje příkazy od oprávněných uživatelů a odpovídá přes DM. Využívá existující `HealthMonitor` a `HealthChecks` infrastrukturu pro zdravotní checky.

### Použití

```bash
# Jednorázový poll (cron)
ruby bin/command_listener.rb

# Dry run (parsuje ale neodpovídá ani nedismissuje)
ruby bin/command_listener.rb --dry-run

# Vlastní config
ruby bin/command_listener.rb -c /path/to/config.yml
```

### Přepínače

| Přepínač | Popis |
|----------|-------|
| `--dry-run` | Parsuje příkazy ale neodpovídá a nedismissuje notifikace |
| `-c, --config FILE` | Vlastní konfigurační soubor (default: `config/health_monitor.yml`) |
| `-h, --help` | Nápověda |

### Cron konfigurace

```bash
# cron_command_listener.sh - wrapper
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
cd "$ZBNW_DIR" || exit 1
ruby bin/command_listener.rb "$@" >> "${ZBNW_LOG_DIR}/command_listener.log" 2>&1
```

```cron
# Každých 5 minut
*/5 * * * * /app/data/zbnw-ng/cron_command_listener.sh
```

### Soubory

```
bin/command_listener.rb              # CLI entry point (lockfile, OptionParser)
lib/monitoring/command_listener.rb   # Polling, parsování, dispatching, state
lib/monitoring/command_handlers.rb   # Registry příkazů a jejich implementace
cron_command_listener.sh             # Cron wrapper
```

### Příkazy

| Příkaz | Popis | Spouští health checky? |
|--------|-------|------------------------|
| `help` | Seznam dostupných příkazů | Ne |
| `status` | Kompaktní přehled: overall status + jednořádkové výsledky | Ano |
| `detail` / `details` | Plný report s remediací a detaily | Ano |
| `heartbeat` | Status + problematické zdroje (heartbeat formát) | Ano |
| `sources` | Výpis problematických zdrojů | Ano |
| `check [nazev]` | Detail jednoho konkrétního checku | Ano |

**Příklady:**
```
@udrzbot help
@udrzbot status
@udrzbot detail
@udrzbot heartbeat
@udrzbot sources
@udrzbot check server
@udrzbot check nitter
```

### Check aliasy (pro příkaz `check`)

| Alias | Full name |
|-------|-----------|
| `server` | Server |
| `webhook` | Webhook Server |
| `nitter` | Nitter Instance |
| `accounts` | Nitter Accounts |
| `queue` | IFTTT Queue |
| `processing` | Processing |
| `mastodon` | Mastodon API |
| `logs` | Log Errors |
| `sources` | Problematic Sources |

### Konfigurace (v `health_monitor.yml`)

```yaml
command_listener:
  # Účty s přístupem k příkazům (lokální username nebo user@domain)
  # Reálné účty jsou v helper_tools.private.md
  allowed_accounts:
    - '<admin-account>'

  # Max příkazů na účet za jeden poll cyklus
  rate_limit_per_cycle: 3

  # Viditelnost odpovědí ('direct' = DM)
  response_visibility: 'direct'

  # Username bota (pro odstranění z mention textu)
  bot_account: 'udrzbot'

  # Max notifikací na jedno načtení
  poll_limit: 30
```

### Architektura

#### Životní cyklus `run()`

1. Načíst state (cursor `last_notification_id`)
2. Fetch mentions od posledního ID (`GET /api/v1/notifications?types[]=mention&since_id=X`)
3. Pro každou notifikaci:
   - Auth check (whitelist) → neautorizované: tiché dismiss
   - Rate limit check → nad limit: DM s odmítnutím + dismiss
   - Parse: `HtmlCleaner.clean(html)` → odstranění `@udrzbot` → split command + args
   - Dispatch → `CommandHandlers.dispatch(command, args)`
   - Reply: `MastodonPublisher#publish` s `in_reply_to_id:` a `visibility: 'direct'`
   - Dismiss: `POST /api/v1/notifications/:id/dismiss`
4. Uložit nový cursor

#### CommandHandlers

```ruby
class CommandHandlers
  COMMANDS = {
    'help'      => :handle_help,
    'status'    => :handle_status,
    'detail'    => :handle_detail,
    'details'   => :handle_detail,
    'heartbeat' => :handle_heartbeat,
    'sources'   => :handle_sources,
    'check'     => :handle_check
  }

  def dispatch(command, args)     # Hlavní dispatch
  def known_command?(command)     # Je příkaz známý?
end
```

- **Lazy init**: `HealthMonitor` se vytváří jen když příkaz vyžaduje health checky (ne pro `help`)
- **Results caching**: `@results ||= monitor.run_all` — checky běží max jednou per instanci
- **Error handling**: `dispatch` zachytí výjimky a vrátí user-friendly chybovou zprávu

#### Parsování mention textu

Mastodon mention HTML: `<span class="h-card"><a href="...">@<span>udrzbot</span></a></span> status`

Po `HtmlCleaner.clean`: `@ udrzbot status` (tag → space)

Regex: `/@\s*udrzbot(?:\s*@\s*[^\s]+)?\s*/i` → výsledek: `status`

#### State Management

```json
// logs/health/command_listener_state.json
{
  "last_notification_id": "12345",
  "updated_at": "2026-02-08T14:30:00+01:00"
}
```

### Bezpečnostní vlastnosti

| Vlastnost | Popis |
|-----------|-------|
| **Lockfile** | `tmp/command_listener.lock` — `flock(LOCK_NB \| LOCK_EX)` prevence overlapping runs |
| **Whitelist** | Pouze účty z `allowed_accounts` configu mohou posílat příkazy |
| **Rate limiting** | Max `rate_limit_per_cycle` příkazů per účet per cyklus |
| **DM odpovědi** | `visibility: 'direct'` — odpovědi vidí jen odesílatel |
| **Tiché dismiss** | Neautorizované mentions se tiše dismissnou (bez odpovědi) |
| **První spuštění** | Nastaví cursor bez procesování historických mentions |

### Mastodon API requirements

Token `ZPRAVOBOT_MONITOR_TOKEN` musí mít scopes:

| Scope | Účel |
|-------|------|
| `read:notifications` | Polling mentions |
| `write:notifications` | Dismiss notifikací |
| `write:statuses` | Odpovědi (DM) |
| `read:accounts` | Verifikace účtu |
| `read:statuses` | Čtení mention obsahu |

### Dlouhé odpovědi (splitting)

Odpovědi delší než 2400 znaků se automaticky dělí na chunky a posílají jako thread:

1. Split na hranici řádku (max 2400 chars per chunk)
2. První chunk: `in_reply_to_id` = originální mention
3. Další chunky: `in_reply_to_id` = předchozí odpověď (thread)

### Příklad interakce

```
Uživatel: @udrzbot status

Údržbot (DM):
✅ System OK (14:30)

✅ Server: CPU 0.49 | Disk 35% | RAM 1212MB free | Swap OK
✅ Log Errors: Žádné chyby/h
✅ Webhook Server: OK (uptime 5d 3h)
✅ Nitter Instance: OK (Dostupný)
✅ Nitter Accounts: Žádné account-related chyby
✅ IFTTT Queue: Prázdná (0 failed)
✅ Processing: Všechny subsystémy OK
✅ Mastodon API: OK (Zprávobot.news)
⚠️ Problematic Sources: 2 zdrojů vyžaduje pozornost
```

---

## broadcast.rb

### Umístění
`bin/broadcast.rb` (CLI entry point) → `lib/broadcast/` (4 moduly)

### Účel

Hromadné zasílání zpráv na všechny nebo vybrané Mastodon účty. Podporuje interaktivní i neinteraktivní režim, média, dry-run a graceful shutdown.

### Použití

```bash
# Interaktivní režim (multiline vstup, end s prázdným řádkem)
ruby bin/broadcast.rb

# Neinteraktivní
ruby bin/broadcast.rb --message "Údržba systému 14:00-15:00"

# Preview (bez odeslání)
ruby bin/broadcast.rb --message "..." --dry-run

# Cílení
ruby bin/broadcast.rb --target all                       # Všechny účty
ruby bin/broadcast.rb --target zpravobot                 # Jen zpravobot.news (default)
ruby bin/broadcast.rb --account betabot                  # Konkrétní účet
ruby bin/broadcast.rb --account betabot,enkocz           # Více účtů

# S přílohou
ruby bin/broadcast.rb --message "..." --media img.png --alt "Popis obrázku"

# Viditelnost
ruby bin/broadcast.rb --message "..." --visibility unlisted

# Testovací prostředí
ruby bin/broadcast.rb --message "..." --test
```

### Přepínače

| Přepínač | Popis |
|----------|-------|
| `--message TEXT` | Text zprávy (bez = interaktivní) |
| `--target TARGET` | `zpravobot` (default) nebo `all` |
| `--account ID,...` | Konkrétní účty (přepíše `--target`) |
| `--visibility VIS` | `public` (default), `unlisted`, `direct` |
| `--media FILE` | Cesta k příloze (max 10MB) |
| `--alt TEXT` | Alt text pro přílohu |
| `--dry-run` | Preview bez odeslání |
| `--test` | Testovací prostředí |
| `-h, --help` | Nápověda |

### Exit kódy

| Kód | Význam |
|-----|--------|
| 0 | Úspěch (vše odesláno) |
| 1 | Částečné selhání (některé účty selhaly) |
| 2 | Chyba argumentů / validace |
| 4 | Fatální chyba |
| 130 | SIGINT (graceful shutdown) |

### Architektura

```
bin/broadcast.rb                      # CLI (OptionParser, signal handling)
lib/broadcast/broadcaster.rb          # Core engine (385 LOC)
lib/broadcast/broadcast_logger.rb     # Separátní logger
config/broadcast.yml                  # Konfigurace
```

### Konfigurace (`config/broadcast.yml`)

```yaml
blacklist:                    # Účty vyloučené z broadcastu
  - some_account
throttle:
  delay_seconds: 0.5          # Pauza mezi účty (default)
retry:
  max_attempts: 3              # Max retry pokusů (default)
  backoff_base: 2              # Exponenciální backoff (default)
default_target: zpravobot      # Default cíl
default_visibility: public     # Default viditelnost
```

### Klíčové vlastnosti

| Vlastnost | Popis |
|-----------|-------|
| **Account resolution** | Čte `mastodon_accounts.yml`, filtruje dle target/blacklist |
| **Retry** | Exponenciální backoff (2^attempt), max 3 pokusů |
| **Throttling** | Konfigurovatelná pauza mezi účty (default 0.5s) |
| **Progress bar** | Vizuální progress s failed counter |
| **Graceful shutdown** | SIGINT/SIGTERM → dokončí aktuální účet, zastaví |
| **Logging** | `logs/broadcast_YYYYMMDD.log` (per-session, per-account) |
| **Media** | Soubor se přečte jednou, content type detekce, upload per account |

---

## process_broadcast_queue.rb

### Umístění
`bin/process_broadcast_queue.rb` (cron entry point) → `lib/broadcast/tlambot_queue_processor.rb`

### Účel

Zpracovává broadcast joby z fronty, které byly vytvořeny Mastodon webhookem z účtu @tlambot. Navrženo pro cron invokaci každou minutu.

### Použití

```bash
# Zpracovat frontu (cron)
ruby bin/process_broadcast_queue.rb
```

### Cron

Skript je spouštěn jako součást `cron_command_listener.sh` (každých 5 minut), nikoliv jako samostatný cron job:

```cron
# Spouští udrzbot + tlambot dohromady
*/5 * * * * /app/data/zbnw-ng/cron_command_listener.sh
```

### Architektura

```
Mastodon webhook (status.created z @tlambot)
    │
    ▼
TlambotWebhookHandler
    │ HMAC-SHA256 verifikace
    │ Mention-based routing
    │ HTML → plain text
    │ Media extraction
    ▼
queue/broadcast/pending/*.json
    │
    ▼ (cron 1x/min)
TlambotQueueProcessor
    │ Parse job → resolve accounts
    │ Publish per account (s retry)
    │ Favourite source status
    ▼
queue/broadcast/processed/ | failed/
```

### Mention-based routing

| Mentions v @tlambot postu | Broadcast cíl |
|---------------------------|---------------|
| Žádné (jen @tlambot) | Všechny účty |
| @zpravobot | Pouze účty na zpravobot.news |
| @jedenbot | Konkrétní účet |
| @jedenbot @druhy | Více konkrétních účtů |

Všechny @mentions se automaticky odstraní z textu broadcastu.

### Queue adresáře

```
queue/broadcast/
├── pending/    # Nezpracované joby (JSON)
├── processed/  # Úspěšně zpracované
└── failed/     # Selhavší (JSON parse error, fatal error)
```

### Konfigurace (`config/broadcast.yml` — sekce tlambot)

```yaml
tlambot:
  trigger_account: tlambot        # Účet spouštějící broadcasty
  broadcast_visibility: public    # Override viditelnosti z webhooku
```

### Environment Variables

| Proměnná | Popis |
|----------|-------|
| `TLAMBOT_WEBHOOK_SECRET` | HMAC-SHA256 secret pro verifikaci webhooků |
| `BROADCAST_QUEUE_DIR` | Override adresáře fronty (default: `queue/broadcast`) |

### Klíčové vlastnosti

| Vlastnost | Popis |
|-----------|-------|
| **HMAC verifikace** | `X-Hub-Signature: sha256=...` constant-time comparison |
| **Favourite** | Po úspěšném broadcastu označí source status jako favourite |
| **Blacklist** | Automaticky vyloučí blacklisted účty + tlambot sám sebe |
| **Media z URL** | Stahuje média z webhook payloadu (max 4 per post) |
| **Visibility override** | Broadcast visibility se řídí konfigurací, ne zdrojovým postem |

---

## analyze_domain_fixes.rb

### Umístění
`scripts/analyze_domain_fixes.rb`

### Účel

Analyzuje Twitter a Bluesky zdrojové soubory a navrhuje/aplikuje `url_domain_fixes` — seznam domén, kterým se v textu postu automaticky doplní `https://` (typicky Bluesky posty s holými doménami jako `denikn.cz/clanek`).

Data extrahuje ze dvou zdrojů:
1. **`web:` pole Mastodon profilu** — nejspolehlivější zdroj (přímo doména webu účtu)
2. **Bio text profilu** — holé domény zapsané v popisu účtu

Domény již pokryté globálně v `config/global.yml` → `url.no_trim_domains` se automaticky vynechávají.

### Použití

```bash
# 1. Analyzuj — stáhne profily z Mastodon API, uloží doporučení
ruby scripts/analyze_domain_fixes.rb analyze

# 2. Zkontroluj výsledky
cat output/domain_fixes_recommendations.yml

# 3. Aplikuj doporučení do yml souborů
ruby scripts/analyze_domain_fixes.rb apply [--dry-run]

# 4. Vyčisti domény globálně pokryté v global.yml
ruby scripts/analyze_domain_fixes.rb cleanup [--dry-run]

# Nebo vše najednou
ruby scripts/analyze_domain_fixes.rb all [--dry-run]
```

### Přepínače

| Přepínač | Popis |
|----------|-------|
| `--platform twitter\|bluesky` | Omezit na konkrétní platformu (výchozí: oboje) |
| `--source ID` | Zpracovat jen jeden zdroj (mastodon_account nebo ID bez přípony) |
| `--dry-run` | Pouze výpis, bez zápisu do souborů |

```bash
# Příklady
ruby scripts/analyze_domain_fixes.rb analyze --platform bluesky
ruby scripts/analyze_domain_fixes.rb analyze --source enkocz
ruby scripts/analyze_domain_fixes.rb apply --dry-run
ruby scripts/analyze_domain_fixes.rb cleanup --platform twitter
```

### Výstup

- `output/domain_fixes_recommendations.yml` — mezisoubor s doporučeními (vstup pro `apply`)
- Terminálový výpis s přehledem změn

### Workflow

```
analyze → review output/domain_fixes_recommendations.yml → apply → cleanup
```

`analyze` a `cleanup` lze spustit s `--platform` pro dávkové zpracování jen jedné platformy.
`apply` čte vždy celý `domain_fixes_recommendations.yml` bez ohledu na platformu.

### Filtrování domén

Skript automaticky vynechává:
- Domény z `global.yml` → `url.no_trim_domains` (zkracovače, sociální sítě, speciální služby)
- `linktr.ee`, `discord.gg`, `lnk.bio`, `buymeacoffee.com` a podobné agregátory/platební služby
- Domény bez platné TLD nebo kratší než 4 znaky

---

## zpravobot_stats.rb

### Umístění
`bin/zpravobot_stats.rb`

### Účel

Generuje a publikuje týdenní hitparádu Zpravobot botů jako Mastodon thread. Každou neděli vytvoří dva posty: CZ post (odpovídá jako reply na SK post) — oba sdílejí hashtag `#ZpravobotTOP10`.

Post obsahuje:
- **Nejsledovanější boty** — TOP N podle počtu followers
- **Nejaktivnější boty** — TOP N podle počtu postů za uplynulý týden
- **Skokan aktivity** — bot s největším relativním nárůstem postů (min. 20 postů předchozí týden)
- **Skokan followers** — bot s největším absolutním nárůstem sledujících (dostupné od 2. týdne)
- **TOP kategorie** — platformy/kategorie seřazené podle aktivity
- Číslo týdne a datum rozsahu (Po – Ne)

### Použití

```bash
# Dry run — vytiskne náhled na stdout bez publikace
ruby bin/zpravobot_stats.rb

# Publikovat CZ+SK thread
ruby bin/zpravobot_stats.rb --publish

# Uložit snapshot do DB, bez generování postu
ruby bin/zpravobot_stats.rb --snapshot-only

# Pouze CZ nebo SK post
ruby bin/zpravobot_stats.rb --publish --lang cz
ruby bin/zpravobot_stats.rb --publish --lang sk

# Override čísla týdne (pro zpětné generování)
ruby bin/zpravobot_stats.rb --week 12 --publish

# Jiný publisher účet
ruby bin/zpravobot_stats.rb --publish --account betabot

# Testovací schéma (zpravobot_test)
ruby bin/zpravobot_stats.rb --test
```

### Přepínače

| Přepínač | Default | Popis |
|----------|---------|-------|
| `--publish` | `false` | Publikovat thread přes Mastodon API |
| `--snapshot-only` | `false` | Uložit snapshot do DB, nevytvářet post |
| `--week N` | aktuální ISO týden | Override čísla týdne |
| `--account ID` | `betabot` | Mastodon účet pro publikaci |
| `--lang cz\|sk` | oba | Generovat jen jeden jazykový post |
| `--test` | `false` | Použít schéma `zpravobot_test` |

### Publisher účet

Priorita:
1. `--account` CLI flag
2. ENV proměnná `ZPRAVOBOT_STATS_ACCOUNT`
3. výchozí: `betabot`

### Cron

```bash
# Cloudron cron — každou neděli v 20:00
0 20 * * 0  cd /app/data/zbnw-ng && ruby bin/zpravobot_stats.rb --publish 2>&1 >> logs/stats.log
```

### Architektura

```
bin/zpravobot_stats.rb          # CLI entry point (OptionParser, 11 kroků)
lib/stats/snapshot_store.rb     # Uložení a načítání týdenních snapshotů (DB: account_stats_snapshot)
lib/stats/publishing_stats.rb   # Statistiky publikování z DB (per-account, per-category)
lib/stats/mastodon_stats.rb     # Fetch account stats z Mastodon API (followers, statuses)
lib/stats/skokan_detector.rb    # Detekce největšího pohybu (aktivita + followers)
lib/stats/stats_post_formatter.rb # Formátování textu hitparády (auto-truncate TOP10→5→3)
```

### DB tabulka

`account_stats_snapshot` (migrace `db/patch_add_stats_snapshot.sql`):

| Sloupec | Typ | Popis |
|---------|-----|-------|
| `account_id` | VARCHAR | Mastodon account ID |
| `snapshot_date` | DATE | Datum snapshotu |
| `followers` | INTEGER | Počet sledujících |
| `statuses` | INTEGER | Celkový počet statusů |
| `posts_week` | INTEGER | Postů publikovaných tento týden |

Unikátní index na `(account_id, snapshot_date)` — upsert bezpečný.

### Auto-truncate

Pokud post přesáhne 2 500 znaků (limit instance zpravobot.news), `StatsPostFormatter` automaticky zkrátí pořadí: **TOP 10 → TOP 5 → TOP 3**. Pokud ani TOP 3 nevejde, vyhodí `RuntimeError`.

### Zpracování jazykových skupin

Skripta mapuje zdroje na jazykové skupiny (CZ/SK) podle pole `language:` v source YAML. Zdroje bez `language:` jsou implicitně `cs`. Post se generuje separátně pro každou skupinu a publikuje jako thread (SK reply na CZ post).

---

## trending_post.rb

### Umístění
`bin/trending_post.rb`

### Účel

Fetchuje trending statusy z Mastodon API (`/api/v1/trends/statuses`) a pro každý dosud neanoncovaný status publikuje quote post z účtu `@zpravobot`. Udržuje state v JSON souboru, aby se stejný status necitoval víckrát.

### Použití

```bash
# Normální běh — zkontrolovat trendy a případně citovat
ruby bin/trending_post.rb

# Dry run — výpis co by se citovalo, bez publikace
ruby bin/trending_post.rb --dry-run

# Testovací konfigurace
ruby bin/trending_post.rb --test
```

### Přepínače

| Přepínač | Popis |
|----------|-------|
| `--dry-run` | Náhled bez HTTP POST |
| `--test` | Načíst config z testovacího adresáře |
| `-h, --help` | Nápověda |

### Token pro @zpravobot

Priorita:
1. ENV `ZBNW_MASTODON_TOKEN_ZPRAVOBOT`
2. ENV `ZPRAVOBOT_REPORT_TOKEN`
3. `mastodon_accounts.yml` → klíč `:zpravobot` → `:token`

### State soubor

`data/trending_state.json` (override: ENV `ZBNW_TRENDING_STATE`):

```json
{
  "announced_ids": ["123456789", "987654321"],
  "last_check_at": "2026-03-30T14:00:00+02:00",
  "last_post_at": "2026-03-30T14:00:05+02:00"
}
```

FIFO rotace: uchovává maximálně 200 posledních ID. Soubor se vytvoří automaticky při prvním běhu.

### Logika filtrování

- Přeskočí statusy od `betabot`, `udrzbot`, `tlambot`
- Přeskočí vlastní trending quote posty `@zpravobot` (quote field není nil)
- Max 5 quote postů za jeden běh (`MAX_POSTS_PER_RUN`)
- 2s throttle mezi posty

### Format quote postu

```
📈 Na Zprávobot.news právě trenduje

#zpravobot #trending
```

### Cron

```bash
# Cloudron cron — každou hodinu v :45
45 * * * * /app/data/zbnw-ng/cron_trending.sh
```

`cron_trending.sh` nastaví env a spustí skript.

### Architektura

```
bin/trending_post.rb               # CLI entry point
lib/trending/trending_checker.rb   # Core logika (fetch → filter → publish)
data/trending_state.json           # Persistentní state (announced_ids, last_check_at)
```

---

## log_report.rb

### Umístění
`bin/log_report.rb`

### Účel

Parsuje logy zbnw-ng a vrací strukturovaný JSON na stdout. Určen ke spuštění na prod serveru — klient si výstup stáhne a provede analýzu (žádné závislosti na DB ani lib/).

### Použití

```sh
ruby bin/log_report.rb                                          # včera 07:00 → dnes 07:00
ruby bin/log_report.rb --date 2026-04-16                        # konkrétní den (07:00 → +1 07:00)
ruby bin/log_report.rb --hours 12                               # posledních 12 hodin
ruby bin/log_report.rb --from "2026-04-16 08:00" --to "2026-04-16 20:00"
ruby bin/log_report.rb --pretty                                 # odsazený JSON
```

### Výstupní struktura JSON

| Klíč | Popis |
|------|-------|
| `window.from/to` | Parsované časové okno |
| `summary.runner_published` | Součet `published:` z `[Runner] Run complete` řádků |
| `summary.ifttt_published` | Součet `published:` z `Queue processing complete` řádků |
| `summary.total` | runner + ifttt published celkem |
| `summary.runner_errors` | Součet `errors:` z `[Runner] Run complete` řádků |
| `summary.runner_warnings` | Počet `WARN:` řádků v runner logu |
| `summary.ifttt_errors` | Skutečné chyby IFTTT (bez `deleted_original`) |
| `summary.ifttt_queue_skipped_total` | Catch-all `skipped:` z Queue processing complete — zahrnuje video_dedup, content filter (reposts/replies), already_published, no_config, older_version |
| `summary.ifttt_failed` | Počet webhooků přesunutých do `failed/` |
| `platforms.<platform>` | `published`, `errors`, `error_rate` pro každou platformu (twitter = IFTTT, ostatní = runner) |
| `ifttt_events` | `video_dedup_skipped`, `video_fallback_thumb`, `repost_corrections`, `edit_skipped`, `media_size_skipped` |
| `ifttt_skips` | `deleted_original` (HTTP 404 + Status not found), `duplicate_post` (pouze při `DEBUG=1`) |
| `top_runner_errors` | Top 10 chybových zpráv z runner logu s počtem výskytů |
| `top_ifttt_errors` | Top 5 chybových zpráv z IFTTT logu s počtem výskytů |
| `profile_sync` | Pole per platformu: `type`, `last_run`, `synced`, `skipped`, `errors` |

### Logy

Čte z `logs/` (fallback: `log/`), jen soubory s `.log` příponou:

| Soubor | Obsah |
|--------|-------|
| `runner_YYYYMMDD.log` | Runner (RSS/FB/IG/YT/Bluesky) |
| `ifttt_processor_YYYYMMDD.log` | Twitter webhook zpracování |
| `profile_sync_YYYYMMDD.log` | Denní profile sync (všechny platformy) |
| `profile_sync_<platform>.log` | Platform-specific sync (appendovaný, více běhů) |

---

## Shrnutí

| Nástroj | Účel | Spouštění |
|---------|------|-----------|
| `run_tests.rb` | Centrální test runner + Markdown report | Manuálně |
| `create_source.rb` | Interaktivní vytvoření nového zdroje + DB init | Manuálně |
| `manage_source.rb` | Pause/resume/retire/status/probe zdrojů (lifecycle) | Manuálně |
| `force_update_source.rb` | Reset source pro okamžité zpracování | Manuálně |
| `retry_failed_queue.rb` | Opakování selhavších IFTTT webhooků | Cron (0 * * * *) |
| `health_monitor.rb` | Monitoring a alerting (11 checků) | Cron + manuálně |
| `command_listener.rb` | Interaktivní příkazy přes Mastodon mentions | Cron (*/5) + manuálně |
| `broadcast.rb` | Hromadné publikování zpráv na Mastodon účty | Manuálně |
| `process_broadcast_queue.rb` | Zpracování tlambot broadcast fronty | Cron (*/5 via listener) |
| `analyze_domain_fixes.rb` | Analýza a aktualizace `url_domain_fixes` u Twitter/Bluesky zdrojů | Manuálně |
| `zpravobot_stats.rb` | Týdenní hitparáda #ZpravobotTOP10 (CZ+SK thread) | Cron (0 20 * * 0) |
| `trending_post.rb` | Quote posty pro trendující statusy na zpravobot.news | Cron (45 * * * *) |
| `friendly_follow.rb` | Denní #FF post doporučující 3 účty z zpravobot.news | Cron (15 15/16 * * *) |
| `source_report.rb` | Auto-detekce změn v mastodon_accounts.yml, post na @zpravobot | Cron (denně) |
| `sync_profiles.rb` | Sync avataru/banneru/bio ze zdrojových platforem do Mastodonu | Cron (weekly rotace) |
| `cleanup_orphaned_accounts.rb` | Detekce osiřelých účtů bez aktivního zdroje | Manuálně |
| `cleanup_duplicate_posts.rb` | Odstranění duplicitních postů (schema migrace) | Manuálně (jednorázově) |
| `log_report.rb` | Strukturovaný JSON report z logů prod serveru | Manuálně (on-demand) |

### Health Check Přehled

| # | Check | Co sleduje | Warning | Critical |
|---|-------|-----------|---------|----------|
| 1 | Server | CPU, Disk, RAM, Swap | Load≥2, Disk≥80%, RAM<500MB, SwapIO≥100 | Load≥4, Disk≥95%, RAM<200MB, SwapIO≥500 |
| 2 | Log Errors | Chyby v logs/h | ≥20 chyb/h | ≥50 chyb/h |
| 3 | Webhook Server | HTTP health | HTTP != 200 | Connection error |
| 4 | Nitter Instance | HTTP + HTML check | Degraded | Connection error |
| 5 | Nitter Accounts | Account errors/h | >3 chyb | >10 chyb |
| 6 | IFTTT Queue | Pending/failed files | Stale, >10 failed | >100 pending |
| 7 | Processing | DB activity | Viz sub-checky | - |
| 8 | Mastodon API | HTTP /api/v1/instance | HTTP != 200 | Connection error |
| 9 | Problematic Sources | source_state errors, @mentions | ≥5 chyb | - |
| 10 | Recurring Warnings | Opakující se WARN patterny/h | ≥10 opakování | - |
| 11 | Runner Health | Cron runner stav a crashe | Stale >30min, ≥3 crashe | Stale >60min, žádný úspěch |

### Souvislosti s dalšími komponentami

- **run_tests.rb** spouští testovací skripty z `test/` přes subprocess, parsuje výstup a generuje reporty do `tmp/`
- **create_source.rb** vytváří konfigurace používané **Orchestrátorem** a **ConfigLoaderem**, a inicializuje **source_state** v databázi
- **force_update_source.rb** manipuluje **source_state** tabulkou používanou **StateManagerem**
- **health_monitor.rb** kontroluje **Server resources**, **Logy**, **Webhook Server** (`ifttt_webhook.rb`), **Nitter**, **Queue**, **Processing** a **Mastodon API**
- **command_listener.rb** využívá **HealthMonitor** a **HealthChecks** z `health_monitor.rb`, **MastodonPublisher** pro DM odpovědi, a **HtmlCleaner** pro parsování mention textu
- **broadcast.rb** využívá **ConfigLoader** pro mastodon accounts, **MastodonPublisher** pro publish/media upload, **UiHelpers** pro interaktivní režim
- **manage_source.rb** manipuluje `enabled` v YAML a `disabled_at` v **source_state** tabulce přes **SourceManager**; `status` zobrazuje pauzované zdroje, `probe` spouští dry-run orchestrátor a při úspěchu nabídne resume; init_time wizard při resume
- **retry_failed_queue.rb** čte soubory z `queue/ifttt/failed/`, spolupracuje s **IftttQueueProcessor** (`retry_count` v JSON) a **QueueCheck** (DEAD_ soubory)
- **process_broadcast_queue.rb** využívá **TlambotWebhookHandler** pro parsing webhook payloadů, **Broadcaster** pro account resolution, **MastodonPublisher** pro publish a favourite
- **analyze_domain_fixes.rb** čte `config/sources/*_twitter.yml` a `*_bluesky*.yml`, volá Mastodon API (`/api/v1/accounts/lookup`), spolupracuje s `config/global.yml` (no_trim_domains) a zapisuje do `output/domain_fixes_recommendations.yml`
- **zpravobot_stats.rb** čte všechny source configs přes **ConfigLoader** (jazykové skupiny), fetchuje Mastodon API stats přes **MastodonStats**, čte DB přes **PublishingStats** + **SnapshotStore**, detekuje skoky přes **SkokanDetector**, formátuje přes **StatsPostFormatter** a publikuje přes **MastodonPublisher**
- **trending_post.rb** fetchuje `/api/v1/trends/statuses` z zpravobot.news, udržuje state v `data/trending_state.json`, publikuje quote posty přes **TrendingChecker** z účtu `@zpravobot`
- **friendly_follow.rb** vybírá 3 účty z mastodon_accounts.yml, fetchuje jejich display name + bio přes Mastodon API, udržuje state v `data/ff_state.json`, publikuje #FF post přes **FriendlyFollow** z `@zpravobot`
- **source_report.rb** porovnává aktuální `mastodon_accounts.yml` se snapshotem v `data/source_report_snapshot.yml`, detekuje přidané/odebrané zdroje, publikuje přes **SourceReporter** + **MastodonPublisher** z `@zpravobot`
- **sync_profiles.rb** iteruje enabled zdroje, deleguje na platformově specifické syncery (**BlueskyProfileSyncer**, **FacebookProfileSyncer**, **InstagramProfileSyncer**, **YoutubeProfileSyncer**, **TwitterProfileSyncer**); weekly rotace skupin pro Twitter (hash-based split do 3 skupin)
- **cleanup_orphaned_accounts.rb** prochází `mastodon_accounts.yml` a ověřuje existenci aktivního zdroje v `config/sources/`; `--fix` nabídne interaktivní smazání
- **cleanup_duplicate_posts.rb** jednorázový cleanup po schema migraci `zpravobot_test → zpravobot` (2026-03-27); `--delete` skutečně maže, `--since` filtruje rozsah
- **log_report.rb** parsuje `logs/runner_YYYYMMDD.log`, `logs/ifttt_processor_YYYYMMDD.log` a `logs/profile_sync_*.log`; výstup jde čistě na stdout jako JSON; žádné závislosti na DB ani lib/

---

## Poznámky k údržbě dokumentace

Tento dokument aktualizovat při:
- Změně CLI argumentů nebo chování kteréhokoliv nástroje
- Přidání nového health checku
- Změně konfiguračních konstant nebo thresholdů
- Přidání nových environment variables
- Změně formátu alertů nebo reportů
- Přidání/odebrání testů v `config/test_catalog.yml`
