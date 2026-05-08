# Monitoring ZBNW‑NG

Tento dokument popisuje **monitoring a sledování stavu systému ZBNW‑NG**.

Monitoring odpovídá na otázku:

> „je systém zdravý a funguje, jak má?“

---

## Přehled

Monitoring sleduje:

- běh systému (pipeline)
- publikaci obsahu
- stav zdrojů
- stav queue
- základní výkon a stabilitu

Monitoring je:

- doplňková vrstva (neblokuje systém)
- nezávislá na core pipeline
- založená na logách a kontrolách stavu

Monitoring může být realizován jako samostatné běhy v runtime vrstvě
(viz [`runtime.md`](runtime.md)), ale z pohledu architektury je považován
za **oddělenou pozorovací vrstvu** — existuje mimo tok dat, neovlivňuje ho.

---

## 1. Co se monitoruje

| Oblast | OK stav | Problém |
|---|---|---|
| Běh pipeline | Pravidelné cron běhy, žádné fatální chyby | Nespouští se, padá opakovaně |
| Publikace obsahu | Publikace odpovídá aktivitě zdrojů | Dlouhá pauza bez publikace |
| Stav zdrojů | Jednotlivé chyby jsou normální | Zdroj selhává dlouhodobě nebo více zdrojů naráz |
| IFTTT queue | Backlog stabilní, nízká latence | Fronta roste, stale pending soubory |
| Chyby pipeline | Sporadické chyby | Opakující se vzor, stejná chyba napříč zdroji |
| Serverové zdroje | CPU/RAM/disk v normálu | Vysoký disk, nízká RAM, aktivní swap |

---

## 2. Údržbot — monitoring systém

Monitoring v ZBNW‑NG je realizován nástrojem **Údržbot** (`bin/health_monitor.rb`).

Údržbot provádí **11 zdravotních checků** a posílá alerty na Mastodon.
Podrobné CLI viz [`cli.md`](cli.md).

### Health checky

| # | Check | Co kontroluje |
|---|---|---|
| 1 | ServerResources | CPU load, disk utilization, dostupná RAM, swap I/O |
| 2 | LogAnalysis | Error patterny v logu za poslední hodinu |
| 3 | Webhook | Dostupnost IFTTT webhook serveru (`/health` endpoint) |
| 4 | Nitter | Dostupnost Nitter instance (rate limit, suspended) |
| 5 | NitterAccounts | Account-related chyby v activity_log (rate_limit, unauthorized, …) |
| 6 | Queue | Stáří a velikost IFTTT pending fronty, počet failed |
| 7 | Processing | Čas od posledního publish, zdroje s chybami, IFTTT aktivita, activity trend |
| 8 | Mastodon | Dostupnost Mastodon API (`/api/v1/instance`) |
| 9 | ProblematicSources | Top 10 zdrojů s opakovanými chybami nebo dlouhým výpadkem |
| 10 | RecurringWarnings | Opakující se WARN patterny v logu (normalizované) |
| 11 | RunnerHealth | Staleness a po sobě jdoucí crashe cron runneru |

### Alert úrovně

| Ikona | Úroveň | Příklady |
|---|---|---|
| ✅ | OK | Vše funguje v normálu |
| ⚠️ | WARNING | Degradovaný stav (např. Nitter pomaly, queue backlog) |
| ❌ | CRITICAL | Výpadek (webhook server nereaguje, Mastodon nedostupný) |

### Chytré alerting (AlertStateManager)

Údržbot neposílá alert při každém cron běhu — deduplikuje:

- **Nové problémy** → okamžitý alert
- **Přetrvávající problémy** → opakovací interval: 30 min (7:00–23:00) / 60 min (23:00–7:00)
- **Vyřešené problémy** → “resolved” alert po stabilizační době 20 min (2 cykly)

Stav alertů se persistuje v `logs/health/alert_state.json`.

---

## 3. CommandListener — interaktivní monitoring

Druhá část Údržbotu — `bin/command_listener.rb` — polluje Mastodon mentions a odpovídá na příkazy přes DM.

Spouští se každých 5 minut jako cron job (`cron_command_listener.sh`).

### Příkazy

| Příkaz | Výstup |
|---|---|
| `@udrzbot help` | Seznam příkazů |
| `@udrzbot status` | Kompaktní přehled + jednořádkové výsledky všech checků |
| `@udrzbot detail` | Plný report s remediací |
| `@udrzbot heartbeat` | Status + problematické zdroje |
| `@udrzbot sources` | Výpis problematických zdrojů s @mentions |
| `@udrzbot check server` | Detail konkrétního checku (server/webhook/nitter/queue/…) |

---

## 4. Alerting pravidla

### Kritické alerty (❌)

- webhook server nereaguje
- Mastodon API nedostupné
- runner log je starý > 60 min bez úspěchu
- disk využití > 95%

→ akce: okamžitý zásah

### Varovné alerty (⚠️)

- Nitter degradovaný (rate_limit, suspended)
- zdroj selhává opakovaně (error_count ≥ 5)
- queue backlog starý > 30 min nebo > 100 čekajících
- žádná publikace > 60 min
- activity trend pod 80 % baseline

→ akce: analyzovat příčinu, plánovat opravu

---

## 5. Vztah k ostatním nástrojům

Monitoring říká „něco není v pořádku” — řešení je jinde:

- **CLI** (`health_monitor.rb --details`) → ruční diagnostika
- **DB** (`source_state.error_count`) → stav zdrojů
- **Logy** (`runner_YYYYMMDD.log`, `ifttt_processor.log`) → detail chyb

Monitoring **nesmí blokovat pipeline** ani měnit chování systému.
I při selhání monitoringu musí pipeline fungovat normálně.

---

## 6. Shrnutí

Monitoring ZBNW‑NG odpovídá na:

- „běží systém správně?” — 11 automatizovaných checků
- „zhoršuje se stav?” — activity trend, recurring warnings
- „mám zasáhnout?” — smart alerting, Mastodon DM notifikace