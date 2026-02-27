# Twitter Platform - ZBNW-NG

> **Verze exportu:** 2026-02-04  
> **Status:** Produkční  
> **Poslední aktualizace:** 2026-02-13

---

## Přehled

Twitter/X integrace v ZBNW-NG používá **hybridní architekturu** kombinující:
- **IFTTT webhooky** - spolehlivé real-time triggery z oficiálního Twitter API
- **Nitter scraping** - kompletní data (full text, všechny obrázky, thread context)
- **Twitter Syndication API** - média + text bez vlastní infrastruktury (Tier 1.5, 3.5)

### Proč hybridní přístup?

| Přístup | Výhody | Nevýhody |
|---------|--------|----------|
| Čistý IFTTT | Spolehlivé triggery, oficiální API | Zkrácený text (>257 znaků), max 1 obrázek, žádný thread context |
| Čistý Nitter | Kompletní data | Rate limiting, nestabilní, žádné push notifikace |
| Syndication API | Média, JSON response, rychlé | Zkrácený text pro Twitter Blue (>280 znaků), neoficiální |
| **Hybrid** | Spolehlivé triggery + kompletní data + fallbacky | Složitější implementace |

---

## Architektura

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
     nitter_processing:   nitter_processing:
          false               true (default)
              │               │
              ▼               ▼
          Tier 1.5      determine_tier()
        (Syndication)         │
              │         ┌─────┴─────┐
              ▼         ▼           ▼
             OK      Tier 1      Tier 2
                    (IFTTT)    (Nitter)
                       │           │
                       ▼           ▼
                      OK      3 pokusy
                                  │
                              ┌───┴───┐
                            OK      Fail
                                      │
                                      ▼
                                  Tier 3.5
                                (Syndication)
                                      │
                                  ┌───┴───┐
                                OK      Fail
                                          │
                                          ▼
                                       Tier 3
                                      (IFTTT)
                                          │
                                          ▼
                                  TwitterFormatter
                               (→ UniversalFormatter)
                                          │
                                          ▼
                                 MastodonPublisher
```

### Soubory

| Soubor | Umístění | Popis |
|--------|----------|-------|
| `twitter_nitter_adapter.rb` | `lib/adapters/` | Tier 1/1.5/3 logika, IFTTT payload parsing + fallback_post |
| `twitter_tweet_processor.rb` | `lib/processors/` | Unifikovaná Twitter pipeline — Nitter fetch, Syndication fallback, threading, PostProcessor |
| `syndication_media_fetcher.rb` | `lib/services/` | Twitter Syndication API klient (Tier 3.5) |
| `twitter_adapter.rb` | `lib/adapters/` | Orchestrace Nitter fetch (210 řádků) |
| `twitter_rss_parser.rb` | `lib/adapters/` | RSS parsing modul (314 řádků) |
| `twitter_html_parser.rb` | `lib/adapters/` | HTML parsing modul (307 řádků) |
| `twitter_tweet_classifier.rb` | `lib/adapters/` | Tweet type detection (102 řádků) |
| `twitter_formatter.rb` | `lib/formatters/` | Wrapper delegující na UniversalFormatter |
| `universal_formatter.rb` | `lib/formatters/` | Hlavní formatting logika |
| `twitter_profile_syncer.rb` | `lib/syncers/` | Avatar/banner/bio sync přes Nitter |
| `twitter_thread_processor.rb` | `lib/processors/` | Thread chain extraction z Nitter HTML (IFTTT pipeline) |
| `edit_detector.rb` | `lib/processors/` | Edit detection (similarity matching) |
| `ifttt_queue_processor.rb` | `lib/webhook/` | Priority-based batch processing |
| `ifttt_webhook.rb` | `bin/` | Webhook HTTP server (dual-environment) |
| `twitter.yml` | `config/platforms/` | Platform defaults |
| `cron_ifttt.sh` | `/` | Cron wrapper pro queue processing |

---

## IFTTT Webhook Server

> **Aktualizace 2026-01-31:** Podpora dual-environment (prod/test) pomocí query parametru

**Soubor:** `bin/ifttt_webhook.rb`

Lightweight Ruby HTTP server (stdlib only, ~10-15MB RAM) s podporou pro **oddělené produkční a testovací prostředí**.

### Spuštění

```bash
# Basic (webhook only, queue processed by cron)
ruby bin/ifttt_webhook.rb

# S integrovaným queue processing
ruby bin/ifttt_webhook.rb --process-queue

# S auto-shutdown po neaktivitě
ruby bin/ifttt_webhook.rb --idle-shutdown 3600

