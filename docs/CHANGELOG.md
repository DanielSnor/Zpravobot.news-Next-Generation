# Changelog

Funkční změny a milníky systému ZBNW‑NG — nejnovější záznamy nahoře.

Architektonická zdůvodnění a trade-offy jsou v [`90-meta/decisions.md`](90-meta/decisions.md).

## Jak číst changelog

Tento changelog je psaný **chronologicky po měsících** (projekt nepoužívá verze/releasy).

- Čti shora dolů: nahoře jsou nejnovější změny.
- Každý měsíc začíná krátkým shrnutím „co bylo cílem“.
- Detailní výčet změn je členěn do sekcí jako **Přidáno / Opraveno / Zabezpečení / Výkon / Refaktoring**.
- Pokud tě zajímá *proč* k zásadní změně došlo, hledej odkaz na ADR v `docs/90-meta/decisions.md`.

---

---
## 2026-05 — RSS-social, opravy, model upgrade
Květen se soustředil na **kvalitu výstupu** a stabilizaci „RSS‑social“ integrační větve (Facebook/Instagram přes RSS), plus několik oprav okrajových případů v enrichmentu a URL zpracování. Současně proběhl upgrade modelu pro Hrubota.

### Přidáno
- FB heuristiky pro formátování RSS-social postů; sdílený modul; config overlay z platformové YAML
- Podpora `playlist_id` pro YouTube zdroje sledující konkrétní playlist

### Opraveno
- Propagace `video_thumbnail_url` do raw dat při Syndication enrichmentu
- Rozbité URL pro handles s tečkou (`@kimi.antonelli`)
- Instagram: hashtags a `@mentions` na oddělených řádcích; tag blok podporuje mentions za hashtagy

### Změněno
- Hrubot: upgrade modelu na `claude-sonnet-4-6`

---

## 2026-04 — Security, performance, Bluesky publishing, refaktorovací vlna
Duben je „produkční hardening“ fáze: přibyly bezpečnostní ochrany pro vstupy (webhooky/HTTP fetch), výkonové optimalizace a větší architektonické úpravy zvyšující udržitelnost (pipeline kroky, sjednocené HTTP, stats tracking). Současně vznikl BlueskyPublisher pro doplňkové subsystémy a proběhly významné rozšíření profilové synchronizace a testování.

### Přidáno
- **BlueskyPublisher** — cross-posting ze 4 doplňkových skriptů (stats, trending, FF, source report); hlavní pipeline zůstává Mastodon-only (ADR-031)
- **InstagramProcessor** — heuristická rekonstrukce odstavců, hashtag/mention bloků a struktury captionů; 4 heuristiky; 13/13 testů (ADR-023)
- **Hrubot** — AI komentáře u trending postů přes Claude API (`lib/trending/hrubot_commenter.rb`) (ADR-033)
- **YouTube Browserless** — profile sync přepnut na Browserless.io kvůli EU consent redirectu; sdílený `BROWSERLESS_TOKEN` (ADR-046)
- `bin/instance_status.rb` — one-shot JSON health snapshot přes SSH
- `bin/log_report.rb` rozšíření: `--source` flag, infra error korelace, `ifttt_skips`, health agregace per platformu
- `Utils::AtomicFile` — atomic write helper (`tmp.PID` + fsync + rename) pro JSON state soubory (ADR-040)
- Non-blocking rate limit handling — `AccountRateLimitedError`, skip místo sleep; soubory zůstávají v `pending/`; pre-flight check `raise_if_rate_limited!`; thread-safe propagace v parallel upload (ADR-037)
- Profile syncer test suite — 23 (`ImageCacheManager`) + 20 (`MastodonProfileUpdater`) + 51 (`subclasses`) = 94 testů PASS (TEST-1)
- Friendly Follow: Bluesky vlákno per účet ≤300 grafémů paralelně s Mastodon long-postem (ADR-032)
- LRU eviction cap pro thread cache (10 000 záznamů)

