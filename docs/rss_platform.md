# RSS platforma v ZBNW-NG

> **Poslední aktualizace:** 2026-04-11
> **Stav:** Produkční

> **Recent changes:**
> - **2026-04-09 (SEC-2 + OGP):** OGP image fetcher obsahuje SSRF blocklist — privátní IP ranges (RFC1918, 127/8, 169.254/16) jsou odmítnuty před fetch i na redirectu
> - **2026-02-15 (BUG-12):** RSS adapter sleduje HTTP 301/302/307/308 redirecty (max 5 hopů) s detekcí smyček

---

## Obsah

1. [Přehled](#přehled)
2. [Architektura](#architektura)
3. [RssAdapter](#rssadapter)
4. [RssFormatter](#rssformatter)
5. [Konfigurace](#konfigurace)
6. [Content Modes](#content-modes)
7. [Cron a scheduling](#cron-a-scheduling)
8. [Časté problémy](#časté-problémy)

> **Facebook a Instagram přes RSS.app:** Viz [`rss.app_platform.md`](rss.app_platform.md)

---

## Přehled

RSS integrace v ZBNW-NG umožňuje:

- **Stahování postů** ze standardních RSS 2.0 a Atom feedů
- **Formátování** pro Mastodon (title/content kombinace)
- **HTML čištění** a entity decoding

Sociální sítě přes RSS.app (Facebook, Instagram, ...) viz [`rss.app_platform.md`](rss.app_platform.md).

### Klíčové vlastnosti

| Funkce | Stav | Poznámka |
|--------|------|----------|
| RSS 2.0 | ✅ | Standardní RSS feedy |
| Atom | ✅ | Atom feedy |
| Media/Enclosures | ✅ | `<enclosure>` + `<media:content>` (RSS.app) |
| HTML čištění | ✅ | Entity decoding, tag removal |
| Pre-truncation | ✅ | Pro dlouhé HTML feedy |
| Redirect following | ✅ | Automatické sledování 301/302/307/308 (max 5 hopů) |
| Relativní URL media | ✅ | Root-relative cesty doplněny na absolute |
| Sociální sítě (RSS.app) | → | Viz `rss.app_platform.md` |

---

## Architektura

```
┌─────────────────────┐     ┌──────────────────┐     ┌───────────────────┐
│  RSS Feed (HTTP)    │────▶│   RssAdapter     │────▶│   RssFormatter    │
│  (RSS 2.0 / Atom)   │     │  (fetch + parse) │     │  (format text)    │
└─────────────────────┘     └──────────────────┘     └───────────────────┘
                                                               │
                                                               ▼
┌─────────────────────┐     ┌──────────────────┐
│  Mastodon API       │◀────│ MastodonPublisher│
│                     │     │                  │
└─────────────────────┘     └──────────────────┘
```

### Soubory

| Soubor | Účel |
|--------|------|
| `lib/adapters/rss_adapter.rb` | Stahování a parsing feedů |
| `lib/formatters/rss_formatter.rb` | Formátování textu |
| `lib/utils/html_cleaner.rb` | HTML entity decoding |
| `config/platforms/rss.yml` | Výchozí nastavení platformy |

Pro RSS.app (FB/IG) viz [`rss.app_platform.md`](rss.app_platform.md).

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

### Mentions transformace

**AKTUÁLNÍ STAV: VYPNUTO**

Mentions transformace je **vypnutá** pro RSS — `@username` zůstává jako prostý text bez transformace.

**Důvod:** URL transformace (`@user` → `https://...`) způsobovala problémy s Mastodon link preview — generoval se náhled profilu místo článku.

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

> **Facebook preprocessing:** Pro RSS.app FB feedy viz [`rss.app_platform.md`](rss.app_platform.md) — sekce FacebookProcessor.

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

> **Facebook a Instagram zdroje přes RSS.app:** Viz [`rss.app_platform.md`](rss.app_platform.md) — obsahuje YAML příklady, konfiguraci, profile sync a RSS.app specifika.

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

### 4. @mentions v textu

**Chování:** `@username` zůstává jako prostý text bez transformace na URL.

**Důvod:** URL transformace byla záměrně vypnuta — způsobovala problémy s Mastodon link preview (náhled profilu místo článku).

**Poznámka:** Toto je očekávané chování, ne chyba.

### 5. Media se nenahrávají

**Příčina:** Feed neobsahuje enclosures nebo jsou v nepodporovaném formátu.

**Diagnostika:**
```bash
# Zkontrolovat raw feed
curl -s "https://example.com/rss.xml" | grep -i enclosure
```

**Poznámka:** RSS adapter extrahuje media z `<enclosure>` tagů i z `<media:content>` (RSS.app feedy). Pro RSS.app problémy viz [`rss.app_platform.md`](rss.app_platform.md).

### 6. HTTP 403/404 při stahování feedu

**Příčiny:**
- Feed URL je neplatná
- Server blokuje User-Agent
- Feed vyžaduje autentizaci

**Diagnostika:**
```bash
curl -H "User-Agent: Zpravobot/1.0" "https://example.com/rss.xml"
```

### 7. HTTP 301/308 redirect

**Chování:** Adapter automaticky sleduje redirecty (301, 302, 307, 308) až do 5 hopů. Redirect je logován jako WARNING, finální URL jako SUCCESS.

**Log příklad:**
```
WARN: [RssAdapter] Redirect 301: https://cestina20.cz/rss → https://cestina20.cz/feed
INFO: [RssAdapter] Followed to final URL: https://cestina20.cz/feed
```

**Poznámka:** Permanentní redirecty (301, 308) naznačují, že by se měl aktualizovat `feed_url` v konfiguraci zdroje na novou URL. Adapter si poradí automaticky, ale přímá URL je efektivnější.

### 8. Duplicitní posty

**Příčina:** Feed nemá stabilní GUID/ID.

**Řešení:** ZBNW-NG používá `entry_id` (GUID → link fallback) pro deduplikaci v DB.

### 9. Nové posty se nepublikují — zpoždění agregátoru

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

Interaktivní generátor `bin/create_source.rb` podporuje RSS platformu pro standardní feedy i RSS.app sociální sítě.

### Content modes v generátoru

```ruby
CONTENT_MODES = {
  'text'     => { show_title_as_content: false, combine_title_and_content: false },
  'title'    => { show_title_as_content: true,  combine_title_and_content: false },
  'combined' => { show_title_as_content: false, combine_title_and_content: true }
}.freeze
```

Pro RSS.app specifika (RSS source types, banned_phrases, profile sync) viz [`rss.app_platform.md`](rss.app_platform.md).
