# Nitter – instalace a provoz (ZBNW‑NG)

## Role v systému

Nitter slouží jako **proxy vrstva** pro přístup k Twitter/X datům bez oficiálního API:

- **Tier 2 enrichment** — fetchuje plný text tweetu, média a thread kontext pro zpracování IFTTT webhooků
- **Profile sync** — scraping profilové stránky pro synchronizaci avataru, banneru a bio na Mastodon

Nitter je **kritická komponenta** pro Twitter/X ingest. Její kritičnost lze snížit používáním IFTTT webhooků jako primárního triggeru — v takovém případě Nitter slouží jako Tier 2 enrichment (kvalita dat) a jeho výpadek pipeline nezastaví.

Viz [`../40-tools/nitter.md`](../40-tools/nitter.md) pro architekturu, endpointy a failure model.

---

Tento dokument **doplňuje** oficiální instalaci Nitteru o specifika potřebná pro ZBNW‑NG.
Základní instalaci řeší: https://github.com/zedeus/nitter

Neobsahuje citlivé údaje — credentials, IP adresy ani konkrétní konfigurační hodnoty patří do `docs-private/`.

---

## 1. Doporučená architektura

Nitter by měl běžet na **odděleném serveru** od ZBNW‑NG (Cloudron):

```
ZBNW‑NG (Cloudron)
       │
       │ HTTP (Tier 2 + profile sync)
       ▼
  Nitter VPS
  ┌─────────────────────────────┐
  │  Nginx (access restriction) │
  │       │                     │
  │  Docker: nitter             │
  │       │                     │
  │  Redis + sessions.jsonl     │
  └─────────────────────────────┘
       │
       ▼
  Twitter/X (burner cookies)
```

Důvody pro oddělený server:
- nezávislost dostupnosti (výpadek Nitter VPS neovlivní Cloudron)
- dedikované zdroje pro scraping
- izolace přístupu (nginx povoluje pouze ZBNW‑NG server)

---

## 2. Kritická nastavení pro ZBNW‑NG

### 2.1 sessions.jsonl — formát ID (nejčastější past)

Nitter vyžaduje, aby `id` v `sessions.jsonl` bylo **string**, ne číslo:

```json
{ "id": "123456789012345678" }   ✅
{ "id": 123456789012345678 }     ❌  → "invalid integer" při startu
```

Při sestavování `sessions.jsonl` ručně nebo ze skriptu vždy ověř, že ID jsou v uvozovkách.

---

### 2.2 Přístup z ZBNW‑NG serveru

Nginx na Nitter VPS musí povolovat přístup **pouze ze ZBNW‑NG serveru**. Nitter instance obsahuje Twitter session cookies — přístup z veřejného internetu by znamenal, že kdokoli může tyto cookies využít přes tvou instanci a vyčerpat nebo zkompromitovat burner účty.

Konkrétní konfigurace (IP adresy) patří do `docs-private/`.

Ověření, že omezení funguje správně:
- z ZBNW‑NG serveru: `curl http://<nitter>/settings` → HTTP 200
- z jiné IP: → HTTP 403 nebo connection refused

---

### 2.3 ENV konfigurace v ZBNW‑NG

V `env.sh` na Cloudron serveru nastav:

```bash
export NITTER_INSTANCE="http://<adresa-nitter-instance>"
```

Per-source override je možný přes `source.nitter_instance` v YAML konfiguraci zdroje.

---

### 2.4 Burner účty a cookies

Nitter přistupuje k Twitter/X přes **guest účty** (burner cookies). Bez platných cookies Nitter vrací chyby `"No guest accounts"` nebo `"Could not authenticate you"`.

Co je potřeba vědět:
- cookies mají omezenou životnost a je třeba je obnovovat
- obnova cookies vyžaduje specifický postup — viz `docs-private/`
- po obnovení cookies je třeba restartovat Nitter: `docker compose restart nitter`

---

## 3. Ověření funkční integrace

Po instalaci ověř, že ZBNW‑NG instanci skutečně používá:

```bash
# Na ZBNW-NG serveru: ověř dostupnost a zdraví instance
curl "$NITTER_INSTANCE/settings"

# Spusť Tier 2 enrichment pro konkrétní tweet
ruby bin/run_zbnw.rb --source <twitter_source_id> --dry-run
```

Očekávaný výsledek v logu:
```
Tier 2: ✅ Nitter fetch OK for <tweet_id>
```

Zdravotní stav průběžně monitoruje Údržbot (NitterCheck + NitterAccountsCheck) — viz [`../40-tools/monitoring.md`](../40-tools/monitoring.md).

---

## 4. Provozní doporučení

### Aktualizace Nitteru

Nitter parsuje HTML Twitter/X — **změna struktury HTML na straně Twitteru může rozbít parsing** bez varování. Doporučení:
- sleduj Nitter release notes a issues na GitHubu
- po aktualizaci ověř Tier 2 enrichment na vzorkovém tweetu
- pokud parsing přestane fungovat, zkontroluj nejprve verzi Nitteru před laděním ZBNW‑NG kódu

### Monitoring

Údržbot monitoruje Nitter automaticky dvěma způsoby:
- **NitterCheck** (každých 10 min) — HTTP GET na `/settings`, detekuje `rate_limit` a `suspended` v HTML
- **NitterAccountsCheck** — prohledává `activity_log` za poslední hodinu na account-related chyby

Manuální kontrola stavu:
```bash
ruby bin/health_monitor.rb --details
```

### Restart po problémech

```bash
# Na Nitter VPS
docker compose restart nitter   # reset session rotace (pomáhá u rate limitů)
docker compose up -d            # pokud container neběží
```

---

## 5. Typické instalační problémy

### "invalid integer" při startu Nitteru

**Příčina:** `id` v `sessions.jsonl` je číslo místo stringu.

**Oprava:** Ověř formát — viz sekce 2.1 výše.

---

### 403 z ZBNW‑NG při přístupu na Nitter

**Příčina:** IP adresa Cloudron serveru není v nginx whitelistu Nitter VPS.

**Řešení:** Přidat IP do nginx konfigurace na Nitter VPS — viz `docs-private/`.

---

### "Could not authenticate you" / "No guest accounts"

**Příčina:** Burner cookies expirovali nebo IP mismatch (cookies získány z jiné IP než Nitter používá).

**Řešení:** Obnovit cookies — viz `docs-private/`.

---

### Connection refused

**Příčina:** Nitter container neběží.

**Diagnostika a řešení:**
```bash
docker compose ps
docker compose logs nitter --tail 20
docker compose up -d
```

---

## Co tento dokument neobsahuje

- IP adresy, konkrétní domény
- credentials, cookies, tokeny
- postup obnovy burner cookies (→ `docs-private/`)
- specifická nginx konfigurace s adresami (→ `docs-private/`)
