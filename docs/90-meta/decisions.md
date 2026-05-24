# ZBNW-NG – Architecture Decision Records

Tento dokument zachycuje klíčová rozhodnutí učiněná při vývoji ZBNW-NG.
Každý záznam vysvětluje **proč** – ne jak. „Jak" je v kódu a platformní dokumentaci.

Formát záznamu:
- **Kontext** – situace a alternativy, které existovaly
- **Rozhodnutí** – co jsme zvolili
- **Důsledky** – co to přináší a co to vylučuje

⚠️ **Poznámka k datům rozhodnutí**

Tento dokument vznikl částečně rekonstrukcí architektonických rozhodnutí
z historických chatů, commitů a produkčních incidentů.
V některých případech proto není možné určit přesné datum rozhodnutí.
U těchto záznamů je uveden orientační časový rámec (měsíc nebo období),
který odpovídá době, kdy bylo rozhodnutí fakticky uplatněno v produkci.

---

## Kategorie

1. [Infrastruktura a provoz](#1-infrastruktura-a-provoz)
2. [Architektura systému](#2-architektura-systému)
3. [Zpracování obsahu](#3-zpracování-obsahu)
4. [Twitter platforma](#4-twitter-platforma)
5. [Bluesky platforma](#5-bluesky-platforma)
6. [RSS, Facebook, Instagram](#6-rss-facebook-instagram)
7. [Publikování na Mastodon](#7-publikování-na-mastodon)
8. [Synchronizace profilů](#8-synchronizace-profilů)
9. [Pomocné funkce](#9-pomocné-funkce)
10. [Doplňkové subsystémy](#10-doplňkové-subsystémy)
11. [Bezpečnost a spolehlivost](#11-bezpečnost-a-spolehlivost)
12. [Sdílená infrastruktura kódu](#12-sdílená-infrastruktura-kódu)

---

## 1. Infrastruktura a provoz

### ADR-001: Cron model místo daemon procesu

**Datum:** leden 2026

**Kontext:**
Orchestrátor potřebuje pravidelně zpracovávat zdroje. Dvě hlavní alternativy:
- Daemon proces (Ruby loop se `sleep`) – běží 24/7
- Cron job spouštějící skript každých N minut

**Rozhodnutí:**
Cron model. Orchestrátor se spustí, zpracuje co je na řadě a ukončí se.

**Důsledky:**
- ✅ Žádné memory leaky – každý run začíná s čistou pamětí
- ✅ Jednodušší monitoring – cron logy jsou dostačující
- ✅ Pád procesu = žádný problém, cron ho znovu spustí
- ✅ In-memory cache (např. `@thread_cache`) se automaticky vyčistí po každém runu
- ❌ Nelze reagovat na události mezi cron ticky (minimalizováno IFTTT webhooky pro Twitter)
- ❌ Přechod na daemon v budoucnu by vyžadoval refaktoring cache management

---

### ADR-002: Jeden centrální orchestrátor místo per-bot cron jobů

**Datum:** leden 2026

**Kontext:**
Se stovkami botů bylo lákavé mít pro každého bota vlastní cron job.
Alternativy:
- 200+ individuálních cron jobů (jeden per bot)
- Jeden orchestrátor, který zpracuje všechny zdroje v každém runu

**Rozhodnutí:**
Jeden centrální orchestrátor (`bin/run_zbnw.rb`) spouštěný cronem.
Orchestrátor si sám rozhodne, které zdroje jsou „na řadě" podle priority a `last_fetched_at`.

**Důsledky:**
- ✅ Snadné přidávání nových zdrojů – jen YAML soubor, žádný nový cron
- ✅ Centrální rate limiting a error handling
- ✅ Priority systém implementovatelný v jednom místě
- ✅ Škálování na 500+ botů bez změny infrastruktury
- ❌ Jediný bod selhání – pokud orchestrátor crashne, nezpracuje se nic (mitigováno: cron ho znovu spustí)

---

### ADR-003: `setsid` pro spuštění webhook serveru z cronu

**Datum:** duben 2026

**Kontext:**
IFTTT webhook server (`bin/ifttt_webhook.rb`) musí běžet jako long-running proces.
Cloudron cron po skončení skriptu zabíjí všechny child procesy – `nohup &` nestačí.
Supervisord je read-only (Cloudron managed), nelze přidat vlastní service.

**Rozhodnutí:**
Webhook spouštíme přes `setsid`, který odpojí proces od parent session:
```bash
setsid ruby bin/ifttt_webhook.rb >> "$LOG_FILE" 2>&1 < /dev/null &
```

**Důsledky:**
- ✅ Webhook přežije ukončení cron skriptu i restart cron session
- ✅ Nevyžaduje změnu Cloudron konfigurace
- ❌ Webhook není pod supervisord dohledem – pokud crashne, cron watchdog ho restartuje při dalším ticku (max 5 min prodleva)

---

### ADR-004: Mastodon instance s limitem 2500 znaků

**Datum:** leden 2026

**Kontext:**
Standardní Mastodon instance má limit 500 znaků. Zpravodajské posty (perex + titulek + URL) a vlákna přirozeně překračují 500 znaků.

**Rozhodnutí:**
Vlastní Mastodon instance `zpravobot.news` nakonfigurována s limitem 2500 znaků.

**Důsledky:**
- ✅ Zpravodajské posty lze publikovat v plném rozsahu bez nucené zkratky
- ✅ Souhrnné posty (digesty, FF, statistiky) se vejdou do jediného tootu
- ❌ Nekompatibilita s budoucím přesunem na standardní instanci

---

### ADR-005: Mastodon memory tuning – 1 Puma worker + `MALLOC_ARENA_MAX=2`

**Datum:** duben 2026

**Kontext:**
Mastodon na serveru s 8 GB RAM postupně rostl na 3,5 GB, plnil swap (4 GB) a způsoboval výpadky. Výchozí konfigurace (2 Puma workery, žádný `MALLOC_ARENA_MAX`) je navržena pro instance se stovkami aktivních uživatelů, ne pro bot-driven instanci s minimálním lidským provozem. Přidání `MALLOC_ARENA_MAX=2` dramaticky omezuje Ruby memory fragmentaci.

**Rozhodnutí:**
- `WEB_CONCURRENCY=1` (jeden Puma worker místo dvou)
- `MALLOC_ARENA_MAX=2` v supervisord environment

**Důsledky:**
- ✅ RAM spotřeba Mastodon klesla z ~3,5 GB na ~1,2 GB
- ✅ Swap se uvolnil z 100% na ~17%
- ✅ Jeden worker plně dostačuje pro bot-driven provoz
- ❌ Při náhlém nárůstu lidského provozu by byl jeden worker úzkým hrdlem (akceptovatelné)

---

### ADR-051: `manage_source.rb` — lifecycle management zdrojů (pause / resume / retire)

**Datum:** únor 2026

**Kontext:**
Operátoři neměli způsob dočasně pozastavit nebo vyřadit zdroj bez manuálního editování YAML a přímého přístupu do DB. Alternativy: webový admin panel (velká investice), čistě YAML bez DB (source_state by neodpovídal), čistě DB (neodráží konfiguraci).

**Rozhodnutí:**
`bin/manage_source.rb` implementuje tři operace:
- `pause` — zapíše `enabled: false` + komentáře `# paused_at` / `# paused_reason` přímo do YAML; v DB nastaví `disabled_at = NOW()`
- `resume` — vrátí `enabled: true`, odstraní pause komentáře; v DB `disabled_at = NULL`, reset `error_count`, init time wizard
- `retire` — přesune YAML do `config/sources/retired/`; v DB smaže `source_state` a `published_posts` (ale `activity_log` se zachovává pro audit)

`retire` vždy vyžaduje explicitní potvrzení od operátora.

**Důsledky:**
- ✅ Operátor spravuje lifecycle bez přístupu do DB ani přímého editování YAML
- ✅ `activity_log` zůstává po retire pro retrospektivu
- ❌ YAML a DB state musí zůstat synchronizované — `manage_source.rb` je jediná autorizovaná cesta pro tyto operace

---

## 2. Architektura systému

### ADR-006: YAML konfigurace – jeden soubor per zdroj

**Datum:** leden 2026

**Kontext:**
Konfigurace zdrojů mohla být v databázi nebo v konfiguračních souborech.
Uvnitř konfiguračních souborů: jeden velký soubor nebo jeden soubor per zdroj.

**Rozhodnutí:**
Jeden YAML soubor per zdroj (`config/sources/{id}_{platform}.yml`).
Konfigurace má hierarchii: globální defaults → platform defaults → per-source overrides.

**Důsledky:**
- ✅ Konfigurace je verzovatelná v gitu
- ✅ Přidání/odebrání zdroje = přidání/odebrání jednoho souboru
- ✅ Celý kontext bota na jednom místě, editovatelné bez DB klienta
- ❌ Nelze měnit za běhu bez restartu
- ❌ Při 200+ zdrojích je potřeba wizard (`bin/create_source.rb`) pro konzistenci

---

### ADR-007: `Post` jako univerzální mezimodel

**Datum:** leden 2026

**Kontext:**
Každá platforma vrací data v jiném formátu (Bluesky AT Protocol, Twitter JSON, RSS XML, YouTube Atom…).
Alternativy: platform-specifická data přes celý pipeline, nebo unifikovaný mezimodel.

**Rozhodnutí:**
Všechny adaptéry vrací `Post` – datový objekt s fixní sadou atributů s rozumnými defaults:
`id`, `text`, `url`, `author`, `media`, `is_repost`, `is_quote`, `quoted_post`, `is_reply`, `reply_to`, `created_at`, `uri` aj.

**Důsledky:**
- ✅ Formatter a pipeline kroky pracují s jedním typem – žádná platform-specifická větvení downstream
- ✅ Testy pipeline jsou platform-agnostické
- ✅ Přidání nové platformy = nový adaptér, pipeline se nedotýká
- ❌ `Post` musí mít rozumné defaults pro atributy, které ne každá platforma plní

---

### ADR-008: Explicitní kroková pipeline v `PostProcessoru`

**Datum:** leden–únor 2026

**Kontext:**
Zpracování postu zahrnuje deduplikaci, filtrování, formátování, content replacement, ořezání délky, URL processing, media enrichment a publikaci. Mohlo být implementováno jako jedna velká metoda, chain of responsibility, nebo explicitní kroky.

**Rozhodnutí:**
Explicitní sekvenční kroky v `PostProcessor#process`:
`DeduplicationStep → EditDetectionStep → ContentFilterStep → FormattingStep → ContentReplacementStep → TrimmingStep → UrlProcessingStep → MediaEnrichmentStep → PublishingStep`

**Důsledky:**
- ✅ Každý krok lze testovat izolovaně
- ✅ Pořadí kroků je viditelné a pochopitelné
- ✅ Early return (`:skipped`) je čitelný
- ✅ Přidání nového kroku = nová třída, ostatní se nedotýká
- ❌ Verbóznější než funkcionální pipeline; akceptovatelné pro explicitnost

---

### ADR-009: Evidence-based development – žádné preemptivní optimalizace

**Datum:** průběžně 2026

**Kontext:**
Při vývoji se opakovaně objevovala lákadla k preemptivním refaktoringům a optimalizacím „pro jistotu".

**Rozhodnutí:**
Změny se dělají na základě reálně pozorovaných problémů v produkci, ne na základě teoretických obav.
Technický dluh se dokumentuje (viz `technical_debt_private.md`) ale neřeší, dokud není evidence, že způsobuje skutečný problém.

**Příklady aplikace:**
- `@thread_cache` bez LRU eviction – v cron modelu nevadí, odloženo
- Daemon model místo cronu – neimplementováno, cron plně postačuje
- Per-core load thresholds v health monitoru – implementováno až po produkčních alertech

**Důsledky:**
- ✅ Kód zůstává jednoduchý; komplexita se přidává jen tehdy, když ji potřebujeme
- ✅ Rychlejší iterace v počátečních fázích vývoje
- ❌ Technický dluh se může akumulovat; mitigováno průběžnou dokumentací

---

## 3. Zpracování obsahu

### ADR-010: PostgreSQL pro state management

**Datum:** leden 2026

**Kontext:**
Systém potřebuje pamatovat si, co bylo publikováno (deduplikace), kdy byl zdroj naposledy fetchován a jaký je Mastodon ID posledního postu (pro threading).
Alternativy: SQLite soubory per bot, Redis, PostgreSQL, JSON state soubory.

**Rozhodnutí:**
PostgreSQL s oddělenými schématy (`zpravobot` pro produkci, `zpravobot_test` pro vývoj).
Klíčové tabulky: `published_posts`, `source_state`, `activity_log`, `edit_detection_buffer`, `media_fingerprints`.

**Důsledky:**
- ✅ ACID transakce – žádné race conditions
- ✅ SQL queries pro reporting a debugging
- ✅ Oddělené schéma pro test = bezpečné experimenty bez dopadu na produkci
- ❌ PostgreSQL dependency
- ❌ „Squatujeme" v DB Mastodon instance – pro jednodušší use cases preferovat JSON soubory (viz ADR-029)

---

### ADR-011: Oddělená tabulka `edit_detection_buffer`

**Datum:** únor 2026

**Kontext:**
Potřebujeme detekovat editované posty. Alternativy: full-text scan `published_posts` (2M+ záznamů ročně), nebo separátní buffer jen pro nedávné posty.

**Rozhodnutí:**
Separátní tabulka `edit_detection_buffer` s TTL (záznamy starší než 2 hodiny se mažou).

**Důsledky:**
- ✅ Query nad malou tabulkou (~200 záznamů) je řádově rychlejší
- ✅ `published_posts` zůstává čistým permanentním záznamem
- ✅ Jasná separace: „co jsme publikovali" vs „co jsme nedávno viděli"

---

### ADR-012: Edit detection – Jaccard + containment similarity, threshold 0.80

**Datum:** únor 2026

**Kontext:**
Pro detekci editací bylo potřeba zvolit algoritmus podobnosti a práh.
Alternativy: Levenshtein distance, čistá Jaccard, prefix matching, kombinace metrik.

**Rozhodnutí:**
Vážená kombinace: `max(Jaccard, containment) × 0.85 + prefix × 0.15`.
Threshold: 0.80 (80 % podobnost = edit).

**Kontext rozhodnutí:**
Čistá Jaccard penalizuje přidání slov na konec (typický Twitter edit). Prefix matching penalizuje edity uprostřed textu. Containment (`kolik % kratšího textu je v delším`) zachytí přidání slov bez penalizace. Kombinace pokrývá oba případy.

**Důsledky:**
- ✅ Zachytí edity přidávající slova na konec (containment) i edity uprostřed (Jaccard)
- ✅ Threshold 0.80 má nízký počet false positives v praxi
- ❌ Může selhat u velmi krátkých postů (nestabilní Jaccard)

---

### ADR-013: Edit s médii → delete + republish; edit bez médií → Mastodon update

**Datum:** únor 2026

**Kontext:**
Mastodon Update API (`PUT /api/v1/statuses/:id`) umožňuje změnit text, ale **média jsou immutable** – `media_ids` při update jsou ignorovány.

**Rozhodnutí:**
- Edit bez médií → `update_status()` (Mastodon vytvoří historii verzí)
- Edit s médii → `delete_status()` + `publish()` (nový post)

**Důsledky:**
- ✅ Zobrazí se aktualizovaný obsah včetně médií
- ❌ Delete + republish ztratí boosty a replies původního postu

---

### ADR-014: Video deduplication přes SHA-256 hash

**Datum:** březen 2026

**Kontext:**
Účet @Rainmaker1973 publikuje ~210 postů denně, z toho ~2/3 jsou duplicitní (stejné video, mírně upravený text).
Alternativy: perceptuální hash (vyžaduje ffmpeg), textová deduplikace, binární SHA-256 hash.

**Rozhodnutí:**
SHA-256 hash z binárních dat stáhnutého MP4, uložený v tabulce `media_fingerprints`.

**Kontext rozhodnutí:**
Empiricky ověřeno, že Twitter při opakovaném zveřejnění stejného videa **nerekóduje** – SHA-256 hashů identických videí se shodují byte-for-byte. Perceptuální hash s ffmpeg by byl zbytečnou komplexitou.

**Důsledky:**
- ✅ Spolehlivá deduplication bez externích závislostí
- ✅ Nulové false positives
- ❌ Pokud by Twitter v budoucnu rekódoval videa, hash přestane fungovat

---

## 4. Twitter platforma

### ADR-015: Twitter – hybridní IFTTT + Nitter, třístupňový systém

**Datum:** leden 2026

**Kontext:**
Twitter/X neumožňuje scraping bez API. Alternativy:
- Čistý Nitter polling – spaluje burner účty při 300+ zdrojích
- Čisté IFTTT – spolehlivý trigger, ale ořezaný text, jen 1 obrázek, žádná vlákna
- Hybrid: IFTTT jako push trigger, Nitter pro doplnění dat

**Rozhodnutí:**
Třístupňový systém:
- **Tier 1** – IFTTT data jsou kompletní → přímá publikace
- **Tier 2** – IFTTT trigger + Nitter HTML fetch pro kompletní data (vlákna, více obrázků, zkrácený text, quotes)
- **Tier 3** – Nitter nedostupný → IFTTT data + `📖➡️` indikátor

**Důsledky:**
- ✅ Burner účty se spotřebovávají jen na fetch konkrétních tweetů, ne polling 300 účtů
- ✅ Tier 3 zajišťuje, že vždy něco publikujeme (degraded mode místo ztráty dat)
- ❌ Komplikovanější architektura než čistý polling
- ❌ IFTTT Pro+ předplatné je nutností (business dependency)

---

### ADR-016: Priority jako sémantická zkratka pro scheduling i IFTTT frontu

**Datum:** leden 2026

**Kontext:**
Priorita `high/normal/low` mohla být jen interní konfigurace intervalů, nebo mohla řídit i chování IFTTT fronty. Záměrem bylo jednoduché sémantické pravidlo: „jak rychle potřebuji aktualizace".

**Rozhodnutí:**
Priority mají dvojí efekt:
1. **Scheduling interval** (Orchestrátor): `high` = 5 min, `normal` = 20 min, `low` = 55 min
2. **IFTTT fronta**: `high` = okamžité zpracování; `normal`/`low` = batch s 2minutovým zpožděním pro správné seřazení threadů

**Důsledky:**
- ✅ Operátor nastavuje jedinou hodnotu a zbytek se odvíjí automaticky
- ✅ Batch delay pro `normal`/`low` přirozeně pomáhá thread detection
- ❌ Batch delay způsobuje 2minutové zpoždění i pro posty, které žádné vlákno netvoří

---

### ADR-017: Rychlost > threading při výpadku Nitteru; žádná fronta čekajících

**Datum:** leden 2026

**Kontext:**
Při výpadku Nitteru bylo možné: přidat tweet do fronty čekajících a zkusit znovu za X minut, nebo okamžitě fallback na Tier 3.

**Rozhodnutí:**
Žádná fronta čekajících. Po 3 pokusech (1s, 2s, 4s) okamžitě Tier 3.
Zpravodajský obsah ztrácí hodnotu s časem; lepší publikovat něco teď než kompletní post za 30 minut.

**Důsledky:**
- ✅ Žádný backlog, systém zpracovává v reálném čase
- ✅ Jednoduchá implementace bez fronty a state management pro čekající posty
- ❌ Tier 3 posty mají horší kvalitu (zkrácený text, méně médií)

---

### ADR-018: Nitter cookies přes SOCKS5 proxy (IP matching)

**Datum:** leden 2026

**Kontext:**
Nitter vyžaduje Twitter session cookies. Pokud se přihlásíte do Twitteru z jiné IP, než ze které Nitter volá API, Twitter session okamžitě invaliduje.

**Rozhodnutí:**
Cookies se získávají výhradně přes SSH SOCKS5 tunel do Nitter VPS (`ssh -D 1080 -N -4 user@nitter-vps`), takže přihlášení na Twitter probíhá ze stejné IP jako Nitter API volání.

**Důsledky:**
- ✅ Session zůstane platná (Twitter vidí konzistentní IP)
- ❌ Přidání nového burner účtu vyžaduje manuální postup se SSH tunelem
- ❌ Nelze se odhlásit (invaliduje session); prohlížeč je třeba zavřít bez logout

---

### ADR-048: `TwitterTweetProcessor` — unifikace IFTTT a RSS vstupních kanálů

**Datum:** únor 2026

**Kontext:**
Twitter posty přicházely dvěma cestami: IFTTT webhook (real-time push) a Nitter RSS polling (periodický pull). Každá cesta měla vlastní Tier logiku, threading a zpracování — funkčně nekonzistentní a obtížně udržovatelné. Adaptér se původně jmenoval `IftttTwitterAdapter`, název odrážel IFTTT původ místo skutečné funkce.

**Rozhodnutí:**
Nová unifikovaná vrstva `TwitterTweetProcessor` (`lib/processors/twitter_tweet_processor.rb`). Oba kanály předají jen `post_id + username + source_config + fallback_post` — od tohoto bodu identická Tier logika, identický threading, identický `PostProcessor`.
IFTTT větev odpovídá za: příjem payloadu, queue management, priority systém, edit detection.
RSS větev odpovídá za: polling, scheduling.
Adaptér přejmenován `IftttTwitterAdapter → TwitterNitterAdapter` (název popisuje funkci, ne trigger).

**Důsledky:**
- ✅ Jedna Tier logika, jeden threading mechanismus — konzistentní výstup z obou kanálů
- ✅ Odstraněn `TwitterThreadFetcher` a `maybe_fetch_thread_context` (mrtvý kód)
- ✅ Přidání nového vstupního kanálu = nový vstupní bod, pipeline se nedotýká
- ❌ `TwitterTweetProcessor` je singleton sdílený napříč sources — thread cache je sdílená (záměrné)

---

### ADR-049: IFTTT Failed Queue — `DEAD_` prefix místo mazání selhavších webhooků

**Datum:** únor 2026

**Kontext:**
Selhavší webhooky v `failed/` se nikdy neopakovaly — trvalá ztráta obsahu při přechodných selháních (Nitter timeout, Mastodon rate limit). Alternativy: mazat soubory (ztráta auditní stopy), retryovat vše donekonečna (nevratné chyby se opakují zbytečně), klasifikovat na retryable vs. DEAD.

**Rozhodnutí:**
`bin/retry_failed_queue.rb` klasifikuje soubory v `failed/`:
- **PERMANENT_ERRORS** (smazaný tweet, neznámý bot_id, nevalidní JSON, prázdný text) → prefix `DEAD_`, soubor zůstává v `failed/` jako archiv
- **Retryable** (timeout, rate limit, přechodná chyba) → vrátí se do `pending/`, `MAX_RETRIES=1`, `MAX_RETRY_AGE=6h`

`move_to_failed()` přidává `_failure: { retry_count, reason, timestamp }` do JSON před přesunem.
Health monitor vidí `dead_count` separátně od `failed_count`.

**Důsledky:**
- ✅ Přechodné chyby mají druhou šanci bez manuálního zásahu
- ✅ DEAD soubory slouží jako archiv pro post-mortem analýzu
- ❌ `failed/` adresář roste — operátor musí periodicky mazat DEAD soubory ručně

---

## 5. Bluesky platforma

### ADR-019: Bluesky přes AT Protocol API místo RSS

**Datum:** leden 2026

**Kontext:**
Bluesky nabízí RSS feed a veřejné AT Protocol API.
RSS feed neposkytuje reposty vůbec – pro zpravodajské boty deal-breaker.

**Rozhodnutí:**
AT Protocol API (`app.bsky.feed.getAuthorFeed`). Veřejné endpointy, nevyžaduje autentizaci.

**Důsledky:**
- ✅ Kompletní data – posty, reposty, quotes, vlákna, metadata médií
- ✅ Strukturovaný JSON přímo mapuje na `Post` model
- ❌ Dependency na AT Protocol API; při změně API nutná úprava adaptéru

---

### ADR-020: Bluesky threading – nativní reply chain

**Datum:** leden 2026

**Kontext:**
Bluesky API přímo poskytuje `reply.parent.uri` a `reply.root.uri` pro každý post (na rozdíl od Twitteru, viz ADR-021).

**Rozhodnutí:**
Bluesky vlákna se publikují jako Mastodon reply chain: každá část vlákna s `in_reply_to_id` na Mastodon ID předchozí části. State management mapuje `bluesky_uri → mastodon_id`.

**Důsledky:**
- ✅ Nativní Mastodon vlákno
- ✅ 100% spolehlivé (metadata z API, ne heuristika)
- ❌ Vyžaduje ukládání mapování `uri → mastodon_id` do databáze

---

### ADR-021: Twitter threading – heuristika z HTML scrapingu

**Datum:** leden 2026

**Kontext:**
Twitter v Nitter RSS/HTML neposkytuje `in_reply_to_status_id` ani `conversation_id`. Thread je potřeba rekonstruovat z HTML.

**Rozhodnutí:**
Thread detection z Nitter HTML stránky `/status/{id}` – sekce `before-tweet` obsahuje předcházející tweety vlákna.
Pokud chain nelze rekonstruovat, tweet se publikuje standalone.

**Důsledky:**
- ✅ Funguje pro majority self-reply vláken
- ❌ Méně spolehlivé než Bluesky (závisí na HTML struktuře Nitteru)
- ❌ Nelze spolehlivě detekovat odpovědi na cizí tweety

---

## 6. RSS, Facebook, Instagram

### ADR-022: Facebook a Instagram přes RSS.app

**Datum:** leden 2026

**Kontext:**
Facebook ani Instagram nemají veřejné API ani RSS feedy. Alternativy: přímý scraping (nestabilní, agresivní anti-bot), nebo RSS.app jako zprostředkovatel.

**Rozhodnutí:**
RSS.app pro Facebook a Instagram. Data se zpracovávají jako standardní RSS s extra procesory pro FB/IG specifika.

**Důsledky:**
- ✅ Žádná závislost na headless browseru v produkčním pipeline
- ❌ RSS.app je placená služba (business dependency)
- ❌ Formátování IG captionů je ztraceno (RSS.app flattuje odstavce) – řešeno heuristicky (viz ADR-023)

---

### ADR-023: Instagram formátování captionů – heuristika místo Browserless

**Datum:** duben 2026

**Kontext:**
RSS.app flattuje Instagram captions do jednoho bloku bez odstavců.
Alternativy: Browserless.io pro fetch originální IG stránky (spolehlivé, ale přidává závislost a latenci), nebo heuristická rekonstrukce.

**Rozhodnutí:**
Heuristika (`InstagramProcessor`): detekce IG vzorů (hashtag bloky, emoji jako bullet, sekvence emoji jako oddělovač) a vložení `\n\n`. Free tier Browserless by kapacitně stačil, ale riziko bloku od Instagramu a latence v pipeline ho diskvalifikovaly.

**Důsledky:**
- ✅ Funguje offline, nulové externí závislosti
- ✅ Zachytí nejčastější IG patterny spolehlivě
- ❌ Próza bez výrazných signálů se nerekonstruuje – edge case

---

### ADR-024: Mentions transformace vypnutá pro RSS, Facebook, Instagram

**Datum:** leden 2026

**Kontext:**
Původní záměr byl transformovat `@username` na URL. Po testování: URL mention způsobuje Mastodon preview hijack a vizuálně mate čtenáře.

**Rozhodnutí:**
Mentions transformace vypnutá (`type: 'none'`) pro RSS/FB/IG. `@username` zůstává jako prostý text.

**Důsledky:**
- ✅ Žádný preview hijack
- ✅ Čitelnější posty
- ❌ `@username` není klikatelný – akceptovatelné, stejný handle zpravidla neexistuje na Mastodonu

---

## 7. Publikování na Mastodon

### ADR-025: Dummy 1×1px PNG jako workaround pro Mastodon mention preview hijack

**Datum:** březen 2026

**Kontext:**
Mastodon chování: pokud post obsahuje `@mention` a nemá žádná média, vygeneruje se preview karta na první zmíněný profil – ne na URL článku. Podmínka: post má mention + nemá media.

Alternativy: mentions nepřidávat vůbec; přidávat jen pokud post má vlastní média; dummy media attachment.

**Rozhodnutí:**
Pokud post obsahuje alespoň jednu mention a nemá vlastní média → přidat `assets/transparent_1x1.png` jako media attachment před publikací.

**Důsledky:**
- ✅ Mention preview hijack eliminován
- ✅ Mentions v textu fungují (klikatelné lokální profily)
- ❌ Post s dummy obrázkem negeneruje link card z URL (Mastodon upřednostní media) – akceptovatelné, lepší než karta na špatný profil
- ❌ Workaround závisí na konkrétním chování Mastodon

---

### ADR-026: URL zkracovač neimplementovat

**Datum:** leden 2026

**Kontext:**
Xcancel URL jsou dlouhé (60+ znaků). Byl zvažován vlastní zkracovač (`zbnw.cz`).

**Rozhodnutí:**
Zkracovač neimplementovat. **Mastodon počítá každou URL jako přesně 23 znaků bez ohledu na délku.** Zkrácení neušetří ani jeden znak v limitu postu – přínos by byl čistě vizuální za cenu registrace domény, provozování redirect service a dalšího bodu selhání.

**Důsledky:**
- ✅ Jednodušší architektura, žádná další závislost
- ✅ Xcancel URL jsou srozumitelné (čtenář ví, kam míří)
- ❌ Posty mají delší URL vizuálně (nevadí, Mastodon je zkrátí v zobrazení)

---

### ADR-027: URL délka v Mastodonu – pevná konstanta 23, `max_chars` konfigurovatelný

**Datum:** leden 2026

**Kontext:**
Dřívější chyba: `MASTODON_MAX_CHARS = 500` bylo hardcoded v kódu. `zpravobot.news` má limit 2500 znaků. URL délka 23 znaků je součástí Mastodon specifikace (platí pro všechny instance).

**Rozhodnutí:**
- `MASTODON_URL_LENGTH = 23` – pevná konstanta (specifikace, ne konfigurace)
- `MASTODON_MAX_CHARS` – konfigurovatelný per instance v YAML

**Důsledky:**
- ✅ Přesný výpočet délky postu i s URL
- ✅ Bez nutnosti API callu pro zjištění hodnoty per instance
- ❌ Pokud by Mastodon změnil specifikaci, je potřeba ruční update (velmi nepravděpodobné)

---

### ADR-050: MIME type médií z magic bytes, ne z přípony souboru

**Datum:** únor 2026

**Kontext:**
Mastodon odmítal uploadovaná média s chybou „File has contents that are not what they are reported to be". Příčina: CDN servery (Twitter, Nitter) servírují jiný formát než naznačuje přípona URL — typicky WebP na URL s `.jpg`. Původní kód detekoval MIME typ z přípony souboru.

**Rozhodnutí:**
Primárním zdrojem MIME typu jsou **magic bytes** (binární signatury obsahu souboru) — detekce JPEG, PNG, GIF, WebP, MP4, WebM z prvních bajtů stáhnutého souboru. Přípona souboru je pouze fallback. Před uploadem se i název souboru opraví aby odpovídal detekovanému formátu.
`application/octet-stream` (nerozpoznaný formát) se odmítne místo odesílání s falešným `image/jpeg`.

**Důsledky:**
- ✅ Žádné 422 chyby při uploadu médií z CDN s nesprávnými příponami
- ✅ Mastodon dostane konzistentní Content-Type i filename
- ❌ Detekce vyžaduje stáhnout alespoň prvních N bajtů — akceptovatelné, soubor se stahuje stejně

---

### ADR-054: Local mentions — typ `domain_suffix_with_local`

**Datum:** únor 2026

**Kontext:**
Twitter mentions se transformovaly na `@handle@twitter.com`. Pokud handle odpovídá zdroji na `zpravobot.news`, tento formát nevytvoří klikatelný lokální profil ani notifikaci. Alternativy: neřešit (ztráta interakce), whitelist ručně, dynamická mapa z konfigurace.

**Rozhodnutí:**
Nový typ mentions transformace `domain_suffix_with_local`: `ConfigLoader` sestaví mapu `{ twitter_handle → mastodon_id }` ze všech Twitter sources s instancí `zpravobot.news`. Pro known handle → `@id@zpravobot.news` (lokální), pro unknown → `@handle@twitter.com` (fallback). Mapa se cachuje v `@twitter_handle_map`. Orchestrátor i IFTTT větev automaticky obohacují konfiguraci pro Twitter sources.

**Důsledky:**
- ✅ Mention na sledovaný účet vytvoří klikatelný profil a notifikaci botu
- ✅ Nový Twitter zdroj = automaticky v mapě, žádná extra konfigurace
- ❌ Mapa je sestavena při startu — přidání nového zdroje bez restartu efekt nenastane (akceptovatelné, cron model)

---

## 8. Synchronizace profilů

### ADR-028: Profile sync – frekvence a které boty synchronizovat

**Datum:** leden 2026

**Kontext:**
Mastodon profily botů (avatar, banner, bio, fields) je třeba udržovat v souladu s původní platformou. Otázky: jak často synchronizovat a které boty vůbec synchronizovat?

**Rozhodnutí:**
- Bluesky boti: sync 4× denně (API je stabilní)
- Twitter boti: sync 2× denně (Nitter scraping je pomalejší)
- Agregátoři (více zdrojů na jednom botu): sync vypnutý – nemají jeden „originální" profil
- Default: `profile_sync: enabled: false`; každý bot musí explicitně opt-in

**Důsledky:**
- ✅ Profily botů zůstávají aktuální automaticky
- ✅ Agregátoři nemají falešnou „originalitu" jedné platformy
- ❌ Nitter scraping pro Twitter profile sync je křehčí než Bluesky API

---

### ADR-029: Mastodon fields – `field_1` = zdroj profilu, `SPRAVUJE` = zdroj obsahu

**Datum:** leden 2026

**Kontext:**
U botů, kde se vizuální identita bere z jiné platformy než obsah, mohlo dojít k záměně „odkud syncujeme profil" a „odkud pochází obsah".

**Rozhodnutí:**
Jasná sémantika fields:
- **Field 1** (`X:` / `BLUESKY:` / `RSS:`) → odkud pochází *vizuální identita*
- **Field 2** (`WEB:`) → web zdroje nebo `—`
- **Field 3** (`SPRAVUJE:`) → `@zpravobot@zpravobot.news z X` (odkud pochází *obsah*)
- **Field 4** (`RETENCE:`) → retence dat (30/90/180 dní)

Příklad: RSS bot, který vizuál bere z Twitteru:
- Field 1: `X: twitter.com/handle` (vizuál)
- Field 3: `SPRAVUJE: @zpravobot@zpravobot.news z RSS` (obsah)

**Důsledky:**
- ✅ Jednoznačná sémantika pro čtenáře profilu
- ✅ Automatická aktualizace via profile sync

---

### ADR-052: RSS profile sync — delegátor na platform syncery, bez `RssProfileSyncer`

**Datum:** únor 2026

**Kontext:**
RSS boti mají vizuální identitu z jiné platformy (Twitter, Bluesky, Facebook). Bylo třeba rozhodnout, jak implementovat profile sync: nová třída `RssProfileSyncer` (čistší abstrakce), nebo delegátor volající stávající platform syncery.

**Rozhodnutí:**
`sync_profiles.rb` deleguje RSS zdroje na `sync_twitter_for_rss` / `sync_bluesky_for_rss` / `sync_facebook_for_rss` — žádná nová třída. Klíčový detail: `source.source_handle` u RSS vrací URL feedu (ne sociální handle) — handle se čte z `social_profile.handle` v YAML. Extrahován sdílený `run_syncer` helper eliminující duplikaci.

**Důsledky:**
- ✅ Žádná nová třída — stávající platform syncery pokrývají celý use case
- ✅ RSS bot se chová jako platform bot pro účely profile sync — konzistentní výstup
- ❌ Delegátor musí explicitně mapovat `social_profile.platform` → správný syncer; nová platforma = nová větev

---

## 9. Pomocné funkce

### ADR-030: FF rotace – stav v JSON souboru, ne v databázi

**Datum:** duben 2026

**Kontext:**
Friendly Follow (#FF) rotace potřebuje trackovat, kteří účty byli v aktuálním cyklu zmíněni.
Alternativy: DB tabulka (`ff_rotation`), JSON soubor.

**Rozhodnutí:**
JSON soubor (`data/ff_rotation.json`): `{ cycle, promoted: [], remaining: [] }`.
DB tabulka by byla zbytečná – nepotřebujeme dotazování, relace ani transakce.

**Kontext rozhodnutí:**
ZBNW-NG „squatuje" v PostgreSQL databázi Mastodon instance. Každá nová tabulka je zásah do cizí DB; JSON soubor tuto závislost eliminuje pro jednoduché use cases.

**Důsledky:**
- ✅ Jednoduchá implementace, čitelný a debugovatelný stav
- ❌ Při souběžném zápisu může dojít ke korrupci – akceptovatelné, FF skript běží jako jediný cron job

---

## 10. Doplňkové subsystémy

### ADR-031: Bluesky jako cíl publikace (cross-posting)

**Datum:** duben 2026

**Kontext:**
Bluesky byl dosud výhradně **zdrojem** obsahu (adaptér čte posty). Alternativy pro rozšíření dosahu zpravobot.news obsahu:
- Zůstat Mastodon-only
- IFTTT bridge na Bluesky (nelze, IFTTT podporuje jen Mastodon)
- Vlastní `BlueskyPublisher` s AT Protocol API

**Rozhodnutí:**
Bluesky se stává i **cílem** — `BlueskyPublisher` publikuje paralelně s Mastodonem ze čtyř doplňkových cron skriptů: `zpravobot_stats.rb`, `trending_post.rb`, `friendly_follow.rb`, `source_report.rb`.
Hlavní bot pipeline (news posty) zůstává Mastodon-only.

**Důsledky:**
- ✅ Zdvojený dosah (Mastodon + Bluesky) pro meta-obsah bez změny hlavní pipeline
- ✅ AT Protocol API je veřejné, nevyžaduje schválení
- ❌ Druhá aktivní session (AT identifier + password) a ruční obnova při expiry
- ❌ Bluesky AT Protocol se vyvíjí; breaking changes jsou reálné

---

### ADR-032: Friendly Follow — Mastodon jeden post, Bluesky vlákno per účet

**Datum:** duben 2026

**Kontext:**
Mastodon a Bluesky mají odlišné limity a konvence. Mastodon instance má 2500 znaků a jedno vlákno je přirozené. Bluesky má limit 300 grafémů a jedno dlouhé vlákno je problematické.
Navíc formát mentions se liší: na Mastodonu funguje `@handle@instance`, na Bluesky je třeba `@handle.bsky.social` (DID-based).

**Rozhodnutí:**
- **Mastodon:** jeden long post s abecedně seřazenými účty (formát `@handle@instance`)
- **Bluesky:** vlákno, kde každý FF účet je samostatný post ≤300 grafémů (format `@handle.bsky.social`)

**Důsledky:**
- ✅ Platformně-přirozený výstup na obou stranách
- ✅ Bluesky vlákno je lépe čitelné a lajkovatelné po částech
- ❌ Dvě oddělené cesty formátování v `bin/friendly_follow.rb`

---

### ADR-033: Trending quote-posty s AI komentáři (Hrubot)

**Datum:** únor–duben 2026

**Kontext:**
Posty s vysokou viralitou na zpravobot.news byly „neviditelné" pro uživatele, kteří nesledují instanci přímo. Alternativy:
- Manuální sdílení (neudržitelné)
- Automatický boost (nepřidává hodnotu)
- Quote-post s AI komentářem z `@zpravobot`

**Rozhodnutí:**
`bin/trending_post.rb` pravidelně fetchuje trending statusy Mastodon instance, a ty nad konfigurovaným prahem retootů/favů quote-postuje z `@zpravobot`.
Volitelně se připojí AI komentář od Hrubota (`lib/trending/hrubot_commenter.rb`) generovaný přes Claude API (model `claude-sonnet-4-6`).

**Technické detaily rozhodnutí:**
- State file (`data/trending_state.json`) brání duplicitnímu publikování
- `MAX_POSTS_PER_RUN = 5` a `THROTTLE_SECONDS = 2` chrání před burst publikováním
- Bot-owned účty (`betabot`, `udrzbot`, `tlambot`) jsou z trendingu vyloučeny

**Důsledky:**
- ✅ Virální obsah dostane druhou šanci u jiného publika
- ✅ AI komentář přidává editorský hlas bez manuální práce
- ❌ AI dependency — pokud Claude API selže, komentář se přeskočí (graceful degradation)
- ❌ Riziko quote-postování triviálního obsahu při nízkém provozu na instanci (mitigováno prahem)

---

### ADR-034: Týdenní hitparáda #ZpravobotTOP10

**Datum:** únor 2026

**Kontext:**
Neexistoval žádný pravidelný přehled toho, co bylo na zpravobot.news nejúspěšnější. Alternativy:
- Manuální sestavení (neudržitelné)
- Výpis z DB bez formátování
- Automatický týdenní post ze stávajících dat

**Rozhodnutí:**
`bin/zpravobot_stats.rb` (cron každou neděli) sbírá statistiky z Mastodon API, sestavuje TOP 10 postů týdne a publikuje jako vlákno na Mastodon i Bluesky pod hashtagem `#ZpravobotTOP10`.

**Důsledky:**
- ✅ Pravidelný engagement bez manuální práce
- ✅ Slouží i jako systémová verifikace — pokud selže, víme o problému s API
- ❌ Závisí na dostupnosti Mastodon instance stats endpointů

---

### ADR-035: Údržbot — interaktivní ovládání přes Mastodon mentions

**Datum:** únor 2026

**Kontext:**
Diagnostika a operace (stav zdrojů, reload, check) dříve vyžadovaly SSH přístup na server. Alternativy:
- Webový admin panel (velká investice)
- Telegram/Signal bot (třetí platforma)
- Mastodon mentions na `@udrzbot` (zero-dependency, funguje z mobilu)

**Rozhodnutí:**
`bin/command_listener.rb` (cron každých 5 minut) polluje mention notifikace `@udrzbot`. Autorizovaní uživatelé mohou posílat příkazy (`status`, `detail {source}`, `check {source}`, `sources`, `help`). Bot odpovídá v DM.

**Důsledky:**
- ✅ Plná diagnostika přístupná z Mastodon klienta na mobilu
- ✅ Zero-dependency na třetích stranách
- ❌ Polling každých 5 minut = latence odpovědi 0–5 min
- ❌ Bezpečnostní hranice je whitelist účtů v konfiguraci — chyba konfigurace = neautorizovaný přístup

---

### ADR-036: Tlambot — broadcast spouštěný Mastodon webhookem

**Datum:** únor 2026

**Kontext:**
Hromadné zprávy (oznámení výpadku, systémové informace) bylo možné odesílat jen ručně přes `bin/broadcast.rb` se SSH přístupem. Alternativy:
- Webový trigger (třetí systém)
- IFTTT (nespolehlivý pro systémové účely)
- Mastodon webhook z dedikovaného účtu `@tlambot`

**Rozhodnutí:**
Post na účtu `@tlambot` triggeruje Mastodon `status.created` webhook → `TlambotWebhookHandler` (HMAC verifikace) → fronta souborů → `TlambotQueueProcessor` → broadcast všem/vybraným účtům.

**Důsledky:**
- ✅ Broadcast = post na Mastodonu, bez nutnosti SSH
- ✅ HMAC verifikace webhookového payloadu chrání před zneužitím
- ❌ Tlambot webhook server musí být živý (viz ADR-003 o `setsid`)
- ❌ Výpadek webhook serveru = tichá ztráta triggeru (cron watchdog restartuje, ale trigger se nepřehraje)

---

## 11. Bezpečnost a spolehlivost

### ADR-037: Non-blocking rate limit handling — `AccountRateLimitedError`

**Datum:** duben 2026

**Kontext:**
Mastodon vrací HTTP 429 při překročení rate limitu. Původní chování: `sleep(retry_after)`. Při hromadném publikování na stovky účtů by jeden rate-limited účet zablokoval celý cron run.

**Rozhodnutí:**
`MastodonPublisher` při 429 uloží `@rate_limited_until` a vyhodí `AccountRateLimitedError`. Pipeline vrátí `:rate_limited`, orchestrátor přeskočí účet. Pro IFTTT frontu soubory zůstávají v `pending/` a zpracují se v dalším cron tiku.
Pre-flight check (`raise_if_rate_limited!`) zabrání i zbytečným round-tripům před expiry.

**Důsledky:**
- ✅ Rate-limited účet nezablokuje zpracování ostatních
- ✅ Soubory v `pending/` se nepřepíší, obsah se neztratí
- ❌ Rate-limited účet má zpoždění publikace O(minuty) místo okamžitého retry
- ❌ Komplexnější state tracking (Set rate-limited účtů v IftttQueueProcessor)

---

### ADR-038: Webhook hardening — Content-Length limit, field caps, sanitizace souborů

**Datum:** duben 2026

**Kontext:**
IFTTT webhook přijímá data z externího triggeru bez záruky integrity payloadu. Identifikované vektory:
- Neomezený Content-Length → memory exhaustion
- Nevalidovaná délka polí → log injection / DB bloat
- Nesanitizovaný `bot_id` v názvech souborů fronty → path traversal

**Rozhodnutí:**
- `MAX_PAYLOAD_SIZE = 1 MB` (HTTP 413 při překročení)
- Délkové limity: `bot_id` ≤100, `username` ≤100, `text` ≤50 000 znaků
- `sanitize_filename_part()` helper na všech místech, kde `bot_id` / `username` vstupuje do cesty souboru

**Důsledky:**
- ✅ Odolnost proti malformovaným nebo záměrně maliciózním webhookům
- ✅ Log entries mají předvídatelnou délku
- ❌ Legitimní extrémně dlouhý text (>50k) bude odmítnut — akceptovatelné, žádný reálný use case

---

### ADR-039: OGP fetcher — SSRF blocklist privátních IP rozsahů

**Datum:** duben 2026

**Kontext:**
`OgpFetcher` fetchuje og:image z URL obsažených v postech. Bez ochrany by bylo možné z IFTTT payloadu dodat URL na `169.254.x.x` (metadata service) nebo `10.x.x.x` (interní síť).

**Rozhodnutí:**
`private_address?` metoda kontroluje resolvnutou IP oproti privátním rozsahům (`10/8`, `172.16/12`, `192.168/16`, `127/8`, `169.254/16`, `::1`, `fc00::/7`) jak před fetchem, tak při každém redirectu.

**Důsledky:**
- ✅ SSRF útok z maliciózní URL blokován na síťové úrovni
- ❌ Legitimní URL na neveřejné IP (dev env) bude odmítnuto — neovlivňuje produkci

---

### ADR-040: Atomic file writes pro JSON state

**Datum:** duben 2026

**Kontext:**
State soubory (`data/ff_rotation.json`, `data/trending_state.json`, `data/alert_state.json`) jsou zapisovány přímo. SIGKILL nebo výpadek napájení uprostřed zápisu = corrupted JSON = selhání při dalším spuštění.

**Rozhodnutí:**
`Utils::AtomicFile.write` zapíše data do `{path}.tmp` a pak provede `File.rename` (atomická operace na POSIX). Každý zápis JSON state jde přes tento helper.

**Důsledky:**
- ✅ Čtec vždy vidí buď starý kompletní soubor nebo nový kompletní soubor — nikdy corrupted
- ✅ Implementace je triviální (15 řádků), žádná závislost
- ❌ Rename není atomický přes filesystémové hranice — akceptovatelné, vše je na stejném disku

---

### ADR-041: Twitter video + image konflikt → drop images

**Datum:** březen 2026

**Kontext:**
Mastodon API vrátí HTTP 422 pokud post obsahuje zároveň video a obrázky (mixed-media error). Twitter posty mohou mít thumbnail videa extrahovaný jako obrázek + samotné video.

**Rozhodnutí:**
Pokud post obsahuje video, obrázky se zahodí před uploadem. Video má přednost.

**Důsledky:**
- ✅ Žádné 422 chyby při publikaci videí
- ✅ Implementace je jednoduchá (guard clause v media upload stepu)
- ❌ Posty s videem + doprovodnou galerií (reálně vzácné) ztratí galerii

---

### ADR-042: Smart alerting — per-core CPU thresholds, alert cooldown

**Datum:** únor 2026

**Kontext:**
Původní health monitor alertoval na absolutní load average bez ohledu na počet CPU jader. Na 4-jádrovém serveru je load 3.5 normální, ale alert prahy byly nastaveny pro 1 jádro.

**Rozhodnutí:**
CPU threshold = `load_average / n_cores`. Alert cooldown brání opakovaným alertům při trvalém zatížení (alert se pošle, pak ticho po konfigurovanou dobu).

**Důsledky:**
- ✅ Žádné false-positive alerty na vytíženém, ale zdravém serveru
- ✅ Alert storms eliminovány cooldownem
- ❌ Cooldown může zpozdit notifikaci o eskalujícím problému — akceptovatelné, v produkci se to osvědčilo

---

### ADR-055: Bezpečnostní model webhook serveru — síťová izolace kontejneru + HMAC

**Datum:** květen 2026

**Kontext:**
Webhook server (`bin/ifttt_webhook.rb`, port 8089) obsluhuje dva nezávislé endpointy: IFTTT (`/api/ifttt/...`) a Tlambot broadcast (`/api/mastodon/broadcast`). Při auditu vznikl opakovaný omyl o tom, jak broadcast funguje a zda má jeho HMAC verifikace smysl. Příčina omylu: `cron_command_listener.sh` spouští ve stejném kroku dva mechanismy, které vypadají souvisle, ale fungují opačně:

- **Údržbot** (`command_listener.rb`) — **pull / polling**. Cron tahá Mastodon notifications API (cursor přes `last_notification_id`), zpracuje DM příkazy. Bez cronu se nic neděje; cron je řídící prvek.
- **Tlambot** (`process_broadcast_queue.rb`) — **push / webhook**. Mastodon server-level webhook (`status.created` na účtu `@tlambot`) volá endpoint v reálném čase. Request **okamžitě** zapíše soubor do `queue/broadcast/pending/` (jediný zapisovatel je `handle_broadcast_webhook`). Cron pak frontu jen slepě konzumuje — `TlambotQueueProcessor` s Mastodonem nekomunikuje, věří obsahu souboru včetně pole `username == tlambot`.

Důsledek: u Tlambota **není hradlem cron, ale HMAC na vstupu webhooku.** Cokoli se dostane do fronty jako validní JSON, je do 5 minut odvysíláno na všechny boty — nejmocnější operace v systému.

HMAC mechanika (proč je secret nutný): `TLAMBOT_WEBHOOK_SECRET` je **sdílené tajemství** uložené současně v Mastodon adminu (Webhooks → Podpisový klíč) a v `env.sh`. Secret se v requestu **neposílá** — Mastodon jím spočítá `HMAC-SHA256` z těla a pošle jen otisk v hlavičce `X-Hub-Signature`. ZBNW spočítá otisk svou kopií a porovná. Bez shody secretu nelze padělat platný payload.

**Rozhodnutí:**
Bezpečnostní model = dvě vrstvy:

1. **Síťová izolace kontejneru** (`IFTTT_BIND="0.0.0.0"`) — webhook server poslouchá na všech rozhraních **kontejneru**, ale kontejner sám není přímo routovatelný z internetu. Nginx běží na **hostu** (mimo kontejner) a proxuje `wh.zpravobot.news → container-ip:8089` přes Docker bridge síť. Co nginx-on-host explicitně neproxuje, zvenčí dosažitelné není.

   **Proč ne loopback (`127.0.0.1`):** Vyzkoušeno empiricky 2026-05-23 18:44 — nginx na hostu se na loopback uvnitř kontejneru nedosáhne (loopback je per-network-namespace). Důsledek: 13h výpadek IFTTT pipeline (do 2026-05-24 07:46), vráceno na `0.0.0.0`. Loopback model by fungoval jen kdyby nginx běžel ve stejném kontejneru — což v Cloudronu není.

2. **HMAC verifikace** (`TLAMBOT_WEBHOOK_SECRET`, musí sedět s podpisovým klíčem v Mastodonu) — autentizuje původ payloadu. Při bindu `0.0.0.0` je HMAC **primární autentizace broadcast endpointu**, nikoli pouhý defense-in-depth — kdokoli s přístupem na container-ip:8089 (Docker bridge) by jinak mohl frontu napustit.

Cílový stav: oba secrety (`IFTTT_AUTH_TOKEN`, `TLAMBOT_WEBHOOK_SECRET`) jsou **povinné** a server bez nich fail-closed odmítne nastartovat.

**Přechodný stav (květen 2026 — ramping IFTTT applet auth):** Po nasazení autentikace na IFTTT appletech běží server v *WARN-only* módu — při chybějícím tajemství jen logguje varování, ale startuje a propouští unauth requesty. Smyslem je odchytit legacy applety, které ještě token nezískaly, bez okamžitého výpadku pipeline. Flip na fail-closed plánován po týdnu monitoringu (viz `bin/ifttt_webhook.rb:42` + `lib/webhook/signature_verifier.rb:19` + `lib/webhook/routes/ifttt_route.rb:18`).

**Důsledky:**
- ✅ Broadcast endpoint není přímo dostupný z internetu — nginx na hostu by ho musel vědomě proxovat (dnes nikoli; proxuje jen IFTTT cestu)
- ✅ HMAC kryje útok z Docker bridge / sousedních kontejnerů — což je s `BIND=0.0.0.0` jediná dostupná povrchová obrana
- ✅ Údržbot (polling) vs. Tlambot (webhook) je explicitně zdokumentován — odstraňuje opakovaný omyl „cron to ovládá, zvenčí nehrozí"
- ❌ Loopback bind (`127.0.0.1`) v Cloudron topologii **nefunguje** — ověřeno výpadkem 2026-05-23 18:44 – 2026-05-24 07:46; nezkoušet znovu bez přesunu nginx do kontejneru
- ❌ `TLAMBOT_WEBHOOK_SECRET` v ZBNW musí být ručně sesynchronizován s podpisovým klíčem v Mastodon adminu; rotace klíče („Obnovit klíč") vyžaduje update na obou stranách, jinak broadcast padá na 401
- ❌ Single point of failure: pokud by secret unikl nebo nginx-on-host začal proxovat broadcast cestu, broadcast vrstva je kompromitována — žádný další záchytný bod není

---

## 12. Sdílená infrastruktura kódu

### ADR-043: Sjednocený `HttpClient` — žádné přímé `Net::HTTP` bypassy

**Datum:** březen 2026

**Kontext:**
Kód obsahoval více míst s vlastní inicializací `Net::HTTP`, různými timeouty, různým User-Agentem a bez konzistentního retry. Každé nové místo přidávalo vlastní boilerplate.

**Rozhodnutí:**
Veškerý HTTP provoz přechází přes `Utils::HttpClient` (GET, POST, PUT, DELETE, download, request_with_retry). Sdílený User-Agent, konfigurovatelné timeouty, connection pooling (PERF-2), SSRF blocklist v OGP fetcheru.
Nové `Net::HTTP.new` bypassy v code review odmítáme.

**Důsledky:**
- ✅ Jedno místo pro retry strategii, User-Agent a logging
- ✅ Connection pooling bez duplikace kódu
- ❌ Přidání nestandardního HTTP chování (např. streaming) vyžaduje rozšíření `HttpClient`

---

### ADR-044: `Data.define` jako default pro immutable return types

**Datum:** duben 2026

**Kontext:**
Kód používal `Struct` pro jednoduché return objekty (`ProcessingResult`, `WebhookPayload`, …). `Struct` je mutable, instancovatelný prázdný a nevynucuje pojmenované argumenty.

**Rozhodnutí:**
Nové immutable return type objekty se definují přes `Data.define` (Ruby 3.2+). Stávající `Struct` se při příležitosti refaktoru migrují.

**Důsledky:**
- ✅ Immutability by default — žádné neúmyslné mutace return hodnot
- ✅ Pojmenované argumenty vynuceny — nečitelné positional konstruktory odstraněny
- ❌ Vyžaduje Ruby ≥ 3.2 — v projektu akceptovatelné, cílíme Ruby 3.4

---

### ADR-045: Stats::RunStats — sjednocený stats tracking

**Datum:** duben 2026

**Kontext:**
`Orchestrator` a `IftttQueueProcessor` paralelně udržovaly totožnou stats logiku s drobnými inkonzistencemi (různá inicializace klíčů, různá terminologie). Přidání nového stats klíče vyžadovalo změnu na 4 místech.

**Rozhodnutí:**
Třída `Stats::RunStats` s metodami `increment(:key)`, `merge!(result)`, `to_h`. Explicitní klíče (`:processed, :published, :skipped, :rate_limited, :errors`) inicializovány na 0 v konstruktoru. Orchestrátor i IftttQueueProcessor sdílí stejnou třídu.

**Důsledky:**
- ✅ Přidání nového stats klíče = změna na jednom místě
- ✅ Terminologie a inicializace konzistentní napříč systémem
- ❌ Další třída v lib/stats/ (triviální overhead)

---

### ADR-053: `OgpFetcher` — záměrná výjimka z pravidla `HttpClient`

**Datum:** březen 2026

**Kontext:**
ADR-043 stanovuje, že veškerý HTTP provoz prochází přes `Utils::HttpClient`. `OgpFetcher` toto pravidlo záměrně porušuje a zůstává s přímým `Net::HTTP`.

**Rozhodnutí:**
`OgpFetcher#fetch_html_partial` dělá **streaming partial read** — zastaví načítání po 32 KB přes `read_body + break`, vlastní redirect budget s SSRF kontrolou na každém skoku, a custom `Accept` headery. `HttpClient` tyto operace nepodporuje a přidání podpory by zbytečně zkomplikovalo sdílenou knihovnu pro okrajový use case.
Výjimka je explicitně zdokumentována v kódu komentářem.

**Důsledky:**
- ✅ `HttpClient` zůstává jednoduchý — bez streaming API
- ✅ `OgpFetcher` má plnou kontrolu nad read budgetem a redirect logiku
- ❌ Druhá implementace HTTP v projektu — každý code reviewer musí vědět o této výjimce (proto ADR)

---

### ADR-046: YouTube profile sync přes Browserless (consent.youtube.com bypass)

**Datum:** duben 2026

**Kontext:**
EU uživatelé jsou YouTubem přesměrováni na `consent.youtube.com` před zobrazením kanálu. Prostý HTTP GET na URL profilu vrátí consent stránku místo `ytInitialData` JSON, z nějž se extrahuje avatar, banner a bio.
Alternativy: přidat `CONSENT` cookie k plain HTTP requestu (nestabilní, YouTube to mění), nebo použít Browserless (reálný prohlížeč).

**Rozhodnutí:**
`YoutubeProfileSyncer` fetchuje profil přes Browserless.io s cookie `CONSENT=YES+1`. Reuse stávajícího `BROWSERLESS_TOKEN` (sdíleno s jinými scraping use cases).

**Důsledky:**
- ✅ Spolehlivý fetch i přes EU consent wall
- ✅ Nová závislost (Browserless) se neopakuje — token je sdílený
- ❌ Browserless free tier má měsíční limit — překročení = fallback na prázdný profil (akceptovatelné, sync je best-effort)
- ❌ Pokud YouTube změní cookie název `CONSENT`, sync přestane fungovat

---

### ADR-047: Custom test framework — NEmigrovat na RSpec/Minitest

**Datum:** duben 2026

**Kontext:**
ZBNW-NG má vlastní lightweight test runner (`bin/run_tests.rb`, `lib/test_runner/`). Po dosažení 99 test souborů a 2032 assertů se opakovaně diskutovalo o migraci na standardní RSpec nebo Minitest.

**Rozhodnutí:**
Nemigrovat. Explicitně rozhodnuto 2026-04-23 v rámci auditu technického dluhu.
Důvody:
- Migrace = týdny práce za nulový byznys přínos (testy PASS, CI funguje)
- Vlastní runner je plně funkční pro sólo/malý tým projekt
- RSpec/Minitest přidává gem dependencies a jiná konvence testů

**Důsledky:**
- ✅ Stávající testy fungují, žádná disruption
- ✅ Žádná gem závislost na test frameworku
- ❌ Nový contributor musí pochopit vlastní runner místo standardního nástroje
- ❌ Méně nástrojů z ekosystému (RSpec matchers, mock libs) — akceptovatelné, stávající stubování postačuje

---

*Dokument je živý. Nové záznamy se přidávají při každém netriviálním rozhodnutí.*
*Formát: ADR-NNN, chronologické pořadí v rámci kategorie, datum rozhodnutí.*