# Nápověda
ruby bin/ifttt_webhook.rb --help
```

### Endpointy

| Endpoint | Metoda | Účel |
|----------|--------|------|
| `/api/ifttt/twitter` | POST | Přijetí IFTTT webhook (produkce) |
| `/api/ifttt/twitter?env=test` | POST | Přijetí IFTTT webhook (test) |
| `/health` | GET | Health check |
| `/stats` | GET | Queue statistiky (obě prostředí) |

### Dual-Environment Podpora

Jeden webhook server obsluhuje **obě prostředí** - produkci i test:

| URL | Cílová queue |
|-----|--------------|
| `POST /api/ifttt/twitter` | `/app/data/zbnw-ng/queue/ifttt/pending/` |
| `POST /api/ifttt/twitter?env=test` | `/app/data/zbnw-ng-test/queue/ifttt/pending/` |

**Konfigurace queue adresářů:**

```ruby
QUEUE_DIRS = {
  'prod' => ENV['IFTTT_QUEUE_DIR'] || '/app/data/zbnw-ng/queue/ifttt',
  'test' => ENV['IFTTT_QUEUE_DIR_TEST'] || '/app/data/zbnw-ng-test/queue/ifttt'
}
```

### IFTTT Applet Nastavení

**Produkční applet:**
```
Webhook URL: http://your-server:8089/api/ifttt/twitter
```

**Testovací applet:**
```
Webhook URL: http://your-server:8089/api/ifttt/twitter?env=test
```

### IFTTT Payload struktura

V IFTTT appletu nastavit **Action: Webhooks → Make a web request** s tímto Body:

```json
{
  "text": "<<<{{Text}}>>>",
  "embed_code": "<<<{{TweetEmbedCode}}>>>",
  "link_to_tweet": "{{LinkToTweet}}",
  "first_link_url": "{{FirstLinkUrl}}",
  "username": "{{UserName}}",
  "bot_id": "ct24_twitter"
}
```

#### Popis polí

| Pole | Typ | Popis |
|------|-----|-------|
| `text` | IFTTT ingredient | Text tweetu. `<<<>>>` escapuje speciální znaky |
| `embed_code` | IFTTT ingredient | HTML embed kód (pro detekci médií). `<<<>>>` escapuje |
| `link_to_tweet` | IFTTT ingredient | URL tweetu (pro extrakci tweet ID) |
| `first_link_url` | IFTTT ingredient | První odkaz v tweetu (pro detekci obrázků/videí) |
| `username` | IFTTT ingredient | Twitter username autora (IFTTT vyplní automaticky) |
| `bot_id` | **statický string** | ID YAML konfigurace - musí odpovídat `id:` v source YAML! |

#### bot_id - párování s YAML konfigurací

**DŮLEŽITÉ:** `bot_id` je klíčové pro správné směrování webhooků na YAML konfiguraci.

Systém hledá konfiguraci v tomto pořadí:
1. `username` jako source ID (např. hledá `chmuchmi.yml` s `id: chmuchmi`)
2. Explicit `bot_id` pokud je jiné než username
3. Handle fallback - prohledá twitter sources podle `source.handle`
4. Aggregator fallback - vytvoří dynamickou konfiguraci

**Kdy je bot_id povinné:**
- Když máte **více appletů pro stejný Twitter účet** s různými konfiguracemi
- Když `id:` v YAML **neodpovídá** Twitter username

#### Příklad: Dva applety pro stejný účet

Máte Twitter účet `@chmuchmi` a chcete:
- Obecný bot - všechny tweety
- Výstražný bot - pouze tweety s klíčovými slovy o výstrahách

**YAML konfigurace:**

```yaml
# config/sources/chmuchmi_twitter.yml
id: chmuchmi_twitter
platform: twitter
source:
  handle: chmuchmi
target:
  mastodon_account: chmuchmi
```

```yaml
# config/sources/vystrahy_chmuchmi_twitter.yml
id: vystrahy_chmuchmi_twitter
platform: twitter
source:
  handle: chmuchmi
target:
  mastodon_account: vystrahy
filtering:
  required_keywords:
    type: or
    content:
      - výstra
      - varov
      - nebezpeč
```

**IFTTT Applet 1 - Obecný:**
```json
{
  "text": "<<<{{Text}}>>>",
  "embed_code": "<<<{{TweetEmbedCode}}>>>",
  "link_to_tweet": "{{LinkToTweet}}",
  "first_link_url": "{{FirstLinkUrl}}",
  "username": "{{UserName}}",
  "bot_id": "chmuchmi_twitter"
}
```

**IFTTT Applet 2 - Výstrahy:**
```json
{
  "text": "<<<{{Text}}>>>",
  "embed_code": "<<<{{TweetEmbedCode}}>>>",
  "link_to_tweet": "{{LinkToTweet}}",
  "first_link_url": "{{FirstLinkUrl}}",
  "username": "{{UserName}}",
  "bot_id": "vystrahy_chmuchmi_twitter"
}
```

Oba applety mají stejný trigger (`from:chmuchmi`), ale díky různému `bot_id` směřují na různé YAML konfigurace s odlišným filtrováním a cílovými účty.

### /stats Response

```json
{
  "server": {
    "requests": 42,
    "uptime": 3600,
    "requests_by_env": {
      "prod": 40,
      "test": 2
    }
  },
  "environments": {
    "prod": {
      "queue_dir": "/app/data/zbnw-ng/queue/ifttt",
      "pending": 0,
      "processed": 150,
      "failed": 2
    },
    "test": {
      "queue_dir": "/app/data/zbnw-ng-test/queue/ifttt",
      "pending": 1,
      "processed": 10,
      "failed": 0
    }
  }
}
```

### /health Response

```json
{
  "status": "healthy",
  "service": "ifttt-webhook-light",
  "uptime": 3600,
  "requests": 42,
  "environments": ["prod", "test"]
}
```

### Logging

Server loguje s emoji pro snadné rozlišení prostředí:

```
[20:40:17] ℹ️ Queued [🚀 PROD]: @ct24zive/1234567890
[20:40:18] ℹ️ Queued [🧪 TEST]: @test_account/9876543210
```

### Environment Variables

| Proměnná | Default | Popis |
|----------|---------|-------|
| `IFTTT_PORT` | `8089` | Port serveru |
| `IFTTT_BIND` | `0.0.0.0` | Bind address |
| `IFTTT_AUTH_TOKEN` | - | Bearer token pro autentizaci |
| `IFTTT_QUEUE_DIR` | `/app/data/zbnw-ng/queue/ifttt` | Produkční queue |
| `IFTTT_QUEUE_DIR_TEST` | `/app/data/zbnw-ng-test/queue/ifttt` | Testovací queue |

### Watchdog Cron

```bash
# cron_webhook.sh - každou minutu kontroluje že server běží
* * * * * /app/data/zbnw-ng/cron_webhook.sh
```

Skript automaticky restartuje server pokud není dostupný.

---

## Pětistupňový systém (Tier 1/1.5/2/3.5/3)

### Přehled Tierů

| Tier | Zdroj dat | Média | Plný text | HTTP req | Kdy se použije |
|------|-----------|-------|-----------|----------|----------------|
| **1** | IFTTT | ❌ | ✅ (krátký) | 0 | `nitter_processing: true` + krátký tweet bez médií |
| **1.5** | Syndication | ✅ | ⚠️ možná zkrácený | 1 | `nitter_processing: false` |
| **2** | Nitter | ✅ | ✅ | 1-3 | `nitter_processing: true` + média/dlouhý/RT/thread |
| **3.5** | Syndication | ✅ | ⚠️ možná zkrácený | 1 | Fallback když Nitter selže |
| **3** | IFTTT | ❌ | ⚠️ zkrácený | 0 | Finální fallback (Nitter i Syndication selhaly) |

### Tier 1: Přímé IFTTT zpracování

- **Kdy:** `nitter_processing: true` (default) + text není zkrácený, žádná média, žádné vlákno
- **Data:** Pouze z IFTTT payloadu
- **Výhody:** Nejrychlejší, žádné další HTTP requesty
- **Nevýhody:** Žádné obrázky
- **HTTP requesty:** 0

### Tier 1.5: IFTTT + Syndication API

> **Nové v 2026-02-02**

- **Kdy:** `nitter_processing: false` v source YAML
- **Data:** IFTTT trigger + média z Twitter Syndication API
- **Výhody:** 
  - Média (až 4 fotky, video thumbnail)
  - Rychlejší než Nitter (JSON, ne HTML parsing)
  - Žádná vlastní infrastruktura
- **Nevýhody:** Text může být zkrácený pro Twitter Blue tweety (>280 znaků)
- **HTTP requesty:** 1 (Syndication API)
- **Retry:** 3 pokusy s exponential backoff (1s, 2s, 4s)
- **Fallback:** Tier 1 (IFTTT bez médií)

**Detekce zkráceného textu (Syndication):**
```ruby
# Syndication zkracuje Twitter Blue tweety na ~280 znaků
if final_text.length >= 270
  ends_with_tco = final_text.match?(/https:\/\/t\.co\/\S+\s*$/)
  has_terminator = has_natural_terminator?(final_text)

  if ends_with_tco || !has_terminator
    truncated = true
    final_text = final_text.rstrip + '…' unless has_terminator
  end
