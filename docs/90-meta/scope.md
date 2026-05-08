# Scope systému ZBNW‑NG

Tento dokument definuje **hranice systému ZBNW‑NG**.

Cílem je jednoznačně odpovědět:

- co systém JE
- co systém NENÍ
- kde končí jeho odpovědnost

---

## Jak tento dokument používat

Scope slouží pro:

- rychlé pochopení systému (onboarding)
- rozhodování o nových funkcích
- prevenci scope creep

Použij ho jako filtr:

- „Patří tahle změna ještě do scope?“
- „Není to odpovědnost jiné vrstvy?“
- „Nesnažíme se z toho udělat jiný typ systému?“

---

## Co ZBNW‑NG JE

ZBNW‑NG je:

### 1. Agregační a publikační systém

- sbírá obsah z externích platforem
- transformuje ho do jednotného formátu
- publikuje ho na cílové platformy:
  - **Mastodon** — primární cíl, výstup hlavní pipeline
  - **Bluesky** — doplňkový výstup *mimo* hlavní pipeline (stats, trending, Friendly Follow)

---

### 2. Pipeline pro zpracování obsahu

- obsah prochází definovanými kroky (pipeline)
- každý krok má jasnou odpovědnost
- výstup je konzistentní bez ohledu na zdroj

---

### 3. Batch‑based systém

- běží periodicky (cron / scheduler)
- zpracování je dávkové
- není založený na kontinuálním streamu dat

---

### 4. Konfigurovatelný systém zdrojů

- zdroje jsou definované konfiguračně (YAML)
- přidání nového zdroje nevyžaduje změnu kódu
- chování systému je řízeno konfigurací

---

### 5. Integrátor externích platforem

- pracuje s platformami jako:
  - Twitter/X
  - Bluesky
  - Facebook
  - Instagram
  - YouTube
  - RSS
- sjednocuje jejich heterogenní data

---

## Co ZBNW‑NG NENÍ

ZBNW‑NG není:

---

### ❌ CMS (Content Management System)

- neposkytuje UI pro správu obsahu
- uživatelé nevytváří ani neupravují obsah ručně

---

### ❌ Sociální síť / publikační platforma

- není náhradou Mastodonu
- neřeší interakce (likes, replies, follows)

---

### ❌ Real‑time processing engine

- nepracuje s event streamy
- negarantuje okamžité zpracování
- vědomé architektonické rozhodnutí → viz [`constraints.md`](constraints.md) (C1)

---

### ❌ Obecný crawler nebo scraping framework

- není univerzální nástroj pro sběr dat z webu
- podporuje pouze definované integrační kanály
- vědomé architektonické rozhodnutí → viz [`constraints.md`](constraints.md) (C2)

---

### ❌ Distribuovaný systém

- neběží jako cluster
- neřeší distribuované zpracování
- vědomé architektonické rozhodnutí → viz [`constraints.md`](constraints.md) (C5)

---

### ❌ Monitoring / observability platforma

- monitoring existuje, ale je doplňkový
- není to hlavní účel systému

---

## Hranice systému

### Co je uvnitř systému

- adaptery (získávání dat)
- model `Post`
- pipeline zpracování
- publisher (Mastodon jako primární cíl, Bluesky pro doplňkové subsystémy)
- state management (DB)
- konfigurace zdrojů

---

### Co je mimo systém

#### 1. Externí platformy

- Twitter/X, Bluesky, Facebook, Instagram, YouTube, RSS
- systém je pouze spotřebovává

---

#### 2. Cílové publikační platformy

- Mastodon instance (primární)
- Bluesky (pro doplňkové subsystémy)
- systém je neřídí, pouze publikuje obsah

---

#### 3. Infrastruktura

- hosting (např. Cloudron)
- databáze jako služba
- cron scheduler

👉 popsané v `../30-infrastructure`

---

#### 4. Provozní nástroje

- CLI nástroje
- monitoring
- webhook servery

👉 popsané v `../40-tools` a `../50-operations`

---

#### 5. Privátní konfigurace a secrets

- tokeny
- cookies
- credentials

👉 nejsou součástí veřejné dokumentace

---

## Rozhraní systému (interfaces)

ZBNW‑NG komunikuje s okolím:

### Vstupy
- API / RSS / scraping zdroje
- webhook payloady (např. IFTTT)

### Výstupy
- Mastodon API, Bluesky API (publikace)
- logy
- monitoring výstupy

---

## ❌ Co do tohoto dokumentu nepatří

- implementační detaily (konkrétní skripty, cesty)
- konfigurace (YAML, env proměnné)
- historické důvody (→ [`decisions.md`](decisions.md))
- principy návrhu (→ [`principles.md`](principles.md))
- omezení systému (→ [`constraints.md`](constraints.md))

---

## Jak změnit scope

Scope změň pouze pokud:

- systém se skutečně posouvá do nové role
- změna je vědomá a dlouhodobá
- existuje odpovídající ADR v `decisions.md`

Jinak změna pravděpodobně patří do:
- konfigurace
- implementace
- nebo není potřeba