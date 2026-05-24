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
## 2026-05 — Security hardening, výkonová revize, strukturální refaktoring

Květen přinesl komplexní revizi codebase ve 6 vlnách: bezpečnostní záplaty, výkonové optimalizace a strukturální refaktoring zvyšující udržitelnost. Paralelně proběhla stabilizace RSS‑social větve a upgrade modelu.

### Přidáno
- **Threads.net** — nová platforma via RSS.app bridge: `ThreadsProcessor` (sdílí heuristiky s IG přes `SocialTextHeuristics`), `ThreadsProfileSyncer` (bez cookies — veřejné profily), `config/platforms/threads.yml`, source wizard, 17 testů
- FB heuristiky pro formátování RSS-social postů; sdílený modul; config overlay z platformové YAML
- Podpora `playlist_id` pro YouTube zdroje sledující konkrétní playlist
- **`BrowserlessProfileSyncer`** — sdílená základní třída pro Facebook, Instagram, Threads, YouTube syncery; `cookies:` + `safe_encoding:` parametry eliminují 4× duplikaci `fetch_page_via_browserless`
- **`Utils::MimeDetector`** — magic bytes detekce MIME typů extrahována z `MastodonPublisher` jako reusable modul
- **`lib/webhook/`** — webhook business logika přesunuta z `bin/ifttt_webhook.rb` do `lib/webhook/http_server.rb`, `routes/ifttt_route.rb`, `routes/broadcast_route.rb`, `signature_verifier.rb`, `queue_writer.rb`; `bin/` redukován na ~70 ř. entry pointu
- `Utils::HttpClient#streaming_get` — chunked čtení s early abort při překročení `max_size`; `Content-Length` kontrola ještě před stažením těla
- `monitoring.ok_if_idle: true` — flag pro příležitostné zdroje; přeskočí staleness check, chyby se stále reportují
- Profile sync bio: mention rewrite + t.co expanze (`BaseProfileSyncer#format_bio_text`; `TwitterProfileSyncer` přepisuje `expand_short_urls` přes `Utils::TcoExpander`); `ConfigLoader#enrich_mentions_config` jako sdílený helper

### Zabezpečení
- **S1** — `bin/ifttt_webhook.rb`: startup warning pokud `IFTTT_AUTH_TOKEN` nebo `TLAMBOT_WEBHOOK_SECRET` nejsou nastaveny; server běží dál, ale přijímá neautentizované požadavky resp. neověřuje HMAC podpisy
- **S2** — `secure_compare` helper přes `OpenSSL.fixed_length_secure_compare`; použit v IFTTT Bearer auth i v broadcast HMAC verifikaci (eliminuje ruční XOR loop)
- **S3** — odstraněn `File.delete(LOCKFILE)` v `bin/run_zbnw.rb` — race condition vedoucí k duplicitním postům (kernel uvolní flock při exitu, identicky jako `sync_profiles.rb`)
- **S4** — `ProfileFieldsBuilder`: `sanitize_field_value` + `sanitize_url_field` — strip HTML tagů, null bajtů a control chars; zamítnutí non-http(s) schémat (`javascript:`, `data:`, `vbscript:`); truncate na Mastodon limit 255 znaků; aplikováno na všechny hodnoty ze sociálních sítí vstupující do Mastodon profilových polí

### Výkon
- **P1** — `ConfigLoader`: `mastodon_accounts.yml` parsován jednou za životnost instance; `@mastodon_accounts_cache`; dopad ~500+ eliminovaných YAML parsů per cron cyklus
- **P2** — `ContentFilter`: regexpy z `content_replacements` prekompilovány v `initialize` přes `precompile_replacements`; žádný `Regexp.new` per post
- **P3** — `HttpClient#download`: streaming s `max_size` limitem; `:too_large` abort z `Content-Length` hlavičky nebo při accumulated bytes
- **P4** — `Orchestrator`: sort před limitem — `.sort_by { published_at }.last(max_posts)` garantuje nejnovější posty bez ohledu na pořadí z adapteru

### Opraveno
- Propagace `video_thumbnail_url` do raw dat při Syndication enrichmentu
- Rozbité URL pro handles s tečkou (`@kimi.antonelli`)
- Instagram: hashtags a `@mentions` na oddělených řádcích; tag blok podporuje mentions za hashtagy
- Webhook: `SO_REUSEADDR` před `bind()` — eliminuje minutové crash smyčky při restartu po OOM pádu (port v TIME_WAIT stavu)
- Webhook: `SO_RCVTIMEO`/`SO_SNDTIMEO` 5s na accepted socketech — fix crash loop při hanging IFTTT connection blokující main loop a health check
- `MastodonPublisher`: download selhání nově loguje HTTP status kód a geo-blocked hint (`HttpClient.download` rozšířen o `on_failure` callback)

### Změněno
- Hrubot: upgrade modelu na `claude-sonnet-4-6`

