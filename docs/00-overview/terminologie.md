# Terminologie ZBNW-NG

## Typy pojmů (orientace)

Pro rychlé skenování dokumentace rozlišujeme:

- **Model** – datové entity, které systém zpracovává (např. Post, Media)
- **Komponenty** – části systému v kódu (např. Adapter, Formatter, Publisher, Orchestrator)
- **Procesy** – opakované postupy a toky (např. Pipeline, Webhook, Fronta)
- **Konfigurace** – deklarativní pojmy popisující, co systém sleduje (Platforma, Zdroj, Priority)
- **Nástroje (tools)** – technické prostředníky integrace (např. Nitter)

---

Tento dokument definuje jednotnou terminologii používanou v projektu
**ZBNW-NG (Zpravobot News – Next Generation)**.

Je určen jako referenční slovník pro **maintainery**, **contributory** i jako
pomůcka při čtení kódu a ostatní dokumentace.

✅ **Cíl:** aby každý pojem měl **jeden význam**, **jedno pojmenování**
a byl používán **konzistentně** napříč dokumentací i kódem.

---

## Základní pojmy

### ZBNW-NG

**Zpravobot News – Next Generation**.
Serverový Ruby systém zajišťující sběr, zpracování a publikování obsahu
z externích platforem na Mastodon instanci **zpravobot.news**.

---

### Platforma (`platform`)

Externí služba nebo protokol, ze kterého ZBNW-NG získává data.

**Příklady:**

- `twitter`
- `bluesky`
- `rss`
- `youtube`

Platforma určuje:

- použitý **Adapter**
- výchozí **Formatter**
- výchozí **platform defaults** (`config/platforms/*.yml`)

---

### Zdroj (`source`)

Konkrétní konfigurace jednoho sledovaného účtu / feedu / kanálu.

Každý `source`:

- reprezentuje **jednu větev obsahu**
- má vlastní **stav v databázi** (`source_state`)
- typicky mapuje vztah **1 → 1 Mastodon účet**

**Technicky:**

- jeden YAML soubor v `config/sources/*.yml`
- identifikován klíčem `id`

**Příklad:**

```yaml
id: denikn_bluesky
platform: bluesky
```

---

### Source ID (`source_id`)

Jednoznačný identifikátor zdroje napříč systémem.

Používá se:

- v databázi (`published_posts`, `source_state`, `activity_log`)
- v logách
- jako identifikátor při příjmu externích notifikací

> ⚠️ `source_id` **není** nutně stejný jako `handle` zdroje.

---

### Handle (`handle`)

Platformně specifický identifikátor účtu nebo stránky.

**Příklady:**

- Twitter/X: `ct24zive`
- Bluesky: `demagog.cz`
- Facebook / Instagram: `page-handle`

Poznámky:

- v systému může existovat více polí typu *handle*
  (`source.handle`, `social_profile.handle`)
- význam vždy závisí na **kontextu platformy**

---

### Priority (`priority`)

Konfigurační hodnota určující, jak rychle má být zdroj zpracováván.

**Hodnoty:**

- `high` – vysoká priorita, krátký interval zpracování
- `normal` – standardní interval
- `low` – nízký interval zpracování

Priority ovlivňují:

- frekvenci zpracování zdrojů (scheduling)
- chování fronty při asynchronním příjmu dat

---

## Architektonické pojmy

### Adapter

Třída odpovědná za **získání dat z platformy** a jejich převod
na jednotný model `Post`.

Vlastnosti:

- komunikuje se vzdálenou službou (API, RSS, scraping)
- **neřeší** formátování textu
- **neřeší** publikaci ani deduplikaci

**Příklady:**

- `TwitterAdapter`
- `BlueskyAdapter`
- `RssAdapter`
- `YouTubeAdapter`

---

### Post

Unifikovaný datový model reprezentující **jeden publikovatelný příspěvek**.

Typicky obsahuje:

- `id` (platformní ID)
- `url`
- `text`
- `author`
- `media` – pole objektů `Media`
- příznaky (`is_reply`, `is_repost`, `is_quote`, `is_thread_post`)

`Post` **není** Mastodon status – je to mezikrok v pipeline.

---

### Media

Reprezentace jednoho mediálního objektu připojeného k `Post`.

**Typy (neúplný výčet):**

- `image`
- `video`
- `gif`
- `audio`
- `link_card`
- `video_thumbnail`

Lifecycle média:

1. stažení
2. upload do Mastodonu
3. mapování na `media_id`

---

### Formatter

Komponenta převádějící `Post` → **text Mastodon statusu**.

Vlastnosti:

- řeší text, emoji, hlavičky, zmínky, URL a vlákna
- deleguje společnou logiku na `UniversalFormatter`

**Příklady:**

- `TwitterFormatter`
- `BlueskyFormatter`
- `RssFormatter`
- `YouTubeFormatter`

---

### UniversalFormatter

Sdílená formátovací vrstva používaná všemi platformami.

Implementuje např.:

- výběr obsahu (`title`, `text`, `combined`)
- trim strategie (`smart`, `word`, `hard`)
- práci s URL na konci postu

Platformní formattery ji pouze **obalují**.

---

### Processor / Pipeline

Sekvence kroků, kterou musí každý `Post` projít před publikací.

V kódu reprezentováno třídou:

- `PostProcessor`

Typický průběh:

1. deduplikace
2. detekce editací
3. filtrování obsahu
4. formátování
5. úpravy textu a URL
6. zpracování médií
7. publikace
8. aktualizace stavu

---

### Orchestrator

Koordinátor běhu systému.

Odpovídá za:

- načtení konfigurací
- rozhodnutí, **které zdroje jsou na řadě** (scheduling)
- vytvoření adapterů
- delegaci postů do pipeline

Vstupní bod:

- `bin/run_zbnw.rb`

---

### Webhook

Mechanismus příjmu externích push notifikací.

V ZBNW‑NG:

- přijímá notifikace o nových příspěvcích z externích systémů
- data jsou vložena do fronty
- zpracování probíhá asynchronně

Webhook je vstupní kanál komplementární k polling adaptérům.

---

### Fronta (`queue`)

Persistentní buffer pro asynchronní příjem a zpracování dat.

Funguje jako:

- vstupní buffer pro webhook data
- izolace příjmu od zpracování

Fronta umožňuje:

- zpracovávat data v dávkách
- retry při selhání
- přežít výpadky zpracovávající komponenty

---

### Nitter

Technická vrstva zprostředkovávající přístup k datům Twitter/X.

Funguje jako:

- prostředník mezi ZBNW‑NG a Twitter/X
- zdroj dat pro `TwitterAdapter`

Nitter je:

- externí komponenta, nikoli součást core systému
- považován za best‑effort integraci

Viz [`nitter.md`](../40-tools/nitter.md).

---

## Stav a databáze

### State Manager

Abstrakční vrstva nad PostgreSQL.

Zajišťuje:

- deduplikaci publikovaných postů
- sledování stavu zdrojů
- activity log
- podporu lookupů pro vlákna

Třída:

- `State::StateManager`

---

### `published_posts`

Databázová tabulka zaznamenávající **všechny publikované posty**.

Používá se pro:

- deduplikaci
- threading (hledání parent postů)
- detekci editací

---

### `source_state`

Tabulka držící **runtime stav každého zdroje**.

Typicky obsahuje:

- `last_check`
- `last_success`
- `posts_today`
- `error_count`

Používá se pro scheduling a health monitoring.

---

## Publikace

### Mastodon Publisher

Komponenta komunikující s Mastodon API.

Zajišťuje:

- upload médií (v2 async API)
- publikaci statusů
- řešení rate limitů (HTTP 429)
- retry při chybách

---

### Mastodon Status

Konečný výstup systému – příspěvek publikovaný na Mastodonu.

Identifikován polem:

- `mastodon_status_id`

Jednomu `Post` typicky odpovídá jeden Mastodon status.
Výjimka: editace s médii mohou vést k **delete + republish**.

---

## Související dokumenty

- [`architecture.md`](architecture.md) – architektura systému
- [`zbnw-ng-system.md`](../10-system/zbnw-ng-system.md) – detailní popis jádra
- [`20-platforms/`](../20-platforms/) – platformní detaily
- [`decisions.md`](../90-meta/decisions.md) – architektonická rozhodnutí

---

> Tento dokument je **normativní**.
> Nové pojmy se **nejprve přidávají sem**, teprve poté se používají jinde.

---

## Doplňky (append-only)

Tato sekce doplňuje několik pojmů a explicitních definic, aniž by měnila původní text výše.

### Post (upřesnění)

V původním textu je Post definován jako unifikovaný model. Pro architektonickou orientaci platí:

- **Post je kanonický mezimodel** (architektonická hranice) mezi integrací a zpracováním.
- Downstream logika pracuje s Postem bez platformních větvení.

### Pipeline (explicitní definice)

V původním textu je pipeline popsaná v sekci **Processor / Pipeline**. V terminologii znamená **pipeline**:

- deterministickou sekvenci kroků nad `Post` před publikací
- možnost předčasného ukončení zpracování (early-exit)
- jednotný tok zpracování napříč platformami

### Publisher (obecně)

V původním textu je uveden konkrétní **Mastodon Publisher**. Obecně **publisher** označuje komponentu, která:

- převádí interní reprezentaci na volání cílového API
- provádí publikaci (včetně retry / rate-limit handlingu)

### Nástroj (tool)

V původním textu je Nitter popsán jako technická vrstva. Pro konzistenci vrstvené dokumentace platí:

- **Platforma** = odkud data pochází (Twitter/X, Bluesky, RSS…)
- **Nástroj (tool)** = technický prostředník integrace (např. Nitter), který není zdrojovou platformou

Nástroje jsou typicky implementační detail a jejich provozní nastavení patří do provozní (často privátní) dokumentace.
