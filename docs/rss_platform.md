# RSS platforma v ZBNW-NG

> **Poslední aktualizace:** 2026-03-03
> **Stav:** Produkční

---

## Obsah

1. [Přehled](#přehled)
2. [Architektura](#architektura)
3. [RssAdapter](#rssadapter)
4. [RssFormatter](#rssformatter)
5. [FacebookProcessor](#facebookprocessor)
6. [Konfigurace](#konfigurace)
7. [RSS source types](#rss-source-types)
8. [Content Modes](#content-modes)
9. [Cron a scheduling](#cron-a-scheduling)
10. [Časté problémy](#časté-problémy)

---

## Přehled

RSS integrace v ZBNW-NG umožňuje:

- **Stahování postů** ze standardních RSS 2.0 a Atom feedů
- **Formátování** pro Mastodon (title/content kombinace)
- **Zpracování sociálních sítí** - Facebook a Instagram přes RSS.app
- **HTML čištění** a entity decoding

### Klíčové vlastnosti

| Funkce | Stav | Poznámka |
|--------|------|----------|
| RSS 2.0 | ✅ | Standardní RSS feedy |
| Atom | ✅ | Atom feedy |
| Facebook (via RSS.app) | ✅ | S em-dash duplikát odstraněním |
| Instagram (via RSS.app) | ✅ | S mention transformací |
| Media/Enclosures | ✅ | Obrázky, video, audio |
| HTML čištění | ✅ | Entity decoding, tag removal |
| Pre-truncation | ✅ | Pro dlouhé HTML feedy |
| Redirect following | ✅ | Automatické sledování 301/302/307/308 (max 5 hopů) |
| Profile sync | ✅ | Pro Facebook sources via `FacebookProfileSyncer` (Browserless.io) |

---

## Architektura

```
┌─────────────────────┐     ┌──────────────────┐     ┌───────────────────┐
│  RSS Feed (HTTP)    │────▶│   RssAdapter     │────▶│   RssFormatter    │
│  (RSS 2.0 / Atom)   │     │  (fetch + parse) │     │  (format text)    │
└─────────────────────┘     └──────────────────┘     └───────────────────┘
                                    │                         │
                                    │                         ▼
                                    │                ┌───────────────────┐
                                    │                │ FacebookProcessor │
                                    │                │ (optional FB fix) │
                                    │                └───────────────────┘
                                    ▼                         │
┌─────────────────────┐     ┌──────────────────┐              │
│  Mastodon API       │◀────│ MastodonPublisher│◀─────────────┘
│                     │     │                  │
└─────────────────────┘     └──────────────────┘
```

### Soubory

| Soubor | Účel |
|--------|------|
| `lib/adapters/rss_adapter.rb` | Stahování a parsing feedů |
| `lib/formatters/rss_formatter.rb` | Formátování textu |
| `lib/processors/facebook_processor.rb` | Facebook-specific čištění |
| `lib/utils/html_cleaner.rb` | HTML entity decoding |
| `lib/syncers/facebook_profile_syncer.rb` | Profile sync pro Facebook (Browserless.io) |
| `config/platforms/rss.yml` | Výchozí nastavení platformy |

---

## RssAdapter

### Umístění
`lib/adapters/rss_adapter.rb`

### Účel

Stahuje a parsuje RSS/Atom feedy. Podporuje oba formáty díky Ruby `RSS` knihovně.

### Inicializace

```ruby
Adapters::RssAdapter.new(
  feed_url: 'https://example.com/rss.xml',
  source_name: 'Example Feed',           # Volitelné
  max_input_chars: 2000                   # Volitelné - pre-truncation
)
```

### Parametry

| Parametr | Typ | Default | Popis |
|----------|-----|---------|-------|
| `feed_url` | String | **povinné** | URL RSS/Atom feedu |
| `source_name` | String | `nil` | Název zdroje pro author |
| `max_input_chars` | Integer | `nil` | Pre-truncation pro dlouhý HTML |

### Feed detekce

```ruby
def get_feed_entries(feed)
  if feed.respond_to?(:entries)
    # Atom feed
    Array(feed.entries)
  elsif feed.respond_to?(:channel) && feed.channel.respond_to?(:items)
    # RSS 2.0 feed
    Array(feed.channel.items)
  elsif feed.respond_to?(:items)
    # Some RSS formats
    Array(feed.items)
  else
    log "Unknown feed format: #{feed.class}", level: :warn
    []
  end
end
```

### HTTP Fetch (s redirect following)

`fetch_url` automaticky sleduje HTTP redirecty (301, 302, 307, 308) až do `MAX_REDIRECTS` (5) hopů.
Každý redirect je logován jako WARNING, úspěšný fetch po redirectu jako SUCCESS.

```ruby
MAX_REDIRECTS = 5
REDIRECT_CODES = %w[301 302 307 308].freeze

def fetch_url(url)
  current_url = url
  visited = []

  MAX_REDIRECTS.times do
    raise "Redirect loop detected" if visited.include?(current_url)
    visited << current_url

    response = HttpClient.get(current_url, headers: { 'Accept' => '...' })

    if REDIRECT_CODES.include?(response.code)
      location = response['location']
      location = URI.join(current_url, location).to_s unless location.start_with?('http')
      log "Redirect #{response.code}: #{current_url} → #{location}", level: :warn
      current_url = location
      next
    end

    raise "HTTP #{response.code}" unless response.code.to_i == 200
    log "Followed to final URL: #{current_url}", level: :success if visited.size > 1
    return yield StringIO.new(response.body.force_encoding('UTF-8'))
  end

  raise "Too many redirects (#{MAX_REDIRECTS})"
end
```

**Logování:**
- `WARN: [RssAdapter] Redirect 301: https://old.cz/rss → https://new.cz/feed`
- `INFO: [RssAdapter] Followed to final URL: https://new.cz/feed`
- `ERROR: [RssAdapter] Too many redirects (5) for https://loop.cz/rss`
- `ERROR: [RssAdapter] Redirect loop detected for https://a.cz/rss`

### Entry parsing

RSS entry se konvertuje na univerzální `Post` objekt:

```ruby
def entry_to_post(feed, entry)
  Post.new(
    platform: 'rss',
    id: entry_id(entry),              # GUID nebo link
    url: entry_link(entry),           # Odkaz na článek
    title: entry_title(entry),        # Titulek
    text: entry_text(entry),          # Očištěný obsah
    published_at: entry_time(entry),  # Čas publikace
    author: entry_author(feed, entry),
    media: entry_media(entry),        # Enclosures
    
    # RSS nemá social features
    is_repost: false,
    is_quote: false,
    is_reply: false,
    
    # Raw data pro debugging
    raw: {
      entry_class: entry.class.name,
      categories: entry_categories(entry),
      feed_title: feed_title(feed)
    }
  )
end
```

### Entry extraktory

#### entry_id

```ruby
def entry_id(entry)
  if entry.respond_to?(:id) && entry.id
    entry.id.content || entry.id
  elsif entry.respond_to?(:guid) && entry.guid
    entry.guid.content || entry.guid
  else
    entry_link(entry)  # Fallback na URL
  end
end
```

#### entry_link

```ruby
def entry_link(entry)
  if entry.respond_to?(:link) && entry.link
    entry.link.respond_to?(:href) ? entry.link.href : entry.link
  else
    nil
  end
end
```

#### entry_title

```ruby
def entry_title(entry)
  return nil unless entry.respond_to?(:title)
  
  title = entry.title
  title.respond_to?(:content) ? title.content : title.to_s
end
```

#### entry_text (s pre-truncation)

```ruby
def entry_text(entry)
  # Pokus o různá pole v pořadí preference
  content = if entry.respond_to?(:content) && entry.content
              entry.content.respond_to?(:content) ? entry.content.content : entry.content
            elsif entry.respond_to?(:summary) && entry.summary
              entry.summary.respond_to?(:content) ? entry.summary.content : entry.summary
            elsif entry.respond_to?(:description)
              entry.description
            else
              ""
            end

  raw_content = content.to_s
  
  # Pre-truncation: pokud je obsah příliš dlouhý, zkrátit PŘED HTML čištěním
  if @max_input_chars && @max_input_chars > 0 && raw_content.length > @max_input_chars
    raw_content = pre_truncate_html(raw_content, @max_input_chars)
  end

  clean_html(raw_content)
end
```

#### entry_time

```ruby
def entry_time(entry)
  time = if entry.respond_to?(:published) && entry.published
           entry.published
         elsif entry.respond_to?(:updated) && entry.updated
           entry.updated
         elsif entry.respond_to?(:pubDate) && entry.pubDate
           entry.pubDate
         else
           Time.now
         end

  time.is_a?(Time) ? time : Time.parse(time.to_s)
rescue ArgumentError
  Time.now
end
```

#### entry_author

```ruby
def entry_author(feed, entry)
  author_name = if entry.respond_to?(:author) && entry.author
                  entry.author
                elsif entry.respond_to?(:dc_creator)
                  entry.dc_creator
                else
                  @source_name || feed_title(feed)
                end

  # Extrahovat jméno pokud je to objekt
  author_name = author_name.name if author_name.respond_to?(:name)
  author_name = author_name.content if author_name.respond_to?(:content)

  Author.new(
    username: @source_name || feed_title(feed),
    full_name: author_name.to_s,
    url: feed_link(feed)
  )
end
```

#### entry_media (enclosures)

```ruby
def entry_media(entry)
  return [] unless entry.respond_to?(:enclosure) && entry.enclosure

  enclosure = entry.enclosure
  
  [Media.new(
    type: guess_media_type(enclosure.type),
    url: enclosure.url,
    size: enclosure.length
  )]
end

def guess_media_type(mime_type)
  return 'unknown' unless mime_type
  
  mime_type = mime_type.to_s.downcase
  
  case mime_type
  when /^image\//   then 'image'
  when /^video\//   then 'video'
  when /^audio\//   then 'audio'
  else 'unknown'
  end
end
```

### Pre-truncation pro dlouhý HTML

Některé feedy obsahují velmi dlouhý HTML s navigací/sidebar před samotným obsahem. Pre-truncation zkracuje HTML PŘED čištěním:

```ruby
def pre_truncate_html(html, max_chars)
  return html if html.length <= max_chars
  
  truncated = html[0...max_chars]
  
  # Zkusit najít poslední UZAVÍRACÍ tag pro čisté říznutí
  last_closing_tag = truncated.rindex(%r{</[a-zA-Z][a-zA-Z0-9]*>})
  
  if last_closing_tag
    tag_end = truncated.index('>', last_closing_tag)
    if tag_end
      return truncated[0..tag_end]
    end
  end
  
  # Fallback: řezat před otevíracím tagem
  last_open_tag = truncated.rindex('<')
  if last_open_tag && last_open_tag > 0
    last_close = truncated.rindex('>')
    if last_close.nil? || last_close < last_open_tag
      return truncated[0...last_open_tag]
    end
  end
  
  truncated
end
```

---

## RssFormatter

### Umístění
`lib/formatters/rss_formatter.rb`

### Účel

Formátuje Post objekt z RssAdapter do textu pro Mastodon. Deleguje na UniversalFormatter s RSS-specifickými rozšířeními.

### Výchozí nastavení

```ruby
DEFAULT_CONFIG = {
  # Content composition (IFTTT-compatible)
  show_title_as_content: false,
  combine_title_and_content: false,
  title_separator: ' — ',
  
  # URL handling
  move_url_to_end: true,
  prefix_post_url: "\n\n",
  
  # Length limits
  max_length: 500,
  
  # Optional source name
  source_name: nil,
  
  # RSS source type (pro rozlišení Facebook/Instagram/RSS)
  rss_source_type: 'rss',
  
  # Mentions config - VYPNUTO pro všechny typy
  mentions: {
    type: 'none',
    value: ''
  }
}.freeze
```

> **Poznámka:** Mentions transformace je vypnuta. `@username` zůstává jako prostý text.

### Mentions transformace podle source type

**AKTUÁLNÍ STAV: VYPNUTO**

Mentions transformace je **vypnutá** pro všechny platformy včetně Facebook a Instagram zdrojů.

```ruby
# Aktuální produkční nastavení:
MENTIONS_BY_SOURCE_TYPE = {
  'facebook'  => { type: 'none', value: '' },
  'instagram' => { type: 'none', value: '' },
  'rss'       => { type: 'none', value: '' },
  'other'     => { type: 'none', value: '' }
}.freeze
```

**Důvod:** Mentions URL transformace (`@user` → `https://...`) způsobovala problémy s Mastodon náhledy - generoval se náhled na profil místo na článek.

**Výsledek:** `@username` zůstává jako prostý text bez transformace.

> **Poznámka:** Kód v `rss_formatter.rb` může stále obsahovat starou konfiguraci s URL prefixes, ale `mentions: { type: 'none' }` v platform YAML přepisuje toto nastavení.

### Formát výstupu

**Standardní RSS (text mode):**
```
Obsah článku nebo perex...

https://example.com/clanek
```

**Title mode:**
```
Titulek článku

https://example.com/clanek
```

**Combined mode:**
```
Titulek článku — Obsah článku nebo perex...

https://example.com/clanek
```

### Facebook preprocessing

Pro Facebook zdroje se automaticky volá FacebookProcessor:

```ruby
def format(post)
  raise ArgumentError, "Post cannot be nil" if post.nil?
  
  # Pre-processing: Facebook-specific processing
  if @config[:rss_source_type] == 'facebook'
    post = apply_facebook_preprocessing(post)
  end
  
  # Delegate to UniversalFormatter
  @universal.format(post, runtime_config)
end
```

---

## FacebookProcessor

### Umístění
`lib/processors/facebook_processor.rb`

### Účel

Zpracovává Facebook-specifické problémy z RSS.app feedů:
- **Em-dash duplikáty** - Reels často mají "Text… — Text…" (title i description jsou stejné)

### Příklad problému

RSS.app pro Facebook Reels vrací:
```
Title: "Čo ďalšie odznelo? bit.ly/xxx"
Description: "Čo ďalšie odznelo? bit.ly/xxx"
```

Bez zpracování by výstup byl:
```
Čo ďalšie odznelo? bit.ly/xxx — Čo ďalšie odznelo? bit.ly/xxx
```

### Řešení

```ruby
class FacebookProcessor
  EM_DASH_SEPARATOR = ' — '
  SIMILARITY_THRESHOLD = 0.6

  def process(text)
    return '' if text.nil? || text.empty?

    result = text.dup

    # Remove em-dash duplicates
    result = remove_emdash_duplicate(result)

    result.strip
  end

  def remove_emdash_duplicate(text)
    return text unless text.include?(EM_DASH_SEPARATOR)

    parts = text.split(EM_DASH_SEPARATOR, 2)
    return text if parts.length < 2

    first_part = parts[0].strip
    second_part = parts[1].strip

    # Skip if either part is empty
    return text if first_part.empty? || second_part.empty?

    # Check for duplicate/similar content
    if similar_content?(first_part, second_part)
      # Return the longer (more complete) version
      first_part.length >= second_part.length ? first_part : second_part
    else
      text
    end
  end

  def similar_content?(text1, text2)
    # Exact match
    return true if normalize(text1) == normalize(text2)
    
    # One is prefix of the other
    shorter, longer = [text1, text2].sort_by(&:length).map { |t| normalize(t) }
    return true if longer.start_with?(shorter[0...(shorter.length * 0.7).to_i])
    
    # Word overlap similarity
    words1 = normalize(text1).split(/\s+/).reject { |w| w.length < 3 }
    words2 = normalize(text2).split(/\s+/).reject { |w| w.length < 3 }
    
    return false if words1.length < 3 || words2.length < 3
    
    intersection = (words1 & words2).size
    union = (words1 | words2).size
    
    return false if union.zero?
    
    (intersection.to_f / union) >= SIMILARITY_THRESHOLD
  end

  def normalize(text)
    text.downcase.gsub(/[…]|\.{3,}/, '').gsub(/[^\w\s]/, '').strip
  end
end
```

---

## Konfigurace

### Platform defaults

Soubor: `config/platforms/rss.yml`

```yaml
# ============================================================
# Zpravobot NG: Platform Configuration - RSS
# ============================================================

# ------------------------------------------------------------
# FILTERING - Filtrování obsahu
# ------------------------------------------------------------
filtering:
  skip_replies: false       # N/A pro RSS
  skip_retweets: false      # N/A pro RSS
  skip_quotes: false        # N/A pro RSS
  banned_phrases: []
  required_keywords: []

# ------------------------------------------------------------
# CONTENT - Zpracování obsahu
# ------------------------------------------------------------
content:
  show_title_as_content: false
  combine_title_and_content: false
  title_separator: " — "
  max_input_chars: 2000     # Pre-truncation pro dlouhé HTML feedy

# ------------------------------------------------------------
# FORMATTING - Formátování výstupu
# ------------------------------------------------------------
formatting:
  platform_emoji: "📰"
  move_url_to_end: true
  prefix_post_text: ""      # Prázdný - RSS nemá header
  prefix_post_url: "\n"

# ------------------------------------------------------------
# URL - Úprava odkazů
# ------------------------------------------------------------
url:
  replace_from: []
  replace_to: ""
  domain_fixes: []

# ------------------------------------------------------------
# MENTIONS - Zpracování zmínek
# ------------------------------------------------------------
# VYPNUTO pro všechny RSS typy (facebook, instagram, rss, other)
# Důvod: Mentions URL transformace způsobovala problémy s Mastodon náhledy
# @username zůstává jako prostý text
mentions:
  type: none
  value: ""

# ------------------------------------------------------------
# PROCESSING - Zpracování textu
# ------------------------------------------------------------
processing:
  max_length: 200           # Kratší default pro RSS
  trim_strategy: smart

# ------------------------------------------------------------
# SCHEDULING - Plánování stahování
# ------------------------------------------------------------
scheduling:
  priority: normal
  max_posts_per_run: 5
```

### Standardní RSS zdroj (YAML)

```yaml
id: denikn_rss
enabled: true
platform: rss

source:
  feed_url: "https://denikn.cz/rss/"

target:
  mastodon_account: denikn

formatting:
  source_name: "Deník N"

# Obsah
content:
  show_title_as_content: false
  combine_title_and_content: false

profile_sync:
  enabled: false  # RSS nemá profily
```

### Facebook zdroj via RSS.app (YAML)

```yaml
id: tvnoviny_facebook
enabled: true
platform: rss
rss_source_type: facebook    # DŮLEŽITÉ!

source:
  feed_url: "https://rss.app/feeds/xxxxx.xml"
  handle: "tvnovinyslovakia"  # Facebook page handle pro profile sync

target:
  mastodon_account: tvnovinyslovakia

formatting:
  source_name: "TV Noviny"

# Filtrování - banned_phrases automaticky přidány pro FB zdroje
filtering:
  banned_phrases:
    - "updated their cover photo"
    - "updated their profile picture"
    - "is with"
    - "was live"

# RSS.app content replacements
processing:
  content_replacements:
    - { pattern: "^.+?\\s+(Posted|shared|updated status)$", replacement: "", flags: "i", literal: false }
    - { pattern: "(When[^>]+deleted.)", replacement: "", flags: "gim", literal: false }

# Profile sync přes Browserless.io (vyžaduje BROWSERLESS_TOKEN a Facebook cookies)
profile_sync:
  enabled: true
  language: cs
  retention_days: 90
```

> **Poznámka:** Profile sync pro Facebook vyžaduje:
> - `source.handle` - Facebook page handle
> - `BROWSERLESS_TOKEN` v env.sh
> - Facebook cookies v `config/platforms/facebook.yml`
> - Viz `lib/syncers/facebook_profile_syncer.rb` pro detaily

### Instagram zdroj via RSS.app (YAML)

```yaml
id: brand_instagram
enabled: true
platform: rss
rss_source_type: instagram   # DŮLEŽITÉ!

source:
  feed_url: "https://rss.app/feeds/yyyyy.xml"

target:
  mastodon_account: brand

formatting:
  source_name: "Brand"

# Filtrování - banned_phrases automaticky přidány pro IG zdroje
filtering:
  banned_phrases:
    - "updated their profile picture"

processing:
  content_replacements:
    - { pattern: "^.+?\\s+(Posted|shared|updated status)$", replacement: "", flags: "i", literal: false }
    - { pattern: "(When[^>]+deleted.)", replacement: "", flags: "gim", literal: false }

profile_sync:
  enabled: false
```

---

## RSS source types

### Přehled typů

| Typ | Popis | Profile sync | Banned phrases | Extra processing |
|-----|-------|-------------|----------------|------------------|
| `rss` | Standardní RSS feed | ❌ | ❌ | Žádný |
| `facebook` | Facebook via RSS.app | ✅ (Browserless) | ✅ (4 fráze) | FacebookProcessor |
| `instagram` | Instagram via RSS.app | ❌ | ✅ (1 fráze) | Content replacements |
| `other` | Vlastní typ | ❌ | ❌ | Žádný |

> **Poznámka:** Mentions transformace byla vypnuta pro všechny typy kvůli problémům s Mastodon náhledy.

### Nastavení v source YAML

```yaml
rss_source_type: facebook  # Povinné pro FB/IG feedy!
```

### RSS.app content replacements

Pro Facebook a Instagram feedy se doporučují tyto content replacements pro odstranění RSS.app šumu:

```yaml
processing:
  content_replacements:
    # Odstranění "Posted" / "shared" / "updated status" řádků
    - { pattern: "^.+?\\s+(Posted|shared|updated status)$", replacement: "", flags: "i", literal: false }
    # Odstranění GDPR warningů
    - { pattern: "(When[^>]+deleted.)", replacement: "", flags: "gim", literal: false }
```

---

## Content Modes

RSS formatter podporuje tři módy kompozice obsahu (kompatibilní s IFTTT):

### 1. Text mode (default)

```yaml
content:
  show_title_as_content: false
  combine_title_and_content: false
```

**Výstup:** Pouze perex/content, titulek jako fallback

### 2. Title mode

```yaml
content:
  show_title_as_content: true
  combine_title_and_content: false
```

**Výstup:** Pouze titulek, ignoruje perex

### 3. Combined mode

```yaml
content:
  show_title_as_content: false
  combine_title_and_content: true
```

**Výstup:** Titulek + separator + perex

### Priorita v kódu

```ruby
# V UniversalFormatter
def select_content(post, config)
  if config[:combine_title_and_content] && post.title && post.text
    # Combined mode
    "#{post.title}#{config[:title_separator]}#{post.text}"
  elsif config[:show_title_as_content] && post.title
    # Title mode
    post.title
  else
    # Text mode (default)
    post.text.presence || post.title || ''
  end
end
```

---

## Cron a scheduling

### Runner (stahování postů)

```bash
# Každých 8 minut (RSS + ostatní platformy kromě Twitter)
*/8 * * * * /app/data/zbnw-ng/cron_zbnw.sh --exclude-platform twitter
```

### Priority intervals

| Priorita | Interval | Použití |
|----------|----------|---------|
| `high` | 5 min | Hot news, breaking news |
| `normal` | 20 min | Standardní zdroje |
| `low` | 55 min | Low-priority content |

### Manuální spuštění

```bash
# Konkrétní zdroj
./bin/run_zbnw.rb --source denikn_rss --test

# Celá platforma
./bin/run_zbnw.rb --platform rss

# S verbose logováním
./bin/run_zbnw.rb --source denikn_rss --verbose
```

---

## Časté problémy

### 1. "RSS feed_url required"

**Příčina:** Chybí `feed_url` v source konfiguraci.

**Řešení:**
```yaml
source:
  feed_url: "https://example.com/rss.xml"  # Přidat!
```

### 2. Obsah je zkrácený/nečitelný

**Příčina:** Feed obsahuje velmi dlouhý HTML s navigací před obsahem.

**Řešení:**
```yaml
content:
  max_input_chars: 3000  # Zvýšit limit pre-truncation
```

### 3. HTML entity nejsou dekódovány

**Příčina:** HtmlCleaner nezpracovává některé entity.

**Diagnostika:**
```ruby
# Test HTML cleaneru
require_relative 'lib/utils/html_cleaner'
HtmlCleaner.clean("&aacute; &nbsp; &mdash;")
# => "á   —"
```

**Řešení:** HtmlCleaner podporuje 100+ entit včetně českých znaků s háčky a čárkami.

### 4. Facebook Reels mají duplicitní text

**Příčina:** `rss_source_type: facebook` není nastaveno.

**Řešení:**
```yaml
rss_source_type: facebook  # Aktivuje FacebookProcessor
```

### 5. @mentions v textu

**Chování:** `@username` zůstává jako prostý text bez transformace na URL.

**Důvod:** Mentions URL transformace byla záměrně vypnuta pro všechny platformy, protože způsobovala problémy s Mastodon náhledy (generoval se náhled na profil místo na článek).

**Poznámka:** Toto je očekávané chování, ne chyba.

### 6. Media se nenahrávají

**Příčina:** Feed neobsahuje enclosures nebo jsou v nepodporovaném formátu.

**Diagnostika:**
```bash
# Zkontrolovat raw feed
curl -s "https://example.com/rss.xml" | grep -i enclosure
```

**Poznámka:** RSS adapter extrahuje media pouze z `<enclosure>` tagů.

### 7. HTTP 403/404 při stahování feedu

**Příčiny:**
- Feed URL je neplatná
- Server blokuje User-Agent
- Feed vyžaduje autentizaci

**Diagnostika:**
```bash
curl -H "User-Agent: Zpravobot/1.0" "https://example.com/rss.xml"
```

### 8. HTTP 301/308 redirect

**Chování:** Adapter automaticky sleduje redirecty (301, 302, 307, 308) až do 5 hopů. Redirect je logován jako WARNING, finální URL jako SUCCESS.

**Log příklad:**
```
WARN: [RssAdapter] Redirect 301: https://cestina20.cz/rss → https://cestina20.cz/feed
INFO: [RssAdapter] Followed to final URL: https://cestina20.cz/feed
```

**Poznámka:** Permanentní redirecty (301, 308) naznačují, že by se měl aktualizovat `feed_url` v konfiguraci zdroje na novou URL. Adapter si poradí automaticky, ale přímá URL je efektivnější.

### 9. Duplicitní posty

**Příčina:** Feed nemá stabilní GUID/ID.

**Řešení:** ZBNW-NG používá `entry_id` (GUID → link fallback) pro deduplikaci v DB.

### 10. Nové posty se nepublikují — RSS.app zpoždění

**Příznak:** Runner hlásí `Fetched 0 posts` přestože feed obsahuje nové články.

**Příčina:** RSS.app (a podobné aggregátory) mají zpoždění mezi publikací článku a jeho
zobrazením ve feedu. Článek se objeví v RSS feedu s původním `pubDate`, ale tato doba je
již "v minulosti" vůči `last_success` timestampu (který se posouvá dopředu při každém
checku, i s 0 posty).

**Příklad race condition:**
```
13:41  Runner check → since = 13:21 → feed vrátí 0 nových → last_success = 13:41
13:50  Článek publikován na webu (pubDate = 13:50)
14:01  Runner check → since = 13:41 → pubDate 13:50 > 13:41 ✓ → článek NALEZEN... jenže
       RSS.app ještě článek ve feedu nemá (zpoždění) → Fetched 0 posts → last_success = 14:01
14:21  RSS.app konečně vrátí článek s pubDate = 13:50
       Runner check → since = 14:01 → pubDate 13:50 < 14:01 ✗ → článek PŘESKOČEN navždy
```

**Řešení (implementováno):** Pro RSS platformu se `since` filtr v orchestrátoru záměrně
nepoužívá — vždy se stahují všechny položky feedu. Deduplication je zajištěna GUID-based
kontrolou v `published_posts` tabulce (PostProcessor), která bezpečně přeskočí
již publikované posty.

```ruby
# lib/orchestrator.rb
# RSS feeds jsou záměrně fetched bez date filteringu.
since = source.platform == 'rss' ? nil : extract_since_time(state)
```

**Proč to funguje:** RSS feedy typicky obsahují 20–50 položek. GUID kontrola v DB je levná.
Přidání date filtru by bylo micro-optimalizace, která ale způsobuje ztrátu postů.

---

## HtmlCleaner

### Umístění
`lib/utils/html_cleaner.rb`

### Účel

Čistí HTML obsah a dekóduje entity. Podporuje:

- **Základní entity:** `&amp;`, `&lt;`, `&gt;`, `&quot;`, `&nbsp;`
- **České znaky:** `&aacute;` → `á`, `&ccaron;` → `č`, atd.
- **Numerické entity:** `&#225;` → `á`, `&#x00E1;` → `á`
- **Typografické entity:** `&mdash;`, `&hellip;`, `&rsquo;`, atd.

### České entity

```ruby
CZECH_ENTITIES = {
  # Samohlásky s čárkou
  'aacute' => 'á', 'eacute' => 'é', 'iacute' => 'í', 
  'oacute' => 'ó', 'uacute' => 'ú', 'yacute' => 'ý',
  
  # Souhlásky s háčkem
  'ccaron' => 'č', 'dcaron' => 'ď', 'ecaron' => 'ě',
  'ncaron' => 'ň', 'rcaron' => 'ř', 'scaron' => 'š',
  'tcaron' => 'ť', 'zcaron' => 'ž',
  
  # Kroužek
  'uring' => 'ů'
}
```

---

## Orchestrator integrace

### Vytvoření adapteru

V `lib/orchestrator.rb`:

```ruby
def create_adapter(source)
  case source.platform
  when 'rss'
    Adapters::RssAdapter.new(feed_url: source.source_feed_url)
  # ...
  end
end
```

### Vytvoření formatteru

```ruby
def create_formatter(source_config)
  case platform
  when :rss
    rss_config = config.merge(
      show_title_as_content: content['show_title_as_content'] || false,
      combine_title_and_content: content['combine_title_and_content'] || false,
      title_separator: content['title_separator'] || ' — ',
      rss_source_type: source_config['rss_source_type'] || 'rss'
    )
    Formatters::RssFormatter.new(rss_config)
  # ...
  end
end
```

---

## create_source.rb podpora

Interaktivní generátor `bin/create_source.rb` podporuje RSS platformu:

### RSS source types v generátoru

```ruby
RSS_SOURCE_TYPES = {
  'rss' => { label: 'RSS', suffix: 'rss' },
  'facebook' => { label: 'Facebook', suffix: 'facebook' },
  'instagram' => { label: 'Instagram', suffix: 'instagram' },
  'other' => { label: nil, suffix: nil }
}.freeze
```

### Content modes v generátoru

```ruby
CONTENT_MODES = {
  'text' => { show_title_as_content: false, combine_title_and_content: false },
  'title' => { show_title_as_content: true, combine_title_and_content: false },
  'combined' => { show_title_as_content: false, combine_title_and_content: true }
}.freeze
```

### RSS.app content replacements

```ruby
RSSAPP_CONTENT_REPLACEMENTS = [
  { pattern: "^.+?\\s+(Posted|shared|updated status)$", replacement: "", flags: "i", literal: false },
  { pattern: "(When[^>]+deleted.)", replacement: "", flags: "gim", literal: false }
].freeze
```

### Banned phrases (automaticky přidané)

`create_source.rb` automaticky přidává banned_phrases pro FB/IG zdroje do YAML:

```ruby
RSSAPP_BANNED_PHRASES = {
  'facebook' => [
    "updated their cover photo",
    "updated their profile picture",
    "is with",
    "was live"
  ],
  'instagram' => [
    "updated their profile picture"
  ]
}.freeze
```

Tyto fráze filtrují noise posty, které nemají informační hodnotu.

### Profile sync pro Facebook

`create_source.rb` nabízí profile sync pro `rss_source_type: facebook` pokud je zadán `handle`.
Sync používá `FacebookProfileSyncer` s Browserless.io API.

**Požadavky:**
- `BROWSERLESS_TOKEN` v env.sh
- Facebook cookies v `config/platforms/facebook.yml`
- `source.handle` v source YAML

**Spuštění:**
```bash
./bin/sync_profiles.rb --source tvnoviny_facebook --dry-run
```

**Cron (každé 3 dny):**
```bash
0 3 */3 * * cd /app/data/zbnw-ng && source env.sh && bundle exec ruby bin/sync_profiles.rb --platform facebook
```

> **Poznámka:** `--platform facebook` interně filtruje RSS sources s `rss_source_type: facebook`.
> V `sync_profiles.rb` se efektivní platforma detekuje jako `facebook` když `source.platform == 'rss' && source.rss_source_type == 'facebook'`.