### Zabezpečení
- Webhook hardening: `MAX_PAYLOAD_SIZE = 1 MB` (413 při překročení), délkové limity polí (`bot_id` ≤100, `text` ≤50k), `sanitize_filename_part` pro path traversal ochranu (ADR-038)
- OGP fetcher: SSRF blocklist privátních IP rozsahů (RFC1918, 127/8, 169.254/16, link-local IPv6) + kontrola na každém redirectu (ADR-039)

### Výkon
- Prefetch HTML pro Twitter: eliminace double Nitter fetch u threadovaných tweetů (PERF-1)
- DB connection pooling: reconnect ping max 1× za 5 min + retry na stale connection (PERF-2)
- HTTP connection pooling přes `Utils::HttpClient` — per-host cache s 30s TTL (ADR-043)
- IFTTT batch limit `.sort.first(500)` brání přetížení jednoho běhu (PERF-5)
- `@last_fingerprint_cleanup` — cleanup max 1× za hodinu (dříve 15 min) (PERF-4)

### Refaktoring (bez funkční změny)
- `Stats::RunStats` — sjednocený stats tracking sdílený Orchestrátorem i IFTTT procesorem (ADR-045)
- `MediaEnrichmentStep` extrahován z `PostProcessor` jako samostatný pipeline krok (REFACTOR-3)
- `source_config#to_processor_hash` — eliminuje `build_source_config_hash` (REFACTOR-2)
- `Struct` → `Data.define` pro immutable return typy (ADR-044)
- `map+compact` → `filter_map`; odstraněny Ruby 2.6 komentáře (MODERNIZE-1)
- `YAML.load_file` → `safe_load_file` na 5 call sites (MODERNIZE-3)
- `respond_to?` cargo-cult odstraněno z `Post`/`Author`/`Media` (MODEL-1)
- Hash dispatch + `CAMEL_TO_SNAKE` konstanta v `ContentFilterStep` (CLEANUP-7)
- Odstraněno 5× `LoadError rescue` v `post_processor.rb` — přímé require (CLEANUP-8)

---

## 2026-03 — Profile sync refaktor, OGP, video deduplikace, Zpravobot Týdeník
Březen přinesl několik „viditelných“ kvalitativních kroků: OGP image fetcher pro lepší vizuální výstup, robustnější deduplikaci videí a výrazné posílení profilové synchronizace. Současně vznikl týdenní digest #ZpravobotTOP10 a řada oprav chování kolem URL, mentionů a text cleanupu.

### Přidáno
- **OGP image fetcher** (`lib/utils/ogp_fetcher.rb`) — streaming partial read 32KB; `og:image` jako nativní příloha; obchází Mastodon scraper blocker; třívrstevný fallback URL; 14/14 testů (ADR-053)
- **SHA-256 video deduplikace** (`lib/processors/media_dedup.rb`) — fingerprint z binárních dat MP4 v tabulce `media_fingerprints`; idempotentní DB migrace; 16/16 testů (ADR-014)
- **pHash/aHash video deduplikace** (`lib/processors/thumbnail_phash.rb`) — Average Hash 64-bit přes ImageMagick; Hamming distance ≤10 pro detekci duplicit; `phash_int BIGINT` sloupec v DB; Hamming počítána v SQL (`BIT_COUNT(phash_int XOR $2)`)
- **Zpravobot Týdeník** (`#ZpravobotTOP10`) — týdenní TOP 10 postů + publikace na Mastodon i Bluesky (ADR-034)
- **Mentions typ `local_or_domain_suffix`** — lokální Twitter handle → holý `@mastodon_id` (klikatelný profil + notifikace); cizí → `@handle@twitter.com`; Twitter platform default přepnut z `none` (ADR-054)
- `analyze_domain_fixes.rb` — analýza a aktualizace `url_domain_fixes` pro Twitter/Bluesky zdroje; aplikováno na 231 Twitter + 16 Bluesky zdrojů
- `BaseRepository` — sdílený základ pro 5 repository tříd
- `ImageCacheManager` — download + TTL cache (7 dní) pro avatar/banner
- `MastodonProfileUpdater` — dedikovaná třída pro API update profilu
- `ProfileFieldsBuilder` — Template Method pattern pro profile sync
- `bin/source_report.rb` — přehled stavu zdrojů s live daty
- **Syndication Tier 2 video enrichment** (`enrich_video_from_syndication`) — po Nitter fetchi nahradí `video_thumbnail` skutečným mp4 z Syndication API; skip pokud Nitter již má přímé mp4
- `InstagramProfileSyncer` — profile sync přes Browserless.io; `IG_COOKIE_*` ze ENV; aktivováno pro `kimi_antonelli`, `formulovy_svet`, `arvid_lindblad` (ADR-046 základ)