end
```

**Kdy použít `nitter_processing: false`:**
- High-volume zdroje (šetří Nitter kapacitu)
- Zdroje kde obrázek je důležitější než kompletní text
- Sportovní výsledky, grafy, infografiky
- Účty které nepoužívají Twitter Blue

### Tier 2: IFTTT trigger + Nitter fetch

- **Kdy:** `nitter_processing: true` + zkrácený text, obrázky, video, vlákno, retweet
- **Data:** IFTTT trigger + plná data z Nitter HTML
- **Výhody:** Kompletní data včetně plného textu
- **HTTP requesty:** 1-3 (Nitter)
- **Retry:** 3 pokusy s exponential backoff (1s, 2s, 4s)
- **Fallback:** Tier 3.5 (Syndication)

### Tier 3.5: Syndication Fallback

> **Nové v 2026-02-02**

- **Kdy:** Nitter selhal po všech 3 pokusech
- **Data:** Média z Twitter Syndication API
- **Výhody:** Stále získáme média i když Nitter nefunguje
- **HTTP requesty:** 1 (Syndication API)
- **Retry:** 3 pokusy s exponential backoff
- **Fallback:** Tier 3 (IFTTT)

### Tier 3: Finální Fallback (degraded)

- **Kdy:** Nitter i Syndication selhaly
- **Data:** IFTTT data s indikátorem `📖➡️`
- **Chování:** 
  - Přidá ellipsis `…` pokud text >= 257 znaků bez natural terminator
  - Přidá `force_read_more: true` → zobrazí `📖➡️` odkaz na originál
- **HTTP requesty:** 0

### Rozhodovací logika v `process_webhook()`

```ruby
def process_webhook(payload, bot_config, force_tier2: false)
  ifttt_data = parse_ifttt_payload(payload)
  
  # Check nitter_processing config
  nitter_enabled = bot_config.dig('nitter_processing', 'enabled') != false

  # Determine tier
  tier = if !nitter_enabled
           1.5   # Syndication
         elsif force_tier2
           2     # Forced for batch thread detection
         else
           determine_tier(ifttt_data)  # Returns 1 or 2
         end

  case tier
  when 1   then process_tier1(ifttt_data, bot_config)
  when 1.5 then process_tier1_5(ifttt_data, bot_config)
  when 2   then process_tier2(ifttt_data, bot_config)
  end
end
```

### `determine_tier()` logika (pro nitter_processing: true)

```ruby
def determine_tier(ifttt_data)
  text = ifttt_data[:text]
  first_link = ifttt_data[:first_link_url]
  embed_code = ifttt_data[:embed_code]
  username = ifttt_data[:username]
  
  # Retweet → vždy Tier 2 (IFTTT zkracuje RT)
  return 2 if text&.match?(/^RT\s+@\w+:/i)
  
  # Self-reply (thread) → Tier 2
  return 2 if is_self_reply?(text, username)
  
  # Photo v first_link_url → Tier 2
  return 2 if first_link&.match?(%r{/photo/\d*$})
  
  # Photo v embed_code → Tier 2 (FIX 2026-01-30)
  return 2 if has_image_in_embed?(embed_code)
  
  # Video → Tier 2
  return 2 if first_link&.match?(%r{/video/\d*$})
  
  # Quote tweet → Tier 2
  return 2 if first_link&.match?(%r{/status/\d+$})
  
  # Zkrácený text → Tier 2
  return 2 if likely_truncated?(text)
  
  # Ostatní → Tier 1
  1
end
```

---

## Edit Detection

### Problém

Twitter/X umožňuje editaci tweetů do 1 hodiny od publikace. Při editaci:
- Vzniká **nové status ID** pro editovanou verzi
- IFTTT zachytí obě verze jako **samostatné triggery**
- Bez detekce by se publikovaly oba tweety → duplicity

### Řešení

ZBNW-NG používá **EditDetector** v `IftttQueueProcessor`:

Tweet v1 (ID: 123) ──► IFTTT ──► Queue ──► Publish ──► Buffer
                                              │
Tweet v2 (ID: 456) ──► IFTTT ──► Queue ──┬────┘
                                         │
                                    Detekce: 85% podobnost
                                         │
                                         ▼
                              ┌──────────┴──────────┐
                              │                     │
                          Má média?             Bez médií
                              │                     │
                              ▼                     ▼
                      DELETE + PUBLISH        UPDATE text
                       (nový post)          (Mastodon edit)

### Proč Delete + Republish pro média?

**Mastodon Update API (`PUT /api/v1/statuses/:id`) neumožňuje změnu médií!**

Média jsou immutable - při update lze změnit pouze text, sensitivity a spoiler. Proto:

| Situace | Akce | Důsledek |
|---------|------|----------|
| Edit BEZ médií | `update_status()` | Mastodon edit (historie verzí) |
| Edit S médii | `delete_status()` + `publish()` | Nový post (ztráta boostů/replies) |

### Integrace

**Soubor:** `lib/webhook/ifttt_queue_processor.rb`
```ruby
# V process_webhook metodě
edit_result = @edit_detector.check_for_edit(source_id, post_id, username, text)

