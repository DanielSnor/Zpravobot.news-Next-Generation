# Integrační nástroje ZBNW‑NG

Tento dokument popisuje, jak ZBNW‑NG **komunikuje s externími systémy**.

Integration vrstva odpovídá na otázku:

> „jak data vstupují do systému a jak jsou bezpečně předána do pipeline“

---

## Přehled

ZBNW‑NG používá dva základní modely integrace:

- **pull (polling)** – systém si stahuje data
- **push (webhook)** – externí systém posílá data

Tyto vstupy jsou sjednoceny a zpracovány stejnou pipeline.

---

## 1. Typy integrací

### 1.1 Pull model (polling)

**Popis:**
Systém pravidelně získává data z externího zdroje.

Použití:

- RSS
- platformy bez webhook supportu

**Vlastnosti:**

- jednoduchý a predikovatelný model
- odolný vůči výpadkům
- závislý na scheduleru (interval kontroly)

**Důsledky v praxi:**

- data nejsou real-time
- může vznikat zpoždění
- výpadek platformy neblokuje systém

---

### 1.2 Push model (webhook)

**Popis:**
Externí systém posílá data do ZBNW‑NG ve chvíli, kdy nastane událost.

Použití:

- event-driven zdroje (např. webhook integrace)

**Vlastnosti:**

- nízká latence
- závislost na externím systému
- vyžaduje bezpečné zpracování vstupu

**Důsledky v praxi:**

- payload musí být validován
- zpracování nesmí blokovat příjem dalších dat

### 1.3 Přehled integrací podle platformy

| Typ | Platformy | Mechanismus |
|---|---|---|
| API-based | Bluesky, Mastodon | AT Protocol / REST API, token autentizace |
| RSS-based | RSS, Facebook (RSS.app), Instagram (RSS.app), YouTube | Polling RSS/Atom feedu |
| Proxy-based | Twitter/X (Nitter) | Scraping přes alternativní frontend |
| Push webhook | Twitter/X (IFTTT) | Event-driven push do lokální fronty |
| Headless browser | Facebook, Instagram, YouTube (profile sync) | Browserless.io — EU consent bypass |

---

## 2. Queue jako boundary systému

### 2.1 Role queue

Queue slouží jako:

> oddělení mezi externím světem a interní pipeline

### 2.2 Funkce queue

Queue zajišťuje:

- stabilitu (pipeline nepadne na špatném vstupu)
- asynchronní zpracování
- buffering (absorpce špiček)

### 2.3 Zpracování queue

Queue je **konceptuální boundary** — odděluje příjem od zpracování.
Její zpracování za běhu zajišťuje queue processor (viz [`runtime.md`](runtime.md)).

Queue processor:

- načte položky z fronty
- převádí je na interní model (`Post`)
- posílá je do pipeline

---

## 3. Tok dat (data flow)

### 3.1 Pull flow

Platform → Adapter → Post → Pipeline → Publisher

### 3.2 Push flow

External system → Webhook → Queue → Processor → Pipeline → Publisher

### 3.3 Klíčový princip

Bez ohledu na zdroj:

> veškerá data musí skončit jako `Post` a projít stejnou pipeline

---

## 4. Failure model

Integration vrstva musí počítat s chybami:

### 4.1 Nevalidní vstup

- poškozený payload
- chybějící data

Řešení:

- validace
- graceful skip

### 4.2 Výpadek externího systému

- API neodpovídá
- RSS je nedostupné

Řešení:

- retry v dalších bězích
- degradace kvality

### 4.3 Duplicate vstupy

- stejný event vícekrát

Řešení:

- deduplikace downstream

### 4.4 Queue backlog

- rychlejší ingest než zpracování

Řešení:

- queue bufferuje
- systém backlog dožene

---

## 5. Vztah k ostatním vrstvám

Integration propojuje:

- platforms → zdroje dat
- runtime → běh systému
- system → pipeline

---

## 6. Bezpečnost

Integration vrstva pracuje s externími daty.

Musí:

- validovat vstupy
- omezovat payload
- chránit se proti zneužití

---

## 7. Přehled integračních nástrojů

Integrační vrstva využívá specializované komponenty mezi platformou a adapterem:

| Nástroj | Platforma | Model | Role |
|---|---|---|---|
| IFTTT | Twitter/X | Push (webhook) | Doručuje Twitter události do lokální fronty přes HTTP webhook |
| Nitter | Twitter/X | Pull (HTTP) | Scraping layer pro enrichment tweetů — viz [`nitter.md`](nitter.md) |
| Twitter Syndication API | Twitter/X | Pull (HTTP) | Fallback pro média a plný text, nevyžaduje auth |
| RSS.app | Facebook, Instagram | Pull (RSS) | Generuje RSS feed z platforem bez veřejného API |
| Browserless.io | Facebook, Instagram, YouTube | Pull (headless) | Headless browser pro profile sync (EU consent bypass) |

Každý nástroj abstrahuje jeden přístupový mechanismus — adaptér s ním pracuje jako s datovým zdrojem, nezávisle na implementačním detailu.

---

## 8. Co integration NEŘEŠÍ

- business logiku pipeline
- formátování obsahu
- publikaci na cílové platformy

Tyto odpovědnosti leží downstream od hranice `Post`.

---

## 9. Shrnutí

Integration vrstva odpovídá na:

- odkud přichází data (pull polling / push webhook)
- jak vstupují do systému (queue boundary, adapter mapování)
- jak se chrání před chybami (deduplikace, graceful skip, buffering)
