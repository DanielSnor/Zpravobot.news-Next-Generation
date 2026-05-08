# Architektonická omezení (constraints) ZBNW‑NG

Tento dokument definuje **vědomá omezení systému ZBNW‑NG**.

Constraints říkají:
> „co systém záměrně nedělá / neřeší / nepoužívá“

Na rozdíl od limitací (co zatím neumíme) jsou constraints:
- **vědomě zvolené**
- **stabilní v čase**
- **důležité pro udržení jednoduchosti systému**

> Konkrétní rozhodnutí jsou v `decisions.md`.
> Principy návrhu jsou v `principles.md`.

---

> Constraints jsou výsledkem aplikace principů v praxi.
> Každý constraint lze stopovat zpět k jednomu nebo více principům — viz [`principles.md`](principles.md).
> Logická posloupnost: **principles → constraints → decisions**

---

## Jak tento dokument používat

Používej constraints jako filtr:

- „Je tato změna v rozporu s některým omezením?“
- „Nesnažíme se řešit problém, který jsme vědomě nechali out-of-scope?“
- „Je potřeba constraint změnit, nebo jen správně pochopit?“

---

## Omezení systému

### C1 — Není to real‑time systém

**Popis:**
ZBNW‑NG je dávkový (batch) systém, ne real‑time streaming platforma.

**Důsledky v praxi:**
- zpoždění publikace je akceptovatelné
- webhooky jsou doplněk, ne základ
- architektura neoptimalizuje latenci na milisekundy

---

### C2 — Není to obecný crawler / scraper framework

**Popis:**
Systém není určen pro obecné scrapování internetu.

**Důsledky v praxi:**
- podporované jsou jen konkrétní platformy
- nové zdroje musí zapadnout do modelu `adapter → Post → pipeline`
- neřeší se univerzální crawling engine

---

### C3 — Není to full-featured publish platforma

**Popis:**
ZBNW‑NG není náhrada Mastodonu ani CMS.

**Důsledky v praxi:**
- systém nepodporuje správu obsahu ručně
- nepřidává komplexní UI
- soustředí se pouze na ingest → transform → publish

---

### C4 — Nepoužívá serverless / event‑driven architekturu

**Popis:**
Systém nevyužívá event-driven backend ani serverless compute.

**Důsledky v praxi:**
- běh je řízen cronem / schedulerem
- systém je predikovatelný a restartovatelný
- neřeší se orchestrace eventů nebo message brokery

---

### C5 — Není horizontálně škálovaný distribuovaný systém

**Popis:**
ZBNW‑NG běží jako single-instance aplikace.

**Důsledky v praxi:**
- není potřeba distribuovaného locking mechanismu
- není řešen clustering
- scaling je vertikální (infra), ne architektonický

---

### C6 — Dependence na externích platformách je nevyhnutelná

**Popis:**
Systém je závislý na externích zdrojích dat (Twitter/X, Bluesky, RSS atd.).

**Důsledky v praxi:**
- změny API nebo formátu jsou normální
- systém musí počítat s výpadky
- nelze garantovat 100% kvalitu či dostupnost dat

---

### C7 — Data nejsou plně konzistentní ani úplná

**Popis:**
ZBNW‑NG pracuje s neúplnými a nekonzistentními daty.

**Důsledky v praxi:**
- chybějící fields jsou normální
- validace nesmí být příliš striktní
- výsledný obsah je „best effort“

---

### C8 — Neexistuje centrální schema pro všechny platformy

**Popis:**
Ne všechny platformy poskytují stejnou strukturu dat.

**Důsledky v praxi:**
- `Post` je kompromisní model
- některé vlastnosti nelze sjednotit
- downstream kód musí být tolerantní

---

### C9 — Secrets a credentials nejsou součástí veřejné dokumentace

**Popis:**
Systém pracuje s přístupovými údaji, ale ty nejsou součástí veřejných docs.

**Důsledky v praxi:**
- dokumentace neobsahuje tokeny, cookies ani connection strings
- konfigurace se dělí na public a private
- public docs musí být bezpečné ke sdílení

---

### C10 — Monitoring není kritická součást pipeline

**Popis:**
Monitoring je doplňková vrstva, ne core součást systému.

**Důsledky v praxi:**
- selhání monitoringu nesmí zastavit pipeline
- alerting je best‑effort
- core logika nesmí být závislá na monitoringu

---

## ❌ Co do tohoto dokumentu nepatří

- aktuální technické problémy („tohle teď nefunguje“)
- dočasná omezení implementace
- konkrétní konfigurace (cron, env, paths)
- historické důvody („protože jsme měli bug X“)
- rozhodnutí (→ `decisions.md`)

---

## Jak změnit constraint

Constraint změň pouze pokud:

- jeho porušení přináší jasnou hodnotu
- změna je vědomá a zdokumentovaná
- existuje odpovídající ADR v `decisions.md`

Jinak constraint platí jako ochrana jednoduchosti systému.