case edit_result[:action]
when :skip_older_version
  return :skipped
  
when :update_existing
  post = adapter.process_webhook(payload, bot_config)
  has_media = post.media && !post.media.empty?
  
  if has_media
    # Mastodon neumožňuje změnu médií při update → delete + republish
    publisher.delete_status(edit_result[:mastodon_id])
    media_ids = upload_media(post.media)
    new_status = publisher.publish(text, media_ids: media_ids)
  else
    # Simple update (text only)
    publisher.update_status(edit_result[:mastodon_id], formatted_text)
  end
  
when :publish_new
  # Normální publikace
end

# Po publikaci
@edit_detector.add_to_buffer(source_id, post_id, username, text, mastodon_id: result['id'])
```

### MastodonPublisher metody
```ruby
# UPDATE - pouze text (média nelze změnit!)
# PUT /api/v1/statuses/:id
publisher.update_status(mastodon_id, new_text)

# DELETE - pro delete + republish workflow
# DELETE /api/v1/statuses/:id
publisher.delete_status(mastodon_id)

# UPLOAD - asynchronní v2 API, automaticky čeká na zpracování
# POST /api/v2/media → poll GET /api/v1/media/:id (backoff 1-5s, max 10x)
publisher.upload_media(data, filename:, content_type:, description:)

# PUBLISH - nový post s médii
# POST /api/v1/statuses
# Thread fallback: parent not found → retry jako standalone
publisher.publish(text, media_ids: [...])
```

### Konfigurace

| Parametr | Hodnota | Popis |
|----------|---------|-------|
| `SIMILARITY_THRESHOLD` | 0.80 | 80% podobnost pro detekci |
| `EDIT_WINDOW` | 3600s | 1 hodina (Twitter edit window) |
| `BUFFER_RETENTION` | 7200s | 2 hodiny retence |

### Monitoring
```bash
# Edit detection
grep -i "similar post\|detected edit\|updated:" logs/ifttt_processor.log

# Delete + republish (nově)
grep -i "delete.*republish\|Deleted original\|Republished as" logs/ifttt_processor.log
```

Očekávané logy:

[EditDetector] Similar post found: 456 ~ 123 (85.2%)
Edit detected: 456 is newer version of 123 (85.2% match)
Edit has media (1 items) → delete + republish
Deleted original status 116005282681894504
Republished as 116005321912136918

---

## Nitter Processing & Syndication Mode

### Přehled

Konfigurace `nitter_processing` určuje jak se zpracovávají tweety:

| `nitter_processing` | Výsledek |
|---------------------|----------|
| `enabled: true` (default) | Tier 1/2 s Nitter, fallback Tier 3.5/3 |
| `enabled: false` | Tier 1.5 (Syndication), fallback Tier 1 |

### Konfigurace

```yaml
# S Nitter (default) - plná funkcionalita
# config/sources/ct24_twitter.yml
id: ct24_twitter
enabled: true
platform: twitter
source:
  handle: "CT24zive"
target:
  mastodon_account: ct24
# nitter_processing.enabled = true (default)
```

```yaml
# Bez Nitter (Syndication only) - média bez plného textu
# config/sources/sport_bot.yml
id: sport_bot
enabled: true
platform: twitter
source:
  handle: "SportResults"
target:
  mastodon_account: sport
nitter_processing:
  enabled: false    # → Tier 1.5 (Syndication)
thread_handling:
  enabled: false    # Doporučeno vypnout
```

### Porovnání režimů

| Funkce | S Nitter (default) | Bez Nitter (Syndication) |
|--------|-------------------|--------------------------|
| Text | Plný (>257 znaků) | Možná zkrácený (>280 znaků) |
| Obrázky | Až 4 | Až 4 ✅ |
| Video thumbnail | ✅ | ✅ |
| Threading | ✅ Funguje | ❌ Nefunguje |
| Quoted tweets | ✅ Plné URL | ⚠️ Pouze text |
| HTTP requesty | 1-3 na tweet | 1 na tweet |
| Fallback | Tier 3.5 → Tier 3 | Tier 1 |

### Kdy použít který režim

**Použij `nitter_processing: true` (default) pro:**
- ✅ Zpravodajské zdroje (důležitý plný text)
- ✅ Twitter Blue účty (dlouhé tweety)
- ✅ Zdroje kde jsou důležité thready
- ✅ Nízko-volume zdroje

**Použij `nitter_processing: false` pro:**
- ✅ High-volume zdroje (šetří Nitter)
- ✅ Zdroje kde obrázek > text
- ✅ Sportovní výsledky, grafy, infografiky
- ✅ Účty které nepoužívají Twitter Blue
- ⚠️ **Ne pro** zpravodajství s dlouhými texty

### Úspora

Přibližně **2200 Nitter requestů denně** při aplikaci na sportovní boty.

---

## Syndication API

### Přehled

Twitter Syndication API je neoficiální endpoint používaný pro embed widgety. ZBNW-NG ho využívá jako:
- **Tier 1.5** - primární zdroj pro `nitter_processing: false`
- **Tier 3.5** - fallback když Nitter selže

### Endpoint

```
https://cdn.syndication.twimg.com/tweet-result?id={tweet_id}&token={token}
```

### Implementace

**Soubor:** `lib/services/syndication_media_fetcher.rb`

```ruby
module Services
  module SyndicationMediaFetcher
    SYNDICATION_URL = 'https://cdn.syndication.twimg.com/tweet-result'
    USER_AGENT = 'Googlebot/2.1'
    MAX_RETRIES = 3
    RETRY_DELAYS = [1, 2, 4]  # Exponential backoff
    
    def self.fetch(tweet_id)
      # Returns:
      # {
      #   success: true/false,
      #   text: "plný text tweetu",
      #   photos: ["url1", "url2", ...],  # až 4
      #   video_thumbnail: "url" nebo nil,
      #   display_name: "User Name",
      #   username: "handle",
      #   created_at: "timestamp",
      #   error: nil nebo "error message"
      # }
    end
  end