### Opraveno
- Profile card blocker: `transparent_1x1.png` (70B) → `white_strip_1280x1.png` (76B) — Elk renderoval průhledný PNG jako zelený čtverec
- `@handle@instance` formát v Mastodon postech obnoven po regresi
- t.co URL rozbalení: oprava pořadí podmínek
- Facebook: `FacebookProfileSyncer` fetchuje `/about` URL; `FOOTER_DOMAINS` filtruje zápatí
- Text cleanup v `build_syndication_post` — expand t.co + strip media URL (dříve raw text s t.co linky)
- Délka postu: off-by-one po URL domain fixes v `apply_domain_fixes`
- YouTube false positive errory — `skip_hours`, `YouTubeTransientError`, WARN místo ERROR
- `InstagramProfileSyncer` — regex `\b` za HTML atributem vždy failoval; `og:image` detekce

### Refaktoring
- Profile sync refaktorován na Template Method pattern (`BaseProfileSyncer`)
- Retry/timeout konstanty sjednoceny a deduplikovány přes `HttpClient` aliasy
- Logging volání sjednoceno na jeden vzor

---

## 2026-02 — Velká refaktorovací vlna, provozní nástroje, Twitter pipeline unifikace
Únor je největší konsolidační etapa: projekt byl uveden do gitu (zahájen 2026‑02‑27) a proběhla rozsáhlá refaktorovací vlna, která sjednotila error handling, HTTP vrstvu, state management a pipeline kroky. Současně vznikly klíčové provozní nástroje (manage_source, failed queue retry, Údržbot/Tlambot) a zásadní sjednocení Twitter vstupních kanálů do jediné Tier logiky.

