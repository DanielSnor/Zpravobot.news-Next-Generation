# CLI nástroje ZBNW‑NG

Tento dokument popisuje **CLI (command-line) nástroje** pro manuální práci se systémem ZBNW‑NG.

CLI je podpůrná vrstva — spouští stejné runtime komponenty jako scheduler, ale manuálně.
Viz [`runtime.md`](runtime.md) pro přehled automatického běhu.

Použité pojmy jsou definovány v [`../00-overview/terminologie.md`](../00-overview/terminologie.md).

---

## Role CLI

CLI slouží pro:

- **manuální spouštění pipeline** — ověření po změně kódu, ad-hoc fetch jednoho zdroje
- **správu zdrojů** — vytváření, pozastavení, reset stavu
- **diagnostiku** — přehled logů, snapshot stavu instance, retry selhavších operací

CLI spouští stejné runtime komponenty jako scheduler, ale ručně a výběrově.
Normální provoz zajišťuje scheduler automaticky — CLI je pro výjimečné situace, debug a onboarding.

---

## Přehled nástrojů

| Nástroj | Umístění | Účel |
|---|---|---|
| `run_zbnw.rb` | `bin/` | Hlavní orchestrator runner |
| `sync_profiles.rb` | `bin/` | Profile synchronizace |
| `create_source.rb` | `bin/` | Interaktivní průvodce vytvořením zdroje |
| `manage_source.rb` | `bin/` | Správa životního cyklu zdrojů (pause/resume/retire) |
| `force_update_source.rb` | `bin/` | Reset source state (vynutí zpracování při příštím běhu) |
| `retry_failed_queue.rb` | `bin/` | Ruční opakování selhavších IFTTT webhooků |
| `health_monitor.rb` | `bin/` | Monitoring infrastruktury (Údržbot) |
| `command_listener.rb` | `bin/` | Interaktivní příkazy přes Mastodon mentions (Údržbot) |
| `broadcast.rb` | `bin/` | Hromadná zpráva na Mastodon účty (Tlambot) |
| `process_broadcast_queue.rb` | `bin/` | Cron processor Tlambot fronty (spouštěn z `cron_command_listener.sh`) |
| `run_tests.rb` | `bin/` | Centrální test runner |
| `log_report.rb` | `bin/` | Strukturovaný report z logů |
| `instance_status.rb` | `bin/` | One-shot JSON snapshot stavu instance |
| `zpravobot_stats.rb` | `bin/` | Týdenní digest #ZpravobotTOP10 |
| `trending_post.rb` | `bin/` | Automatické quote posty pro trendy |
| `analyze_domain_fixes.rb` | `scripts/` | Analýza a doplnění `url_domain_fixes` dle Mastodon profilů |

---

## Orchestrator (`run_zbnw.rb`)

Hlavní runner pro spuštění pipeline.

```bash
# Všechny platformy
ruby bin/run_zbnw.rb

# Konkrétní platforma
ruby bin/run_zbnw.rb --platform bluesky

# Vyloučit platformu
ruby bin/run_zbnw.rb --exclude-platform twitter

# Konkrétní zdroj
ruby bin/run_zbnw.rb --source ct24_twitter

# Bez publikace
ruby bin/run_zbnw.rb --dry-run

# Testovací schema
ruby bin/run_zbnw.rb --test
```

---

## Profile sync (`sync_profiles.rb`)

```bash
# Konkrétní platforma
ruby bin/sync_profiles.rb --platform bluesky
ruby bin/sync_profiles.rb --platform twitter --group 0

# Bez zápisu
ruby bin/sync_profiles.rb --platform bluesky --dry-run
```

---

## Správa zdrojů

### `create_source.rb` — nový zdroj

Interaktivní průvodce pro vytvoření konfiguračního YAML souboru a inicializaci záznamu v DB.

```bash
ruby bin/create_source.rb          # Plný průvodce
ruby bin/create_source.rb --quick  # Pouze povinné údaje
ruby bin/create_source.rb --test   # Testovací prostředí
```

Průvodce pokrývá: platformu, handle/feed_url/channel_id, Mastodon účet, filtering, scheduling, profile sync, inicializační čas. Po dokončení automaticky vytvoří záznam v `source_state`.

