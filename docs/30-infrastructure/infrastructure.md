# Infrastruktura ZBNW‑NG

Tento dokument popisuje **veřejně sdělitelný přehled infrastruktury**, na které je systém **ZBNW‑NG** provozován.

Cílem je vysvětlit:

- jaké **typy infrastruktury** systém vyžaduje,
- jaké jsou **hranice odpovědnosti** mezi aplikací a hostingem,
- které části jsou **normativní** (požadavky) a které pouze **implementační**.

Dokument je záměrně abstrahovaný:

- neobsahuje přístupové údaje,
- neobsahuje názvy hostitelů, IP adresy ani topologii,
- nepopisuje incidenty ani provozní historii.

---

## 1. Role infrastruktury v systému

ZBNW‑NG je **aplikační systém**. Infrastruktura poskytuje:

- výpočetní prostředí pro běh Ruby aplikace,
- síťovou konektivitu pro outbound HTTP(S),
- perzistenci stavu (databáze + úložiště),
- plánování dávkových běhů.

---

## 2. Normativní požadavky (co musí hosting umět)

ZBNW‑NG předpokládá:

- Linux‑based runtime prostředí
- možnost plánování periodických úloh (cron‑like scheduler)
- databázovou perzistenci pro state management
- perzistentní úložiště pro logy, cache a fronty

ZBNW‑NG **nevyžaduje**:

- Kubernetes / orchestraci kontejnerů
- serverless runtime
- distribuovaný výpočetní cluster

---

## 3. Běhový model

ZBNW‑NG je dávkový systém:

- spouštěný periodicky
- každý běh je samostatný proces
- dlouhodobý stav se ukládá mimo proces (DB, soubory)

---

## 4. Perzistence

Infrastruktura musí zajistit dlouhodobou perzistenci pro:

- historii publikací (deduplikace) — databáze
- stav zdrojů (scheduling, error tracking) — databáze
- fronty a webhook payloady — perzistentní úložiště (aktuální implementace: souborový systém)
- cache (profily, threading lookup) — perzistentní úložiště
- stavové soubory doplňkových subsystémů — perzistentní úložiště
- logy běhů — perzistentní úložiště s rotací

---

## 5. Síťová konektivita

Systém vyžaduje především **odchozí** konektivitu k externím platformám (HTTP/S).

Výchozí batch běh příchozí konektivitu nevyžaduje — veškerá komunikace je odchozí.

**Webhook server** je doplňkový komponent, nikoli součást core pipeline. Přijímá příchozí HTTP požadavky od externích systémů a vyžaduje příchozí konektivitu alespoň na interní nebo chráněné síťové úrovni. Jeho absence neovlivní batch zpracování.

---

## 6. Bezpečnost (high‑level)

Infrastruktura by měla umožnit:

- oddělení tajných hodnot od veřejného kódu (secrets management)
- kontrolu síťové komunikace na úrovni hostingu
- logování a audit běhů

---

## 7. Vztah k runtime

Tento dokument definuje **prostředí**, ve kterém runtime běhy probíhají.
Chování samotných běhů — skripty, cron schedule, spouštění komponent — je popsáno v:

- [`docs/40-tools/runtime.md`](../40-tools/runtime.md)

---

## 8. Implementační poznámka: Cloudron

Aktuální produkční nasazení ZBNW‑NG běží na **Cloudronu** (implementační detail).
Cloudron poskytuje například managed PostgreSQL, perzistentní storage a cron management.

Tato volba **není** architektonickým požadavkem systému.
Detailní, veřejně bezpečný popis nasazení na Cloudronu je v:

- [`cloudron.md`](cloudron.md)
