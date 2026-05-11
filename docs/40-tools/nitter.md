# Nitter (Twitter/X scraping layer)

Tento dokument popisuje roli **Nitteru** v systému ZBNW‑NG.

Použité pojmy jsou definovány v [`../00-overview/terminologie.md`](../00-overview/terminologie.md).
Architektura Twitter integrace je popsána v [`../20-platforms/twitter.md`](../20-platforms/twitter.md).

Dokument popisuje **aktuální chování systému** a záměrně se vyhýbá privátním provozním
podkladům (IP adresy, konkrétní tokeny, SSH konfigurace).

---

## 1. Role Nitteru v systému

> **Nitter není platforma.** Je to **proxy vrstva** — prostředník pro přístup k Twitter/X datům. Z pohledu systému jde o integrační nástroj, nikoli o zdroj obsahu.

Nitter je **self-hosted alternativní frontend pro Twitter/X**, který ZBNW‑NG používá ve dvou rolích:

| Role | Popis |
|---|---|
| **Tweet enrichment (Tier 2)** | `fetch_single_post()` — HTML parsing konkrétního tweetu pro plný text, média a kontext vlákna |
| **Profile sync** | Scraping profilové stránky pro synchronizaci avataru, banneru a bio na Mastodon |

> **Důležité:** ZBNW‑NG **nepoužívá** Nitter RSS feed pro polling. Primárním triggerem pro Twitter jsou IFTTT webhooky. Nitter vstupuje do hry až v Tier 2, kdy má systém konkrétní tweet ID k obohacení.

Zapojení do Twitter 5-tier systému viz [`../20-platforms/twitter.md`](../20-platforms/twitter.md).

---

## 2. Proč vlastní instance

| Aspekt | Veřejné Nitter instance | Vlastní instance |
|---|---|---|
| Dostupnost | Nepředvídatelná, často nedostupné | Pod kontrolou ZBNW‑NG |
| Rate limiting | Sdíleno s veřejností | Dedikované pro systém |
| Bezpečnost | Třetí strana vidí provoz | IP whitelist — pouze Cloudron server |
| Spolehlivost | Monitorovatelnost nulová | Monitorována Údržbotem |

Vlastní instance je nutná pro produkční spolehlivost Tier 2 enrichmentu.

---

## 3. Architektura

```
ZBNW‑NG (Cloudron)
       │
       │ HTTP (Tier 2 + profile sync)
       ▼
  Nitter VPS
  ┌─────────────────────────────┐
  │  Nginx (port 8080, whitelist)│
  │       │                     │
  │  Docker: nitter             │
  │  (port 8082 intern)         │
  │       │                     │
  │  Redis + sessions.jsonl     │
  └─────────────────────────────┘
       │
       ▼
  Twitter/X API (burner cookies)
```

Nitter slouží jako proxy vrstva — ZBNW‑NG komunikuje s Nitterem přes HTTP, Nitter zprostředkovává přístup k Twitter datům.

---

## 4. Endpointy používané ZBNW‑NG

| Endpoint | Účel |
|---|---|
| `/{handle}/status/{tweet_id}` | HTML single tweet fetch (Tier 2 enrichment) |
| `/{handle}` | HTML profil pro profile sync |
| `/pic/...` | Proxy obrázků (standardní rozlišení) |
| `/pic/orig/...` | Proxy obrázků (full resolution) |

RSS feed endpointy (`/{handle}/rss`) existují v Nitteru, ale ZBNW‑NG je aktivně nepoužívá.

---

## 5. Konfigurace na straně ZBNW‑NG

ENV proměnná `NITTER_INSTANCE` určuje URL Nitter instance (nastaveno v `env.sh`).

Adapter ji čte při inicializaci:

```ruby
@nitter_instance = ENV['NITTER_INSTANCE']
```

Per-source override je možný přes `source.nitter_instance` v YAML konfiguraci.

---

## 6. Tweet enrichment — `fetch_single_post`

`TwitterAdapter#fetch_single_post(tweet_id)` stáhne HTML stránku tweetu a extrahuje:

- plný text tweetu
- média (obrázky, video thumbnail)
- kontext vlákna (je-li tweet součástí self-reply řetězce)

**Thread detection:** Nitter formátuje title self-reply jako `R to @same_handle:` — adaptér z tohoto vzoru detekuje `is_thread_post: true`.

---

## 7. Profile sync

`TwitterProfileSyncer` synchronizuje Twitter profil (přes Nitter HTML scraping) na Mastodon bot účet.

### Co se synchronizuje

| Položka | Synchronizuje | Poznámka |
|---|---|---|
| Bio / description | ✅ | Z Nitter HTML profilu |
| Avatar | ✅ | S cache (7 dní TTL) |
| Banner | ✅ | S cache (7 dní TTL) |
| Metadata pole 1 | ✅ | `𝕏` → URL Twitter profilu |
| Metadata pole 3 | ✅ | `spravuje:` → @zpravobot |
| Metadata pole 4 | ✅ | `retence:` → počet dní |
| Display name | ❌ | Obsahuje :bot: badge, nesynchronizuje se |

### Skupinová rotace

Twitter profily jsou rozděleny do 3 skupin dle `source_id.bytes.sum % 3`.
Každá skupina se synchronizuje v jiný den v týdnu (St/Čt/Pá).
Tím se distribuuje zátěž na Nitter a snižuje riziko rate limitingu.

---

## 8. Health monitoring

Údržbot monitoruje Nitter ve dvou checích:

### NitterCheck (check #4)

Každých 5 minut posílá HTTP GET na `/settings` stránku Nitter instance a hledá v HTML:

| Stav HTML | Výsledek |
|---|---|
| HTTP 200, žádné problémy | ✅ OK |
| `rate_limit`, `suspended` v HTML | ⚠️ WARNING — degradovaný stav |
| Connection refused / timeout | ❌ CRITICAL — instance nedostupná |

### NitterAccountsCheck (check #5)

Prohledává `activity_log` za poslední hodinu pro account-related chyby:
`rate_limit`, `guest_account`, `unauthorized`, `suspended`

- > 3 chyby → ⚠️ WARNING
- > 10 chyb → ❌ CRITICAL

---

## 9. Failure model

Nitter může selhat:

- nedostupnost instance (VPS restart, síťová chyba)
- rate limiting burner účtů
- změna HTML struktury po aktualizaci Nitteru

**Důsledky:**

- Tier 2 enrichment se nezdaří → systém propadne na Tier 3.5 (Syndication API) nebo Tier 3 (IFTTT only)
- Profile sync selže → `error_count` roste, next run zkusí znovu

Výpadek Nitteru **neblokuje** celý systém — Twitter zdroje dále fungují s nižší kvalitou dat.

---

## 10. Shrnutí

Nitter v ZBNW‑NG:

- je kritická součást Tier 2 Twitter enrichmentu
- zprostředkovává full text a média pro tweety bez přístupu k oficiálnímu API
- je self-hosted pro zajištění spolehlivosti a bezpečnosti
- je monitorován Údržbotem (NitterCheck + NitterAccountsCheck)
- jeho výpadek degraduje kvalitu Twitter dat, nezastavuje systém