### `manage_source.rb` — životní cyklus

```bash
ruby bin/manage_source.rb --source ct24_twitter --pause
ruby bin/manage_source.rb --source ct24_twitter --resume
ruby bin/manage_source.rb --source ct24_twitter --retire
```

### `force_update_source.rb` — reset stavu

Vynuluje `last_check` v DB, takže zdroj bude zpracován při příštím cron běhu.

```bash
ruby bin/force_update_source.rb ct24_twitter
```

---

## IFTTT queue

### `retry_failed_queue.rb` — ruční retry

Přesune soubory z `queue/ifttt/failed/` zpět do `pending/` pro zpracování.
Soubory s prefixem `DEAD_` jsou přeskočeny (trvalý archiv).

```bash
ruby bin/retry_failed_queue.rb
```

---

## Testování (`run_tests.rb`)

Centrální test runner s reportem v Markdown.

```bash
ruby bin/run_tests.rb              # Výchozí: offline unit testy
ruby bin/run_tests.rb --unit       # Unit testy (offline)
ruby bin/run_tests.rb --network    # Síťové testy (vyžadují internet)
ruby bin/run_tests.rb --db         # DB testy (vyžadují PostgreSQL)
ruby bin/run_tests.rb --e2e        # E2E (interaktivní, publikuje)
ruby bin/run_tests.rb --all        # unit + network + db
ruby bin/run_tests.rb --file edit  # Filtr dle názvu souboru
ruby bin/run_tests.rb --tag bluesky # Filtr dle tagu
ruby bin/run_tests.rb --list       # Jen vypsat, nespouštět
```

Testy jsou registrované v `config/test_catalog.yml` s metadaty (kategorie, tagy, timeout).
Report se generuje do `tmp/test_report_YYYYMMDD_HHMMSS.md`.

### Kategorie testů

| Kategorie | Počet | Závislosti |
|---|---|---|
| `unit` | ~77 | Žádné (offline) |
| `network` | ~18 | Internet (API, Nitter, RSS, YouTube) |
| `db` | ~2 | PostgreSQL |
| `e2e` | ~6 | Mastodon credentials (publikuje) |

---

## Diagnostika

### `log_report.rb` — report z logů

```bash
ruby bin/log_report.rb             # Agregovaný report
ruby bin/log_report.rb --source ct24_twitter  # Slim report pro jeden zdroj
```

### `instance_status.rb` — snapshot instance

One-shot JSON výstup stavu instance: disk, runner log, queue size, Nitter, DB schema.
Vhodné pro out-of-band health check přes SSH.

```bash
ruby bin/instance_status.rb
```

---

## Správa URL domain fixes (`analyze_domain_fixes.rb`)

Bluesky posty z některých zdrojů obsahují holé domény bez protokolu (`denikn.cz/clanek`).
`url_domain_fixes` v source YAML říká systému, pro které domény doplnit `https://`.

`analyze_domain_fixes.rb` tuto konfiguraci automatizuje — stáhne Mastodon profily zdrojů
a navrhne/aplikuje `url_domain_fixes` dle `web:` pole nebo bio.

```bash
# 1. Analyzuj — stáhne profily, uloží doporučení do output/domain_fixes_recommendations.yml
ruby scripts/analyze_domain_fixes.rb analyze

# 2. Aplikuj doporučení do YAML souborů zdrojů
ruby scripts/analyze_domain_fixes.rb apply [--dry-run]

# 3. Vyčisti domény globálně pokryté v global.yml
ruby scripts/analyze_domain_fixes.rb cleanup [--dry-run]

# Nebo vše najednou
ruby scripts/analyze_domain_fixes.rb all [--dry-run]
```

| Přepínač | Popis |
|---|---|
| `--platform twitter\|bluesky` | Omezit na konkrétní platformu |
| `--source ID` | Zpracovat jen jeden zdroj |
| `--dry-run` | Pouze výpis, bez zápisu |

Domény pokryté globálně v `global.yml → url.no_trim_domains` jsou automaticky vynechány.

---