### Instagram heuristiky
- H2 — první věta zakončená `!` = nadpis; `\n\n` za ní (pattern `\A([^.!?\n]+!)\s+(?=[[:upper:]])`)
- Emoji titulek — emoji na začátku řádku/textu jako dekorace nadpisu; oddělen `\n\n` od těla
- Vlajkový seznam — `:` + vlajka → `\n\n` před blokem; vlajka → vlajka → `\n` mezi položkami (aktivuje se jen při 2+ vlajkách)
- Citace v uvozovkách → vlastní odstavec (podporuje `"`, `"`, `„`)
- Příliš dlouhé bloky (>250 znaků) — rekurzivní split na větné hranici + velké písmeno

### Refaktoring (bez funkční změny)
- **R1** — `PostProcessor` pipeline dokončena: `FormatterFactory` (nahrazuje 60 ř. platform switch), `FormatStep`; pipeline kroky 1–4 plně extrahované do `pipeline_steps.rb`
- **R2** — Profile syncery: `sync_twitter` / `sync_twitter_for_rss` a 5 dalších párů sloučeny do jedné metody s keyword arg defaults (~140 ř. méně); `build_fields` rozšířen o `extra_data[:website]` v base třídě (eliminuje override v FB/IG)
- **R3** — viz Přidáno: webhook → `lib/webhook/`
- **R4** — `BlueskyPublisher` + `HrubotCommenter` přepsány na `HttpClient.post_json`; odstraněn duplicitní `Net::HTTP` boilerplate
- **R5** — viz Přidáno: `Utils::MimeDetector`
- **R6** — zbývající `File.write` přepnuty na `Utils::AtomicFile.write`: `command_listener.rb` (state cursor), `image_cache_manager.rb` (cache meta soubory)
- **R7** — `TwitterNitterAdapter` (937 → ~320 ř.): extrahováno do 3 modulů `Twitter::TierDecision`, `Twitter::SyndicationPostBuilder`, `Twitter::NitterFetcher`; tier chain explicitní v `process_webhook` přes `||` operátor
- **R8** — taby → 2-space indentace v `lib/orchestrator.rb`
- **R9** — `BlueskyPublisher`: `refresh_session` přes `com.atproto.server.refreshSession`; automatický retry po `BlueskyAuthError` (expirovaný JWT); relevantní pro long-lived procesy (`--process-queue`, trending)
- `SocialTextHeuristics` — sdílený modul pro `InstagramProcessor` a `ThreadsProcessor`; eliminuje duplikaci `restore_exclamation_title`, `restore_flag_list`, `restore_list_breaks`, `restore_quote_breaks`, `FLAG_EMOJI`
- `Utils::TcoExpander` — konsolidace t.co expanderu z `twitter_nitter_adapter` a `twitter_tweet_processor` do sdíleného modulu; přidán volitelný `on_error` blok pro logování

### Audit codebase (vlna 6)

Komplexní revize zaměřená na výkon, spotřebu zdrojů, bezpečnost a „co bylo zapomenuto". Odlišné číslování oproti vlnám 1–5 (`S/P/R`) — používá prefixy **B** (bezpečnost), **P** (perf), **R** (resource), **F** (forgotten/cleanup), **T** (test housekeeping), aby byly odkazy během auditu jednoznačné.

#### Zabezpečení
- **B2** — ADR-055 přepsán: `IFTTT_BIND="0.0.0.0"` je vědomé rozhodnutí (Cloudron topologie — nginx běží na hostu mimo kontejner, loopback bind by ho odřízl; ověřeno 13h výpadkem 2026-05-23 18:44 → 2026-05-24 07:46). HMAC povýšen z „defense-in-depth" na **primární autentizaci** broadcast endpointu. Doplněn odstavec o přechodném WARN-only stavu (viz B1 odložené).
- **B3** — `Utils::OgpFetcher` SSRF guard: zavřen TOCTOU mezi DNS check a `Net::HTTP.new` (útočník s krátkým TTL mohl podstrčit private IP mezi check a connect). Nově `resolve_and_validate` resolvuje jednou, validuje **všechny** vrácené IPs (any private = blok), TCP pinováno přes `http.ipaddr =`. `PRIVATE_RANGES` rozšířeno o `0.0.0.0/8`, `100.64.0.0/10` (CGNAT), `224.0.0.0/4` (multicast), `fc00::/7` (IPv6 ULA), `fe80::/10` (IPv6 link-local). 6 nových testů s mock `Resolv.getaddresses`.
- **B4** — `Broadcast::TlambotWebhookHandler#verify_signature` odstraněn jako dead code (duplikoval `Webhook::SignatureVerifier` s rozdílnou politikou — fail-closed vs. fail-open — a vlastní ruční constant-time porovnání). Class komentář explicitně dokumentuje, že HMAC verifikuje upstream `Webhook::SignatureVerifier`.
- **B5** — `Publishers::MastodonPublisher#sanitize_multipart_filename` + `Syncers::MastodonProfileUpdater#sanitize_multipart_filename`: filename z URL po percent-decode mohlo obsahovat `"`, `\r`, `\n` (Content-Disposition header injection / předčasná terminace multipart). Sanitizace na `[a-zA-Z0-9._-]` (stejný regex jako `Webhook::QueueWriter.sanitize`), cap 200 znaků.