### Přidáno (funkce)
- **`TwitterTweetProcessor`** — unifikuje IFTTT a RSS vstupní kanály; identická Tier logika, threading a `PostProcessor` pro oba vstupy; `IftttTwitterAdapter` → `TwitterNitterAdapter` (ADR-048)
- **Tier 1.5** (Syndication API pro `nitter_processing: false`) — video jako přehratelné mp4; ~2200 Nitter requestů/den ušetřeno pro sportovní boty (ADR-015)
- **Tier 3.5** (Syndication fallback po selhání Nitteru) — média i bez Nitteru
- **`bin/manage_source.rb`** — lifecycle: `pause` (YAML + `disabled_at`), `resume` (reset error_count + init wizard), `retire` (přesun YAML, smazání DB state s audit log zachováním) (ADR-051)
- **IFTTT Failed Queue** — `DEAD_` prefix pro permanentní chyby, retry pro přechodné; `_failure: {retry_count, reason, timestamp}` v JSON; `dead_count` separátně v health monitoru (ADR-049)
- **Tlambot** — broadcast ze souboru i přes Mastodon webhook; HMAC verifikace payloadu; `TlambotWebhookHandler` + `TlambotQueueProcessor` + `bin/process_broadcast_queue.rb` (ADR-036)
- **Údržbot / Command Listener** — interaktivní diagnostika přes Mastodon mentions na `@udrzbot`; příkazy `status`, `detail`, `check`, `sources`, `help`; whitelist autorizace, rate limiting, cursor-based polling, DM odpovědi, lockfile (ADR-035)
- **`FacebookProfileSyncer`** — profile sync přes Browserless.io; avatar, banner, bio, metadata fields (ADR-022 základ)
- **MIME typ z magic bytes** — primární MIME detekce z binárních dat souboru; eliminuje 422 chyby od Mastodon při CDN s nesprávnými příponami (ADR-050)
- **RSS profile sync delegátor** — RSS boti delegují na platform syncery; `social_profile.handle` jako kanonický handle (ADR-052)
- **`domain_suffix_with_local`** — lokální Twitter handle → `@id@zpravobot.news` (s notifikací); cizí → `@handle@twitter.com` (ADR-054)
- **Smart alerting** — per-core CPU threshold (`load / n_cores`), alert cooldown s pending_resolved stavem (ADR-042)
- **Dummy 1×1px PNG** — profile card blocker pro Mastodon mention preview hijack (ADR-025)
- **Profile sync skupinová rotace** — Twitter zdroje rozděleny do 3 skupin (deterministické `source_id.bytes.sum % 3`); cron Po/Čt=0, Út/Pá=1, St/So=2; ~100 místo ~300 profilů najednou
- `ServerResourcesCheck` (CPU, Disk, RAM, Swap I/O) a `LogAnalysisCheck` (error patterns) v health monitoru
- `bin/run_tests.rb` + `lib/test_runner/` — centrální test runner s katalogem (`config/test_catalog.yml`), output parserem a Markdown reportem
- `create_source.rb` — `yaml_quote` helper; auto-předvyplnění Mastodon account ID; nitter processing default `false`; `ask_choice` UX sjednocení
- Automatické sledování HTTP redirectů v `RssAdapter`
- Edit Detection: delete + republish pro edity s médii (Mastodon Update API neumožňuje změnu médií) (ADR-013)

### Velký refaktoring codebase (2026-02-10, Fáze 6–10)
- **Error hierarchy** — `lib/errors.rb`: `Zpravobot::Error` se 7 podtřídami
- **`Utils::HttpClient`** — centralizovaný HTTP, nahrazuje duplicitní `Net::HTTP` (ADR-043)
- **`Support::Loggable`** — unified logging mixin, nahrazuje 13 lokálních `def log`
- **StateManager split** — `lib/state/` facade + 5 repositories (DatabaseConnection, PublishedPosts, SourceState, ActivityLogger, EditBuffer)
- **Pipeline Steps** — `lib/processors/pipeline_steps.rb`: dekompozice `PostProcessor#process` do tříd
- **`BaseProfileSyncer`** — Template Method pattern; 3 subclassy; ~900 řádků eliminované duplikace
- **Source Wizard split** — `lib/source_wizard/` 8 souborů z monolitického `create_source.rb`
- **HashHelpers** — `deep_symbolize_keys`, `deep_merge`; sjednocení hash key konvencí
- 28 technických dluhů vyřešeno; 40/40 unit testů + 8 nových test souborů PASS

### Opraveno (výběr klíčových)
- Encoding crash v `TwitterThreadProcessor` — `force_encoding('UTF-8')` → `.encode('UTF-8', 'binary', ...)` ve 4 souborech; centrální `sanitize_encoding()` helper (3 fáze: 2026-02-07, 02-11, 02-12)
- Media count overflow (>4 médií → Mastodon 422) — parser filtruje GIF video při 4+ obrázcích; post-upload trim
- Thread cache lookup struktura — `@thread_cache.dig(source_id, username)` místo `@thread_cache[username]`
- Twitter thread chain extraction — greedy regex pro `before-tweet`, `#m` suffix v tweet-link, HTML strip pro text preview
- Async media processing — poll `GET /api/v1/media/:id` po 202 z v2 API (backoff 1–5s, max 10 pokusů)
- Reply tweet text — fallback hledá pouze v `main-tweet` sekci, ne v `before-tweet` parent
- `flock` lock v `cron_ifttt.sh` — zamezení race condition při překrývajících se cron runs
- `verbose_mode?` v Orchestrátoru vždy vracelo `true` — přepsáno na `@verbose` flag