## Broadcast (`broadcast.rb`)

Hromadné zaslání zprávy na Mastodon účty. Bez `--message` spustí interaktivní režim (multiline vstup ukončený prázdným řádkem).

```bash
# Interaktivní
ruby bin/broadcast.rb

# Zpráva inline
ruby bin/broadcast.rb --message "Údržba systému 14:00–15:00"

# Preview bez odeslání
ruby bin/broadcast.rb --message "..." --dry-run

# Cílení
ruby bin/broadcast.rb --target zpravobot          # Jen zpravobot.news (default)
ruby bin/broadcast.rb --target all                 # Všechny účty
ruby bin/broadcast.rb --account betabot,enkocz     # Konkrétní účty

# S přílohou
ruby bin/broadcast.rb --message "..." --media img.png --alt "Popis"

# Viditelnost
ruby bin/broadcast.rb --message "..." --visibility unlisted
```

| Přepínač | Default | Popis |
|---|---|---|
| `--message TEXT` | — | Text zprávy (bez = interaktivní) |
| `--target TARGET` | `zpravobot` | `zpravobot` nebo `all` |
| `--account ID,...` | — | Konkrétní účty (přepíše `--target`) |
| `--visibility VIS` | `public` | `public`, `unlisted`, `direct` |
| `--media FILE` | — | Cesta k příloze (max 10 MB) |
| `--alt TEXT` | — | Alt text pro přílohu |
| `--dry-run` | — | Preview bez odeslání |
| `--test` | — | Testovací prostředí |

Exit kódy: `0` = vše odesláno, `1` = částečné selhání, `2` = chyba argumentů, `4` = fatální chyba, `130` = SIGINT.

Konfigurace v `config/broadcast.yml` (blacklist, throttle, retry, default_target).

---

## Statistiky (`zpravobot_stats.rb`)

Generuje týdenní hitparádu `#ZpravobotTOP10` jako Mastodon thread (CZ + SK post). Spouštěno automaticky každou neděli v 20:00, ale lze spustit i manuálně.

```bash
# Náhled na stdout bez publikace (default)
ruby bin/zpravobot_stats.rb

# Publikovat thread
ruby bin/zpravobot_stats.rb --publish

# Jen snapshot do DB, bez generování postu
ruby bin/zpravobot_stats.rb --snapshot-only

# Jeden jazyk
ruby bin/zpravobot_stats.rb --publish --lang cz
ruby bin/zpravobot_stats.rb --publish --lang sk

# Zpětné generování konkrétního týdne
ruby bin/zpravobot_stats.rb --week 12 --publish
```

| Přepínač | Default | Popis |
|---|---|---|
| `--publish` | `false` | Publikovat přes Mastodon API |
| `--snapshot-only` | `false` | Uložit snapshot, nevytvářet post |
| `--week N` | aktuální ISO týden | Override čísla týdne |
| `--account ID` | `betabot` | Mastodon účet pro publikaci |
| `--lang cz\|sk` | oba | Generovat jen jeden jazykový post |
| `--test` | `false` | Použít schéma `zpravobot_test` |

---

## Trendy (`trending_post.rb`)

Fetchuje trending statusy z Mastodon API a pro každý dosud neanoncovaný status publikuje quote post z účtu `@zpravobot`. State se persistuje v `data/trending_state.json`. Spouštěno automaticky každou hodinu v :45.

```bash
# Normální běh
ruby bin/trending_post.rb

# Náhled bez publikace
ruby bin/trending_post.rb --dry-run
```

---

## Kdy CLI použít

| Situace | Nástroj |
|---|---|
| Ověřit funkčnost po změně kódu | `run_zbnw.rb --dry-run` |
| Zpracovat jeden zdroj izolovaně | `run_zbnw.rb --source <id>` |
| Zdroj je zaseknutý (ignoruje nové posty) | `force_update_source.rb <id>` |
| Přidat nový bot | `create_source.rb` |
| Zkontrolovat zdraví systému | `health_monitor.rb --details` |
| Spustit testy | `run_tests.rb` |

CLI není určeno pro běžný provoz — ten řeší scheduler (viz [`runtime.md`](runtime.md)).
