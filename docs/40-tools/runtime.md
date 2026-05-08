# Runtime nástroje ZBNW‑NG

Tento dokument popisuje **běhové nástroje a komponenty**, které zajišťují
spuštění a koordinaci systému ZBNW‑NG.

Runtime vrstva odpovídá na otázku:

> „jak se systém skutečně spouští a zpracovává data“

---

## Přehled

Runtime ZBNW‑NG se skládá z několika nezávislých běhů:

- orchestrator (hlavní pipeline)
- queue processor (asynchronní vstupy)
- pomocné běhy (monitoring, reporting)

Tyto běhy:

- jsou spouštěny periodicky (schedulerem)
- jsou krátkožijící (batch model)
- sdílí stav přes databázi a filesystem

---

## 1. Hlavní komponenty

---

### 1.1 Orchestrator (hlavní runner)

**Role:**
- řídí hlavní pipeline
- iteruje přes zdroje
- zpracovává obsah

**Charakteristika:**
- spouštěn pravidelně (např. každých X minut)
- zpracovává více zdrojů v jednom běhu
- je „entry point“ systému

**Důsledky:**
- musí být robustní vůči chybám
- nesmí padnout na jednom zdroji
- musí být idempotentní

---

### 1.2 Queue processor

**Role:**
- zpracovává asynchronní vstupy (např. webhook payloady)
- odděluje externí svět od pipeline

**Charakteristika:**
- běží nezávisle na orchestratoru
- čte položky z fronty
- zpracovává je přes stejnou pipeline

**Důsledky:**
- fail jednoho payloadu nesmí ovlivnit ostatní
- backlog je absorbován queue, ne pipeline

---

### 1.3 Webhook receiver (doplňkový komponent)

**Role:**
- přijímá externí eventy
- zapisuje je do queue

**Charakteristika:**
- jednoduchý vstupní bod
- neobsahuje business logiku

**Důsledky:**
- validace musí být minimální, ale bezpečná
- payload se zpracovává až asynchronně

---

### 1.4 Pomocné běhy

**Role:**
- doplňkové úlohy mimo hlavní pipeline

Typicky:

- monitoring (health checks)
- reporting (statistiky, summary)
- profile sync

**Důsledky:**
- nesmí ovlivnit core pipeline
- mohou být vypnuty bez dopadu na ingest/publish flow

---

## 2. Běhový model

---

### 2.1 Batch execution

ZBNW‑NG je batch systém:

- každý běh je samostatný proces
- po dokončení se ukončí
- další běh začíná z čistého stavu

---

### 2.2 Stateless runtime (s perzistencí)

Runtime je:

- krátkodobý (in-memory)
- dlouhodobý stav je uložen v:
  - databázi
  - souborech (logs, queue, cache)

---

### 2.3 Idempotence

Každý běh musí být:

- bezpečný při opakování
- odolný vůči restartu

To zajišťuje:

- deduplikace
- timestamp tracking
- state management

---

## 3. Scheduler (spouštění)

Runtime nástroje jsou spouštěny externím schedulerem (cron nebo ekvivalent).

Scheduler neobsahuje business logiku — pouze spouští jednotlivé běhy ve správných intervalech.

### Scheduling intervaly

| Komponenta | Interval | Účel |
|---|---|---|
| Webhook watchdog | 1 min | Okamžitá detekce výpadku; automatický restart |
| IFTTT queue processor | 2 min | Rychlé zpracování Twitter webhooků |
| IFTTT failed queue retry | 1× za hod | Opakování selhavších webhooků (mimo `DEAD_` permanentní chyby) |
| Content sync (Bluesky, RSS, YouTube) | 10 min | Polling zdrojů; Twitter jde přes IFTTT pipeline |
| Profile sync — Bluesky | 1× denně | Nativní API, stabilní |
| Profile sync — Facebook | 1× za 3 dny | Scraping, šetření rate limitů |
| Profile sync — Twitter | 2× týdně na skupinu | Nitter scraping; 3 skupiny rotující po dnech týdne |
| Profile sync — RSS | 1× týdně | Deleguje na BS/FB/TW syncery |
| Health check + alerting | 10 min | Monitoring s podmíněnými alerty |
| Command listener + broadcast queue | 5 min | Polling Mastodon mentions + broadcast fronta |
| Maintenance | 1× denně | Rotace logů, čištění processed fronty (TTL 7 dní) |

Konkrétní cron syntaxe a shell skripty patří do provozní dokumentace, nikoli sem.

---

## 4. Oddělení běhů

Jednotlivé runtime části jsou oddělené:

| Komponenta        | Běží nezávisle |
|------------------|---------------|
| orchestrator     | ✅ |
| queue processor  | ✅ |
| monitoring       | ✅ |

Díky tomu:

- selhání jedné části neblokuje systém
- jednotlivé části lze restartovat izolovaně

---

## 5. Failure model

Runtime musí počítat s chybami:

---

### 5.1 Chyba zdroje

- neblokuje celý běh
- systém pokračuje s dalšími zdroji

---

### 5.2 Chyba payloadu

- neblokuje queue
- payload může být retryován

---

### 5.3 Chyba pipeline kroku

- může ovlivnit konkrétní post
- nesmí zastavit celý běh

---

## 6. Vztah k ostatním vrstvám

Runtime propojuje:

- **infrastructure** → scheduler, DB, storage  
- **system** → pipeline, modely  
- **tools** → CLI, integration, monitoring  

---

## 7. Co runtime NEŘEŠÍ

Runtime vrstva neobsahuje:

- konfiguraci zdrojů (→ config)
- integrační logiku platforem (→ adapters)
- provozní postupy (→ operations)

---

## ❌ Co do tohoto dokumentu nepatří

- konkrétní cron konfigurace
- shell skripty a jejich obsah
- cesty v souborovém systému
- credentials a přístupové údaje

👉 ty patří do:
- private dokumentace
- nebo infrastruktury

---

## ✅ Cíl dokumentu

- vysvětlit, jak systém běží
- ukázat hranice jednotlivých runtime komponent
- umožnit orientaci bez znalosti implementace

---

## 📌 Shrnutí

Runtime odpovídá na:

- „co se spouští?“
- „jak spolu běhy souvisí?“
- „co se stane, když něco selže?“