# Bluesky platforma v ZBNW-NG

> **Poslední aktualizace:** 2026-04-11
> **Stav:** Produkční

> **Recent changes:**
> - **2026-04-11 (TEST-1):** Přidán `test/test_profile_syncer_subclasses.rb` — 9 unit testů pro `BlueskyProfileSyncer` (template methods, parse, fetch happy-path + errors)
> - **2026-04-09 (PERF-7):** `BlueskyProfileSyncer.fetch_display_name` měl tichý rescue — přidán `warn` log
> - **2026-03-13:** Profile card blocker — při mention v textu bez jiných médií se nahraje `white_strip_1280x1.png` (dříve transparent), aby Mastodon nezobrazoval profile card místo link card

---

## Obsah

1. [Přehled](#přehled)
2. [Architektura](#architektura)
3. [BlueskyAdapter](#blueskyadapter)
4. [BlueskyFormatter](#blueskyformatter)
5. [BlueskyProfileSyncer](#blueskyprofilesyncer)
6. [Konfigurace](#konfigurace)
7. [Threading (vlákna)](#threading-vlákna)
8. [Cron a scheduling](#cron-a-scheduling)
9. [Časté problémy](#časté-problémy)
10. [API reference](#api-reference)

---

## Přehled

Bluesky integrace v ZBNW-NG umožňuje:

- **Stahování postů** z uživatelských profilů a custom feedů
- **Formátování** pro Mastodon (reposty, citace, vlákna)
- **Synchronizaci profilů** (avatar, banner, bio, metadata)
- **Threading** - publikace vláken jako nativní Mastodon threads

### Klíčové vlastnosti

| Funkce | Stav | Poznámka |
|--------|------|----------|
| Profile feed | ✅ | Posty z uživatelského profilu |
| Custom feed | ✅ | Posty z feed generátorů |
| Reposty | ✅ | S hlavičkou 🦋🔁 |
| Citace | ✅ | S hlavičkou 🦋💬 |
| Author header | ✅ | Pro feed sources (`show_author_header: true`) |
| Vlákna | ✅ | Nativní Mastodon threads |
| Média | ✅ | Obrázky, video, link cards |
| Profile sync | ✅ | Avatar, banner, bio, fields |

---

## Architektura

```
┌─────────────────┐     ┌──────────────────┐     ┌───────────────────┐
│  Bluesky API    │────▶│  BlueskyAdapter  │────▶│  BlueskyFormatter │
│  (AT Protocol)  │     │  (fetch posts)   │     │  (format text)    │
└─────────────────┘     └──────────────────┘     └───────────────────┘
                                                          │
                                                          ▼
┌─────────────────┐     ┌──────────────────┐     ┌───────────────────┐
│  Mastodon API   │◀────│ MastodonPublisher│◀────│  Orchestrator     │
│                 │     │                  │     │  (threading, etc) │
└─────────────────┘     └──────────────────┘     └───────────────────┘

┌─────────────────┐     ┌──────────────────────┐
│  Bluesky API    │────▶│ BlueskyProfileSyncer │────▶ Mastodon API
│  (profile)      │     │  (avatar, bio, etc)  │
└─────────────────┘     └──────────────────────┘
```

### Soubory

| Soubor | Účel |
|--------|------|
| `lib/adapters/bluesky_adapter.rb` | Stahování postů |
| `lib/formatters/bluesky_formatter.rb` | Formátování textu |
| `lib/syncers/bluesky_profile_syncer.rb` | Synchronizace profilů |
| `lib/processors/edit_detector.rb` | Detekce delete+repost duplicit |
| `lib/models/media.rb` | Model médií (link cards s title/description) |
| `config/platforms/bluesky.yml` | Výchozí nastavení platformy |

---

## BlueskyAdapter

### Umístění
`lib/adapters/bluesky_adapter.rb`

### Dva režimy provozu

#### 1. Profile mód (`MODE_PROFILE`)

Stahuje posty z konkrétního uživatelského profilu.

```ruby
Adapters::BlueskyAdapter.new(
  handle: 'demagog.cz',
  include_self_threads: true
)
```

**API endpoint:** `app.bsky.feed.getAuthorFeed`

#### 2. Custom Feed mód (`MODE_CUSTOM_FEED`)

Stahuje posty z custom feed generátoru (tematické feedy).

```ruby
Adapters::BlueskyAdapter.new(
  feed_url: 'https://bsky.app/profile/richardgolias.cz/feed/aaalpdtfsootk'
)
```

**API endpoint:** `app.bsky.feed.getFeed`

### Rozhodovací logika

```ruby
def validate_config!
  if config[:feed_url]
    @mode = MODE_CUSTOM_FEED
    parse_feed_url(config[:feed_url])
  elsif config[:handle]
    @mode = MODE_PROFILE
    @handle = config[:handle]
  else
    raise ArgumentError, "Bluesky config requires either 'handle' or 'feed_url'"
  end
end
```

### Parametry

| Parametr | Typ | Default | Popis |
|----------|-----|---------|-------|
| `handle` | String | - | Bluesky handle (pro profile mód) |
| `feed_url` | String | - | URL custom feedu (pro feed mód) |
| `include_self_threads` | Boolean | `false` | Stahovat self-replies pro vlákna |
| `skip_replies` | Boolean | `true` | Přeskočit externí odpovědi |
| `skip_reposts` | Boolean | `false` | Přeskočit reposty |
| `skip_quotes` | Boolean | `false` | Přeskočit citace |

### Typy postů

| Typ | Detekce | Příznak |
|-----|---------|---------|
| Běžný post | default | - |
| Repost | `reason.$type == 'reasonRepost'` | `is_repost: true` |
| Citace | `embed.$type == 'record'` | `is_quote: true` |
| Odpověď | `record.reply != nil` | `is_reply: true` |
| Self-reply (vlákno) | DID match | `is_thread_post: true` |

### Facet URL expansion

Bluesky ukládá plné URL ve facets, ale v textu zobrazuje zkrácené. Adapter automaticky nahrazuje:

```
Text: "Více na example.com/very-lo..."
Facet: { uri: "https://example.com/very-long-article-url" }
→ Výstup: "Více na https://example.com/very-long-article-url"
```

### Media extrakce

Podporované typy:
- `app.bsky.embed.images#view` → obrázky
- `app.bsky.embed.video#view` → video (HLS playlist)
- `app.bsky.embed.external#view` → link cards
- `app.bsky.embed.recordWithMedia#view` → citace s médii

### Media model

`lib/models/media.rb` - reprezentace média v postu.

```ruby
Media.new(
  type: :link_card,      # image, video, gif, audio, link_card, video_thumbnail
  url: "https://...",
  alt_text: "popis",
  thumbnail_url: "https://...",
  title: "Titulek",      # pro link_card
  description: "Popis"   # pro link_card
)
```

**Poznámka:** Parametry `title` a `description` jsou používány pouze pro `link_card` typ (embed external z Bluesky).

---

## BlueskyFormatter

### Umístění
`lib/formatters/bluesky_formatter.rb`

### Účel

Formátuje Post objekt z BlueskyAdapter do textu pro Mastodon. Deleguje na UniversalFormatter.

### Výchozí nastavení

```ruby
DEFAULTS = {
  prefix_repost: '🦋🔁',
  prefix_quote: '🦋💬',
  prefix_thread: '🧵',
  prefix_video: '🎬',
  prefix_post_url: "\n",
  prefix_self_reference: 'svůj post',
  language: 'cs',
  mentions: {
    type: 'none',
    value: ''
  },
  max_length: 500
}
```

### Formát výstupu

**Regular post z feed source (s `show_author_header: true`):**
```
Marcela_N (@marcellan.bsky.social) 🦋:
Text postu...

https://bsky.app/profile/marcellan.bsky.social/post/xyz
```

Formát headeru: `{display_name} (@{handle}) {platform_emoji}:`

**Repost:**
```
🦋🔁 Jméno Autora:
Text původního postu...

https://bsky.app/profile/autor/post/xyz
```

**Citace:**
```
🦋💬 Jméno Autora cituje svůj post:
Text citace...

Citovaný text...

https://bsky.app/profile/autor/post/xyz
```

**Vlákno (thread):**
```
Text postu... 🧵

https://bsky.app/profile/autor/post/xyz
```

### Mentions transformace

| Typ | Vstup | Výstup |
|-----|-------|--------|
| `none` | `@user.bsky.social` | `@user.bsky.social` |
| `prefix` | `@user.bsky.social` | `https://bsky.app/profile/user.bsky.social` |
| `domain_suffix` | `@user.bsky.social` | `@user.bsky.social@bsky.social` |

---

## BlueskyProfileSyncer

### Umístění
`lib/syncers/bluesky_profile_syncer.rb`

### Účel

Synchronizuje profil z Bluesky na Mastodon bot účet:
- Avatar
- Banner (header)
- Bio (popis)
- Metadata fields (4 pole)

### Použití

```ruby
syncer = Syncers::BlueskyProfileSyncer.new(
  bluesky_handle: 'demagog.cz',
  mastodon_instance: 'https://zpravobot.news',
  mastodon_token: 'xxx',
  language: 'cs',
  retention_days: 90
)

# Preview (bez změn)
syncer.preview

# Plná synchronizace
syncer.sync!

# Částečná synchronizace
syncer.sync_avatar!
syncer.sync_banner!
syncer.sync_bio!
syncer.sync_fields!

# Vynucená synchronizace (bypass cache)
syncer.force_sync!
```

### Metadata fields

Syncer nastavuje 4 metadata pole na Mastodon profilu:

| # | Pole (cs/sk/en) | Hodnota |
|---|-----------------|---------|
| 1 | `bsky:` | `https://bsky.app/profile/{handle}` |
| 2 | `web:` | Zachováno z původního profilu, nebo `—` |
| 3 | `spravuje:` / `spravované:` / `managed by:` | `@zpravobot@zpravobot.news` |
| 4 | `retence:` / `retencia:` / `retention:` | `{N} dní` / `{N} dní` / `{N} days` |

**Příklad (čeština):**
```
bsky:      bsky.app/profile/nesestra.bsky.social
web:       —
spravuje:  @zpravobot
retence:   180 dní
```

**Poznámka:** Pole `web:` se zachovává z původního Mastodon profilu. Pokud neexistovalo, nastaví se na `—`.

### Cache

Obrázky (avatar, banner) se cachují po dobu 7 dní:
- Umístění: `/app/data/zbnw-ng-test/cache/profiles/`
- TTL: 604800 sekund (7 dní)

### Konfigurace v source YAML

```yaml
profile_sync:
  enabled: true           # Povolit synchronizaci
  sync_avatar: true       # Synchronizovat avatar
  sync_banner: true       # Synchronizovat banner
  sync_bio: true          # Synchronizovat bio
  sync_fields: true       # Synchronizovat metadata
  language: cs            # Jazyk pro metadata (cs/sk/en)
  retention_days: 90      # Retence postů (7/30/90/180)
```

---

## Konfigurace

### Platform defaults

Soubor: `config/platforms/bluesky.yml`

```yaml
filtering:
  skip_replies: true
  skip_retweets: false
  skip_quotes: false
  allow_self_retweets: true

formatting:
  platform_emoji: "🦋"
  prefix_repost: "🦋🔁"
  prefix_quote: "🦋💬"
  prefix_self_reference: "svůj post"
  move_url_to_end: true

mentions:
  type: prefix
  value: "https://bsky.app/profile/"

processing:
  max_length: 500
  trim_strategy: smart

scheduling:
  priority: normal
  max_posts_per_run: 10
```

### Profile zdroj (YAML)

```yaml
id: demagogcz_bluesky
enabled: true
platform: bluesky
# bluesky_source_type: handle  # default

source:
  handle: "demagog.cz"

target:
  mastodon_account: demagogcz

formatting:
  source_name: "Demagog.cz"

profile_sync:
  enabled: true
  language: cs
  retention_days: 90
```

### Custom Feed zdroj (YAML)

```yaml
id: odemknuto_bluesky_feed
enabled: true
platform: bluesky
bluesky_source_type: feed  # POVINNÉ!

source:
  feed_url: "https://bsky.app/profile/richardgolias.cz/feed/aaalpdtfsootk"

target:
  mastodon_account: odemknuto

formatting:
  show_author_header: true  # Přidat header s autorem pro regular posty

profile_sync:
  enabled: false  # Feed nemá profil
```

### Klíčové rozdíly

| Položka | Profile | Feed |
|---------|---------|------|
| `bluesky_source_type` | `handle` (default) | `feed` (povinné!) |
| `source.handle` | ✅ povinné | ❌ nepoužívá se |
| `source.feed_url` | ❌ nepoužívá se | ✅ povinné |
| `show_author_header` | `false` (nedává smysl) | `true` (doporučeno) |
| `profile_sync.enabled` | `true` | `false` |
| Threading | ✅ podporováno | ❌ nedává smysl |

---

## Threading (vlákna)

### Jak vlákna fungují

1. Autor vytvoří post (1/2 🧵)
2. Autor odpoví na svůj post (2/2 🧵) = **self-reply**
3. ZBNW detekuje self-reply porovnáním DID
4. Publikuje jako Mastodon thread s `in_reply_to_id`

### Detekce self-reply

```ruby
def detect_self_reply(reply, author_data)
  parent_uri = reply.dig('parent', 'uri')
  # URI format: at://did:plc:xxx/app.bsky.feed.post/rkey
  parent_did = extract_did_from_uri(parent_uri)
  author_did = author_data['did']
  
  parent_did == author_did  # true = self-reply
end
```

### API filtry

| Parametr | API filtr | Výsledek |
|----------|-----------|----------|
| `include_self_threads: false` | `posts_no_replies` | Jen samostatné posty |
| `include_self_threads: true` | `posts_and_author_threads` | Posty + self-replies |

### Orchestrator integrace

V `lib/orchestrator.rb`, metoda `create_adapter`:

```ruby
when 'bluesky'
  if source.bluesky_source_type == 'feed'
    # Feed - bez threading
    Adapters::BlueskyAdapter.new(feed_url: source.source_feed_url)
  else
    # Profile - s threading
    Adapters::BlueskyAdapter.new(
      handle: source.source_handle,
      include_self_threads: true
    )
  end
```

### DB schema pro threading

```sql
-- Tabulka published_posts
platform_uri       VARCHAR  -- AT URI (at://did:plc:xxx/...)
mastodon_status_id VARCHAR  -- Mastodon post ID

-- Lookup pro threading
SELECT mastodon_status_id 
FROM published_posts 
WHERE source_id = ? AND platform_uri = ?
```

---

## Edit Detection

### Problém

Bluesky **nepodporuje editaci postů** (AT Protocol neumožňuje měnit existující záznamy). Autoři však často:
1. Publikují post
2. Všimnou si chyby (např. špatná pozice URL)
3. Smažou post
4. Publikují opravenou verzi

Pokud ZBNW-NG stihne zpracovat první verzi před smazáním, vznikne duplicita.

### Příklad

```
07:48:00 - Deník N postne verzi 1 (URL na začátku)
07:48:30 - ZBNW-NG polluje, publikuje verzi 1 na Mastodon
07:49:00 - Deník N smaže verzi 1, postne verzi 2 (URL na konci)
07:56:30 - ZBNW-NG polluje, detekuje podobnost → UPDATE Mastodon
```

### Řešení

ZBNW-NG používá **EditDetector** v `PostProcessor`:

```ruby
# V process metodě
if edit_detection_enabled?(platform)  # true pro 'bluesky'
  edit_result = check_for_edit(source_id, post_id, post, source_config)
  
  case edit_result[:action]
  when :skip_older_version
    return Result.new(status: :skipped, skipped_reason: 'older_version')
  when :update_existing
    return process_as_update(post, source_config, edit_result, options)
  end
end
```

### Bluesky TID vs Twitter Snowflake

| Platforma | Formát ID | Porovnání |
|-----------|-----------|-----------|
| Twitter | `2017125315533799497` (číselné) | Numerické (`to_i <=> to_i`) |
| Bluesky | `3lhtptd7apc2i` (base32) | Lexikografické (`to_s <=> to_s`) |

EditDetector automaticky detekuje formát a použije správné porovnání.

### Konfigurace

| Parametr | Hodnota | Popis |
|----------|---------|-------|
| `SIMILARITY_THRESHOLD` | 0.80 | 80% podobnost pro detekci |
| `EDIT_WINDOW` | 3600s | 1 hodina lookup window |
| `BUFFER_RETENTION` | 7200s | 2 hodiny retence |

### Monitoring

```bash
grep -i "similar post\|detected edit\|updated:" logs/app_*.log | grep bluesky
```

Očekávané logy:
```
[EditDetector] Similar post found: 3lhtqwe1abc2j ~ 3lhtptd7apc2i (83.6%)
[denikn_bluesky] Detected edit: 3lhtqwe1abc2j updates 3lhtptd7apc2i (84% similar)
[denikn_bluesky] Updated: 123456789
```

---

## Cron a scheduling

### Runner (stahování postů)

```bash
# Každých 8 minut (bluesky + ostatní platformy kromě twitter)
*/8 * * * * /app/data/zbnw-ng-test/cron_zbnw.sh --exclude-platform twitter
```

### Profile sync

```bash
# 4x denně (0:00, 6:00, 12:00, 18:00)
0 0,6,12,18 * * * /app/data/zbnw-ng-test/cron_profile_sync.sh --platform bluesky
```

### Manuální spuštění

```bash
# Konkrétní zdroj
./bin/run_zbnw.rb --source demagogcz_bluesky --test

# Celá platforma
./bin/run_zbnw.rb --platform bluesky

# Profile sync - preview
./bin/sync_profiles.rb --source demagogcz_bluesky --dry-run

# Profile sync - execute
./bin/sync_profiles.rb --source demagogcz_bluesky
```

---

## Časté problémy

### 1. "Bluesky handle required"

**Příčina:** Feed zdroj nemá `bluesky_source_type: feed`.

**Řešení:**
```yaml
bluesky_source_type: feed  # Přidat!
source:
  feed_url: "https://..."
```

### 2. Vlákna se nepublikují kompletně

**Příčina:** `include_self_threads` není předáno do adapteru.

**Řešení:** Zkontrolovat `create_adapter` v orchestratoru - musí být:
```ruby
include_self_threads: true
```

### 3. Vlákna se nepropojují

**Příčina:** Parent post není v DB (timing issue).

**Diagnostika:**
```sql
SELECT * FROM zpravobot_test.published_posts 
WHERE source_id = 'demagogcz_bluesky' 
ORDER BY created_at DESC LIMIT 10;
```

### 4. Custom feed nefunguje

**Příčina:** Nelze resolvovat handle na DID.

**Test:**
```bash
curl "https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle?handle=richardgolias.cz"
```

### 5. URL jsou zkrácené

**Příčina:** Facet expansion selhává.

**Diagnostika:** Zkontrolovat `raw.facets` v logu.

### 6. "unknown keywords: :title, :description"

**Příčina:** Media model nepřijímá parametry pro link cards.

**Řešení:** V `lib/models/media.rb` přidat `title` a `description`:
```ruby
attr_reader :type, :url, :alt_text, :width, :height, :thumbnail_url, :title, :description

def initialize(type:, url:, alt_text: nil, width: nil, height: nil, 
               thumbnail_url: nil, title: nil, description: nil)
```

### 7. Profile sync nefunguje

**Příčiny:**
- Neplatný Mastodon token
- Bluesky profil neexistuje
- Rate limiting

**Test:**
```bash
./bin/sync_profiles.rb --source demagogcz_bluesky --dry-run
```

---

## API reference

### Bluesky veřejné API

```
Base URL: https://public.api.bsky.app/xrpc
```

| Endpoint | Účel |
|----------|------|
| `app.bsky.feed.getAuthorFeed` | Posty z profilu |
| `app.bsky.feed.getFeed` | Posty z custom feedu |
| `app.bsky.feed.getFeedGenerator` | Info o feedu |
| `app.bsky.actor.getProfile` | Profil uživatele |
| `com.atproto.identity.resolveHandle` | Handle → DID |

### Příklady volání

```bash
# Profile feed
curl "https://public.api.bsky.app/xrpc/app.bsky.feed.getAuthorFeed?actor=demagog.cz&limit=10&filter=posts_and_author_threads"

# Custom feed (potřebuje AT-URI)
curl "https://public.api.bsky.app/xrpc/app.bsky.feed.getFeed?feed=at://did:plc:xxx/app.bsky.feed.generator/yyy&limit=10"

# Resolve handle
curl "https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle?handle=richardgolias.cz"

# Profile
curl "https://public.api.bsky.app/xrpc/app.bsky.actor.getProfile?actor=demagog.cz"
```