end
```

### Co Syndication API poskytuje

| Data | Dostupné | Poznámka |
|------|----------|----------|
| Text | ✅ | Zkrácený pro Twitter Blue >280 znaků |
| Fotky | ✅ | Až 4, pbs.twimg.com URLs |
| Video thumbnail | ✅ | poster URL |
| Video varianty | ✅ | URLs, bitrate, rozlišení |
| Display name | ✅ | |
| Username | ✅ | |
| Created at | ✅ | |
| Thread context | ❌ | |
| Full text (Twitter Blue) | ❌ | Zkráceno na ~280 znaků |

### Limitace

- **Neoficiální API** - může se změnit bez varování
- **Zkrácený text** pro Twitter Blue tweety (>280 znaků)
- **Občasné prázdné odpovědi** - proto retry logika s 3 pokusy
- **Možný IP blocking** při velmi vysokém volume
- **Žádný thread context** - nelze detekovat thready

### Použití v kódu

```ruby
# Přímé volání
result = Services::SyndicationMediaFetcher.fetch('1234567890')

if result[:success]
  puts "Photos: #{result[:photos].count}"
  puts "Text: #{result[:text]}"
else
  puts "Error: #{result[:error]}"
end
```

---

## TwitterNitterAdapter

**Soubor:** `lib/adapters/twitter_nitter_adapter.rb`

### Konstanty

```ruby
TRUNCATION_THRESHOLD = 257

TERMINATOR_PATTERNS = {
  punctuation: /[.!?。！？…]\s*$/,
  emoji: /\p{Emoji}\s*$/,
  url: /https?:\/\/\S+\s*$/,
  hashtag: /#\w+\s*$/,
  mention: /@\w+\s*$/
}.freeze

TRUNCATION_PATTERNS = {
  ellipsis_text: /…|\.{3}/,
  ellipsis_url: /https?:\/\/[^\s]*…/,
  truncated_tco: /https?:\/\/t\.co\/\w*…/
}.freeze
```

### IFTTT Payload struktura

```ruby
{
  post_id: "1234567890",           # Extrahováno z link_to_tweet
  text: "Tweet text...",           # Text tweetu (může být zkrácený)
  embed_code: "<html>...</html>",  # HTML embed kód
  link_to_tweet: "https://twitter.com/user/status/1234567890",
  first_link_url: "https://...",   # První odkaz (media nebo external)
  username: "username",            # Twitter handle
  bot_id: "bot_name",              # ID bota z IFTTT
  received_at: Time.now
}
```

### Detekce zkrácení (`likely_truncated?`)

Vrací `true` pokud:
1. Text obsahuje `…` nebo `...`
2. URL obsahuje `…`
3. Text >= 257 znaků BEZ natural terminator (interpunkce, emoji, hashtag)
4. Text končí českou předložkou/spojkou
5. Text končí holou číslicí (bez interpunkce)

**Seznam předložek/spojek:**

a, i, k, o, s, u, v, z, na, do, od, po, za, ze, ke, ve, se,
pro, proti, při, před, přes, pod, nad, mezi, mimo, bez,
kvůli, podle, vůči, během,
ani, aby, ale, než, jen, jak, což, nebo, jako, tedy, když, že

**Důležité:** Regex používá `\z` (konec stringu), ne `$` (konec řádku):

```ruby
# SPRÁVNĚ - matchuje konec celého stringu
ends_with_punctuation = text.match?(/[.!?]\s*\z/)

# ŠPATNĚ - matchuje konec kteréhokoliv řádku
ends_with_punctuation = text.match?(/[.!?]\s*$/)
```

### Clean text (oprava 2026-01-30)

```ruby
def clean_text(text)
  return '' unless text
  
  text
    .gsub(/[ \t]+/, ' ')        # Normalize spaces/tabs (NE newlines!)
    .gsub(/\n[ \t]+/, "\n")     # Trim leading whitespace from lines
    .gsub(/[ \t]+\n/, "\n")     # Trim trailing whitespace from lines
    .gsub(/\n{3,}/, "\n\n")     # Max 2 consecutive newlines
    .strip
end
```

**Důležité:** Používá `/[ \t]+/` místo `/\s+/` pro zachování newlines z původního tweetu.

---

## TwitterAdapter

**Soubor:** `lib/adapters/twitter_adapter.rb` (orchestrace, 210 řádků)
**Moduly:** `twitter_rss_parser.rb` (RSS parsing), `twitter_html_parser.rb` (HTML parsing), `twitter_tweet_classifier.rb` (type detection)

TwitterAdapter je rozdělen do 4 souborů — hlavní orchestrace + 3 specializované moduly.

### Inicializace

```ruby
def initialize(handle:, nitter_instance: nil, url_domain: nil)
  @handle = handle.gsub(/^@/, '').downcase
  @nitter_instance = nitter_instance || ENV['NITTER_INSTANCE'] || 'http://xn.zpravobot.news:8080'
  @nitter_instance = @nitter_instance.chomp('/')
  @url_domain = url_domain || "https://xcancel.com"
end
```

### Dva režimy

1. **RSS feed** (`fetch_posts`) - batch stahování pro polling
2. **Single post** (`fetch_single_post`) - HTML parsing pro Tier 2

### Thread detection (RSS)

Pattern v title: `R to @same_handle:` → `is_thread_post = true`

```ruby
def detect_reply_with_thread(text)
  result = { is_reply: false, is_thread_post: false, reply_to_handle: nil }
  return result unless text
  
  # Pattern 1: "R to @username:" (Nitter format)
  if (match = text.match(/^R to @(\w+):/i))
    result[:is_reply] = true
    result[:reply_to_handle] = match[1].downcase
    result[:is_thread_post] = (result[:reply_to_handle] == @handle.downcase)
    return result
  end
  
  # Pattern 2: "@username " at start
  if (match = text.match(/^@(\w+)\s/i))
    result[:is_reply] = true
    result[:reply_to_handle] = match[1].downcase
    result[:is_thread_post] = (result[:reply_to_handle] == @handle.downcase)
  end
  
  result
