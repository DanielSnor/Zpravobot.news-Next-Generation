# ZBNW‑NG – Architecture Overview

Tento dokument poskytuje **strukturální architektonický přehled systému ZBNW‑NG**.
Popisuje hlavní komponenty, jejich odpovědnosti a vzájemné vztahy.

- Terminologie použitých pojmů je definována v `docs/00-overview/terminologie.md`.
- Důvody architektonických rozhodnutí jsou zachyceny v `docs/90-meta/decisions.md`.

Dokument se soustředí na **aktuální tvar architektury** a její rozhraní.
Neřeší historický vývoj ani provozní incidenty.

---

## 1. Architektonické hledisko

ZBNW‑NG je **modulární dávkový systém** postavený okolo jasně oddělených odpovědností:

- koordinace běhu
- získání dat
- zpracování obsahu
- publikace

Jednotlivé části spolu komunikují pomocí explicitních rozhraní a sdílených datových modelů.

---

## 2. High‑level pohled

### Koncepční tok systému

```
┌────────────┐
│ Platformy  │
└─────┬──────┘
      │
┌─────▼──────┐
│ Adaptéry   │
└─────┬──────┘
      │  Post (mezikrok)
┌─────▼────────────┐
│ Zpracovací       │
│ Pipeline         │
└─────┬────────────┘
      │
┌─────▼──────┐
│ Publisher  │
└─────┬──────┘
      │
┌─────▼──────────┐
│ Mastodon /     │
│ další cíle     │
└────────────────┘
```

Každý blok představuje samostatnou odpovědnostní vrstvu.

Systém pracuje se dvěma vstupními kanály:

- **Polling** – adaptér periodicky stahuje data z platformy (hlavní cesta)
- **Webhook / fronta** – asynchronní push notifikace předané do fronty; do pipeline vstupují stejnou cestou jako polling data

---

## 3. Orchestrátor

**Orchestrátor** je vstupním bodem celého systému.

### Role v architektuře

```
┌───────────────┐
│ Orchestrátor │
└─────┬─────────┘
      │ rozhodování
      ▼
[ Zdroj → Adaptér → Pipeline ]
```

Odpovědnosti:

- řídí životní cyklus běhu
- inicializuje subsystémy
- rozhoduje o pořadí a rozsahu zpracování

Orchestrátor:

- neobsahuje business logiku zpracování obsahu
- neřeší platformně specifické chování
- funguje jako koordinační vrstva

---

## 4. Konfigurační vrstva

Konfigurace systému je **deklarativní**.

```
config/
 ├─ platforms/
 ├─ sources/
 └─ defaults/
```

Architektonické vlastnosti:

- konfigurace jsou externí vůči kódu
- konfigurace se načítají při startu běhu
- konfigurace určují chování systému, nikoli jeho strukturu

Tato vrstva umožňuje rozšiřování systému bez zásahů do core architektury.

---

## 5. Adaptéry (Integration Layer)

Adaptéry tvoří integrační vrstvu mezi ZBNW‑NG a externími platformami.

```
[ Twitter ]   [ Bluesky ]   [ RSS ]
     │             │          │
     └───────┬─────┴─────┬────┘
             ▼
        [ Adaptéry ]
             ▼
           Post
```

Architektonická odpovědnost:

- izolovat rozdíly mezi platformami
- sjednotit vstupní data

Charakteristiky:

- každý adaptér odpovídá jedné platformě
- výstupem je vždy jednotný model `Post`
- adaptér nemá znalost downstream kroků

---

## 6. Datový mezimodel (Post)

Model `Post` funguje jako **architektonická hranice** mezi integrací a zpracováním.

```
Adaptér → Post → Pipeline
```

Úloha v architektuře:

- odděluje platformní specifika
- stabilizuje rozhraní pipeline
- umožňuje testovat zpracování izolovaně od zdrojů

`Post` je krátkožijící objekt existující pouze v rámci jednoho běhu.

---

## 7. Pipeline zpracování

Pipeline je sekvenční zpracovatelská vrstva.

### Typický průchod

```
Post
 │
 ▼
[Deduplikace]
 │
 ▼
[Edit detection]
 │
 ▼
[Filtrace]
 │
 ▼
[Formátování]
 │
 ▼
[Media handling]
 │
 ▼
[Publishing]
```

Architektonické vlastnosti:

- jednoznačné pořadí kroků
- každý krok má přesně vymezenou odpovědnost
- pipeline může zpracování ukončit dříve

---

## 8. Publisher

Publisher je výstupní vrstva architektury.

```
Pipeline → Publisher → Mastodon API  (hlavní cíl)
                    └→ Bluesky API   (doplňkové subsystémy)
```

Odpovědnosti:

- komunikace s cílovými platformami
- převod interní reprezentace na externí API volání

Primárním cílem je Mastodon. Doplňkové subsystémy (statistiky, trending, FF) mohou publikovat i na Bluesky.

Publisher je posledním bodem zpracování.

---

## 9. Stavová vrstva

Architektura pracuje s perzistentním stavem.

```
Pipeline ↔ Databáze ↔ Další běh
```

Role stavové vrstvy:

- udržení kontextu mezi běhy
- zajištění konzistence publikace

Stavová vrstva je sdílena napříč běhy, nikoli napříč procesy.

---

## 10. Doplňkové subsystémy

Vedle hlavního publikačního toku existují doplňkové subsystémy.

```
[ Stats / Reporting ]  [ Profile Sync ]  [ Trending / FF ]  [ Údržbot / Tlambot ]
          │                   │                  │                    │
          └───────────────────┴──────────────────┴────────────────────┘
                                        ▼
                                    Sdílená
                                  infrastruktura
```

Doplňkové subsystémy zahrnují:

- statistiky a reporty (`Stats`, `Reporting`)
- synchronizaci profilů (`Profile Sync`)
- výběr trendujícího obsahu (`Trending`)
- rotaci doporučení (`Friendly Follow`)
- interaktivní ovládání (`Údržbot`)
- broadcast mechanismus (`Tlambot`)

Architektonické vlastnosti:

- využívají stejnou infrastrukturu
- nenarušují hlavní tok dat
- jsou logicky oddělené od core pipeline

---

## 11. Architektonické hranice

ZBNW‑NG architektura je navržena s vědomými hranicemi:

- není real‑time streaming systém
- neudržuje permanentní procesní stav
- nepokrývá správu obsahu uživatelským rozhraním

Tyto hranice jsou zásadní pro dlouhodobou udržitelnost architektury.

---

## 12. Vztah k ostatní dokumentaci

- **Terminologie** definuje pojmy, které architektura používá
- **Decisions** vysvětlují důvody architektonických voleb
- **System Overview** popisuje chování systému v běhu

Tento dokument se zaměřuje výhradně na **strukturální pohled**.
