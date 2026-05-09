# Nitter – instalace a provoz (ZBNW‑NG)

Tento dokument popisuje, jak připravit a provozovat **Nitter instance** pro systém ZBNW‑NG.

Je zaměřen na:
- praktický setup
- provozní doporučení
- integraci do ZBNW‑NG

Neobsahuje:
- citlivé údaje
- konkrétní infrastrukturu

---

## Přehled

Nitter je externí komponenta používaná pro ingest dat z Twitter/X.

Viz architektura:
- [`../40-tools/nitter.md`](../40-tools/nitter.md)
- [`../40-tools/integration.md`](../40-tools/integration.md)

---

## 1. Oficiální dokumentace

Základní instalace:

https://github.com/zedeus/nitter

👉 Tento dokument doplňuje:
- co je potřeba pro ZBNW‑NG
- jak instance používat v praxi

---

## 2. Minimální požadavky

Nitter instance musí:

- být dostupná přes HTTP(S)
- mít dostatečný výkon pro scraping
- být spolehlivá (běžet dlouhodobě)

---

## 3. Doporučený setup

### 3.1 Nasazení

Použij:

- izolovaný server nebo kontejner
- oddělený od ZBNW‑NG runtime

---

### 3.2 Přístup

Doporučeno:

- omezit přístup na interní klienty
- nepoužívat veřejné instance

---

### 3.3 Stabilita

- používat vlastní instanci
- nepřepínat instance dynamicky
- plánovat restart/upgrade

---

## 4. Integrace do ZBNW‑NG

ZBNW‑NG používá:

- HTTP endpoint Nitteru
- adapter, který parsuje výstup

Flow:

Twitter/X → Nitter → Adapter → Post → Pipeline

---

## 5. Provozní doporučení

### 5.1 Monitoring

Sleduj:

- dostupnost instance
- response time

---

### 5.2 Aktualizace

- pravidelně aktualizuj Nitter
- sleduj změny HTML struktury

---

### 5.3 Výkon

- omez paralelní požadavky
- sleduj load

---

## 6. Typické problémy

### Problém: Nitter nedostupný

Symptomy:
- žádná data z Twitteru

Akce:
- restart instance
- ověř dostupnost

---

### Problém: Parsing selhává

Symptomy:
- chyba v adapteru

Příčina:
- změna HTML

Akce:
- upravit parser

---

### Problém: Blokace přístupu

Symptomy:
- timeout
- prázdná odpověď

Akce:
- změna IP
- throttling

---

## 7. Omezení

Nitter:

- není garantovaně stabilní
- závisí na změnách Twitter/X

Proto:

- musí být považován za best-effort
- nesmí blokovat systém

---

## ❌ Co sem nepatří

- konkrétní URL instance
- IP adresy
- secrets / cookies
- detailní infra layout

---

## ✅ Cíl dokumentu

- zajistit reprodukovatelný setup
- minimalizovat problémy v provozu
- udržet oddělení architektury a infrastrukturních detailů

---

## 📌 Shrnutí

Nitter setup řeší:

- jak získat data z Twitter/X
- jak provozovat instanci
- jak ji integrovat do ZBNW‑NG
