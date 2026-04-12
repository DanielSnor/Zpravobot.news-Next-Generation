# RSS.app platformy v ZBNW-NG

> **Poslední aktualizace:** 2026-04-11
> **Stav:** Produkční

---

## Obsah

1. [Přehled](#přehled)
2. [Jak RSS.app funguje v ZBNW-NG](#jak-rssapp-funguje-v-zbnw-ng)
3. [Společné vzory všech RSS.app zdrojů](#společné-vzory-všech-rssapp-zdrojů)
4. [FacebookProcessor](#facebookprocessor)
5. [Facebook via RSS.app](#facebook-via-rssapp)
6. [Instagram via RSS.app](#instagram-via-rssapp)
7. [Profile sync](#profile-sync)
8. [create_source.rb podpora](#create_sourcerb-podpora)
9. [Rozšíření na další platformy](#rozšíření-na-další-platformy)
10. [Časté problémy](#časté-problémy)

---

## Přehled

[RSS.app](https://rss.app) je komerční služba, která generuje RSS 2.0 feedy z sociálních sítí, které nativní RSS neposkytují. ZBNW-NG tuto službu využívá jako datový most pro:

| Platforma | Stav | Profile sync |
|-----------|------|-------------|
| Facebook | ✅ | ✅ Browserless.io |
| Instagram | ✅ | ✅ Browserless.io |
| Threads | 🔜 možné | TBD |
| TikTok | 🔜 možné | TBD |
| Telegram | 🔜 možné | TBD |

**Klíčový princip:** Z pohledu ZBNW-NG jsou tyto zdroje technicky RSS feedy (`platform: rss`). Speciální chování (preprocessing, profile sync) se konfiguruje přes `rss_source_type` a `profile_sync.social_profile.*` pole.

---

## Jak RSS.app funguje v ZBNW-NG

```
RSS.app feed URL                  ZBNW-NG pipeline
─────────────────                ─────────────────────────────────────────
https://rss.app/feeds/xxx.xml
        │
        ▼
  RssAdapter.fetch_posts()        platform: rss → načte rss.yml defaults
        │
        ▼
  entry_to_post()                 title + description z RSS.app
  entry_media()                   media:content → obrázek příspěvku
        │
        ▼
  RssFormatter.format()
        │
        ├── rss_source_type: facebook → FacebookProcessor (em-dash dedup)
        └── rss_source_type: instagram → bez extra procesoru
        │
        ▼
  PostProcessor pipeline          dedup, filter, media upload, publish
        │
        ▼
  MastodonPublisher               výsledný Mastodon post
```

### Datový model RSS.app feedu

RSS.app feedy pro FB/IG mají specifickou strukturu:

```xml
<item>
  <title>Text příspěvku nebo caption</title>
  <description>Stejný text nebo zkrácený perex</description>
  <link>https://www.facebook.com/page/posts/123456</link>
  <guid>https://www.facebook.com/page/posts/123456</guid>
  <pubDate>Mon, 30 Mar 2026 10:00:00 +0000</pubDate>
  <media:content url="https://cdn.example.com/image.jpg" medium="image"/>
</item>
```

**Gotcha — `media:content`:** Standardní `<enclosure>` tagy RSS.app nepoužívá. Media se extrahuje z `<media:content>` přes interní `@media_content_map` v `RssAdapter`. Při debugování média je třeba zkontrolovat tento namespace, ne `enclosure`.

---

## Společné vzory všech RSS.app zdrojů

### `rss_source_type` pole

Nepovinné pole v source YAML, které aktivuje platformně specifické chování v `RssFormatter`:

```yaml
rss_source_type: facebook   # aktivuje FacebookProcessor
rss_source_type: instagram  # žádný extra procesor, ale future-proof
# (výchozí: 'rss' — standardní RSS chování)
```

> **Poznámka:** Pole `rss_source_type` ovlivňuje pouze formátování. Pro profile sync je rozhodující `profile_sync.social_profile.platform`.

### RSS.app content replacements

Všechny RSS.app feedy ze sociálních sítí produkují tzv. "noise posty" — systemové akce (změna profilového obrázku, přidání coveru, check-in). Doporučené content replacements pro odstranění šumu:

```yaml
processing:
  content_replacements:
    # "John Doe Posted" / "Page Name shared" / "Page updated status" → smazat
    - pattern: "^.+?\\s+(Posted|shared|updated status)$"
      replacement: ""
      flags: "i"
      literal: false
    # GDPR warning — RSS.app občas přidává "When you delete content..." → smazat
    - pattern: "(When[^>]+deleted.)"
      replacement: ""
      flags: "gim"
      literal: false
```

Tyto vzory generuje `create_source.rb` automaticky pro všechny RSS.app typy.

### Banned phrases

Systémové posty, které nemají informační hodnotu a měly by být filtrovány:

```yaml
# Facebook
filtering:
  banned_phrases:
    - "updated their cover photo"
    - "updated their profile picture"
    - "is with"
    - "was live"

# Instagram
filtering:
  banned_phrases:
    - "updated their profile picture"
```

`create_source.rb` přidává tyto fráze automaticky podle `rss_source_type`.

### Scheduling

RSS.app feedy se typicky mění méně často než zpravodajské RSS. Doporučená priorita:

```yaml
scheduling:
  priority: low          # interval ~55 min
  max_posts_per_run: 10  # RSS.app může dávkovat starší posty
```

---

## FacebookProcessor

### Umístění
`lib/processors/facebook_processor.rb`

### Účel

Zpracovává Facebook-specifický problém RSS.app feedů: **em-dash duplikáty**.

RSS.app pro Facebook Reels (a některé standardní posty) vrací totožný text v `<title>` i `<description>`. `RssFormatter` v combined mode pak vytvoří:

```
Čo ďalšie odznelo? bit.ly/xxx — Čo ďalšie odznelo? bit.ly/xxx
```

`FacebookProcessor` detekuje duplicitu a vrátí jen jednu verzi (delší).

### Logika

```ruby
class FacebookProcessor
  EM_DASH_SEPARATOR = ' — '
  SIMILARITY_THRESHOLD = 0.6

  def process(text)
    result = remove_emdash_duplicate(text)
    result.strip
  end

  def remove_emdash_duplicate(text)
    return text unless text.include?(EM_DASH_SEPARATOR)

    first_part, second_part = text.split(EM_DASH_SEPARATOR, 2).map(&:strip)
    return text if first_part.nil? || second_part.nil?

    if similar_content?(first_part, second_part)
      first_part.length >= second_part.length ? first_part : second_part
    else
      text
    end
  end
end
```

Detekce podobnosti funguje třemi způsoby:
1. **Přesná shoda** po normalizaci (lowercase, strip interpunkce)
2. **Prefix shoda** — jedna část je prefix (≥70 %) druhé
3. **Word overlap** — Jaccard podobnost slov ≥ 0.6 (min 3 slova)

### Aktivace

Procesor se aktivuje automaticky v `RssFormatter` když `rss_source_type == 'facebook'`:

```ruby
def format(post)
  post = apply_facebook_preprocessing(post) if @config[:rss_source_type] == 'facebook'
  @universal.format(post, runtime_config)
end
```

---

## Facebook via RSS.app

### Platform config

`config/platforms/facebook.yml` — výchozí nastavení pro všechny Facebook zdroje:

```yaml
mentions:
  type: "domain_suffix"
  value: "facebook.com"

formatting:
  platform_emoji: "📘"

scheduling:
  priority: normal
  interval_minutes: 60
  max_posts_per_run: 5

profile_sync:
  enabled: false       # opt-in per source
  sync_avatar: true
  sync_banner: true    # Cover photo
  sync_bio: true
  sync_fields: true
```

> **Poznámka:** Tento soubor používá primárně `sync_profiles.rb`. Hlavní pipeline `run_zbnw.rb` načítá pro FB zdroje `rss.yml` (protože `platform: rss`).

### Source YAML — příklad

```yaml
id: akmarketa_facebook
enabled: true
platform: rss

source:
  feed_url: https://rss.app/feeds/nQ3zSZ6rObPaPY7a.xml
  handle: "akmarketa"      # Facebook page handle — povinné pro profile sync

target:
  mastodon_account: akmarketa

scheduling:
  priority: low
  max_posts_per_run: 10

filtering:
  banned_phrases:
    - "updated their cover photo"
    - "updated their profile picture"
    - "is with"
    - "was live"

content:
  show_title_as_content: false
  combine_title_and_content: false

processing:
  content_replacements:
    - pattern: "^.+?\\s+(Posted|shared|updated status)$"
      replacement: ""
      flags: "i"
      literal: false
    - pattern: "(When[^>]+deleted.)"
      replacement: ""
      flags: "gim"
      literal: false

profile_sync:
  enabled: true
  retention_days: 14
```

> **Poznámka k `rss_source_type`:** U existujících FB zdrojů `rss_source_type: facebook` nemusí být explicitně nastaveno — `create_source.rb` ho přidává u nových zdrojů. Bez tohoto pole se `FacebookProcessor` neaktivuje (em-dash duplikáty zůstanou). Pro nové zdroje vždy nastavit.

### Jak RSS.app feed pro Facebook vypadá

- `<title>` — caption příspěvku nebo název stránky + "Posted"
- `<description>` — totéž nebo zkrácený text
- `<link>` — URL na konkrétní FB post
- `<media:content>` — obrázek nebo thumbnail videa
- Reels: title = description (em-dash duplikát problém)
- Živé přenosy: "was live" → filtrovat

---

## Instagram via RSS.app

### Platform config

`config/platforms/instagram.yml` — výchozí nastavení pro všechny Instagram zdroje:

```yaml
mentions:
  type: "domain_suffix"
  value: "instagram.com"

formatting:
  platform_emoji: "📸"

scheduling:
  priority: normal
  interval_minutes: 60
  max_posts_per_run: 5

profile_sync:
  enabled: false       # opt-in per source
  sync_avatar: true
  sync_banner: false   # Instagram nemá cover photo
  sync_bio: true
  sync_fields: true
```

### Source YAML — příklad

```yaml
id: kimi_antonelli_instagram
enabled: true
platform: rss

source:
  feed_url: https://rss.app/feeds/XNbC8dp1Ld0490rs.xml
  # Pozor: handle pro IG je v profile_sync.social_profile, ne source.handle

target:
  mastodon_account: kimi_antonelli

scheduling:
  priority: low
  max_posts_per_run: 10

filtering:
  banned_phrases:
    - "updated their profile picture"

content:
  show_title_as_content: false
  combine_title_and_content: false

processing:
  content_replacements:
    - pattern: "^.+?\\s+(Posted|shared|updated status)$"
      replacement: ""
      flags: "i"
      literal: false
    - pattern: "(When[^>]+deleted.)"
      replacement: ""
      flags: "gim"
      literal: false

profile_sync:
  enabled: true
  retention_days: 30
  social_profile:
    platform: instagram
    handle: kimi.antonelli    # IG handle — POZOR: tečky, ne podtržítka!
```

### IG specifické gotchas

**Mastodon handle vs. Instagram handle:**
Mastodon používá podtržítka (`kimi_antonelli`), Instagram tečky (`kimi.antonelli`). Toto jsou dvě různé věci — `social_profile.handle` musí být skutečný IG handle (ověřit na instagramu.com/@handle).

**Žádný banner:**
Instagram nemá cover photo. `sync_banner: false` v platform configu je proto výchozí.

**Bio z meta tagu:**
`InstagramProfileSyncer` čte bio z `<meta name="description">`, ne z JSON pole `biography` (bývá prázdné). Content je před názvem v atributu (`content="..." name="description"`), `&quot;` uvozovky jsou encodovány.

### Jak RSS.app feed pro Instagram vypadá

- `<title>` — caption příspěvku
- `<description>` — totéž (kratší nebo shodné)
- `<link>` — URL na konkrétní IG post
- `<media:content>` — obrázek nebo thumbnail Reelu
- Stories: nejsou v RSS.app feedu (stories jsou ephemeral)

---

## Profile sync

Profile sync pro FB/IG zdroje funguje přes `Browserless.io` — cloudový headless Chrome. Načítá JavaScript-heavy stránky a parsuje výsledné HTML.

### Architektura

```
bin/sync_profiles.rb
        │
        ├── platform: facebook → FacebookProfileSyncer
        │     fetchuje /about stránku, parsuje bio + obrázky + website
        │
        └── platform: instagram → InstagramProfileSyncer
              fetchuje profil, parsuje bio + avatar + website z meta tagů
        │
        ▼
  MastodonProfileUpdater
        updateuje description, avatar, header, custom fields
```

### Soubory

| Soubor | Účel |
|--------|------|
| `lib/syncers/facebook_profile_syncer.rb` | Browserless.io scraping FB stránek |
| `lib/syncers/instagram_profile_syncer.rb` | Browserless.io scraping IG profilů |
| `lib/syncers/mastodon_profile_updater.rb` | Aktualizace Mastodon profilu |
| `config/platforms/facebook.yml` | Výchozí config + credentials template |
| `config/platforms/instagram.yml` | Výchozí config + credentials template |

### Spuštění

```bash
# Všechny FB zdroje s enabled profile sync
./bin/sync_profiles.rb --platform facebook

# Všechny IG zdroje s enabled profile sync
./bin/sync_profiles.rb --platform instagram

# Konkrétní zdroj
./bin/sync_profiles.rb --source akmarketa_facebook --dry-run

# Náhled bez změn
./bin/sync_profiles.rb --platform facebook --dry-run
```

### Co se synchronizuje

| | Facebook | Instagram |
|-|----------|-----------|
| Bio / description | ✅ `/about` stránka | ✅ meta description tag |
| Avatar | ✅ profile photo | ✅ profile photo |
| Banner / header | ✅ cover photo | ❌ (Instagram nemá) |
| Website URL | ✅ z `/about` | ✅ z profilu (pokud nastaveno) |
| Display name | ❌ (obsahuje :bot: badge) | ❌ |
| Custom fields | ✅ fb:, web:, spravuje:, retence: | ✅ ig:, web:, spravuje:, retence: |

### Požadavky pro profile sync

**Přihlašovací cookies** (nastavit v `env.sh`):

```bash
# Facebook cookies
export FB_COOKIE_DATR="..."
export FB_COOKIE_C_USER="..."
export FB_COOKIE_XS="..."
export FB_COOKIE_SB="..."

# Instagram cookies
export IG_COOKIE_SESSIONID="..."
export IG_COOKIE_CSRFTOKEN="..."
export IG_COOKIE_DS_USER_ID="..."
export IG_COOKIE_MID="..."

# Browserless.io token (sdílený pro FB i IG)
export BROWSERLESS_TOKEN="..."
```

**Source YAML nastavení:**

Pro Facebook:
```yaml
source:
  handle: "page-handle"     # Facebook page handle (bez @)
profile_sync:
  enabled: true
```

Pro Instagram:
```yaml
profile_sync:
  enabled: true
  social_profile:
    platform: instagram
    handle: actual.ig.handle   # Skutečný IG handle (s tečkami pokud jsou)
```

### Facebook website extraction — gotcha

Facebook hlavní stránka (`facebook.com/pageID`) neobsahuje web profilu — jen zápatí (messenger.com, meta.com...). `FacebookProfileSyncer` proto fetchuje `/about` URL a filtruje footer domény přes `FOOTER_DOMAINS` konstantu.

### Cron

Profile sync se spouští jednou týdně (různé dny pro různé platformy):

```bash
# Úterý 3:30 — Facebook + Instagram
30 3 * * 2  cd /app/data/zbnw-ng && source env.sh && ruby bin/sync_profiles.rb --platform facebook 2>&1 >> logs/sync.log
35 3 * * 2  cd /app/data/zbnw-ng && source env.sh && ruby bin/sync_profiles.rb --platform instagram 2>&1 >> logs/sync.log
```

---

## create_source.rb podpora

Interaktivní průvodce `bin/create_source.rb` plně podporuje RSS.app zdroje:

### RSS source types v generátoru

```ruby
RSS_SOURCE_TYPES = {
  'rss'       => { label: 'RSS',       suffix: 'rss' },
  'facebook'  => { label: 'Facebook',  suffix: 'facebook' },
  'instagram' => { label: 'Instagram', suffix: 'instagram' },
  'other'     => { label: nil,         suffix: nil }
}.freeze
```

Průvodce se zeptá na typ a podle výběru:
- nastaví `rss_source_type`
- přidá odpovídající `banned_phrases`
- přidá `content_replacements`
- nabídne nastavení `profile_sync`

### Automaticky generovaný content_replacements blok

```ruby
RSSAPP_CONTENT_REPLACEMENTS = [
  { pattern: "^.+?\\s+(Posted|shared|updated status)$",
    replacement: "", flags: "i", literal: false },
  { pattern: "(When[^>]+deleted.)",
    replacement: "", flags: "gim", literal: false }
].freeze
```

---

## Rozšíření na další platformy

RSS.app podporuje i další sítě (Threads, TikTok, Telegram, LinkedIn, Pinterest...). Přidání nové platformy do ZBNW-NG vyžaduje:

1. **Source YAML:** `platform: rss`, nový `rss_source_type: threads` (nebo jiný)
2. **Platform config:** `config/platforms/threads.yml` (volitelné, pokud je potřeba odlišné chování)
3. **Banned phrases:** specifické pro danou síť (přidat do `create_source.rb` konstant)
4. **Procesor:** pokud platforma generuje specifický šum (analogicky k `FacebookProcessor`)
5. **Profile sync:** nový syncer v `lib/syncers/` (volitelné)

Samotná `RssAdapter` implementace nevyžaduje žádné změny — RSS.app feedy jsou standardní RSS 2.0.

---

## Časté problémy

### 1. Duplicitní text — "Text… — Text…"

**Příčina:** `rss_source_type: facebook` není nastaveno (chybí `FacebookProcessor`).

**Řešení:**
```yaml
rss_source_type: facebook
```

### 2. Noise posty ("updated their cover photo" apod.)

**Příčina:** Chybějící `banned_phrases`.

**Řešení:** Přidat odpovídající seznam (viz sekce [Společné vzory](#společné-vzory-všech-rssapp-zdrojů)).

### 3. Obrázky se nepublikují

**Příčina:** RSS.app používá `media:content`, ne `enclosure`. `RssAdapter` to podporuje přes `@media_content_map`, ale pouze pokud XML parsing proběhne správně.

**Diagnostika:**
```bash
curl -s "https://rss.app/feeds/xxx.xml" | grep "media:content"
```

### 4. Profile sync selže — "website always messenger.com"

**Příčina:** Syncer fetchuje hlavní FB stránku místo `/about`. Opraveno — viz `fetch_platform_profile` v `FacebookProfileSyncer`.

**Diagnostika:**
```bash
ruby bin/sync_profiles.rb --source akmarketa_facebook --dry-run
```

### 5. Profile sync selže — "instagram cookie expired"

**Příčina:** IG cookies mají životnost ~90 dní. Při vypršení je třeba obnovit.

**Řešení:** Přihlásit se do Instagramu v prohlížeči, zkopírovat cookies do `env.sh`.

### 6. IG handle nenalezen

**Příčina:** `social_profile.handle` v source YAML obsahuje podtržítko místo tečky (nebo naopak).

**Diagnostika:**
```bash
curl "https://www.instagram.com/@skutecny.handle/" -L | head -20
```

### 7. RSS.app zpoždění — nové posty se přeskočí

**Příčina:** RSS.app má zpoždění mezi publikací na sociální síti a zobrazením ve feedu. Článek se objeví s původním `pubDate`, který je starší než `last_success` timestamp orchestrátoru.

**Řešení (implementováno):** Pro RSS platformu se `since` filtr záměrně nepoužívá — stahují se vždy všechny položky feedu. Deduplication zajišťuje `published_posts` tabulka přes GUID.

```ruby
# lib/orchestrator.rb
since = source.platform == 'rss' ? nil : extract_since_time(state)
```