#### Výkon
- **P1** — `Processors::ContentFilter`: dotaženo precompile na `banned_phrases` a `required_keywords` (předchozí vlna pokrývala jen `content_replacements`). Nový rekurzivní `precompile_rule` walks tree: `type: 'regex'` → `_compiled`, `type: 'and|or|not'` → `_compiled_content_regex` atd. arrays, `type: 'complex'` → rekurze. Helper `compile_regex` sdílený pro init i fallback. Dopad: řádově 10 000+ eliminovaných `Regexp.new` per cron tick.
- **P2** — `Orchestrator#process_source`: sloučení duplicitního `get_source_state` (předtím volaný uvnitř `source_due?` i pro `extract_since_time`). Nově state načten jednou na začátku, propagován oběma. ~500 zdrojů → úspora ~500 DB roundtripů per cron tick.
- **R2** — `Utils::HttpClient::ConnectionPool` — nová per-host connection pool struktura s `Mutex` + `ConditionVariable`. Drží až `MAX_POOL_SIZE_PER_HOST = 4` connections; vlákno přes `checkout` získá exkluzivní vlastnictví, `checkin` vrátí. Plný pool + vše `in_use` ⇒ vlákno čeká do `CHECKOUT_TIMEOUT = 5 s`, pak `PoolTimeoutError`. Nahrazen předchozí per-thread klíč v cache — paralelní upload média (4 vlákna k stejnému hostu) teď sdílí keep-alive místo 4 nezávislých TLS handshakes. 7 nových concurrency testů.

#### Refaktoring / cleanup
- **P3** — `Orchestrator#process_source`: odstraněn mrtvý řádek `@thread_cache[source.id] = {}` (přiřazoval String klíč, zatímco `ThreadingSupport` používá tuple klíče `[source_id, author_handle]` — entries z jiných sources se navzájem neovlivňují, per-source reset není potřeba). Komentář dokumentuje proč.
- **P4** — `lib/reporting/source_reporter.rb`, `lib/stats/mastodon_stats.rb`, `lib/ff/friendly_follow.rb`: migrace z přímého `Net::HTTP.new` na `HttpClient.get` (ADR-043). Všechny 3 dělaly identický pattern `GET /api/v1/accounts/verify_credentials` s Bearer auth. Health checks (`lib/health/checks/*`) zůstávají záměrně mimo (chceme rychlé jednorázové dotazy bez retry).
- **R1** — `HttpClient.close_all_connections` smazán jako dead code (nikdy nevolán, OS uklidí connections při exit procesu; long-running `ifttt_webhook.rb` nedělá outbound HTTP). `drop_cached_connection` zachován (volaný z `execute` na stale connection retry).
- **R3** — `bin/run_zbnw.rb#acquire_lock`: explicitní `flock(...) ? true : false` (flock vrací `0`/`false`, ne `true`/`false` — defenzivní hardening proti budoucímu refaktoru typu `== true`).
- **F3** — `cron_webhook.sh`: `setsid bundle exec ruby` místo `setsid ruby` (sjednoceno s ostatními cron skripty; chrání před tím že webhook server poběží mimo bundler kontext).
- **F4** — smazán zakomentovaný debug `# puts` v `Formatters::TwitterFormatter#initialize`.
- **B6** — falsy alarm: schema interpolace v `bin/instance_status.rb:163` se zdála jako SQL injection vektor, ale `DatabaseHelpers.validate_schema!` je volaná těsně před `SET search_path` (allowlist `%w[zpravobot zpravobot_test]`). Ověřeno u všech 5 callsitů v repu.

#### Testy (housekeeping)
- **T1** — `test/test_orchestrator.rb` přepsán na hybridní strukturu: `extract_since_time` unit testy běží vždy, integration část (config load + DB connect + dry-run) **graceful skip** pokud `config/sources/<source>.yml` neexistuje (nejsou v gitu, jen na serveru) nebo PostgreSQL není dostupný. Exit 0 v obou případech. Plný běh jen tam, kde existuje obojí.
- **T2** — `test/test_mastodon_publisher.rb` opraven po R5 MimeDetector extrakci (test sahal na neexistující metodu `detect_content_type_from_bytes`). Pokrytí magic bytes detekce přesunuto do nového **`test/test_mime_detector.rb`** (52 testů — všechny formáty + edge cases). Sekce `publish — input validation` přepsána ze skutečných volání na `example.com` na stub `api_post` (eliminuje log noise + síťové volání v testech kategorie offline).

#### Odložené
- **B1** — fail-open webhook (`bin/ifttt_webhook.rb:42-46`, `lib/webhook/signature_verifier.rb:19`, `lib/webhook/routes/ifttt_route.rb:18`) zůstává v WARN-only módu jako vědomé meziobdobí během rampingu autentikace IFTTT appletů. Flip na fail-closed plánován **2026-05-30** s manuálním dohledem (verifikace logů na `Invalid signature`/`401`, identifikace případných legacy appletů bez tokenu, pak commit + nasazení).

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
