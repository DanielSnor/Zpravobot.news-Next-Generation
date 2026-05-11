# ZBNW-NG — Dokumentace

ZBNW-NG je batch systém, který agreguje obsah z externích platforem (Twitter/X, Bluesky, Facebook, Instagram, YouTube, RSS) a publikuje ho na Mastodon instanci [zpravobot.news](https://zpravobot.news).

Systém sjednocuje data přes jednotný model `Post` a zpracovává je deterministickou pipeline. Je navržen jako jednoduchý, robustní systém, který preferuje konzistenci a toleranci k chybám před perfektními daty.

## Systém jednou větou

```
Platform → Adapter → Post → Pipeline → Publisher → Mastodon
                         ↑
                   Orchestrator (cron)
```

---

## Dokumentace je strukturována do vrstev

Každá vrstva odpovídá na jinou otázku:

| Vrstva | Odpovídá na |
|---|---|
| [`00-overview`](#00--overview) | Co systém je? |
| [`10-system`](#10--system) | Jak systém funguje interně? |
| [`20-platforms`](#20--platforms) | Odkud přichází data? |
| [`30-infrastructure`](#30--infrastructure) | Kde systém běží? |
| [`40-tools`](#40--tools) | Jak systém ovládat? |
| [`50-operations`](#50--operations) | Jak systém provozovat? |
| [`90-meta`](#90--meta) | Proč je systém navržen tak, jak je? |

---

## Jak číst podle situace

| Situace | Kde začít |
|---|---|
| Chci pochopit projekt | [`00-overview`](#00--overview) → [`10-system`](#10--system) |
| Přidávám nebo ladím platformu | [`20-platforms`](#20--platforms) → [`10-system`](#10--system) |
| Něco nefunguje | [`50-operations`](#50--operations) → [`40-tools`](#40--tools) |
| Navrhuji architektonickou změnu | [`90-meta`](#90--meta) → [`00-overview`](#00--overview) |
| Hledám pojem nebo termín | [`00-overview/terminologie.md`](00-overview/terminologie.md) |

---

## Jak číst lineárně (onboarding)

1. [architecture.md](00-overview/architecture.md) — co systém obsahuje a jak jsou komponenty propojené
2. [zbnw-ng-system.md](10-system/zbnw-ng-system.md) — jak systém funguje za běhu (pipeline, scheduling, state)
3. [`20-platforms/`](#20--platforms) — jak se chovají jednotlivé zdroje dat
4. [`40-tools/`](#40--tools) — jak systém běží (cron, CLI, monitoring)
5. [`50-operations/`](#50--operations) — jak systém provozovat (deploy, troubleshooting)
6. [`90-meta/`](#90--meta) — proč je navržený takto (ADR, principy, scope, design rules)

---

## 00 — Overview

*Základní orientace: co systém je, jak je pojmenován a jak jsou komponenty propojené.*

| Soubor | Obsah |
|---|---|
| [architecture.md](00-overview/architecture.md) | Celková architektura systému — komponenty, tok dat, vrstvy |
| [terminologie.md](00-overview/terminologie.md) | Normativní glosář — zdroj, platforma, post, pipeline, tier |

---

## 10 — System

*Jak systém funguje interně: pipeline, orchestrace, stavový model, lifecycle postu.*

| Soubor | Obsah |
|---|---|
| [zbnw-ng-system.md](10-system/zbnw-ng-system.md) | Systémový přehled — orchestrátor, PostProcessor pipeline (9 kroků), StateManager, adaptery, formattery |

---

## 20 — Platforms

*Odkud přichází data: specifika každé zdrojové platformy, integrační model, omezení.*

| Soubor | Obsah |
|---|---|
| [twitter.md](20-platforms/twitter.md) | IFTTT + Nitter hybridní architektura, 5-tierový fallback, IFTTT payload, Syndication API, threading, profile sync |
| [bluesky.md](20-platforms/bluesky.md) | AT Protocol API, feed pagination, thread detection přes AT URI |
| [facebook.md](20-platforms/facebook.md) | RSS.app bridge, FacebookProcessor, profile sync přes Browserless |
| [instagram.md](20-platforms/instagram.md) | RSS.app bridge, InstagramProcessor (rekonstrukce captionů), profile sync přes Browserless |
| [youtube.md](20-platforms/youtube.md) | YouTube RSS, media:group parsing, Shorts filtrování, maintenance window, profile sync |
| [rss.md](20-platforms/rss.md) | Univerzální RSS/Atom, content modes, URL processing |

---

## 30 — Infrastructure

*Kde systém běží: compute, databáze, storage, network — normativní požadavky a Cloudron implementace.*

| Soubor | Obsah |
|---|---|
| [infrastructure.md](30-infrastructure/infrastructure.md) | Přehled infrastruktury — Cloudron server, Nitter VPS, síťová topologie |
| [cloudron.md](30-infrastructure/cloudron.md) | Cloudron platforma — adresářová struktura, env.sh, cron model, DB schema |

---

## 40 — Tools

*Jak systém ovládat: runtime, CLI, monitoring, testování, integrace s externími nástroji.*

| Soubor | Obsah |
|---|---|
| [cli.md](40-tools/cli.md) | Přehled všech bin/ skriptů — argumenty, přepínače, použití |
| [nitter.md](40-tools/nitter.md) | Nitter instance — architektura, burner účty, sessions.jsonl, RSS vs HTML scraping |
| [monitoring.md](40-tools/monitoring.md) | Údržbot — 11 health checků, AlertStateManager, Command Listener, formáty alertů |
| [runtime.md](40-tools/runtime.md) | Cron model, scheduling priorit, IFTTT queue, profil sync rotace |
| [integration.md](40-tools/integration.md) | Browserless.io, RSS.app, IFTTT integrace |
| [testing.md](40-tools/testing.md) | Test runner, katalog testů, architektura frameworku, jak přidat test |

---

## 50 — Operations

*Jak systém provozovat: deployment, troubleshooting, maintenance, incident workflow.*

| Soubor | Obsah |
|---|---|
| [runbook.md](50-operations/runbook.md) | Každodenní provoz — manuální spuštění pipeline, diagnostika, restart komponent |
| [deployment.md](50-operations/deployment.md) | Deployment postup — code-only, DB migrace, nový zdroj, rollback |
| [nitter-setup.md](50-operations/nitter-setup.md) | Instalace Nitter instance — prerekvizity, konfigurace, ověření |
| [maintenance.md](50-operations/maintenance.md) | Pravidelná údržba — týdenní kontroly, cleanup logů a DB, obnova cookies |
| [troubleshooting.md](50-operations/troubleshooting.md) | Řešení problémů — Twitter/IFTTT, RSS, FB/IG, Nitter, infrastruktura (30+ scénářů) |

---

## 90 — Meta

*Proč je systém navržen tak, jak je: principy, design rules, omezení, scope, ADR záznamy.*

| Soubor | Obsah |
|---|---|
| [decisions.md](90-meta/decisions.md) | Architektonická rozhodnutí (ADR) — klíčové volby a jejich zdůvodnění |
| [principles.md](90-meta/principles.md) | Principy návrhu a vývoje |
| [constraints.md](90-meta/constraints.md) | Omezení prostředí (Cloudron, IFTTT, Mastodon API, Nitter) |
| [scope.md](90-meta/scope.md) | Rozsah projektu — co ZBNW-NG dělá a co záměrně nedělá |

---

## Changelog

[CHANGELOG.md](CHANGELOG.md) — přehled změn v čase.

---

## Poznámka k private docs

Některé provozní detaily — konkrétní příkazy pro server, IP adresy, credentials, konfigurační hodnoty — jsou vedeny odděleně v `docs-private/`. Tato složka není součástí veřejného repozitáře. Pokud v těchto dokumentech narazíte na odkaz na `.private.md` soubor, jeho veřejná část je zde; privátní část existuje jen interně.