---

## 2026-01 — Vznik systému a Nitter infrastruktura
Leden zachycuje vznik základní architektury ještě před prvním git pushem (ten proběhl 2026‑02‑27). Vznikl batch‑first orchestrátor, unifikovaný mezimodel `Post`, kroková pipeline a PostgreSQL state management. Současně byla rozběhnuta Twitter/X integrace s hybridním modelem IFTTT + Nitter a nasazena první Nitter infrastruktura.

### Architektura systému
- Orchestrator + cron model místo daemon procesu; centrální orchestrátor iteruje přes všechny zdroje (ADR-001, ADR-002)
- `Post` jako univerzální mezimodel — veškerý obsah z různých platforem → jeden typ (ADR-007)
- Explicitní kroková pipeline v `PostProcessor`: Deduplikace → Edit detection → Content filter → Formátování → Content replacement → Trimming → URL processing → Media enrichment → Publikace (ADR-008)
- PostgreSQL state management: `published_posts`, `source_state`, `activity_log`, `edit_detection_buffer` (ADR-010)
- YAML konfigurace hierarchie — jeden soubor per zdroj; globální → platform → per-source overrides (ADR-006)
- Priority systém (`high` / `normal` / `low`) — scheduling interval i IFTTT fronta batch delay (ADR-016)
- Edit Detection — detekce editovaných tweetů přes Jaccard+containment similarity; threshold 0.80; `edit_detection_buffer` s 2h TTL (ADR-012)
- IFTTT webhook server — dual-environment podpora (`?env=test` parametr); `/health` + `/stats` endpointy; `IFTTT_QUEUE_DIR_TEST` ENV (2026-01-31)

### Platformy
- **Twitter/X**: hybridní IFTTT + Nitter; Tier 1 (přímé IFTTT) + Tier 2 (Nitter) + Tier 3 (degraded fallback); truncation detection (čeština + regex `\z`) (ADR-015, ADR-017, ADR-021)
- **Bluesky**: AT Protocol API (`app.bsky.feed.getAuthorFeed`); nativní threading přes `reply.parent.uri`; podpora profile i custom feed zdrojů; autor header pro feed zdroje (ADR-019, ADR-020)
- **Facebook + Instagram**: RSS.app jako zprostředkovatel RSS feedů; mentions transformace VYPNUTA (preview hijack); Facebook Reels dedup; content replacements (ADR-022, ADR-024); RSS.app od 2026-01-13
- **YouTube**: RSS/Atom feed polling; thumbnail jako média
- **RSS**: periodický polling; best-effort HTML normalizace

### Publikace a provoz
- Mastodon publisher na vlastní instanci `zpravobot.news` s limitem 2500 znaků (ADR-004)
- URL délka = pevná konstanta 23 znaků dle Mastodon specifikace (ADR-027)
- Profile sync: Twitter (2× denně), Bluesky (4× denně); sémantika Mastodon fields (ADR-028, ADR-029)
- IFTTT webhook server spouštěný přes `setsid` (Cloudron kompatibilita) (ADR-003)
- Mastodon memory tuning: 1 Puma worker + `MALLOC_ARENA_MAX=2`; RAM z ~3.5GB na ~1.2GB (ADR-005)

### Nitter infrastruktura (2026-01)
- 2026-01-17: první funkční nasazení Nitter instance (`xn.zpravobot.news`)
- 2026-01-21: vyřešen IPv6 mismatch (`network_mode: host`), nginx IP whitelist
- 2026-01-26/27: přidány burner účty zbnwng03–06 (celkem 7 účtů); kapacita ~3500 req/15 min
- Kritické pravidlo: cookies získávány výhradně přes SSH SOCKS5 tunel (IP matching) (ADR-018)
