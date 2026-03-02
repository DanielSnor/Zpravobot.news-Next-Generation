# ZBNW-NG (Zpravobot Next Generation) – Systémová dokumentace

> **Poslední aktualizace:** 2026-03-02
> **Stav:** Produkční
> **Umístění:** `/app/data/zbnw-ng/` (produkce), `/app/data/zbnw-ng-test/` (test)

---

## Obsah

1. [Filozofie a účel](#filozofie-a-účel)
2. [Architektura přehled](#architektura-přehled)
3. [Sdílená infrastruktura](#sdílená-infrastruktura)
4. [Processing Pipeline](#processing-pipeline)
5. [Orchestrator (Jádro)](#orchestrator-jádro)
6. [PostProcessor](#postprocessor)
7. [IFTTT Webhook systém](#ifttt-webhook-systém)
8. [Adapters (Zdrojové adaptéry)](#adapters-zdrojové-adaptéry)
9. [Formatters](#formatters)
10. [Publishers](#publishers)
11. [State Management](#state-management)
12. [Processors](#processors)
13. [Profile Syncers](#profile-syncers)
14. [Konfigurace](#konfigurace)
15. [Threading (Vlákna)](#threading-vlákna)
16. [Cron a Scheduling](#cron-a-scheduling)
17. [Monitoring (Údržbot)](#monitoring-údržbot)
18. [Broadcast systém](#broadcast-systém)
19. [Databáze](#databáze)
20. [Environment Variables](#environment-variables)
21. [CLI nástroje](#cli-nástroje)
22. [Testování](#testování)
23. [Checklist pro změny](#checklist-pro-změny)

---

## Filozofie a účel

ZBNW-NG je **news aggregation system** pro české zpravodajství, který:

1. **Sbírá obsah** z více platforem (Twitter/X, Bluesky, RSS, YouTube)
2. **Formátuje** do nativně vypadajících Mastodon postů
3. **Publikuje** na zpravobot.news Mastodon instanci

### Základní principy

| Princip | Vysvětlení |
|---------|------------|
| **Nativní vzhled** | Posty nevypadají jako automatizace – správné emoji, formátování, threading |
| **Evidence-based** | Změny na základě reálných problémů, ne teoretických optimalizací |
| **Modularita** | Adapters, Formatters, Publishers, Processors – každý má jednu odpovědnost |
| **Robustnost** | Retry logika, graceful degradation, error tracking |
| **Deduplikace** | PostgreSQL state management zabraňuje duplicitním publikacím |

### Proč vznikl?

Náhrada za IFTTT automatizace, které měly problémy:
- Zkrácený text (>257 znaků)
- Max 1 obrázek
- Žádný thread context
- Nespolehlivé formátování

---

## Architektura přehled

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              VSTUPNÍ KANÁLY                                     │
├─────────────────────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐ │
│  │ Bluesky API │  │  RSS Feeds  │  │ YouTube RSS │  │ Twitter (IFTTT+Nitter)  │ │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └───────────┬─────────────┘ │
└─────────┼────────────────┼────────────────┼─────────────────────┼───────────────┘
          │                │                │                     │
          ▼                ▼                ▼                     ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              ADAPTERS                                           │
├─────────────────────────────────────────────────────────────────────────────────┤
│  BlueskyAdapter    RssAdapter     YouTubeAdapter    TwitterAdapter              │
│                                                     TwitterNitterAdapter        │
└─────────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              POST MODEL                                         │
│  Unified representation: id, url, text, author, media, is_repost, is_quote...   │
└─────────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                          ORCHESTRATOR / QUEUE PROCESSOR                         │
│  - Scheduling (due checks)          - Thread parent resolution                  │
│  - Adapter creation                 - First-run handling                        │
│  - Stats tracking                   - Error handling                            │
└─────────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              POST PROCESSOR                                     │
├─────────────────────────────────────────────────────────────────────────────────┤
│  1. Dedupe check (already_published?)                                           │
│  2. Edit detection (check_for_edit) ← Twitter/Bluesky only                      │
│  3. Content filtering (banned_phrases, required_keywords)                       │
│  3. Format (UniversalFormatter via platform-specific wrapper)                   │
│  4. Apply content_replacements                                                  │
│  5. Content processing (trim by strategy: smart/word/hard)                      │
│  6. URL processing (cleanup, domain fixes)                                      │
│  7. Media upload                                                                │
│  8. Publish to Mastodon                                                         │
│  9. Mark as published                                                           │
└─────────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           MASTODON PUBLISHER                                    │
│  - Status posting with media        - Rate limit handling (429)                 │
│  - Media upload from URL            - Server error retry (5xx)                  │
│  - Threading (in_reply_to_id)       - Credential verification                   │
└─────────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           STATE MANAGER (PostgreSQL)                            │
│  - published_posts (deduplikace)    - source_state (scheduling, errors)         │
│  - activity_log (diagnostika)       - Thread lookup (platform_uri)              │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Hlavní soubory

| Soubor | Účel |
|--------|------|
| `bin/run_zbnw.rb` | Hlavní entry point pro cron |
| `lib/orchestrator.rb` | Koordinace všech komponent |
| `lib/processors/post_processor.rb` | Unified processing pipeline |
| `lib/processors/pipeline_steps.rb` | Pipeline step objekty (Dedup, Edit, Filter, URL) |
| `lib/processors/edit_detector.rb` | Detekce editovaných/duplikovaných postů |
| `lib/publishers/mastodon_publisher.rb` | Publikace na Mastodon |
| `lib/state/state_manager.rb` | Facade pro 5 state repositories |
| `lib/errors.rb` | Error hierarchie (`Zpravobot::Error` → podtřídy) |
| `lib/logging.rb` | Centralizovaný logging s denní rotací |
| `lib/support/loggable.rb` | Unified logging mixin pro všechny třídy |
| `lib/utils/http_client.rb` | Sdílený HTTP klient (get/post/retry/download) |
| `lib/webhook/ifttt_queue_processor.rb` | Twitter webhook zpracování |
| `bin/ifttt_webhook.rb` | HTTP server pro IFTTT webhooks |
| `bin/run_tests.rb` | Test runner s report generátorem |
| `bin/command_listener.rb` | CLI entry point pro Command Listener (Údržbot interaktivní příkazy) |
| `lib/monitoring/command_listener.rb` | Polling mentions, parsování příkazů, reply |
| `lib/monitoring/command_handlers.rb` | Registry a implementace příkazů (help, status, detail, sources, check) |
| `bin/broadcast.rb` | CLI nástroj pro broadcast zpráv na Mastodon účty |
| `bin/process_broadcast_queue.rb` | Cron processor pro tlambot broadcast queue |
| `lib/broadcast/broadcaster.rb` | Core broadcast engine (account resolution, retry, progress) |
| `lib/broadcast/tlambot_webhook_handler.rb` | Webhook parser pro tlambot (HMAC, routing, media) |
| `lib/broadcast/tlambot_queue_processor.rb` | Queue processor pro automatické broadcasty |

---

## Sdílená infrastruktura

Napříč celou aplikací se používá několik sdílených komponent, které byly sjednoceny během refaktoringu (Fáze 6–10).

### Error Hierarchy

**Soubor:** `lib/errors.rb`

Centralizovaná hierarchie exception tříd pro konzistentní error handling.

```
Zpravobot::Error (base)
├── NetworkError          # Síťové/HTTP chyby
│   ├── RateLimitError    # 429 (attr: retry_after)
│   └── ServerError       # 5xx (attr: status_code)
├── ConfigError           # Chybná konfigurace
├── PublishError          # Mastodon publish/update/delete
│   ├── StatusNotFoundError   # 404
│   ├── EditNotAllowedError   # 403
│   └── ValidationError       # 422
├── AdapterError          # Selhání zdrojového adaptéru
└── StateError            # Databáze/persistence
```

```ruby
# Rescue patterns:
rescue Zpravobot::Error => e           # Všechny Zpravobot chyby
rescue Zpravobot::NetworkError => e    # Síťové (včetně RateLimit, Server)
rescue Zpravobot::RateLimitError => e  # Jen rate limit
  sleep e.retry_after
```

### HttpClient

**Soubor:** `lib/utils/http_client.rb`

Centralizovaný HTTP klient eliminující duplicitní `Net::HTTP` boilerplate. Sjednocený User-Agent, retry logika, timeouty.

```ruby
# Simple GET
response = HttpClient.get(url)

# GET s custom headers a timeouty
response = HttpClient.get(url, headers: { 'Accept' => 'application/json' }, timeout: 30)

# POST JSON
response = HttpClient.post_json(url, { key: 'value' })

# PUT JSON, DELETE
response = HttpClient.put_json(url, data)
response = HttpClient.delete(url)

# Download souboru
HttpClient.download(url, '/tmp/image.jpg')

# Request s retry
response = HttpClient.request_with_retry(url, method: :get, max_retries: 3)
```

Používá se v: `MastodonPublisher`, `CommandListener`, `BaseProfileSyncer`, adaptérech.

### Support::Loggable

**Soubor:** `lib/support/loggable.rb`

Unified logging mixin zahrnutý ve všech třídách. Integruje se s centralizovaným `Logging` modulem, fallback na `puts` v testech a standalone skriptech.

```ruby
class MyClass
  include Support::Loggable

  def do_work
    log_info "Starting work..."     # → [INFO] MyClass: Starting work...
    log_warn "Low memory"           # → [WARN] MyClass: Low memory
    log_error "Connection failed"   # → [ERROR] MyClass: Connection failed
  end
end
```

Nahrazuje 13 dřívějších lokálních `def log` metod. Jediný `def log(` v lib/ je nyní v `support/loggable.rb`.

### Logging

**Soubor:** `lib/logging.rb`

Centralizovaný modul pro denní rotaci log souborů.

```ruby
Logging.setup(dir: 'logs', name: 'runner')
Logging.info("Message")   # → [2026-02-10 14:30:00] INFO: Message
Logging.error("Oops")     # → [2026-02-10 14:30:00] ERROR: Oops ❌
```

**Vlastnosti:**
- Denní rotace (nový soubor `name_YYYYMMDD.log` o půlnoci)
- Automatický cleanup starých logů (7 dní retence)
- `MultiLogger` — paralelní zápis do souboru + stdout
- Emoji prefixy v short format (`❌` ERROR, `⚠️` WARN, `ℹ️` INFO)

### HashHelpers

**Soubor:** `lib/utils/hash_helpers.rb`

```ruby
HashHelpers.symbolize_keys(hash)       # String → symbol klíče
HashHelpers.deep_symbolize_keys(hash)  # Rekurzivně
HashHelpers.deep_merge(base, override) # Hluboký merge
```

`ConfigLoader` konvertuje všechna YAML data na symbol klíče přes `deep_symbolize_keys` po `YAML.safe_load`.

---

## Processing Pipeline

Každý post prochází jednotnou pipeline v PostProcessor:

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. DEDUPE CHECK                                                 │
│    state_manager.published?(source_id, post_id)                 │
│    → :skipped if duplicate                                      │
├─────────────────────────────────────────────────────────────────┤
│ 1b. EDIT DETECTION (Twitter/Bluesky only)                       │
│    edit_detector.check_for_edit(source_id, post_id, username)   │
│    → :update_existing if similar post found                     │
│    → :skip_older_version if older version detected              │
├─────────────────────────────────────────────────────────────────┤
│ 2. CONTENT FILTERING                                            │
│    ContentFilter.banned?(text) → :skipped if banned             │
│    ContentFilter.has_required?(text) → :skipped if missing      │
│    Platform-specific skip rules (replies, retweets, quotes)     │
├─────────────────────────────────────────────────────────────────┤
│ 3. FORMATTING                                                   │
│    Platform wrapper (TwitterFormatter, BlueskyFormatter, etc.)  │
│    → UniversalFormatter                                         │
│    Output: formatted text with headers, URLs, mentions          │
├─────────────────────────────────────────────────────────────────┤
│ 4. CONTENT REPLACEMENTS                                         │
│    Apply regex/literal replacements from config                 │
│    (cleaning noise, fixing patterns)                            │
├─────────────────────────────────────────────────────────────────┤
│ 5. CONTENT PROCESSING (TRIM)                                    │
│    ContentProcessor with strategy:                              │
│    - smart: sentence boundary within tolerance                  │
│    - word: break at last word                                   │
│    - hard: exact cut + ellipsis                                 │
│    Preserves trailing URL through trimming                      │
├─────────────────────────────────────────────────────────────────┤
│ 6. URL PROCESSING                                               │
│    UrlProcessor:                                                │
│    - Remove tracking params (utm_*, fbclid, etc.)               │
│    - Apply domain fixes (from config)                           │
│    - Detect/remove truncated URLs (ending with …)               │
│    - Deduplicate URLs at end                                    │
├─────────────────────────────────────────────────────────────────┤
│ 7. MEDIA UPLOAD                                                 │
│    Download from source URL → Upload to Mastodon (v2 API)       │
│    v2 API returns 202 → poll GET /api/v1/media/:id              │
│    until 200 (ready), backoff 1-5s, max 10 attempts             │
│    Limit: max MAX_MEDIA_COUNT (4) per post, rest skipped        │
│    Skip: link_cards, video_thumbnails when video exists         │
│    Safety net: post-upload trim media_ids to MAX_MEDIA_COUNT    │
│    Return: array of media_ids                                   │
├─────────────────────────────────────────────────────────────────┤
│ 8. PUBLISH                                                      │
│    MastodonPublisher.publish(                                   │
│      text, media_ids, visibility, in_reply_to_id                │
│    )                                                            │
│    Retry on rate limit (429) and server errors (5xx)            │
│    Thread fallback: if parent post not found → standalone       │
├─────────────────────────────────────────────────────────────────┤
│ 9. MARK PUBLISHED                                               │
│    state_manager.mark_published(                                │
│      source_id, post_id, post_url, mastodon_status_id,          │
│      platform_uri                                               │
│    )                                                            │
│    state_manager.log_publish(...)                               │
├─────────────────────────────────────────────────────────────────┤
│ 9b. ADD TO EDIT BUFFER (Twitter/Bluesky only)                   │
│    edit_detector.add_to_buffer(source_id, post_id, username,    │
│      text, mastodon_id: mastodon_status_id)                     │
└─────────────────────────────────────────────────────────────────┘
```

---

## Orchestrator (Jádro)

**Soubor:** `lib/orchestrator.rb`

Orchestrator koordinuje běh celého systému. Je volán z `bin/run_zbnw.rb`.

### Hlavní metody

```ruby
class Runner
  # Spustit všechny enabled sources
  def run(dry_run: false, priority: nil, exclude_platform: nil, first_run: false)
  
  # Spustit konkrétní source
  def run_source(source_id, dry_run: false, first_run: false)
  
  # Spustit všechny sources dané platformy
  def run_platform(platform, dry_run: false, first_run: false)
end
```

### Životní cyklus zpracování

1. **Connect** k databázi
2. **Load sources** z config (YAML)
3. Pro každý source:
   - Zkontrolovat `source_due?` (interval)
   - Vytvořit adapter
   - Fetch posts
   - Pro každý post: delegovat na PostProcessor
   - Aktualizovat state
4. **Disconnect** z databáze

### Thread handling (Orchestrator-specific)

```ruby
# Bluesky: explicitní reply_to s AT URI
def resolve_thread_parent(source, post)
  if post.reply_to
    parent_uri = extract_parent_uri_from_reply_to(post.reply_to)
    mastodon_id = find_parent_mastodon_id(source.id, parent_uri)
    return mastodon_id if mastodon_id
  end
  
  # Twitter/generic: ThreadingSupport module
  super(source.id, post)
end
```

### Adapter creation

```ruby
def create_adapter(source)
  case source.platform
  when 'rss'
    Adapters::RssAdapter.new(feed_url: source.source_feed_url)
  when 'youtube'
    Adapters::YouTubeAdapter.new(channel_id: source.source_channel_id, ...)
  when 'bluesky'
    if source.bluesky_source_type == 'feed'
      Adapters::BlueskyAdapter.new(feed_url: source.source_feed_url)
    else
      Adapters::BlueskyAdapter.new(handle: source.source_handle, include_self_threads: true)
    end
  when 'twitter'
    Adapters::TwitterAdapter.new(handle: source.source_handle, nitter_instance: ...)
  end
end
```

---

## PostProcessor

**Soubory:** `lib/processors/post_processor.rb`, `lib/processors/pipeline_steps.rb`

Centralizovaná logika pro zpracování postů. Používá se z:
- **Orchestrator** (cron runner)
- **IftttQueueProcessor** (webhook processing)

### Pipeline Steps

Pipeline je dekompozitována do samostatných step objektů v `pipeline_steps.rb`:

```ruby
# Společné rozhraní: step.call(context) => context | Result
ProcessingContext   # Struct nesoucí data mezi kroky
DeduplicationStep   # Kontrola published?(source_id, post_id)
EditDetectionStep   # Detekce editovaných postů (Twitter/Bluesky)
ContentFilterStep   # Banned phrases, required keywords
UrlProcessingStep   # Tracking params, domain fixes, truncated URLs
```

Kroky redukují cyklomatickou složitost `PostProcessor#process` — každý krok má jednu odpovědnost a společný interface.

### Inicializace

```ruby
@post_processor = Processors::PostProcessor.new(
  state_manager: @state_manager,
  config_loader: @config_loader,
  dry_run: @dry_run,
  verbose: verbose_mode?
)
# PostProcessor includuje Support::Loggable — logging je automatický
```

### Hlavní metoda

```ruby
def process(post, source_config, options = {})
  # options[:in_reply_to_id] - pro threading
  # options[:on_format] - callback po formátování
  # options[:on_final] - callback před publikací
  
  # Vrací ProcessResult s:
  # - status: :published, :skipped, :failed
  # - mastodon_id: ID publikovaného statusu
  # - skipped_reason: důvod přeskočení
  # - error: chybová zpráva
end
```

### Formatter selection

```ruby
def get_formatter(platform, config)
  case platform.to_s
  when 'twitter'
    Formatters::TwitterFormatter.new(config)
  when 'bluesky'
    Formatters::BlueskyFormatter.new(config)
  when 'rss'
    Formatters::RssFormatter.new(config)
  when 'youtube'
    Formatters::YouTubeFormatter.new(config)
  end
end
```

---

## IFTTT Webhook systém

Twitter/X používá **hybridní architekturu** kombinující IFTTT webhooks a Nitter scraping.

### Architektura

```
Twitter API
    │
    ▼
  IFTTT  ──webhook──▶  Webhook Server (port 8089)
                              │
                              ▼
                        Queue Directory
                       /queue/ifttt/pending/
                              │
                              ▼
                      Queue Processor
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
           Tier 1          Tier 2          Tier 3
        (IFTTT only)   (IFTTT+Nitter)   (Fallback)
```

### Webhook Server

**Soubor:** `bin/ifttt_webhook.rb`

Lightweight Ruby HTTP server (stdlib only, ~10-15MB RAM).

```bash
# Spuštění
ruby bin/ifttt_webhook.rb

# S integrovaným queue processing
ruby bin/ifttt_webhook.rb --process-queue

# S auto-shutdown po neaktivitě
ruby bin/ifttt_webhook.rb --idle-shutdown 3600
```

**Endpointy:**

| Endpoint | Metoda | Účel |
|----------|--------|------|
| `/api/ifttt/twitter` | POST | Přijetí IFTTT webhook |
| `/health` | GET | Health check |
| `/stats` | GET | Queue statistiky |

**IFTTT Payload:**

```json
{
  "text": "{{Text}}",
  "embed_code": "{{TweetEmbedCode}}",
  "link_to_tweet": "{{LinkToTweet}}",
  "first_link_url": "{{FirstLinkUrl}}",
  "username": "{{UserName}}",
  "bot_id": "ct24_twitter"
}
```

### Queue Processor

**Soubor:** `lib/webhook/ifttt_queue_processor.rb`

Zpracovává payloady z queue directory s priority-based batch logic.

Po zpracování batche volá `mark_check_success()` pro každý `source_id`, který měl alespoň jeden úspěšný publish/update. Tím se aktualizuje `source_state.last_success` a health monitoring správně reflektuje stav Twitter sources.

**Priority systém:**

| Priority | Chování |
|----------|---------|
| `high` | Okamžité zpracování, bez batch delay |
| `normal` | Batch s 2min delay, thread-aware |
| `low` | Po normal, batch s delay |

**Timing konstanty:**

```ruby
BATCH_DELAY = 120      # 2 min - čas na nahromadění batche
MAX_AGE = 1800         # 30 min - force publish (anti-hromadění)
```

**Failed Queue:**

Při selhání volá `move_to_failed()` — přidá do JSON sekci `_failure: { reason:, failed_at:, retry_count: 0 }` a přesune soubor do `failed/`. Soubory v `failed/` jsou 1× za hodinu zpracovány `cron_retry_failed.sh` → `bin/retry_failed_queue.rb`. Nerecoverable chyby dostanou prefix `DEAD_` a jsou archivovány.

### TwitterTweetProcessor — unifikovaná vrstva

**Soubor:** `lib/processors/twitter_tweet_processor.rb`

Unifikovaná vrstva pro Twitter zpracování — stejná Tier logika pro **IFTTT webhook** i **Nitter RSS polling**. Oba vstupy (`IftttQueueProcessor` i `Orchestrator::Runner`) delegují na tuto třídu.

```
IFTTT webhook           Nitter RSS polling
     │                          │
IftttQueueProcessor    Orchestrator::Runner
     └──────── TwitterTweetProcessor ────────┘
                       │
              nitter_processing: true?
               false              true
                 │                 │
          Tier 1 / 1.5      fetch_single_post (3x retry)
                                   │
                            OK → Tier 2
                            Fail → Tier 3.5 (Syndication fallback)
                            Fail → Tier 3 (fallback_post)
```

### Tier systém

**Tier 1: Přímé IFTTT zpracování** (`nitter_processing: false`, text OK)
- Kdy: `nitter_processing: false` a text není zkrácený
- Data: Pouze z IFTTT payloadu
- Výhody: Nejrychlejší

**Tier 1.5: Syndication API** (`nitter_processing: false`)
- Kdy: `nitter_processing: false` — pro všechny posty přes `TwitterTweetProcessor`
- Data: Twitter Syndication API (neoficiální) — text + media
- Media: skutečné mp4 (`type: 'video'`) pro video tweety; JPEG foto jinak
- Text: t.co expand + strip media URL + FormatHelpers.clean_text
- Fallback: fallback_post (IFTTT data) pokud Syndication selže
- Bez Nitter závislosti

**Tier 2: Nitter HTML fetch + video enrichment** (`nitter_processing: true`, Nitter dostupný)
- Kdy: `nitter_processing: true` a Nitter instance odpoví
- Data: IFTTT trigger + plná data z Nitter HTML scraping
- Video enrichment: pokud detekováno video a Nitter nemá přímé mp4, zavolá Syndication API pro mp4
- Retry: 3 pokusy s exponenciálním backoff

**Tier 3.5: Syndication fallback** (`nitter_processing: true`, Nitter selhal)
- Kdy: Nitter selhal po všech pokusech, ale Syndication API je dostupné
- Data: Twitter Syndication API — záchrana dat po výpadku Nitter

**Tier 3: Čistý fallback (degraded)**
- Kdy: Nitter nedostupný a Syndication také selhal
- Data: IFTTT / RSS data s indikátorem `📖➡️`
- Přidá ellipsis pokud text >= 257 znaků

**Rozhodovací logika:**

```ruby
def determine_tier(ifttt_data)
  # Retweet → vždy Tier 2
  return 2 if text&.match?(/^RT\s+@\w+:/i)
  
  # Self-reply (thread) → Tier 2
  return 2 if is_self_reply?(text, username)
  
  # Photo v first_link_url → Tier 2
  return 2 if first_link&.match?(%r{/photo/\d*$})
  
  # Photo v embed_code → Tier 2
  return 2 if has_image_in_embed?(embed_code)
  
  # Video → Tier 2
  return 2 if first_link&.match?(%r{/video/\d*$})
  
  # Zkrácený text → Tier 2
  return 2 if likely_truncated?(text)
  
  # Ostatní → Tier 1
  1
end
```

### TwitterNitterAdapter

**Soubor:** `lib/adapters/twitter_nitter_adapter.rb`

**Konstanty:**

```ruby
TRUNCATION_THRESHOLD = 257

TERMINATOR_PATTERNS = {
  punctuation: /[.!?。！？…]\s*$/,
  emoji: /\p{Emoji}\s*$/,
  url: /https?:\/\/\S+\s*$/,
  hashtag: /#\w+\s*$/,
  mention: /@\w+\s*$/
}
```

**Detekce zkrácení:**

```ruby
def likely_truncated?(text)
  # 1. Obsahuje ellipsis
  return true if text =~ /[…]|\.{3}/
  
  # 2. URL obsahuje ellipsis
  return true if text =~ /https?:\/\/[^\s]*…/
  
  # 3. Text >= 257 znaků BEZ natural terminator
  if text.length >= TRUNCATION_THRESHOLD
    return !TERMINATOR_PATTERNS.values.any? { |p| text =~ p }
  end
  
  # 4. Končí českou předložkou/spojkou
  return true if text =~ /\s(a|i|k|na|do|že|nebo|ani|ale)\s*$/i
  
  false
end
```

---

## Adapters (Zdrojové adaptéry)

Každý adapter transformuje zdrojová data do unified `Post` modelu.

### Post Model

**Soubor:** `lib/models/post.rb`

```ruby
class Post
  attr_reader :platform, :id, :url, :title, :text, :published_at,
              :author, :is_repost, :is_quote, :is_reply,
              :reposted_by, :quoted_post, :reply_to, :media, :raw,
              :is_thread_post, :reply_to_handle, :has_video
  
  attr_accessor :thread_context  # Lazy loaded
end
```

### Author Model

**Soubor:** `lib/models/author.rb`

```ruby
class Author
  attr_reader :username, :display_name, :full_name, :url, :avatar_url
  
  def handle
    "@#{username}"
  end
end
```

### Media Model

**Soubor:** `lib/models/media.rb`

```ruby
class Media
  VALID_TYPES = %w[image video gif audio link_card video_thumbnail]
  
  attr_reader :type, :url, :alt_text, :width, :height, 
              :thumbnail_url, :title, :description
end
```

### Adapter přehled

| Adapter | Soubor | Zdroj dat |
|---------|--------|-----------|
| BlueskyAdapter | `lib/adapters/bluesky_adapter.rb` | AT Protocol API |
| TwitterAdapter | `lib/adapters/twitter_adapter.rb` | Nitter RSS/HTML |
| TwitterNitterAdapter | `lib/adapters/twitter_nitter_adapter.rb` | IFTTT payload parsing + Tier 1/1.5/3 fallback |
| RssAdapter | `lib/adapters/rss_adapter.rb` | RSS 2.0 / Atom |
| YouTubeAdapter | `lib/adapters/youtube_adapter.rb` | YouTube RSS |

---

## Formatters

Formatters transformují Post objekt do textu pro Mastodon.

### UniversalFormatter

**Soubor:** `lib/formatters/universal_formatter.rb`

Centrální formatter, na který delegují platform-specific wrappery.

**Typy postů:**

| Typ | Metoda | Formát |
|-----|--------|--------|
| Regular | `format_regular` | `{text}\n{url}` |
| Repost | `format_repost` | `{source} 🔄 @{author}:\n{text}\n{url}` |
| Quote | `format_quote` | `{source} 💬 @{quoted}:\n{text}\n{quoted_url}` |
| Thread | `format_thread` | `🧵 {text}\n{url}` |
| With Title | `format_with_title` | RSS/YouTube s title |

**Mentions transformace:**

| Typ | Config value | Vstup | Výstup |
|-----|--------------|-------|--------|
| `none` | - | `@user` | `@user` |
| `prefix` | `https://twitter.com/` | `@user` | `https://twitter.com/user` |
| `suffix` | `https://twitter.com/` | `@user` | `@user (https://twitter.com/user)` |
| `domain_suffix` | `twitter.com` | `@user` | `@user@twitter.com` |

**Poznámka:** Regex používá negative lookbehind `(?<![a-zA-Z0-9.])` aby neovlivňoval e-mailové adresy (např. `user@domain.com` zůstane nezměněn).

**URL rewriting:**

```ruby
def rewrite_urls(text, config)
  target = config[:url_domain]  # např. "nitter.net"
  domains = config[:rewrite_domains]  # ["twitter.com", "x.com"]
  
  domains.each do |domain|
    text.gsub!(%r{https?://(?:www\.)?#{domain}/}, "https://#{target}/")
  end
end
```

### Platform Wrappers

| Wrapper | Soubor | Platform defaults |
|---------|--------|-------------------|
| TwitterFormatter | `lib/formatters/twitter_formatter.rb` | `prefix_repost: '𝕏🔄'` |
| BlueskyFormatter | `lib/formatters/bluesky_formatter.rb` | `prefix_repost: '🦋🔄'` |
| RssFormatter | `lib/formatters/rss_formatter.rb` | `move_url_to_end: true` |
| YouTubeFormatter | `lib/formatters/youtube_formatter.rb` | `prefix_video: '🎬'` |

---

## Publishers

### MastodonPublisher

**Soubor:** `lib/publishers/mastodon_publisher.rb`

```ruby
class MastodonPublisher
  MAX_STATUS_LENGTH = 2500
  MAX_MEDIA_SIZE = 10 * 1024 * 1024  # 10MB
  MAX_MEDIA_COUNT = 4

  def publish(text, media_ids: [], visibility: 'public', in_reply_to_id: nil)
  def upload_media_from_url(url, description: nil)
  def upload_media(data, filename:, content_type:, description: nil)
  def verify_credentials

  private
  def wait_for_media_processing(media_id, max_attempts: 10, initial_delay: 1)
end
```

**Media upload (v2 API):**

Upload používá `POST /api/v2/media`, který je asynchronní — vrací `202 Accepted` dokud se médium zpracovává. Po 202 se automaticky polluje `GET /api/v1/media/:id` s exponenciálním backoffem (1-5s, max 10 pokusů). Publish se provede až po dokončení zpracování (200).

| HTTP kód (poll) | Význam |
|-----------------|--------|
| 200 | Médium ready |
| 206 | Stále se zpracovává → retry |
| Jiný | Neočekávaný stav → warning |

**Retry logika:**

| HTTP kód | Akce |
|----------|------|
| 429 (Rate Limited) | Čekat `Retry-After` + 1-3s, max 3 pokusy |
| 5xx (Server Error) | Čekat 1-3s, max 2 pokusy |
| Timeout | Retry s backoff |

**Thread fallback:**

Pokud publish s `in_reply_to_id` selže protože parent post neexistuje ("Record not found"), automaticky se provede retry jako standalone post bez `in_reply_to_id`. Raději publikovat bez vlákna než nepublikovat vůbec.

---

## State Management

**Adresář:** `lib/state/`

StateManager je **facade**, která deleguje na 5 specializovaných repository tříd. API zůstává kompatibilní — volající kód používá `state_manager.published?()` atd.

```
StateManager (facade, 191 řádků)
├── DatabaseConnection      # connect/disconnect/ensure_connection, schema validace
├── PublishedPostsRepository # published?, mark_published, find_by_*
├── SourceStateRepository    # get_source_state, mark_check_*, sources_due_for_check, stats
├── ActivityLogger           # log_activity, log_fetch/publish/skip/error/transient_error, recent_activity
└── EditBufferManager        # add_to_edit_buffer, find_by_text_hash, cleanup_edit_buffer
```

```ruby
manager = State::StateManager.new(schema: 'zpravobot')
manager.connect
manager.published?('ct24_twitter', 'tweet_123456')
manager.mark_published('ct24_twitter', 'tweet_123456',
  post_url: url, mastodon_status_id: id, platform_uri: uri)
manager.disconnect
```

### Tabulky

**published_posts:**

```sql
CREATE TABLE published_posts (
    id                  BIGSERIAL PRIMARY KEY,
    source_id           VARCHAR(100) NOT NULL,
    post_id             VARCHAR(255) NOT NULL,
    post_url            TEXT,
    mastodon_status_id  TEXT,
    platform_uri        TEXT,  -- Pro thread lookup (Bluesky AT URI)
    published_at        TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT uq_source_post UNIQUE (source_id, post_id)
);
```

**source_state:**

```sql
CREATE TABLE source_state (
    source_id       VARCHAR(100) PRIMARY KEY,
    last_check      TIMESTAMPTZ,
    last_success    TIMESTAMPTZ,
    posts_today     INTEGER DEFAULT 0,
    last_reset      DATE DEFAULT CURRENT_DATE,
    error_count     INTEGER DEFAULT 0,
    last_error      TEXT,
    updated_at      TIMESTAMPTZ DEFAULT NOW(),
    disabled_at     TIMESTAMPTZ               -- NULL = active; nastaveno při pause/retire
);
```

**activity_log:**

```sql
CREATE TABLE activity_log (
    id          BIGSERIAL PRIMARY KEY,
    source_id   VARCHAR(100),
    action      VARCHAR(50) NOT NULL,  -- fetch, publish, skip, error, profile_sync, media_upload, transient_error
    details     JSONB,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);
```

**edit_detection_buffer:**

Dočasná tabulka pro detekci editovaných postů (Twitter/Bluesky).

```sql
CREATE TABLE edit_detection_buffer (
    source_id       VARCHAR(100) NOT NULL,
    post_id         VARCHAR(64) NOT NULL,
    username        VARCHAR(100) NOT NULL,
    text_normalized TEXT NOT NULL,
    text_hash       VARCHAR(64),
    mastodon_id     VARCHAR(64),
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (source_id, post_id)
);

-- Indexy
CREATE INDEX idx_edit_buffer_username_hash ON edit_detection_buffer(username, text_hash);
CREATE INDEX idx_edit_buffer_username_created ON edit_detection_buffer(username, created_at);
CREATE INDEX idx_edit_buffer_created ON edit_detection_buffer(created_at);
```

| Parametr | Hodnota | Popis |
|----------|---------|-------|
| Retence | 2 hodiny | Automatický cleanup |
| Velikost | ~1MB | Self-cleaning buffer |

### Hlavní metody (facade API)

```ruby
class State::StateManager
  # Connection
  def connect / disconnect / connected? / ensure_connection

  # Published Posts (→ PublishedPostsRepository)
  def published?(source_id, post_id)
  def mark_published(source_id, post_id, post_url:, mastodon_status_id:, platform_uri: nil)
  def find_by_platform_uri(source_id, platform_uri)
  def find_by_post_id(source_id, post_id)
  def find_recent_thread_parent(source_id)
  def recent_published(source_id, limit: 10)

  # Source State (→ SourceStateRepository)
  def get_source_state(source_id)
  def mark_check_success(source_id, posts_published: 0)
  def mark_check_error(source_id, error_message)
  def sources_due_for_check(interval_minutes: 10, limit: 20)
  def sources_with_errors(min_errors: 3)
  def stats

  # Activity Log (→ ActivityLogger)
  def log_activity(source_id, action, details)
  def log_fetch / log_publish / log_skip / log_error_activity / log_transient_error
  def recent_activity(source_id, limit: 50)

  # Edit Buffer (→ EditBufferManager)
  def add_to_edit_buffer(source_id:, post_id:, username:, text_normalized:, ...)
  def find_by_text_hash(username, text_hash)
  def cleanup_edit_buffer(retention_hours: 2)
end
```

---

## Processors

### ContentProcessor

**Soubor:** `lib/processors/content_processor.rb`

Trimming strategie:

| Strategie | Chování |
|-----------|---------|
| `smart` | Hledá konec věty v rámci tolerance (default 12%), URL-aware |
| `word` | Ořízne na poslední celé slovo, cleanup neúplných URL |
| `hard` | Přesný řez + ellipsis |

```ruby
processor = Processors::ContentProcessor.new(
  max_length: 500,
  strategy: :smart,
  tolerance_percent: 12
)
```

**Normalizace (`normalize`):**
- `...` (tři tečky) → `…` (Unicode ellipsis)
- `……` (více ellipsis) → `…` (jeden)

**URL-aware trimming (`trim_smart`):**
- Přeskočí `.` uvnitř URL (nedetekuje jako konec věty)
- Přeskočí běžné zkratky (`atd.`, `mj.`, `tzn.`)

**URL cleanup (`clean_url_artifacts`):**
- Odstraní neúplné URL fragmenty po oříznutí
- Odstraní stojatý text za URL (artefakty)

### ContentFilter

**Soubor:** `lib/processors/content_filter.rb`

Identické chování jako IFTTT filter rules.

```ruby
filter = Processors::ContentFilter.new(
  banned_phrases: [...],
  required_keywords: [...],
  content_replacements: [...]
)

filter.banned?(text)      # true pokud obsahuje banned phrase
filter.has_required?(text) # true pokud prázdný list NEBO obsahuje keyword
filter.apply_replacements(text)
```

**Filter rule typy:**

| Typ | Příklad | Chování |
|-----|---------|---------|
| String | `"spam"` | Case-insensitive substring |
| `literal` | `{type: "literal", pattern: "SPAM"}` | Case-insensitive substring |
| `regex` | `{type: "regex", pattern: "sp[a4]m", flags: "i"}` | Regex match |
| `and` | `{type: "and", content: ["a", "b"]}` | Všechny musí matchovat |
| `or` | `{type: "or", content: ["a", "b"]}` | Alespoň jeden musí matchovat |
| `not` | `{type: "not", content: ["a"]}` | Žádný nesmí matchovat |

### UrlProcessor

**Soubor:** `lib/processors/url_processor.rb`

```ruby
processor = Processors::UrlProcessor.new(
  no_trim_domains: ['youtu.be', 'bit.ly', 'facebook.com']
)

processor.process_content(text)  # Celý text
processor.process_url(url)       # Jednotlivá URL
processor.apply_domain_fixes(text, fixes)
```

**Funkce:**
- Odstranění tracking parametrů (utm_*, fbclid, etc.)
- Zachování parametrů pro shorteners a social media
- Detekce truncated URLs (`https://example.com/...`)
- Deduplikace URL na konci postu

### FacebookProcessor

**Soubor:** `lib/processors/facebook_processor.rb`

Specifické čištění pro RSS.app Facebook feedy.

```ruby
processor = Processors::FacebookProcessor.new
cleaned = processor.process("Text… — Text…")  # Odstraní em-dash duplikát
```

### EditDetector

**Soubor:** `lib/processors/edit_detector.rb`

Detekuje editované/duplikované posty a zabraňuje publikaci duplicit.

| Platforma | Problém | Řešení |
|-----------|---------|--------|
| **Twitter/X** | Editace tweetů (do 1h) vytváří nové ID | Detekce + UPDATE Mastodon |
| **Bluesky** | Delete+repost (oprava pozice URL atd.) | Detekce + UPDATE Mastodon |

**Konfigurace:**

| Parametr | Hodnota | Popis |
|----------|---------|-------|
| `SIMILARITY_THRESHOLD` | 0.80 | 80% podobnost pro detekci |
| `EDIT_WINDOW` | 3600 | 1 hodina lookup window |
| `BUFFER_RETENTION` | 7200 | 2 hodiny retence v bufferu |

**Klíčové metody:**

```ruby
class EditDetector
  def check_for_edit(source_id, post_id, username, text)
    # Vrací: { action: :publish_new | :update_existing | :skip_older_version,
    #          mastodon_id: ..., original_post_id: ..., similarity: ... }
  end
  
  def add_to_buffer(source_id, post_id, username, text, mastodon_id:)
    # Přidá post do bufferu pro budoucí detekci
  end
  
  def cleanup(retention_hours: 2)
    # Smaže staré záznamy z bufferu
  end
end
```

**Similarity algoritmus:**
- Kombinace Jaccard similarity a Containment similarity
- Normalizace textu (odstranění URL, mentions, hashtags)
- Podpora Twitter Snowflake ID (numerické) i Bluesky TID (base32 string)

**Post ID porovnání:**

| Platforma | Formát ID | Porovnání |
|-----------|-----------|-----------|
| Twitter | `2017125315533799497` (číselné) | Numerické (`to_i <=> to_i`) |
| Bluesky | `3lhtptd7apc2i` (base32) | Lexikografické (`to_s <=> to_s`) |

---

## Profile Syncers

Synchronizují profily ze zdrojových platforem na Mastodon bot účty.

### BaseProfileSyncer

**Soubor:** `lib/syncers/base_profile_syncer.rb` (595 řádků)

Template Method pattern — sdílená logika pro všechny profile syncery. Subclassy implementují platformně specifické metody.

```ruby
class BaseProfileSyncer
  include Support::Loggable

  # Template methods (implementují subclassy):
  def fetch_profile     # Získá profil ze zdrojové platformy
  def build_bio         # Sestaví bio text
  def build_fields      # Sestaví metadata pole
  def download_avatar   # Stáhne avatar
  def download_header   # Stáhne header image

  # Sdílené metody:
  def preview           # Bez změn
  def sync!             # Plná synchronizace
  def force_sync!       # Bypass cache
end
```

### BlueskyProfileSyncer

**Soubor:** `lib/syncers/bluesky_profile_syncer.rb`

```ruby
syncer = Syncers::BlueskyProfileSyncer.new(
  bluesky_handle: 'demagog.cz',
  mastodon_instance: 'https://zpravobot.news',
  mastodon_token: 'xxx',
  language: 'cs',
  retention_days: 90
)

syncer.preview       # Bez změn
syncer.sync!         # Plná synchronizace
syncer.force_sync!   # Bypass cache
```

### TwitterProfileSyncer

**Soubor:** `lib/syncers/twitter_profile_syncer.rb`

Stejné API, používá Nitter pro scraping.

### FacebookProfileSyncer

**Soubor:** `lib/syncers/facebook_profile_syncer.rb`

Profile sync pro Facebook sources (RSS s `rss_source_type: facebook`).
Používá Browserless.io API pro headless browser rendering.

```ruby
syncer = Syncers::FacebookProfileSyncer.new(
  facebook_handle: 'headlinercz',
  mastodon_instance: 'https://zpravobot.news',
  mastodon_token: 'xxx',
  browserless_token: ENV['BROWSERLESS_TOKEN'],
  facebook_cookies: [...],
  language: 'cs',
  retention_days: 90
)
```

**Požadavky:** `BROWSERLESS_TOKEN`, Facebook cookies v `config/platforms/facebook.yml`

### Metadata fields

Syncery nastavují 4 metadata pole na Mastodon profilu:

| # | Pole | Hodnota |
|---|------|---------|
| 1 | `bsky:` / `x:` / `fb:` | URL profilu |
| 2 | `web:` | Zachováno z původního profilu |
| 3 | `spravuje:` | `@zpravobot@zpravobot.news` |
| 4 | `retence:` | `{N} dní` |

---

## Konfigurace

### Hierarchie

```
config/
├── global.yml              # Globální nastavení
├── platforms/
│   ├── twitter.yml         # Platform defaults
│   ├── bluesky.yml
│   ├── rss.yml
│   └── youtube.yml
├── sources/
│   ├── ct24_twitter.yml    # Jednotlivé zdroje
│   ├── demagogcz_bluesky.yml
│   └── ...
└── mastodon_accounts.yml   # Mastodon credentials
```

**Merge pořadí:** `global.yml` → `platforms/{platform}.yml` → `sources/{id}.yml`

### Příklad source konfigurace

```yaml
id: ct24_twitter
enabled: true
platform: twitter

source:
  handle: "CT24zive"
  nitter_instance: "http://xn.zpravobot.news:8080"

target:
  mastodon_account: ct24
  visibility: public

formatting:
  source_name: "ČT24"
  url_domain: "nitter.net"
  prefix_repost: "𝕏🔄"
  prefix_quote: "𝕏💬"
  max_length: 500

filtering:
  skip_replies: true
  skip_retweets: false
  banned_phrases: []
  required_keywords: []

processing:
  trim_strategy: smart
  content_replacements: []
  url_domain_fixes: []

mentions:
  type: "domain_suffix"
  value: "twitter.com"

scheduling:
  priority: high

profile_sync:
  enabled: true
  language: cs
  retention_days: 90
```

### ConfigLoader

**Soubor:** `lib/config/config_loader.rb`

```ruby
loader = Config::ConfigLoader.new('config')

config = loader.load_source('ct24_twitter')
sources = loader.load_all_sources
platform_sources = loader.load_sources_by_platform('twitter')
creds = loader.mastodon_credentials('ct24')
```

### SourceConfig wrapper

**Soubor:** `lib/config/source_config.rb`

```ruby
source = Config::SourceConfig.new(config_hash)

source.id                    # "ct24_twitter"
source.platform              # "twitter"
source.source_handle         # "CT24zive"
source.mastodon_account      # "ct24"
source.mastodon_token        # Token z credentials
source.filtering             # Hash s filter rules
source.formatting            # Hash s formatting options
source.interval_minutes      # Odvozeno z priority (high=5, normal=20, low=55)
```

---

## Threading (Vlákna)

### ThreadingSupport module

**Soubor:** `lib/support/threading_support.rb`

Sdílený modul pro Orchestrator i IftttQueueProcessor.

```ruby
module ThreadingSupport
  # In-memory thread cache pro aktuální run
  @thread_cache = {}  # source_id => { post_url => mastodon_id }
  
  def resolve_thread_parent(source_id, post)
    # 1. Zkusit in-memory cache
    # 2. Zkusit databázi (platform_uri)
    # 3. Zkusit databázi (post_id jako backup)
  end
  
  def update_thread_cache(source_id, post, mastodon_id)
    # Uložit pro následující posty ve vlákně
  end
end
```

### Platform-specific thread detection

**Bluesky:**
- Self-reply detekce porovnáním DID v AT URI
- `parent_uri` z `record.reply.parent.uri`
- Lookup přes `platform_uri` sloupec

**Twitter:**
- RSS: Pattern `R to @same_handle:` v title
- IFTTT: Pattern `@username` na začátku + batch timing

---

## Cron a Scheduling

### Produkční cron jobs

```bash
# ==================================
# IFTTT Webhook Server (watchdog)
# ==================================
# Kontroluje každou minutu, zda webhook server běží
* * * * * /app/data/zbnw-ng/cron_webhook.sh

# ==================================
# IFTTT Queue Processor (Twitter)
# ==================================
# Zpracovává příchozí prod webhooky každé 2 minuty
*/2 * * * * /app/data/zbnw-ng/cron_ifttt.sh

# Zpracovává failed webhooky každou hodinu (v :00)
0 * * * * /app/data/zbnw-ng/cron_retry_failed.sh

# ==================================
# Content Sync (Bluesky, RSS, YouTube)
# ==================================
# Twitter se zpracovává přes IFTTT pipeline výše
*/10 * * * * /app/data/zbnw-ng/cron_zbnw.sh --verbose --exclude-platform twitter

# ==================================
# Profile Sync
# ==================================
# Bluesky profily - 1x denně v 1:00 (nativní API)
0 1 * * * /app/data/zbnw-ng/cron_profile_sync.sh --platform bluesky

# Facebook profily - 1x za 3 dny ve 2:00 (scraping, šetříme)
0 2 */3 * * /app/data/zbnw-ng/cron_profile_sync.sh --platform facebook

# Twitter profily - 3 skupiny rotující po dnech týdne, ve 3:00 (Nitter scraping, šetříme)
# Po,Čt = skupina 0 | Út,Pá = skupina 1 | St,So = skupina 2 | Ne = volno
0 3 * * 1,4  /app/data/zbnw-ng/cron_profile_sync.sh --platform twitter --group 0
0 3 * * 2,5  /app/data/zbnw-ng/cron_profile_sync.sh --platform twitter --group 1
0 3 * * 3,6  /app/data/zbnw-ng/cron_profile_sync.sh --platform twitter --group 2

# RSS profily - 1x týdně v neděli ve 3:00 (deleguje na BS/FB/TW syncery)
0 3 * * 0    /app/data/zbnw-ng/cron_profile_sync.sh --platform rss

# ==================================
# Údržbot + Tlambot
# ==================================
# Naslouchač každých 5 minut: udrzbot (Mastodon mentions) + tlambot (broadcast queue)
*/5 * * * * /app/data/zbnw-ng/cron_command_listener.sh

# Health check každých 10 minut - alert jen při problému
*/10 * * * * /app/data/zbnw-ng/cron_health.sh --alert --save

# Heartbeat jednou denně v 8:00 - jen když je vše OK
0 8 * * * /app/data/zbnw-ng/cron_health.sh --heartbeat

# ==================================
# Maintenance
# ==================================
# Log rotation - denně v 04:00 (mazat *.log starší než 7 dní)
0 4 * * * find /app/data/zbnw-ng/logs -name "*.log" -mtime +7 -delete 2>/dev/null

# Processed Queue clean-up - denně v 04:00 (mazat *.json starší než 7 dní)
0 4 * * * find /app/data/zbnw-ng/queue/ifttt/processed -name "*.json" -mtime +7 -delete 2>/dev/null
```

### Testovací prostředí

```bash
# Test: Twitter přes RSS polling (TwitterTweetProcessor)
*/5 * * * * /app/data/zbnw-ng-test/cron_zbnw.sh --verbose --platform twitter

# Test: ostatní platformy (Bluesky, RSS, YouTube) - 1x za hodinu
0 * * * * /app/data/zbnw-ng-test/cron_zbnw.sh --verbose --exclude-platform twitter

# Údržba
0 4 * * * find /app/data/zbnw-ng-test/logs -name "*.log" -mtime +7 -delete 2>/dev/null
0 4 * * * find /app/data/zbnw-ng-test/queue/ifttt/processed -name "*.json" -mtime +7 -delete 2>/dev/null
```

### Intervaly podle komponenty

| Komponenta | Interval | Důvod |
|------------|----------|-------|
| Webhook watchdog | 1 min | Okamžitá detekce výpadku |
| IFTTT queue (prod) | 2 min | Rychlé zpracování Twitter webhooků |
| IFTTT failed retry | 1× za hod | Opakování selhavších webhooků (mimo DEAD_) |
| Content sync (prod) | 10 min | Bluesky/RSS/YouTube polling |
| Content sync Twitter (test) | 5 min | Twitter RSS polling via TwitterTweetProcessor |
| Content sync ostatní (test) | 1× za hod | Bluesky/RSS/YouTube polling |
| Profile sync (Bluesky) | 1x denně | Nativní API, stabilní |
| Profile sync (Facebook) | 1x za 3 dny | Scraping, šetření rate limitů |
| Profile sync (Twitter) | 2× týdně/skupinu | Nitter scraping, rotace skupin po dnech |
| Profile sync (RSS) | 1x týdně (Ne) | Deleguje na BS/FB/TW syncery |
| Health check | 10 min | Monitoring s alerty |
| Command listener + broadcast | 5 min | Polling mentions + broadcast queue |

---

## Monitoring (Údržbot)

**Mastodon účet:** `@udrzbot@zpravobot.news`
**Soubory:** `bin/health_monitor.rb`, `bin/cron_health.sh`, `bin/command_listener.rb`, `cron_command_listener.sh`, `config/health_monitor.yml`

Inteligentní monitoring systém s dvěma režimy:
1. **Health Monitor** — automatické kontroly a alertování (jednosměrné)
2. **Command Listener** — interaktivní příkazy přes Mastodon mentions (obousměrné)

### Kontrolované služby

| Služba | Check | Kritéria |
|--------|-------|----------|
| IFTTT Webhook | `webhook_check.rb` | HTTP `/health` response 200, uptime |
| Nitter instance | `nitter_check.rb` | HTTP RSS endpoint response 200 |
| Nitter accounts | `nitter_accounts_check.rb` | Žádné account-related chyby v logech |
| IFTTT Queue | `queue_check.rb` | Žádné failed webhooky |
| Processing | `processing_check.rb` | Sources bez opakovaných errors |
| Mastodon API | `mastodon_check.rb` | HTTP verify_credentials response 200 |
| Problematic Sources | `problematic_sources_check.rb` | Sources bez error_count spikes |
| Log Errors | `log_analysis_check.rb` | Analýza error patternů v logách |
| Server Resources | `server_resources_check.rb` | Disk, paměť, CPU |
| Recurring Warnings | `recurring_warnings_check.rb` | Opakující se warning patterny |
| Runner Health | `runner_health_check.rb` | Stav cron runnerů (poslední běh, trvání) |

**Celkem: 11 health checků** v `lib/health/checks/`.

### CLI Options

```bash
# Zobrazit stav v terminálu
ruby bin/health_monitor.rb

# Detailní výstup s remediací
ruby bin/health_monitor.rb --details

# Poslat alert na Mastodon (jen při problémech)
ruby bin/health_monitor.rb --alert

# Poslat heartbeat (jen když vše OK)
ruby bin/health_monitor.rb --heartbeat

# Uložit report do logs/health/
ruby bin/health_monitor.rb --save

# JSON výstup
ruby bin/health_monitor.rb --json

# Kombinace
ruby bin/health_monitor.rb --alert --save
```

### Smart Alerting

| Situace | Akce |
|---------|------|
| Nový problém | Okamžitý alert |
| Přetrvávající problém (den 7:00–23:00) | Reminder každých 30 minut |
| Přetrvávající problém (noc 23:00–7:00) | Reminder každých 60 minut |
| Problém vyřešen (po 20min stabilizaci) | "Resolved" zpráva |
| Vše OK | Heartbeat 1x denně (8:00) |

**Deduplikace:** Alert state se ukládá do `logs/health/alert_state.json`

### Konfigurace

**Soubor:** `config/health_monitor.yml`

```yaml
# Thresholds
thresholds:
  activity_baseline_variance: 0.5  # 50% pokles = warning
  error_count_critical: 5          # 5+ errors = critical
  
# Alerting
alerting:
  mastodon_instance: "https://zpravobot.news"
  mastodon_account: "@udrzbot@zpravobot.news"
  visibility: "private"            # followers-only
  
# Checks
checks:
  webhook_url: "http://localhost:8089/health"
  nitter_url: "http://xn.zpravobot.news:8080"
```

### Cron Setup

```bash
# Health check každých 10 minut
*/10 * * * * /app/data/zbnw-ng/cron_health.sh --alert --save

# Heartbeat v 8:00
0 8 * * * /app/data/zbnw-ng/cron_health.sh --heartbeat
```

### Příklad alertu

```
🔧 Údržbot hlásí [2026-02-02 14:30]

⚠️ Processing: 3 zdrojů s opakovanými chybami
   → spotlightcz_youtube(59), dvtvcz_youtube(59)
   → ruby bin/run_zbnw.rb --source SOURCE_ID --dry-run
   → UPDATE source_state SET error_count=0 WHERE source_id='X'

✅ OK: Webhook, Nitter, Queue, Mastodon

#údržbot #zpravobot
```

### Command Listener (interaktivní příkazy)

**Soubory:** `bin/command_listener.rb`, `lib/monitoring/command_listener.rb`, `lib/monitoring/command_handlers.rb`

Umožňuje oprávněným uživatelům posílat příkazy Údržbotu přes Mastodon mentions. Bot polluje notifikace, parsuje příkazy a odpovídá přes DM.

#### Použití

```bash
# Jednorázový poll
ruby bin/command_listener.rb

# Dry run (parsuje ale neodpovídá)
ruby bin/command_listener.rb --dry-run

# Vlastní config
ruby bin/command_listener.rb -c /path/to/config.yml
```

#### Cron

```bash
# cron_command_listener.sh - wrapper
*/5 * * * * /app/data/zbnw-ng/cron_command_listener.sh
```

#### Dostupné příkazy

| Příkaz | Popis |
|--------|-------|
| `help` | Seznam příkazů (nespouští health checky) |
| `status` | Kompaktní přehled: overall status + jednořádkové výsledky |
| `detail` / `details` | Plný report s remediací |
| `sources` | Problematické zdroje |
| `check [nazev]` | Detail jednoho checku |

**Příklad:** `@udrzbot status` → DM s přehledem stavu

#### Check aliasy (pro příkaz `check`)

| Alias | Check |
|-------|-------|
| `server` | Server |
| `webhook` | Webhook Server |
| `nitter` | Nitter Instance |
| `accounts` | Nitter Accounts |
| `queue` | IFTTT Queue |
| `processing` | Processing |
| `mastodon` | Mastodon API |
| `logs` | Log Errors |
| `sources` | Problematic Sources |

#### Architektura

```
Mastodon Mentions
    │
    ▼
CommandListener (polling)
    │
    ├── Fetch: GET /api/v1/notifications?types[]=mention&since_id=X
    ├── Auth check (whitelist)
    ├── Rate limit (max 3/cyklus/účet)
    ├── Parse: HtmlCleaner → odstranění @mention → split command+args
    ├── Dispatch → CommandHandlers
    ├── Reply: MastodonPublisher (DM, in_reply_to_id)
    └── Dismiss: POST /api/v1/notifications/:id/dismiss
```

#### Konfigurace (v `health_monitor.yml`)

```yaml
command_listener:
  allowed_accounts:
    - '<admin-account>'           # Reálné účty jsou v zbnw-ng_system.private.md
  rate_limit_per_cycle: 3
  response_visibility: 'direct'
  bot_account: 'udrzbot'
  poll_limit: 30
```

#### Klíčové vlastnosti

| Vlastnost | Popis |
|-----------|-------|
| **Lockfile** | `tmp/command_listener.lock` — prevence overlapping cron runs |
| **State** | `logs/health/command_listener_state.json` — cursor (`last_notification_id`) |
| **První spuštění** | Nastaví cursor na nejnovější notifikaci, neprocesuje historické |
| **Rate limiting** | Max příkazů per účet per cyklus (default 3), nad limit → DM s odmítnutím |
| **Autorizace** | Whitelist účtů z configu; neautorizované → tiché dismiss |
| **Dlouhé odpovědi** | Split na 2400-char chunky, posting jako thread |
| **Lazy init** | `HealthMonitor` se vytváří jen když příkaz vyžaduje health checky |
| **Results caching** | Checky běží max jednou per handler instanci |

#### Mastodon API requirements

Token `ZPRAVOBOT_MONITOR_TOKEN` musí mít scopes:
- `read:notifications` — polling mentions
- `write:notifications` — dismiss notifikací
- `write:statuses` — odpovědi (DM)

---

## Broadcast systém

**Soubory:** `bin/broadcast.rb`, `bin/process_broadcast_queue.rb`, `lib/broadcast/` (4 soubory)

Systém pro hromadné zasílání zpráv na Mastodon účty. Dva režimy:
1. **CLI broadcast** — interaktivní/neinteraktivní odeslání z příkazové řádky
2. **Tlambot webhook** — automatický broadcast spouštěný Mastodon webhookem z účtu @tlambot

### Architektura

```
┌─────────────────────────┐   ┌──────────────────────────────────┐
│   CLI (bin/broadcast.rb) │   │ Mastodon Webhook (status.created) │
│   Interaktivní/CLI args  │   │ z @tlambot účtu                   │
└──────────┬──────────────┘   └────────────────┬─────────────────┘
           │                                    │
           │                              ┌─────▼──────────────────┐
           │                              │ TlambotWebhookHandler  │
           │                              │ HMAC verifikace        │
           │                              │ Mention routing        │
           │                              │ → queue/broadcast/     │
           │                              └─────┬──────────────────┘
           │                                    │
           │                              ┌─────▼──────────────────┐
           │                              │ TlambotQueueProcessor  │
           │                              │ (cron 1x/min)          │
           ▼                              └─────┬──────────────────┘
    ┌──────────────┐                            │
    │  Broadcaster  │◄───────────────────────────┘
    │  - resolve accounts                        │
    │  - filter blacklist                        │
    │  - retry + throttle                        │
    │  - progress bar                            │
    └──────┬───────┘
           │
           ▼
    ┌──────────────────┐
    │ MastodonPublisher │ (pro každý účet)
    │ publish + media   │
    └──────────────────┘
```

### CLI Broadcast (`bin/broadcast.rb`)

```bash
ruby bin/broadcast.rb                                    # Interaktivní režim
ruby bin/broadcast.rb --message "Text"                   # Neinteraktivní
ruby bin/broadcast.rb --message "..." --dry-run          # Preview
ruby bin/broadcast.rb --target all                       # Všechny účty
ruby bin/broadcast.rb --target zpravobot                 # Pouze zpravobot.news (default)
ruby bin/broadcast.rb --account betabot                  # Konkrétní účet
ruby bin/broadcast.rb --account betabot,enkocz           # Více účtů
ruby bin/broadcast.rb --media file.png --alt "Popis"     # S přílohou
ruby bin/broadcast.rb --visibility unlisted              # Unlisted viditelnost
ruby bin/broadcast.rb --test                             # Testovací prostředí
```

**Exit kódy:** 0=úspěch, 1=částečné selhání, 2=chyba argumentů, 130=SIGINT

### Tlambot Webhook

Mastodon webhook `status.created` z @tlambot → TlambotWebhookHandler → fronta → TlambotQueueProcessor.

**Mention-based routing:**

| Mentions v postu | Cíl broadcastu |
|------------------|----------------|
| Žádné (jen @tlambot) | Všechny účty |
| @zpravobot | Pouze účty na zpravobot.news |
| @jedenbot | Konkrétní účet |
| @jedenbot @druhy | Více konkrétních účtů |

Všechny @mentions se odstraní z textu broadcastu. HMAC-SHA256 verifikace podpisu (`X-Hub-Signature` header).

**Queue adresáře:** `queue/broadcast/pending/` → `processed/` | `failed/`

### Konfigurace (`config/broadcast.yml`)

```yaml
blacklist:                    # Účty vyloučené z broadcastu
  - some_account
throttle:
  delay_seconds: 0.5          # Pauza mezi účty
retry:
  max_attempts: 3              # Max retry pokusů
  backoff_base: 2              # Exponenciální backoff
default_target: zpravobot      # Default cíl (zpravobot | all)
default_visibility: public     # Default viditelnost
tlambot:
  trigger_account: tlambot     # Účet spouštějící broadcasty
  broadcast_visibility: public # Override viditelnosti z webhooku
```

### BroadcastLogger

Samostatný append-only logger do `logs/broadcast_YYYYMMDD.log`. Loguje session start/end, per-account výsledky (OK/ERR).

### Soubory

| Soubor | LOC | Účel |
|--------|-----|------|
| `bin/broadcast.rb` | 111 | CLI entry point (OptionParser, signal handling) |
| `bin/process_broadcast_queue.rb` | 42 | Cron entry point pro queue processor |
| `lib/broadcast/broadcaster.rb` | 385 | Core engine (accounts, validation, retry, progress) |
| `lib/broadcast/tlambot_webhook_handler.rb` | 165 | Webhook parser (HMAC, routing, HTML cleaning) |
| `lib/broadcast/tlambot_queue_processor.rb` | 328 | Queue processor (job files, publish, favourite) |
| `lib/broadcast/broadcast_logger.rb` | 72 | Broadcast-specific logging |

---

## Databáze

### Připojení

```ruby
# Z environment variable
ENV['CLOUDRON_POSTGRESQL_URL']

# Manuální
state_manager = State::StateManager.new(schema: 'zpravobot')
state_manager.connect
```

### Schémata

| Schéma | Účel |
|--------|------|
| `zpravobot` | Produkce |
| `zpravobot_test` | Testování |

### Migrace

```bash
# Produkční schéma
psql "$CLOUDRON_POSTGRESQL_URL" -f db/migrate_cloudron.sql

# Test schéma
psql "$CLOUDRON_POSTGRESQL_URL" -f db/migrate_test_schema.sql
```

---

## Environment Variables

| Proměnná | Default | Popis |
|----------|---------|-------|
| `CLOUDRON_POSTGRESQL_URL` | - | PostgreSQL connection string |
| `NITTER_INSTANCE` | `http://xn.zpravobot.news:8080` | Nitter instance URL |
| `IFTTT_WEBHOOK_PORT` | `8089` | Port webhook serveru |
| `IFTTT_QUEUE_DIR` | `/app/data/zbnw-ng/queue/ifttt` | Queue directory |
| `ZBNW_CONFIG_DIR` | `/app/data/zbnw-ng/config` | Config directory |
| `ZBNW_DIR` | `/app/data/zbnw-ng` | Base directory |
| `ZPRAVOBOT_SCHEMA` | `zpravobot` | Database schema |
| `ZPRAVOBOT_MONITOR_TOKEN` | - | Mastodon token pro Údržbot (alerts, commands) |
| `TLAMBOT_WEBHOOK_SECRET` | - | HMAC secret pro tlambot webhook verifikaci |
| `BROADCAST_QUEUE_DIR` | `queue/broadcast` | Adresář broadcast queue |
| `ZBNW_MASTODON_TOKEN_{ID}` | - | ENV override Mastodon tokenu (per account) |
| `DEBUG` | - | Verbose logging |

---

## CLI nástroje

### run_zbnw.rb

```bash
# Všechny zdroje
./bin/run_zbnw.rb

# Konkrétní zdroj
./bin/run_zbnw.rb --source ct24_twitter

# Konkrétní platforma
./bin/run_zbnw.rb --platform bluesky

# Vše kromě platformy
./bin/run_zbnw.rb --exclude-platform twitter

# Test schéma
./bin/run_zbnw.rb --test

# Dry run (bez publikace)
./bin/run_zbnw.rb --dry-run

# First run (inicializace state)
./bin/run_zbnw.rb --first-run --source new_source
```

### sync_profiles.rb

```bash
./bin/sync_profiles.rb                                  # Všechny enabled sources
./bin/sync_profiles.rb --source ct24_twitter            # Konkrétní source
./bin/sync_profiles.rb --platform bluesky               # Jen Bluesky
./bin/sync_profiles.rb --platform facebook              # Jen Facebook (RSS s rss_source_type: facebook)
./bin/sync_profiles.rb --exclude-platform twitter       # Vše kromě Twitteru
./bin/sync_profiles.rb --dry-run                        # Preview bez změn
```

> **Poznámka:** `--platform facebook` filtruje RSS sources s `rss_source_type: facebook`.
> Volby `--source`, `--platform` a `--exclude-platform` jsou vzájemně exkluzivní.

### create_source.rb

```bash
./bin/create_source.rb         # Interaktivní průvodce
./bin/create_source.rb --quick # Pouze povinné údaje
```

### manage_source.rb

```bash
./bin/manage_source.rb                              # Interaktivní menu
./bin/manage_source.rb pause  ct24_twitter          # Pozastavit zdroj
./bin/manage_source.rb pause  ct24_twitter --reason "Výpadek Nitter"
./bin/manage_source.rb resume ct24_twitter          # Obnovit (spustí init_time wizard)
./bin/manage_source.rb retire ct24_twitter          # Trvale vyřadit (odstraní z DB)
./bin/manage_source.rb status ct24_twitter          # Stav zdroje
./bin/manage_source.rb list                         # Výpis všech zdrojů
./bin/manage_source.rb --test                       # Testovací schéma
```

### retry_failed_queue.rb

```bash
./bin/retry_failed_queue.rb            # Zpracovat failed queue (cron)
./bin/retry_failed_queue.rb --dry-run  # Zobrazit co by se stalo
./bin/retry_failed_queue.rb --verbose  # Verbose výpis
```

### health_monitor.rb

```bash
./bin/health_monitor.rb              # Jednorázová kontrola
./bin/health_monitor.rb --heartbeat  # S heartbeat zprávou
./bin/health_monitor.rb --force      # Ignorovat cooldown
```

### broadcast.rb

```bash
./bin/broadcast.rb                                    # Interaktivní
./bin/broadcast.rb --message "Text" --target all      # Hromadný broadcast
./bin/broadcast.rb --message "Text" --dry-run         # Preview
./bin/broadcast.rb --account betabot,enkocz           # Konkrétní účty
./bin/broadcast.rb --media img.png --alt "Popis"      # S přílohou
```

### process_broadcast_queue.rb

```bash
./bin/process_broadcast_queue.rb     # Zpracovat broadcast queue (cron)
```

---

## Testování

### Test Framework

ZBNW-NG používá **vlastní test framework** (ne minitest/RSpec). Testy jsou standalone Ruby skripty s konvencemi:

```ruby
# test/test_example.rb
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

$passed = 0
$failed = 0

def test(name, expected, actual)
  if expected == actual
    $passed += 1
  else
    $failed += 1
    puts "FAIL: #{name} — expected #{expected.inspect}, got #{actual.inspect}"
  end
end

def test_raises(name, exception_class, &block)
  block.call
  $failed += 1
  puts "FAIL: #{name} — expected #{exception_class}, no exception raised"
rescue exception_class
  $passed += 1
rescue => e
  $failed += 1
  puts "FAIL: #{name} — expected #{exception_class}, got #{e.class}"
end

# ... testy ...

puts "#{$passed} passed, #{$failed} failed"
exit($failed > 0 ? 1 : 0)
```

### Test Runner

**Soubory:** `bin/run_tests.rb`, `lib/test_runner/runner.rb`, `lib/test_runner/output_parser.rb`, `lib/test_runner/report_generator.rb`

```bash
ruby bin/run_tests.rb              # Unit testy (default)
ruby bin/run_tests.rb --unit       # Offline unit testy
ruby bin/run_tests.rb --network    # Network-dependent testy
ruby bin/run_tests.rb --db         # Database testy (PostgreSQL)
ruby bin/run_tests.rb --e2e        # E2E / publish testy (interaktivní)
ruby bin/run_tests.rb --all        # unit + network + db (bez interaktivních)
ruby bin/run_tests.rb --tag bluesky # Testy s tagem
ruby bin/run_tests.rb --file edit  # Testy matchující "edit"
ruby bin/run_tests.rb --list       # Seznam testů bez spuštění
```

### Test Catalog

**Soubor:** `config/test_catalog.yml`

Registr testů s metadaty pro test runner:

```yaml
tests:
  test_models:
    file: test/test_models.rb
    category: unit
    tags: [offline, models]
    exit_code_reliable: true
    timeout: 30
```

**Kategorie:** `unit`, `network`, `e2e`, `db`
**Tagy:** `offline`, `bluesky`, `twitter`, `rss`, `youtube`, `facebook`, `nitter`, `syndication`, `mastodon`, `processor`, `formatter`, `config`, `ifttt`

### Aktuální stav

| Metrika | Hodnota |
|---------|---------|
| Unit testy | 56/56 PASS |
| Assertions | 1552 |
| Test souborů | 84 |
| Katalog testů | 82 (56 unit, 18 network, 2 db, 6 e2e) |

---

## Checklist pro změny

### Při úpravě Orchestratoru

- [ ] Otestovat `--dry-run`
- [ ] Otestovat `--first-run` na novém zdroji
- [ ] Zkontrolovat thread handling
- [ ] Aktualizovat tuto dokumentaci

### Při úpravě PostProcessoru

- [ ] Otestovat přes Orchestrator (cron)
- [ ] Otestovat přes IftttQueueProcessor (webhook)
- [ ] Zkontrolovat všechny skip reasons
- [ ] Ověřit formatting output

### Při úpravě Adaptéru

- [ ] Otestovat Post model fields
- [ ] Ověřit media extraction
- [ ] Zkontrolovat thread detection
- [ ] Aktualizovat platformní dokumentaci

### Při úpravě Formatteru

- [ ] Otestovat všechny typy postů (regular, repost, quote, thread)
- [ ] Ověřit mentions transformace
- [ ] Zkontrolovat URL rewriting
- [ ] Ověřit max_length handling

### Při úpravě Konfigurace

- [ ] Ověřit merge hierarchii
- [ ] Zkontrolovat backward compatibility
- [ ] Aktualizovat example soubory
