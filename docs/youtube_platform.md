# YouTube platforma v ZBNW-NG

> **Poslední aktualizace:** 2026-04-11
> **Stav:** Produkční

> **Recent changes:**
> - **2026-04-11 (TEST-1):** `test_profile_syncer_subclasses.rb` — 15 unit testů pro `YoutubeProfileSyncer` (parse ytInitialData, meta tag fallback, channel_url, fetch error paths)
> - **2026-03-01:** Přidán `YoutubeProfileSyncer` — plain HTTP scraping `ytInitialData` (bez API klíče, bez Browserless). **Opt-in**: jen zdroje s `source.handle` v YAML se synchronizují. Cron: neděle 02:00.

---

## Obsah

1. [Přehled](#přehled)
2. [Architektura](#architektura)
3. [YouTubeAdapter](#youtubeadapter)
4. [YouTubeFormatter](#youtubeformatter)
5. [Konfigurace](#konfigurace)
6. [Filtrování Shorts](#filtrování-shorts)
7. [Thumbnail handling](#thumbnail-handling)
8. [Cron a scheduling](#cron-a-scheduling)
9. [Časté problémy](#časté-problémy)
10. [API reference](#api-reference)

---

## Přehled

YouTube integrace v ZBNW-NG umožňuje:

- **Stahování videí** z YouTube kanálů přes RSS feed
- **Extrakci metadat** z `media:group` namespace (popis, views, thumbnail)
- **Filtrování Shorts** pomocí UULF playlist
- **Formátování** pro Mastodon s thumbnailem jako média
- **Detekci Shorts** v URL (pro informační účely)

### Klíčové vlastnosti

| Funkce | Stav | Poznámka |
|--------|------|----------|
| RSS feed | ✅ | Standardní YouTube Atom feed |
| media:group parsing | ✅ | REXML pro plná metadata |
| Popis videa | ✅ | Z `media:description` |
| Thumbnail | ✅ | Upload jako Mastodon média |
| Views count | ✅ | Volitelné zobrazení |
| Star rating | ✅ | Extrahuje se, ale nezobrazuje |
| Shorts filtrování | ✅ | UULF playlist |
| Handle → Channel ID | ❌ | YouTube blokuje - použít channel_id |
| Profile sync | ❌ | N/A - YouTube nemá synchronizovatelný profil |
| Threading | ❌ | N/A - videa nejsou vlákna |

---

## Architektura

```
┌─────────────────────┐     ┌──────────────────┐     ┌────────────────────┐
│  YouTube RSS Feed   │────▶│  YouTubeAdapter  │────▶│  YouTubeFormatter  │
│  (Atom + media:ns)  │     │  (fetch + parse) │     │  (format text)     │
└─────────────────────┘     └──────────────────┘     └────────────────────┘
                                                              │
                                                              ▼
┌─────────────────────┐     ┌──────────────────┐     ┌────────────────────┐
│  Mastodon API       │◀────│ MastodonPublisher│◀────│  Orchestrator      │
│  (status + media)   │     │  (thumbnail up)  │     │  (scheduling)      │
└─────────────────────┘     └──────────────────┘     └────────────────────┘
```

### Soubory

| Soubor | Účel |
|--------|------|
| `lib/adapters/youtube_adapter.rb` | Stahování a parsing RSS feedu |
| `lib/formatters/youtube_formatter.rb` | Formátování textu pro Mastodon |
| `lib/formatters/universal_formatter.rb` | Sdílená formátovací logika |
| `lib/models/post.rb` | Model postu |
| `lib/models/media.rb` | Model média (thumbnail) |
| `config/platforms/youtube.yml` | Výchozí nastavení platformy |

---

## YouTubeAdapter

### Umístění
`lib/adapters/youtube_adapter.rb`

### Inicializace

```ruby
Adapters::YouTubeAdapter.new(
  channel_id: 'UCFb-u3ISt99gxZ9TxIQW7UA',  # Povinné
  source_name: 'DVTV',                       # Volitelné - display name
  no_shorts: false                           # Volitelné - filtrovat Shorts
)
# Poznámka: handle parametr existuje v kódu, ale YouTube blokuje resolution
```

### Parametry

| Parametr | Typ | Default | Popis |
|----------|-----|---------|-------|
| `channel_id` | String | - | YouTube channel ID (UC...) - **povinné** |
| `handle` | String | - | ❌ DEPRECATED - YouTube blokuje resolution |
| `source_name` | String | `nil` | Display name pro autora |
| `no_shorts` | Boolean | `false` | Použít UULF playlist (bez Shorts) |

### Feed URL logika

```ruby
def feed_url
  if @no_shorts
    # UULF playlist = pouze long-form videa (bez Shorts, bez livestreamů)
    playlist_id = @channel_id.sub(/^UC/, 'UULF')
    "https://www.youtube.com/feeds/videos.xml?playlist_id=#{playlist_id}"
  else
    "https://www.youtube.com/feeds/videos.xml?channel_id=#{@channel_id}"
  end
end
```

### Handle resolution

Adapter podporuje překlad `@handle` na `channel_id`:

```ruby
def resolve_handle(handle)
  handle = "@#{handle}" unless handle.start_with?('@')
  
  # Fetch YouTube channel page
  uri = URI.parse("https://www.youtube.com/#{handle}")
  response = http.request(request)
  
  # Try multiple patterns to find channel ID
  patterns = [
    /"channelId":"(UC[a-zA-Z0-9_-]{22})"/,
    /"externalId":"(UC[a-zA-Z0-9_-]{22})"/,
    /channel\/(UC[a-zA-Z0-9_-]{22})/,
    /"browseId":"(UC[a-zA-Z0-9_-]{22})"/
  ]
  
  patterns.each do |pattern|
    match = response.body.match(pattern)
    return match[1] if match
  end
  
  nil
end
```

**⚠️ DEPRECATED:** YouTube aktivně blokuje scraping stránek kanálů. Handle resolution již nefunguje spolehlivě a **není podporován**. Vždy použijte přímo `channel_id`.

### Proces stahování

1. **Fetch RSS** - stáhne XML z YouTube
2. **Parse RSS** - `RSS::Parser` pro základní strukturu
3. **Parse media:group** - `REXML` pro plná metadata
4. **Filter by date** - vyfiltruje starší posty
5. **Convert to Post** - vytvoří Post objekty

```ruby
def fetch_posts(since: nil)
  raw_content = fetch_feed_content
  
  # Parse with RSS gem for basic structure
  feed = RSS::Parser.parse(raw_content, false)
  entries = feed.items
  
  # Parse media:group with REXML for full metadata
  media_data = parse_media_groups(raw_content)
  
  # Filter by date if specified
  if since
    entries = entries.select { |e| entry_time(e) > since }
  end
  
  # Convert to Post objects
  entries.map { |entry| entry_to_post(feed, entry, media_data) }
end
```

### media:group parsing

YouTube RSS feed obsahuje `media:group` namespace s rozšířenými metadaty:

```ruby
def parse_media_groups(xml_content)
  media_data = {}
  
  doc = REXML::Document.new(xml_content)
  
  doc.elements.each('//entry') do |entry|
    video_id = extract_video_id_from_xml(entry)
    next unless video_id
    
    media_info = {
      video_id: video_id,
      description: nil,
      thumbnail_url: nil,
      thumbnail_width: nil,
      thumbnail_height: nil,
      views: nil,
      star_rating: nil
    }
    
    entry.elements.each('media:group') do |group|
      # media:description
      group.elements.each('media:description') do |desc|
        media_info[:description] = desc.text
      end
      
      # media:thumbnail - get highest quality
      best_width = 0
      group.elements.each('media:thumbnail') do |thumb|
        width = thumb.attributes['width'].to_i
        if width > best_width
          best_width = width
          media_info[:thumbnail_url] = thumb.attributes['url']
          media_info[:thumbnail_width] = width
          media_info[:thumbnail_height] = thumb.attributes['height'].to_i
        end
      end
      
      # media:community for views/ratings
      group.elements.each('media:community') do |community|
        community.elements.each('media:statistics') do |stats|
          media_info[:views] = stats.attributes['views']&.to_i
        end
        community.elements.each('media:starRating') do |rating|
          media_info[:star_rating] = {
            count: rating.attributes['count']&.to_i,
            average: rating.attributes['average']&.to_f
          }
        end
      end
    end
    
    media_data[video_id] = media_info
  end
  
  media_data
end
```

### Video ID extrakce

```ruby
def extract_video_id(entry)
  # Try yt:videoId accessor
  if entry.respond_to?(:yt_videoId) && entry.yt_videoId
    return entry.yt_videoId
  end
  
  # Extract from entry ID (format: yt:video:VIDEO_ID)
  entry_id = entry_id(entry).to_s
  if entry_id =~ /video:([a-zA-Z0-9_-]+)/
    return $1
  end
  
  # Extract from URL
  url = entry_link(entry).to_s
  if url =~ /(?:watch\?v=|shorts\/|youtu\.be\/)([a-zA-Z0-9_-]+)/
    return $1
  end
  
  nil
end
```

### Post objekt

```ruby
Post.new(
  platform: 'youtube',
  id: video_id,
  url: entry_link(entry),          # https://www.youtube.com/watch?v=xxx
  title: entry_title(entry),       # Titulek videa
  text: yt_media[:description],    # Popis videa z media:description
  published_at: entry_time(entry),
  author: entry_author(feed, entry),
  media: build_media(video_id, yt_media),  # Thumbnail
  
  # YouTube videa nejsou sociální posty
  is_repost: false,
  is_quote: false,
  is_reply: false,
  
  # Extra YouTube data
  raw: {
    video_id: video_id,
    views: yt_media[:views],
    star_rating: yt_media[:star_rating],
    is_short: entry_link(entry)&.include?('/shorts/'),
    channel_id: @channel_id
  }
)
```

### Thumbnail jako média

```ruby
def build_media(video_id, yt_media)
  return [] unless video_id
  
  thumbnail_url = yt_media[:thumbnail_url] || 
                  "https://i.ytimg.com/vi/#{video_id}/hqdefault.jpg"
  
  # Build alt_text with dimensions if available
  alt_text = "Video thumbnail"
  if yt_media[:thumbnail_width] && yt_media[:thumbnail_height]
    alt_text = "Video thumbnail (#{yt_media[:thumbnail_width]}x#{yt_media[:thumbnail_height]})"
  end
  
  [
    Media.new(
      type: 'image',
      url: thumbnail_url,
      alt_text: alt_text
    )
  ]
end
```

---

## YouTubeFormatter

### Umístění
`lib/formatters/youtube_formatter.rb`

### Účel

Formátuje Post objekt z YouTubeAdapter do textu pro Mastodon. Deleguje na UniversalFormatter s YouTube-specifickými rozšířeními.

### Výchozí nastavení

```ruby
DEFAULT_CONFIG = {
  # Content composition
  show_title_as_content: false,
  combine_title_and_content: false,
  title_separator: ' — ',
  
  # URL handling
  move_url_to_end: true,
  prefix_post_url: "\n\n🎬 ",
  
  # Length limits
  max_length: 500,
  
  # YouTube-specific
  description_max_lines: 3,     # Omezení řádků popisu
  include_views: false,         # Zobrazit počet zhlédnutí
  
  # Mentions (YouTube nemá tradiční @mentions)
  mentions: {
    type: 'none',
    value: ''
  }
}
```

### Formát výstupu

**Základní post (pouze titulek):**
```
Titulek videa

🎬 https://www.youtube.com/watch?v=xxx
```

**Kombinovaný (titulek + popis):**
```
Titulek videa — První řádek popisu
Druhý řádek popisu
Třetí řádek popisu

🎬 https://www.youtube.com/watch?v=xxx
```

**S počtem zhlédnutí:**
```
Titulek videa — Popis...

👍 1 234 567 zhlédnutí

🎬 https://www.youtube.com/watch?v=xxx
```

### YouTube-specifické funkce

#### Omezení řádků popisu

```ruby
def apply_description_limit(post)
  max_lines = @config[:description_max_lines]
  return post unless max_lines && max_lines > 0
  return post unless post.respond_to?(:text) && post.text
  
  text = post.text.to_s
  lines = text.split(/\n/).map(&:strip).reject(&:empty?)
  
  return post if lines.length <= max_lines
  
  limited_text = lines.first(max_lines).join("\n")
  PostTextWrapper.new(post, limited_text)
end
```

#### Počet zhlédnutí

```ruby
def append_views(content, post)
  return content unless post.respond_to?(:raw) && post.raw
  
  views = post.raw[:views] || post.raw['views']
  return content unless views
  
  # Insert before URL if present
  if content.include?(@config[:prefix_post_url])
    parts = content.split(@config[:prefix_post_url], 2)
    "#{parts[0]}\n\n👍 #{format_number(views)} zhlédnutí#{@config[:prefix_post_url]}#{parts[1]}"
  else
    "#{content}\n\n👍 #{format_number(views)} zhlédnutí"
  end
end

# Czech-style number formatting (spaces as thousands separator)
def format_number(num)
  num.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1 ').reverse
end
```

---

## Konfigurace

### Platform defaults

Soubor: `config/platforms/youtube.yml`

```yaml
# ============================================================
# Zpravobot NG: Platform Configuration - YouTube
# ============================================================

# FILTERING
filtering:
  skip_replies: false       # N/A pro YouTube
  skip_retweets: false      # N/A pro YouTube
  skip_quotes: false        # N/A pro YouTube
  banned_phrases: []        # Seznam zakázaných frází
  required_keywords: []     # Požadovaná klíčová slova

# CONTENT
content:
  show_title_as_content: false
  combine_title_and_content: true   # Titulek + separator + popis
  title_separator: " — "
  max_input_chars: 1000             # Pre-truncation pro úsporu paměti
  no_shorts: false                  # Filtrovat Shorts (UULF playlist)
  description_max_lines: 3          # Max řádků popisu
  include_views: false              # Zobrazit počet zhlédnutí

# FORMATTING
formatting:
  platform_emoji: "📺"              # Emoji platformy
  move_url_to_end: true             # Přesunout URL na konec
  prefix_post_text: ""              # Prefix před textem (prázdný)
  prefix_post_url: "\n📺 "          # Prefix před URL videa

# THUMBNAIL
thumbnail:
  upload_as_media: true             # Upload thumbnail jako Mastodon média

# URL
url:
  replace_from: []
  replace_to: ""
  domain_fixes: []

# MENTIONS
mentions:
  type: none
  value: ""

# PROCESSING
processing:
  max_length: 250                   # Maximální délka finálního příspěvku
  trim_strategy: smart              # Strategie zkracování

# SCHEDULING (interval se řídí prioritou: high=5min, normal=20min, low=55min)
scheduling:
  priority: low                     # YouTube - videa vychází méně často
  max_posts_per_run: 3              # Méně postů najednou
```

### Příklad source YAML

```yaml
# config/sources/dvtv_youtube.yml
# ============================================================
# Bot: dvtv_youtube
# ============================================================
# Mastodon: @dvtv@zpravobot.news
# ============================================================

id: dvtv_youtube
enabled: true
platform: youtube

# Zdroj dat
source:
  channel_id: "UCFb-u3ISt99gxZ9TxIQW7UA"

# Cíl publikace
target:
  mastodon_account: dvtv
  visibility: public

# Plánování (interval se řídí prioritou: high=5min, normal=20min, low=55min)
scheduling:
  priority: low
  max_posts_per_run: 3

# Content - přepsat defaults
content:
  combine_title_and_content: true
  description_max_lines: 3
  include_views: false
  no_shorts: true                   # Filtrovat Shorts pro tento kanál
```

### Source s filtrováním

```yaml
# config/sources/zpravy_youtube.yml
id: zpravy_youtube
enabled: true
platform: youtube

source:
  channel_id: "UC..."

target:
  mastodon_account: zpravy

# Filtrování - jen zprávy obsahující určitá slova
filtering:
  required_keywords:
    - "zprávy"
    - "news"
  banned_phrases:
    - "reklama"
    - "sponzorováno"

content:
  no_shorts: true
```

---

## Filtrování Shorts

### Jak Shorts filtrování funguje

YouTube Shorts jsou krátká videa (< 60 sekund). Pro jejich vyfiltrování ZBNW-NG používá UULF playlist.

### UULF Playlist

YouTube automaticky vytváří playlist pro každý kanál:
- **UC** prefix = všechna videa (včetně Shorts a livestreamů)
- **UULF** prefix = pouze long-form videa (bez Shorts, bez livestreamů)

```ruby
# Standardní feed (všechna videa)
"https://www.youtube.com/feeds/videos.xml?channel_id=UCFb..."

# UULF playlist (bez Shorts)
"https://www.youtube.com/feeds/videos.xml?playlist_id=UULFFb..."
```

### Konfigurace

```yaml
# V source YAML
content:
  no_shorts: true   # Použít UULF playlist
```

### Shorts detekce v URL

I při použití UULF playlistu se Shorts mohou někdy objevit. Adapter detekuje Shorts v URL:

```ruby
raw: {
  is_short: entry_link(entry)&.include?('/shorts/')
}
```

Toto je informační hodnota - nefiltruje automaticky, ale může být použita pro logování nebo další zpracování.

---

## Thumbnail handling

### Automatický upload

Thumbnail se automaticky uploaduje jako Mastodon média při publikaci:

1. **Adapter** vytvoří Media objekt s URL thumbnailem
2. **Publisher** stáhne obrázek z YouTube CDN
3. **Publisher** uploaduje do Mastodon jako attachment
4. **Status** se publikuje s přiloženým obrázkem

### Thumbnail URL

```ruby
# Preferovaná: z media:group (nejvyšší kvalita)
thumbnail_url = yt_media[:thumbnail_url]

# Fallback: standardní YouTube CDN
thumbnail_url = "https://i.ytimg.com/vi/#{video_id}/hqdefault.jpg"
```

### Kvalita thumbnailů

YouTube poskytuje různé velikosti:
- `default.jpg` - 120x90
- `mqdefault.jpg` - 320x180
- `hqdefault.jpg` - 480x360 (výchozí fallback)
- `sddefault.jpg` - 640x480
- `maxresdefault.jpg` - 1280x720 (ne vždy dostupné)

ZBNW-NG vybírá nejvyšší dostupnou kvalitu z `media:thumbnail`.

### Konfigurace

```yaml
# V platform nebo source YAML
thumbnail:
  upload_as_media: true   # Povolit upload thumbnailů
```

---

## Cron a scheduling

### Runner (stahování videí)

YouTube běží společně s ostatními non-Twitter platformami:

```bash
# Každých 8 minut (bluesky, rss, youtube)
*/8 * * * * /app/data/zbnw-ng/cron_zbnw.sh --exclude-platform twitter
```

Nebo samostatně:

```bash
# Každých 30 minut jen YouTube
*/30 * * * * /app/data/zbnw-ng/cron_zbnw.sh --platform youtube
```

### Scheduling parametry

| Parametr | Výchozí | Popis |
|----------|---------|-------|
| `priority` | `low` | Určuje interval kontroly (viz tabulka níže) |
| `max_posts_per_run` | 3 | Méně videí najednou |
| `skip_hours` | `[5, 6, 7, 8]` | Hodiny kdy se YouTube zdroje přeskakují (maintenance window) |

### Priority-based intervals

| Priority | Interval | Použití |
|----------|----------|---------|
| `high` | 5 min | Breaking news kanály |
| `normal` | 20 min | Standardní kanály |
| `low` | 55 min | Archivní kanály (doporučeno pro YouTube) |

### YouTube maintenance window

YouTube RSS API má pravidelný ranní maintenance window (~05:00–09:00 CET), během kterého feedy vracejí HTTP 404/500. Po skončení okna vše funguje normálně.

Naměřený pattern (10.–12.2.2026):
| Den | Od | Do | Trvání |
|-----|----|----|--------|
| 10.2. | 05:40 | 08:40 | ~3h |
| 11.2. | 06:20 | 07:40 | ~1.5h |
| 12.2. | 05:50 | 07:31 | ~2h |

**Řešení (implementováno 2026-02-12):**

1. **Scheduling skip:** Parametr `skip_hours: [5, 6, 7, 8]` v `config/platforms/youtube.yml` — orchestrátor přeskočí YouTube zdroje v těchto hodinách
2. **Transientní HTTP errory:** YouTube HTTP 404/500/502/503 se logují jako WARN místo ERROR (třída `YouTubeTransientError`) — nesčítají se do error_count a neeskalují v health monitoru

```yaml
# config/platforms/youtube.yml
scheduling:
  skip_hours: [5, 6, 7, 8]  # YouTube API má ranní maintenance window
```

### Manuální spuštění

```bash
# Konkrétní zdroj
./bin/run_zbnw.rb --source dvtv_youtube --test

# Celá platforma
./bin/run_zbnw.rb --platform youtube

# S verbose logem
./bin/run_zbnw.rb --source dvtv_youtube --test --verbose
```

---

## Časté problémy

### 1. "YouTube channel_id or handle required"

**Příčina:** Chybí `channel_id` v source konfiguraci.

**Řešení:**
```yaml
source:
  channel_id: "UCxxxxxxxxxxxxxxxxxxxxxx"  # Přidat!
```

### 2. "Could not resolve YouTube channel"

**Příčina:** Handle resolution nefunguje - YouTube blokuje scraping.

**Řešení:** Použít přímo `channel_id` místo `handle`:
```yaml
# ❌ Nefunkční - handle resolution je zablokován
source:
  handle: "@DVTV"

# ✅ Správně - vždy použít channel_id
source:
  channel_id: "UCFb-u3ISt99gxZ9TxIQW7UA"
```

**Jak získat channel_id:**
1. Otevřít YouTube kanál
2. About → Share channel → Copy channel ID
3. Nebo: https://commentpicker.com/youtube-channel-id.php

### 3. Shorts se stále objevují

**Příčina:** `no_shorts` není nastaveno.

**Řešení:**
```yaml
content:
  no_shorts: true   # Aktivovat UULF playlist
```

**Poznámka:** UULF playlist není 100% spolehlivý - některé Shorts mohou proklouznout.

### 4. Thumbnail se nenahrává

**Příčiny:**
- YouTube CDN blokuje požadavek
- Timeout při stahování
- Mastodon odmítá formát

**Diagnostika:**
```bash
# Test stahování
curl -I "https://i.ytimg.com/vi/VIDEO_ID/hqdefault.jpg"
```

**Řešení:** Posty se publikují i bez média - jen bez obrázku.

### 5. Popis je prázdný

**Příčina:** Video nemá popis, nebo `media:description` chybí ve feedu.

**Řešení:** ZBNW-NG použije prázdný text a zobrazí pouze titulek.

### 6. Views se nezobrazují

**Příčina:** `include_views` není povoleno.

**Řešení:**
```yaml
content:
  include_views: true
```

### 7. "Failed to fetch feed: HTTP 403"

**Příčina:** YouTube rate limiting nebo geo-blocking.

**Řešení:**
- Snížit prioritu (např. `priority: low`)
- Zkontrolovat User-Agent
- Počkat a zkusit znovu

### 8. Duplicitní titulek a popis

**Příčina:** Někteří tvůrci kopírují titulek do popisu.

**Řešení:** ZBNW-NG automaticky detekuje duplicity a použije pouze jednu verzi:

```ruby
if title_content_duplicate?(title, content)
  # Vrátit delší verzi
  title.length >= content.length ? title : content
end
```

---

## API reference

### YouTube RSS Feed

```
Base URL: https://www.youtube.com/feeds/videos.xml
```

| Parametr | Popis |
|----------|-------|
| `channel_id=UC...` | Feed pro kanál |
| `playlist_id=UULF...` | Feed pro UULF playlist (bez Shorts) |
| `playlist_id=PL...` | Feed pro libovolný playlist |

### Příklady volání

```bash
# Feed kanálu (všechna videa)
curl "https://www.youtube.com/feeds/videos.xml?channel_id=UCFb-u3ISt99gxZ9TxIQW7UA"

# UULF playlist (bez Shorts)
curl "https://www.youtube.com/feeds/videos.xml?playlist_id=UULFFb-u3ISt99gxZ9TxIQW7UA"

# Konkrétní playlist
curl "https://www.youtube.com/feeds/videos.xml?playlist_id=PLxxxxxx"
```

### RSS Feed struktura

```xml
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns:yt="http://www.youtube.com/xml/schemas/2015"
      xmlns:media="http://search.yahoo.com/mrss/">
  <title>Channel Name</title>
  <author>
    <name>Channel Name</name>
    <uri>https://www.youtube.com/channel/UC...</uri>
  </author>
  
  <entry>
    <id>yt:video:VIDEO_ID</id>
    <yt:videoId>VIDEO_ID</yt:videoId>
    <yt:channelId>UC...</yt:channelId>
    <title>Video Title</title>
    <link rel="alternate" href="https://www.youtube.com/watch?v=VIDEO_ID"/>
    <published>2026-02-02T12:00:00+00:00</published>
    <updated>2026-02-02T12:00:00+00:00</updated>
    
    <media:group>
      <media:title>Video Title</media:title>
      <media:description>Full video description...</media:description>
      <media:thumbnail url="https://i.ytimg.com/vi/VIDEO_ID/hqdefault.jpg"
                       width="480" height="360"/>
      <media:community>
        <media:statistics views="123456"/>
        <media:starRating count="1000" average="4.85"/>
      </media:community>
    </media:group>
  </entry>
</feed>
```

### Thumbnail URLs

```
# Standard quality options
https://i.ytimg.com/vi/{VIDEO_ID}/default.jpg        (120x90)
https://i.ytimg.com/vi/{VIDEO_ID}/mqdefault.jpg      (320x180)
https://i.ytimg.com/vi/{VIDEO_ID}/hqdefault.jpg      (480x360)
https://i.ytimg.com/vi/{VIDEO_ID}/sddefault.jpg      (640x480)
https://i.ytimg.com/vi/{VIDEO_ID}/maxresdefault.jpg  (1280x720)
```

---

## Orchestrator integrace

V `lib/orchestrator.rb`, metoda `create_adapter`:

```ruby
when 'youtube'
  Adapters::YouTubeAdapter.new(
    channel_id: source.source_channel_id,
    handle: source.source_handle,
    source_name: source.source_name,
    no_shorts: source.data.dig('content', 'no_shorts') || false
  )
```

### SourceConfig accessory

```ruby
def source_channel_id
  @data.dig('source', 'channel_id')
end
```