end
```

### Media URL processing

```ruby
def fix_media_url(url)
  return url unless url
  
  if url =~ %r{https?://[^/]*zpravobot[^/]*(/.+)$}
    path = $1
    # Full resolution pro obrázky (ne pro video thumbnaily)
    if path.include?('/pic/media') && !path.include?('video')
      path = path.sub('/pic/', '/pic/orig/')
    end
    "#{nitter_instance}#{path}"
  elsif url.start_with?('/pic/') || url.start_with?('/media/')
    path = url
    if path.include?('/pic/media') && !path.include?('video')
      path = path.sub('/pic/', '/pic/orig/')
    end
    "#{nitter_instance}#{path}"
  else
    url
  end
end
```

### Text Processing (oprava 2026-01-30)

Metody `extract_text` (RSS) a `extract_text_from_html` (HTML page) automaticky odstraňují:

```ruby
# Media URL (photo/video) - jsou jako attachmenty, ne v textu
text = text.gsub(%r{\s*https?://[^\s]+/status/\d+/(?:photo|video)/\d+\s*}, ' ')

# Quote marker URL (Nitter přidává #m k quoted tweet URL)
# Tyto URL přidá správně formatter s newline prefixem
text = text.gsub(%r{\s*https?://[^\s]+/status/\d+#m\s*}, ' ')
```

**Důvod:**
- `/photo/1`, `/photo/2` atd. jsou přiloženy jako media attachmenty
- `/video/1` je přiloženo jako thumbnail + video URL
- `#m` quote marker URL se přidá formatterem se správným `\n` prefixem

---

## TwitterFormatter

**Soubor:** `lib/formatters/twitter_formatter.rb`

### Výstupní formáty

**Běžný tweet:**
```
Text tweetu

https://xcancel.com/user/status/123
```

**Repost:**
```
SourceBot 𝕏🔁 @author:

Text původního tweetu

https://xcancel.com/author/status/123
```

**Quote:**
```
SourceBot 𝕏💬 @quoted_author:

Text tweetu s citací

https://xcancel.com/quoted_author/status/123
```

**Video (Tier 3 fallback):**
```
Text tweetu…

🎬 + 📖➡️ https://xcancel.com/user/status/123
```

---

## TwitterProfileSyncer

**Soubor:** `lib/syncers/twitter_profile_syncer.rb`

### Konstanty

```ruby
DEFAULT_NITTER = 'http://xn.zpravobot.news:8080'
DEFAULT_CACHE_DIR = '/app/data/zbnw-ng-test/cache/profiles'
IMAGE_CACHE_TTL = 86400 * 7  # 7 dní

FIELD_LABELS = {
  'cs' => { managed: 'spravuje:', retention: 'retence:', days: 'dní' },
  'sk' => { managed: 'spravované:', retention: 'retencia:', days: 'dní' },
  'en' => { managed: 'managed by:', retention: 'retention:', days: 'days' }
}.freeze

VALID_RETENTION_DAYS = [7, 30, 90, 180].freeze
MANAGED_BY = '@zpravobot@zpravobot.news'
```

### Co synchronizuje

| Položka | Synchronizuje | Poznámka |
|---------|---------------|----------|
| Bio/description | ✅ | Z Nitter profilu |
| Avatar | ✅ | S cache (7 dní) |
| Banner | ✅ | S cache (7 dní) |
| Metadata pole 1 | ✅ | `𝕏` → URL profilu |
| Metadata pole 2 | ✅ | `web` → zachová stávající |
| Metadata pole 3 | ✅ | `spravuje:` → @zpravobot@zpravobot.news |
| Metadata pole 4 | ✅ | `retence:` → X dní |
| Display name | ❌ | Obsahuje :bot: badge |
| Handle | ❌ | Nastaveno při vytvoření účtu |

### API

```ruby
syncer = TwitterProfileSyncer.new(
  twitter_handle: 'ct24zive',
  nitter_instance: 'http://xn.zpravobot.news:8080',
  mastodon_instance: 'https://zpravobot.news',
  mastodon_token: 'xxx',
  language: 'cs',
  retention_days: 90
)

syncer.preview         # Náhled bez změn
syncer.sync!           # Plná synchronizace
syncer.sync_avatar!    # Pouze avatar
syncer.sync_banner!    # Pouze banner
syncer.sync_bio!       # Pouze bio
syncer.sync_fields!    # Pouze metadata pole
syncer.force_sync!     # Bypass cache
```

### Skupinová rotace (Group Rotation)

Pro rozložení zátěže na Nitter jsou Twitter zdroje rozděleny do **3 skupin** (0, 1, 2). Přiřazení je deterministické:

```ruby
def source_group(source_id)
  source_id.to_s.bytes.sum % 3  # → 0, 1, nebo 2
end
```

CLI podpora:
```bash
# Sync pouze skupina 0
bundle exec ruby bin/sync_profiles.rb --platform twitter --group 0

# Kombinovatelné s --dry-run
bundle exec ruby bin/sync_profiles.rb --platform twitter --group 1 --dry-run

# Bez --group = full sync (všechny skupiny)
bundle exec ruby bin/sync_profiles.rb --platform twitter
```

Viz sekce [Cron a scheduling > Profile sync](#profile-sync) pro aktuální cron konfiguraci.

---

## Konfigurace

### Platform defaults (`config/platforms/twitter.yml`)

```yaml
platform: twitter

filtering:
  skip_replies: true
  skip_retweets: false
  skip_quotes: false
  allow_self_retweets: true

formatting:
  platform_emoji: "𝕏"
  prefix_repost: "𝕏🔁"
  prefix_quote: "𝕏💬"
  prefix_video: "🎬"
  prefix_self_reference: "svůj post"
  move_url_to_end: true

mentions:
  type: domain_suffix
  value: "twitter.com"

processing:
  max_length: 2400
  trim_strategy: smart

url:
  domain: "xcancel.com"
  rewrite_domains:
    - twitter.com
    - x.com
    - nitter.net

scheduling:
  priority: normal
```

### Source config příklad

```yaml
id: ct24_twitter
enabled: true
platform: twitter

source:
  handle: "ct24zive"

target:
  mastodon_account: ct24

formatting:
  source_name: "ČT24"

profile_sync:
  enabled: true
  language: cs
  retention_days: 90
```

---

## Mentions transformace

Twitter mentions (`@username`) ZBNW-NG může transformovat různými způsoby.

### Typy transformací

| Typ | Hodnota | Vstup | Výstup |
|-----|---------|-------|--------|
| `none` | (ignorováno) | `@ct24zive` | `@ct24zive` |
| `prefix` | `https://twitter.com/` | `@ct24zive` | `https://twitter.com/ct24zive` |
| `suffix` | `https://twitter.com/` | `@ct24zive` | `@ct24zive (https://twitter.com/ct24zive)` |
| `domain_suffix` | `twitter.com` | `@ct24zive` | `@ct24zive@twitter.com` |

### Aktuální nastavení

```yaml
mentions:
  type: "domain_suffix"
  value: "twitter.com"
```

**Výsledek:** `@username` → `@username@twitter.com`

---

## Cron a scheduling

### IFTTT Queue Processing
```bash
# cron_ifttt.sh - každé 2 minuty
*/2 * * * * /app/data/zbnw-ng/cron_ifttt.sh
```

**Ochrana proti race condition (flock):**

Skript používá `flock` pro zajištění že běží pouze jedna instance:
```bash
LOCK_FILE="${SCRIPT_DIR}/.ifttt_processor.lock"

exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "Another instance is running, skipping..."
    exit 0
fi
```

Bez této ochrany může cron spustit novou instanci zatímco předchozí ještě běží, což vede k duplicitním postům.

### Webhook watchdog

```bash
# Kontrola že webhook server běží - každou minutu
* * * * * /app/data/zbnw-ng/cron_webhook.sh
```

### Profile sync

Twitter profily se synchronizují ve **3 skupinách** rotujících po dnech, aby se rozložila zátěž na Nitter (~300 zdrojů po migraci). Každá skupina se synchronizuje 1× za 3 dny ve 3:00.

Přiřazení do skupiny je **deterministické** — počítá se z `source_id` pomocí `source_id.to_s.bytes.sum % 3`. Nové zdroje se automaticky rovnoměrně rozdělí, žádná manuální konfigurace.

```bash
# Twitter profily: 3 skupiny rotující po dnech, ve 3:00
# Po,Čt = skupina 0, Út,Pá = skupina 1, St,So = skupina 2, Ne = volno
0 3 * * 1,4  /app/data/zbnw-ng/cron_profile_sync.sh --platform twitter --group 0
0 3 * * 2,5  /app/data/zbnw-ng/cron_profile_sync.sh --platform twitter --group 1
0 3 * * 3,6  /app/data/zbnw-ng/cron_profile_sync.sh --platform twitter --group 2
```

Manuální full sync (všechny skupiny najednou) je stále možný:
```bash
bundle exec ruby bin/sync_profiles.rb --platform twitter --dry-run
```

Ověření rozdělení do skupin:
```bash
ruby bin/sync_profiles.rb --platform twitter --group 0 --dry-run 2>&1 | grep "Group"
ruby bin/sync_profiles.rb --platform twitter --group 1 --dry-run 2>&1 | grep "Group"
ruby bin/sync_profiles.rb --platform twitter --group 2 --dry-run 2>&1 | grep "Group"
```

---

## Časté problémy

### 1. Webhook nepřichází

**Příčiny:**
- Webhook server neběží
- IFTTT applet deaktivován
- Firewall blokuje port 8089

**Diagnostika:**
```bash
curl http://localhost:8089/health
curl http://localhost:8089/stats | jq .
tail -f /app/data/zbnw-ng/logs/webhook_server.log
```

### 2. Tier 2 selhává (Nitter nedostupný)

**Příčiny:**
- Nitter instance spadla
- Cookies expirovali
- Rate limiting

**Diagnostika:**
```bash
curl "http://xn.zpravobot.news:8080/ct24zive/status/123"
docker compose logs nitter --tail 50
```

### 3. Obrázky se nezobrazují

**Příčiny:**
- `has_image_in_embed?` nedetekuje obrázky
- Media URL processing selhává

**Diagnostika:**
- Zkontrolovat logy pro `embed_code check:`
- Ověřit že embed_code obsahuje `pbs.twimg.com/media`

### 4. Text obsahuje nežádoucí URL

**Příčiny:**
- `/photo/N` nebo `/video/N` URL nejsou odstraněny
- Quote marker `#m` URL zůstává v textu

**Řešení:**
- Ověřit že `extract_text` používá správné regex patterny (viz sekce Text Processing)

### 5. Newlines zmizely

**Příčiny:**
- `clean_text` používá `/\s+/` místo `/[ \t]+/`

**Řešení:**
- Ověřit regex v `clean_text` metoda (viz sekce Clean text)

### 6. Test webhook jde do produkce

**Příčiny:**
- IFTTT applet nemá `?env=test` parametr

**Řešení:**
- Ověřit URL v testovacím IFTTT appletu: musí být `http://server:8089/api/ifttt/twitter?env=test`

### 7. Tier 1.5/3.5 selhává (Syndication API)

**Příčiny:**
- Syndication API dočasně nedostupné
- Tweet smazán nebo soukromý
- Rate limiting

**Diagnostika:**
```bash
# Test Syndication API
curl -A "Googlebot/2.1" "https://cdn.syndication.twimg.com/tweet-result?id=TWEET_ID&token=$(echo -n TWEET_ID | md5sum | cut -c1-10)"
```

**Řešení:**
- Tier 1.5 automaticky fallbackuje na Tier 1
- Tier 3.5 automaticky fallbackuje na Tier 3
- Pro důležité zdroje použít `nitter_processing: true`

### 8. Text neobsahuje dvojité odřádkování

**Příčiny:**
- `clean_text` nebo jiná funkce používá `/\s{2,}/` místo `/[ \t]{2,}/`

**Řešení:**
- Ověřit že všechny whitespace regex používají `[ \t]` místo `\s` pro zachování newlines

### 9. Duplicitní posty (stejný tweet publikován vícekrát)

**Příčiny:**
- Cron spouští nové instance zatímco předchozí běží
- Chybějící `flock` lock v `cron_ifttt.sh`

**Diagnostika:**
```bash
# Více "Processing batch" ve stejnou sekundu = race condition
grep "Processing batch" logs/ifttt_processor.log | tail -20
```

**Řešení:**
- Ověřit že `cron_ifttt.sh` obsahuje `flock` lock
- Zkontrolovat `.ifttt_processor.lock` soubor

### 10. Threading nefunguje (posty nejsou propojené)

**Příčiny:**
- Špatná struktura `@thread_cache` - lookup používal `@thread_cache[username]` místo `@thread_cache.dig(source_id, username)`
- Volání neexistující metody `cache_thread_post()` místo `update_thread_cache()`
- `extract_thread_chain` regex v `TwitterThreadProcessor` neodpovídal skutečné Nitter HTML struktuře

**Diagnostika:**
```bash
grep "Threading.*Cached\|in_reply_to\|chain extraction" logs/ifttt_processor.log | tail -20
```

Typický chybový log:
```
[14:32:34] ⚠️  [source_id] 🧵 Thread detected but chain extraction failed
[14:32:34] ℹ️  [IftttQueue] Thread detected, in_reply_to: none (thread start)
```

**Řešení:**
- Opraveno v 2026-02-03: thread cache nyní používá správnou dvouúrovňovou strukturu `{source_id => {username => mastodon_id}}`
- Opraveno v 2026-02-04: `mark_published()` v `post_processor.rb` nyní ukládá `platform_uri` pro Bluesky posty, což umožňuje propojení reply chain přes `find_by_platform_uri()`
- Opraveno v 2026-02-04: `extract_thread_chain` v `twitter_thread_processor.rb` - regex opraveny pro skutečnou Nitter HTML strukturu (viz changelog)

### 11. Webhook směřuje na špatnou konfiguraci / duplicitní posty

**Příčiny:**
- Chybějící nebo špatný `bot_id` v IFTTT payload
- `bot_id` neodpovídá `id:` v YAML konfiguraci
- Více appletů pro stejný účet bez rozlišujícího `bot_id`

**Důsledky:**
- Post jde na fallback aggregator místo správného bota
- `published?()` check selže (hledá pod jiným `source_id`) → duplicitní posty
- Filtry a nastavení z YAML konfigurace se neaplikují

**Diagnostika:**
```bash
# Zkontrolovat jaký bot_id přichází
grep "Looking for config" logs/ifttt_processor.log | tail -20

# Ověřit fallback na aggregator
grep "using default aggregator" logs/ifttt_processor.log | tail -10
```

**Řešení:**
1. V IFTTT appletu přidat/opravit `bot_id` v Body:
   ```json
   {
     "text": "<<<{{Text}}>>>",
     ...
     "bot_id": "nazev_z_yaml_konfigurace"
   }
   ```
2. `bot_id` musí přesně odpovídat hodnotě `id:` v YAML souboru
3. Pro více appletů sledujících stejný účet - každý applet musí mít **unikátní `bot_id`** směřující na příslušnou YAML konfiguraci

Viz sekce [IFTTT Payload struktura](#ifttt-payload-struktura) pro detailní příklady.

### 12. Tweet smazán mezi IFTTT triggerem a Nitter fetchem ("Text cannot be empty without media")

**Příčiny:**
- Autor smazal tweet mezi zachycením IFTTT webhookem a Tier 2 Nitter fetchem (typicky 1-2 minuty)
- Nitter vrátí HTTP 200 ale HTML stránka neobsahuje tweet content
- PostProcessor správně odmítne publikovat prázdný text

**Diagnostika:**
```bash
grep "empty content\|tweet likely deleted" logs/ifttt_processor.log | tail -20
```

Očekávané logy:
```
⚠️ Nitter HTML structure found but tweet content is empty for 123456 (tweet likely deleted between IFTTT trigger and Nitter fetch)
⚠️ Nitter returned empty content for post 123456 (tweet likely deleted)
Tier 2: ⚠️ Nitter returned HTTP 200 but tweet content is empty for 123456 (tweet likely deleted)
```

**Chování systému:**
- Nitter fetch vrátí Post objekt s prázdným textem
- MastodonPublisher.publish() vyhodí `ArgumentError: Text cannot be empty without media`
- Post se nepublikuje → správné chování (není co publikovat)

**Řešení:**
- Žádná akce potřeba — systém pracuje správně
- Logy s `⚠️` jasně rozlišují mezi skutečným selháním Nitter a smazaným tweetem

### 13. Encoding crash při zpracování thread chain (`incompatible character encodings: UTF-8 and BINARY`)

**Příčiny:**
- `Net::HTTP` vrací `response.body` jako `ASCII-8BIT` (binary)
- `extract_thread_chain()` extrahuje text z HTML a volá `.encode('UTF-8', ...)` na stringu, který je už tagovaný jako UTF-8 (po `force_encoding`)
- Ruby `.encode('UTF-8', invalid: :replace)` je no-op pokud je source encoding už UTF-8 → nevalidní byte sekvence zůstanou
- Při interpolaci do UTF-8 log stringu dojde ke crash na `incompatible character encodings`
- 100% korelace s thread zpracováním — každý encoding error je předcházen `Thread chain found: N tweets → CRASH`

**Diagnostika:**
```bash
grep "incompatible character encodings" logs/ifttt_processor.log | tail -20
grep "Thread chain found.*CRASH\|encoding" logs/ifttt_processor.log | tail -20
```

Typický chybový log:
```
[14:32:34] ℹ️  [source_id] 🧵 Thread chain found: 5 tweets before current
Error: incompatible character encodings: UTF-8 and BINARY (ASCII-8BIT)
  twitter_thread_processor.rb:150:in 'block in reconstruct_chain'
```

**Řešení:**
- **Částečně opraveno v 2026-02-07:** `.encode('UTF-8', 'UTF-8', ...)` v `extract_thread_chain()` (řádek 124) — opravilo crash při extrakci chain, ale ne v `reconstruct_chain()`
- **Kompletně opraveno v 2026-02-11:** Nahrazeno `force_encoding('UTF-8')` za `.encode('UTF-8', 'binary', invalid: :replace, undef: :replace, replace: '?')` ve 4 místech:
  - `twitter_thread_processor.rb` — `fetch_with_retry()` a `format_chain_tweet()`
  - `twitter_adapter.rb` — `fetch_html_page()` (RSS i HTML fetch)
  - `twitter_thread_fetcher.rb` — `fetch_page()` _(smazán v TASK-10)_
- **Doplňující fix 2026-02-12:** Encoding sanitizace v `reconstruct_chain()` — 14 crashů přetrvávalo kvůli interpolaci ASCII-8BIT dat do log messages
  - Nová helper metoda `sanitize_encoding()` pro centrální encoding sanitizaci
  - Aplikováno na: `tweet[:text_preview]` v debug logu, `e.message` v rescue blocích, `post.text` ve `format_chain_tweet()`
- Klíčový rozdíl: `force_encoding('UTF-8')` pouze přetaguje string, `.encode('UTF-8', 'binary', ...)` skutečně validuje a nahrazuje neplatné byty
