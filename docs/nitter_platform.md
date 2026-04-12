# Nitter Platform - ZBNW-NG

> **Poslední aktualizace:** 2026-04-11
> **Stav:** Produkční
> **Instance:** xn.zpravobot.news

> **Recent changes:**
> - **2026-04-09 (PERF-1):** `TwitterTweetProcessor` nyní prefetchuje Nitter HTML pro threadované tweety — eliminuje dvojí fetch téhož statusu při vláknové resoluci.
> - **2026-02-25 (TASK-10):** Unifikace Twitter pipeline — `TwitterTweetProcessor` nahradil `TwitterThreadFetcher`; `IftttTwitterAdapter` přejmenován na `TwitterNitterAdapter`.

---

## Obsah

1. [Přehled](#přehled)
2. [Architektura](#architektura)
3. [Nasazení serveru](#nasazení-serveru)
4. [Autentizace - sessions.jsonl](#autentizace---sessionsjsonl)
5. [Nginx reverse proxy](#nginx-reverse-proxy)
6. [ZBNW-NG integrace](#zbnw-ng-integrace)
7. [TwitterAdapter](#twitteradapter)
8. [TwitterProfileSyncer](#twitterprofilesyncer)
9. [Health monitoring](#health-monitoring)
10. [Údržba](#údržba)
11. [Troubleshooting](#troubleshooting)
12. [API reference](#api-reference)
13. [Historie změn](#historie-změn)

---

## Přehled

Nitter je self-hosted alternativní frontend pro Twitter/X, který ZBNW-NG používá pro:

- **HTML scraping** - stažení kompletních dat o jednotlivých tweetech (IFTTT Tier 2)
- **Profile scraping** - synchronizace profilových dat na Mastodon

### ⚠️ Důležité: RSS feeds se NEPOUŽÍVAJÍ

V produkci ZBNW-NG **nepoužívá** Nitter RSS feeds pro polling. Místo toho:
- **IFTTT webhooky** = spolehlivé real-time triggery z oficiálního Twitter API
- **Nitter** = pouze pro `fetch_single_post()` v Tier 2 (HTML parsing konkrétních tweetů)

RSS feed funkcionalita v `twitter_adapter.rb` existuje, ale není aktivně používána.

### Proč vlastní instance?

| Aspekt | Veřejné Nitter instance | Vlastní instance |
|--------|-------------------------|------------------|
| Dostupnost | ❌ Často nedostupné | ✅ Pod naší kontrolou |
| Rate limiting | ❌ Sdíleno s veřejností | ✅ Dedikované pro ZBNW-NG |
| Bezpečnost | ❌ Třetí strana vidí traffic | ✅ IP whitelist |
| Spolehlivost | ❌ Nepředvídatelná | ✅ Monitorovaná |

### Klíčové vlastnosti

| Funkce | Stav | Použití |
|--------|------|---------|
| Single tweet fetch | ✅ Aktivní | IFTTT Tier 2 - `fetch_single_post()` |
| Profile scraping | ✅ Aktivní | Avatar, banner, bio sync |
| RSS feed | ⚠️ Nepoužívá se | Existuje v kódu, ale IFTTT hybrid je primární |
| Media proxy | ✅ Aktivní | Full resolution obrázky |
| Video thumbnaily | ✅ Aktivní | Přes `/pic/` endpoint |
| IP whitelist | ✅ Aktivní | Pouze zpravobot.news |

---

## Architektura

```
┌─────────────────────────┐         HTTP/8080        ┌─────────────────────────┐
│     Nitter Server       │ ◄─────────────────────── │       ZBNW-NG           │
│   (<nitter-server-ip>)  │                          │   (zpravobot.news)      │
│   xn.zpravobot.news     │                          │   (<zbnw-server-ip>)    │
└─────────────────────────┘                          └─────────────────────────┘
         │
         ▼
    Twitter/X API
    (via burner cookies)
```

### Komponenty na Nitter serveru

```
┌────────────────────────────────────────────────────┐
│                   Nitter VPS                       │
│   <nitter-server-ip> / <nitter-server-ipv6>        │
│                                                    │
│   ┌───────────────┐    ┌───────────────────────┐   │
│   │    Nginx      │    │   Docker: nitter      │   │
│   │   port 8080   │───▶│   port 8082           │   │
│   │  (whitelist)  │    │   network_mode: host  │   │
│   └───────────────┘    └───────────────────────┘   │
│                               │                    │
│                        ┌──────┴──────┐             │
│                        │             │             │
│              ┌─────────▼───┐   ┌─────▼─────┐       │
│              │   Redis     │   │ sessions  │       │
│              │  port 6379  │   │  .jsonl   │       │
│              └─────────────┘   └───────────┘       │
│                                                    │
└────────────────────────────────────────────────────┘
```

### Soubory na serveru

| Soubor | Umístění | Účel |
|--------|----------|------|
| `nitter.conf` | `~/nitter/` | Hlavní konfigurace Nitteru |
| `docker-compose.yml` | `~/nitter/` | Docker orchestrace |
| `sessions.jsonl` | `~/nitter/` | Burner účty (cookies) |
| `nitter-repo/` | `~/nitter/` | Klonovaný Nitter zdrojový kód |

### Infrastruktura ZBNW-NG

| Soubor | Umístění | Účel |
|--------|----------|------|
| `twitter_adapter.rb` | `lib/adapters/` | RSS/HTML fetch z Nitteru |
| `twitter_profile_syncer.rb` | `lib/syncers/` | Profile sync přes Nitter |
| `twitter_nitter_adapter.rb` | `lib/adapters/` | Tier 1/1.5/3 logika; Tier 2 deleguje na TwitterAdapter |

---

## Nasazení serveru

### Prerekvizity

**Na Nitter VPS:**
- Ubuntu 24.04 LTS
- Docker a Docker Compose
- Nginx
- Git

**Burner Twitter účty:**

Nitter vyžaduje sadu burner Twitter účtů pro autentizaci vůči Twitter API.
Reálná jména a credentials jsou v `nitter_platform.private.md`.

**Kapacita:** ~500 req/15 min na účet. S dostatečným počtem účtů pokryjeme potřeby ZBNW-NG.

### Instalace

#### 1. Příprava adresáře

```bash
mkdir -p ~/nitter
cd ~/nitter
```

#### 2. Klonování repozitáře

Používáme fork od **zedeus** s cookie autentizací:

```bash
git clone https://github.com/zedeus/nitter.git nitter-repo
```

#### 3. Vytvoření nitter.conf

```ini
[Server]
hostname = "xn.zpravobot.news"
title = "nitter"
address = "0.0.0.0"
port = 8082
https = true
httpMaxConnections = 100
staticDir = "./public"

[Cache]
listMinutes = 240
rssMinutes = 10
redisHost = "127.0.0.1"
redisPort = 6379
redisPassword = ""
redisConnections = 20
redisMaxConnections = 30

[Config]
hmacKey = "ZMĚŇTE_NA_NÁHODNÝ_ŘETĚZEC"
base64Media = false
enableRSS = true
enableDebug = false
proxy = ""
proxyAuth = ""
tokenCount = 10

[Preferences]
theme = "Nitter"
replaceTwitter = "xn.zpravobot.news"
replaceYouTube = ""
replaceReddit = ""
replaceInstagram = ""
proxyVideos = true
hlsPlayback = false
infiniteScroll = false
```

**Důležitá nastavení:**

| Parametr | Hodnota | Důvod |
|----------|---------|-------|
| `hostname` | `xn.zpravobot.news` | Pro korektní URL v RSS |
| `port` | `8082` | Interní port (nginx na 8080) |
| `https` | `true` | Generuje HTTPS URL v RSS |
| `redisHost` | `127.0.0.1` | Nutné kvůli `network_mode: host` |
| `hmacKey` | random | Generovat: `openssl rand -hex 16` |
| `rssMinutes` | `10` | Cache RSS feedů |

#### 4. Vytvoření docker-compose.yml

```yaml
services:
  nitter:
    build: ./nitter-repo
    container_name: nitter
    network_mode: host
    volumes:
      - ./nitter.conf:/src/nitter.conf:ro
      - ./sessions.jsonl:/src/sessions.jsonl:ro
    restart: unless-stopped

  nitter-redis:
    image: redis:7-alpine
    container_name: nitter-redis
    command: redis-server --save 60 1 --loglevel warning
    ports:
      - "127.0.0.1:6379:6379"
    volumes:
      - nitter-redis:/data
    restart: unless-stopped

volumes:
  nitter-redis:
```

**Kritické nastavení:**

| Parametr | Hodnota | Důvod |
|----------|---------|-------|
| `network_mode: host` | - | **NUTNÉ** pro IPv6 konektivitu shodnou s cookies |
| `build: ./nitter-repo` | - | Lokální build ze zdrojáků |
| Redis port | `127.0.0.1:6379` | Pouze lokální přístup |

#### 5. Build a spuštění

```bash
cd ~/nitter
docker compose build
docker compose up -d
```

#### 6. Kontrola logů

```bash
docker compose logs -f nitter
```

**Očekávaný výstup:**
```
[sessions] parsing JSONL account sessions file: ./sessions.jsonl
[sessions] successfully added N valid account sessions
Starting Nitter at https://xn.zpravobot.news
Connected to Redis at 127.0.0.1:6379
```

---

## Autentizace - sessions.jsonl

### Formát souboru

Každý řádek = jeden Twitter účet ve formátu JSONL:

```jsonl
{"kind":"cookie","id":"USER_ID","username":"USERNAME","authToken":"AUTH_TOKEN","ct0":"CT0_VALUE"}
```

| Pole | Popis | Příklad |
|------|-------|---------|
| `kind` | Vždy `"cookie"` | `"cookie"` |
| `id` | Twitter User ID (string!) | `"201234567890123456"` |
| `username` | Twitter handle | `"burner_account"` |
| `authToken` | Cookie `auth_token` | 40 znaků hex |
| `ct0` | Cookie `ct0` (CSRF) | ~160 znaků |

### Jak získat cookies

**⚠️ KRITICKÉ:** Cookies musí být získány ze **stejné IP adresy**, jakou používá Nitter!

### ⛔ KRITICKÁ PRAVIDLA PRO COOKIES

1. **NIKDY SE NEODHLAŠOVAT** - odhlášení z Twitteru okamžitě invaliduje cookies
2. **Firefox anonymní okno** - po získání cookies pouze zavřít okno (ne odhlásit se)
3. **Mezi účty ukončit Firefox ÚPLNĚ** - pro další burner účet otevřít nové anonymní okno
4. **Vždy přes SOCKS5 proxy** - musí být ze správné IP
5. **Ověřit IPv6** - ifconfig.me musí ukázat IPv6 adresu serveru

**Správný postup pro více účtů:**
```
1. Spustit SSH tunel
2. Otevřít Firefox anonymní okno
3. Přihlásit se jako první burner účet
4. Vytáhnout cookies
5. ZAVŘÍT Firefox (NE odhlásit se!)
6. Otevřít NOVÉ Firefox anonymní okno
7. Přihlásit se jako další burner účet
8. Vytáhnout cookies
9. ZAVŘÍT Firefox
... opakovat pro další účty
```

#### Krok 1: SSH tunel (SOCKS5 proxy)

```bash
ssh -D 1080 -N <nitter-server-user>@<nitter-server-ip>
```

- `-D 1080` – SOCKS5 proxy na portu 1080
- `-N` – nespouštět shell
- Terminál "zamrzne" – to je správně

#### Krok 2: Nastavení Firefoxu

1. Settings → hledej "proxy"
2. Manual proxy configuration
3. SOCKS Host: `127.0.0.1`, Port: `1080`, SOCKS v5
4. **✅ Zaškrtni "Proxy DNS when using SOCKS v5"**

#### Krok 3: Ověření IP

Otevři https://ifconfig.me ve Firefoxu.
Mělo by zobrazit IPv6 adresu Nitter serveru.

#### Krok 4: Přihlášení na Twitter

1. Otevři https://x.com
2. Přihlaš se burner účtem
3. DevTools (F12) → Application → Cookies → x.com
4. Zkopíruj:
   - `auth_token`
   - `ct0`

#### Krok 5: Získání User ID

V DevTools Console:
```javascript
document.cookie.match(/twid=u%3D(\d+)/)?.[1]
```

Nebo najdi cookie `twid` – hodnota je `u%3D{USER_ID}`.

#### Krok 6: Přidání do sessions.jsonl

```bash
echo '{"kind":"cookie","id":"USER_ID","username":"USERNAME","authToken":"AUTH_TOKEN","ct0":"CT0_VALUE"}' >> ~/nitter/sessions.jsonl
docker compose restart nitter
```

### Důležité poznámky

- Nitter automaticky rotuje mezi účty
- Cookies expirují po týdnech/měsících
- **NIKDY** se nepřihlašuj na burner účet normálně (bez SOCKS) – Twitter session zneplatní
- Při expiraci se v logu objeví `"Could not authenticate you"`

---

## Nginx reverse proxy

### Konfigurace s IP whitelistem

```nginx
server {
    listen 8080;
    server_name _;

    # Povolit pouze zpravobot.news
    allow <zbnw-server-ip>;
    allow 127.0.0.1;
    deny all;

    location / {
        proxy_pass http://127.0.0.1:8082;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### Aktivace

```bash
sudo ln -s /etc/nginx/sites-available/nitter /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

### Porty

| Port | Služba | Přístup |
|------|--------|---------|
| 8080 | Nginx | Veřejný s IP filtrem |
| 8082 | Nitter | Pouze localhost |
| 6379 | Redis | Pouze localhost |

---

## ZBNW-NG integrace

### Konfigurace v YAML

```yaml
source:
  nitter_instance: "http://xn.zpravobot.news:8080"
  handle: "ct24zive"
```

### Environment variable

```bash
NITTER_INSTANCE="http://xn.zpravobot.news:8080"
```

### Dostupné endpointy

| Endpoint | Účel | Příklad |
|----------|------|---------|
| `/{username}/rss` | RSS feed tweetů | `/ct24zive/rss` |
| `/{username}/with_replies/rss` | Včetně odpovědí | `/ct24zive/with_replies/rss` |
| `/{username}/media/rss` | Pouze média | `/ct24zive/media/rss` |
| `/{username}` | HTML profil | `/ct24zive` |
| `/{username}/status/{id}` | Konkrétní tweet | `/ct24zive/status/123` |
| `/pic/media%2F...` | Proxy obrázků | - |
| `/pic/orig/media%2F...` | Full resolution | - |

---

## TwitterAdapter

**Soubor:** `lib/adapters/twitter_adapter.rb`

### Inicializace

```ruby
def initialize(handle:, nitter_instance: nil, url_domain: nil)
  @handle = handle.gsub(/^@/, '').downcase
  @nitter_instance = nitter_instance || ENV['NITTER_INSTANCE'] || 'http://xn.zpravobot.news:8080'
  @nitter_instance = @nitter_instance.chomp('/')
  @url_domain = url_domain || "https://xcancel.com"
end
```

### Dva režimy operace

#### 1. RSS feed (`fetch_posts`)

Batch stahování pro polling (nepoužívané v hybridním režimu):

```ruby
adapter = Adapters::TwitterAdapter.new(handle: 'ct24zive')
posts = adapter.fetch_posts(since: 1.hour.ago, limit: 50)
```

**Proces:**
1. Fetch RSS z `{nitter}/ct24zive/rss`
2. Parse XML pomocí REXML
3. Detekce typu (RT, quote, thread)
4. Extrakce médií z HTML description
5. Vrátí Array<Post>

#### 2. Single post (`fetch_single_post`)

HTML parsing pro Tier 2 (IFTTT hybrid):

```ruby
adapter = Adapters::TwitterAdapter.new(handle: 'ct24zive')
post = adapter.fetch_single_post('1234567890')
```

**Endpoint:** `{nitter}/ct24zive/status/1234567890`

**Použití:** IFTTT trigger → Queue → Tier 2 → `fetch_single_post` pro kompletní data

### Thread detection

Pattern v RSS title: `R to @same_handle:` → `is_thread_post = true`

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

### Detekce typů postů

| Typ | RSS pattern | Post atribut |
|-----|-------------|--------------|
| Repost | `^RT by @\w+:` v title | `is_repost: true` |
| Quote | `— URL#m` na konci textu | `is_quote: true` |
| Reply | `^R to @\w+:` v title | `is_reply: true` |
| Thread | Reply to same handle | `is_thread_post: true` |
| Video | `>Video<` nebo `video_thumb` v HTML | `has_video: true` |

---

## TwitterProfileSyncer

**Soubor:** `lib/syncers/twitter_profile_syncer.rb`

### Účel

Synchronizuje profil z Twitter/X (přes Nitter) na Mastodon bot účet.

### Konstanty

```ruby
DEFAULT_NITTER = 'http://xn.zpravobot.news:8080'
DEFAULT_CACHE_DIR = '/app/data/zbnw-ng/cache/profiles'
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
| Bio/description | ✅ | Z Nitter HTML profilu |
| Avatar | ✅ | S cache (7 dní) |
| Banner | ✅ | S cache (7 dní) |
| Metadata pole 1 | ✅ | `𝕏` → URL profilu |
| Metadata pole 2 | ✅ | `web` → zachová stávající |
| Metadata pole 3 | ✅ | `spravuje:` → @zpravobot |
| Metadata pole 4 | ✅ | `retence:` → X dní |
| Display name | ❌ | Obsahuje :bot: badge |
| Handle | ❌ | Nastaveno při vytvoření |

### Nitter profile scraping

```ruby
def fetch_twitter_profile
  uri = URI("#{nitter_instance}/#{twitter_handle}")
  response = http_get(uri)
  parse_nitter_profile(response.body)
end

def parse_nitter_profile(html)
  profile = {}

  # Display name
  if html =~ /<a[^>]*class="profile-card-fullname"[^>]*>([^<]+)<\/a>/
    profile[:display_name] = decode_html_entities($1.strip)
  end

  # Bio
  if html =~ /<div[^>]*class="profile-bio"[^>]*>(.*?)<\/div>/m
    bio = $1.gsub(/<br\s*\/?>/, "\n").gsub(/<[^>]+>/, '')
    profile[:description] = decode_html_entities(bio).strip
  end

  # Avatar
  if html =~ /<a[^>]*class="profile-card-avatar"[^>]*href="([^"]+)"/
    profile[:avatar_url] = resolve_nitter_url($1)
  end

  # Banner
  if html =~ /<div[^>]*class="profile-banner"[^>]*>\s*<a[^>]*href="([^"]+)"/m
    profile[:banner_url] = resolve_nitter_url($1)
  end

  profile
end
```

### API

```ruby
syncer = Syncers::TwitterProfileSyncer.new(
  twitter_handle: 'ct24zive',
  nitter_instance: 'http://xn.zpravobot.news:8080',
  mastodon_instance: 'https://zpravobot.news',
  mastodon_token: '<token>',
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

### Class-level API

```ruby
# Získání display name bez vytváření plné instance
display_name = Syncers::TwitterProfileSyncer.fetch_display_name(
  'ct24zive',
  nitter_instance: 'http://xn.zpravobot.news:8080'
)
```

---

## Health monitoring

### Údržbot - NitterCheck

**Soubor:** `bin/health_monitor.rb`

```ruby
class NitterCheck
  def run
    uri = URI("#{@config['nitter_url']}/settings")
    response = http.get(uri.path)

    if response.code.to_i == 200
      guest_status = parse_guest_status(response.body)

      if guest_status[:healthy]
        CheckResult.new(name: 'Nitter Instance', level: :ok, ...)
      else
        CheckResult.new(name: 'Nitter Instance', level: :warning, ...)
      end
    end
  end

  def parse_guest_status(html)
    if html.include?('Rate limited') || html.include?('rate_limit')
      { healthy: false, message: 'Rate limited' }
    elsif html.include?('No guest accounts')
      { healthy: false, message: 'Žádné aktivní guest accounts' }
    elsif html.include?('suspended')
      { healthy: false, message: 'Účty suspendovány' }
    else
      { healthy: true, message: 'OK' }
    end
  end
end
```

### Konfigurace monitoringu

```yaml
# config/health_monitor.yml
nitter_url: 'http://xn.zpravobot.news:8080'

thresholds:
  nitter_timeout: 10  # sekundy
  nitter_error_keywords:
    - rate_limit
    - rate limit
    - guest_account
    - guest account
    - unauthorized
    - suspended
    - banned
    - blocked
    - Too Many Requests
    - 429
```

### NitterAccountsCheck

Kontroluje chybové vzory v activity_log:

```ruby
class NitterAccountsCheck
  def run
    # Hledá account-related chyby za poslední hodinu
    result = @conn.exec(<<~SQL)
      SELECT COUNT(*) as error_count
      FROM activity_log
      WHERE action = 'error'
      AND created_at > NOW() - INTERVAL '1 hour'
      AND (details::text ILIKE '%rate_limit%'
           OR details::text ILIKE '%unauthorized%'
           ...)
    SQL

    error_count = result[0]['error_count'].to_i

    if error_count > 10
      CheckResult.new(level: :critical, message: "#{error_count} account-related chyb")
    elsif error_count > 3
      CheckResult.new(level: :warning, ...)
    else
      CheckResult.new(level: :ok, message: 'Žádné account-related chyby')
    end
  end
end
```

### Remediation instrukce

```
Burner účty pravděpodobně expirovany!
1. SSH na Nitter server (viz nitter_platform.private.md)
2. Obnovit cookies přes SOCKS proxy
3. Aktualizovat sessions.jsonl
4. Restart: docker compose restart nitter
```

---

## Údržba

### Běžné příkazy

```bash
cd ~/nitter

# Logy
docker compose logs -f nitter

# Restart
docker compose restart nitter

# Stop
docker compose down

# Start
docker compose up -d

# Rebuild (po aktualizaci Nitteru)
docker compose build
docker compose up -d
```

### Obnovení cookies

Když se v logu objeví `"Could not authenticate you"`:

1. Spusť SOCKS tunel: `ssh -D 1080 -N <user>@<nitter-server-ip>` (viz `nitter_platform.private.md`)
2. Nastav Firefox proxy (anonymní okno!)
3. Ověř IP na ifconfig.me (musí být IPv6 serveru)
4. Přihlaš se na x.com
5. Zkopíruj nové `auth_token` a `ct0`
6. **⚠️ ZAVŘI Firefox (NE odhlásit se!)**
7. Aktualizuj `sessions.jsonl`
8. `docker compose restart nitter`

### Přidání nového účtu

1. Vytvoř burner účet na x.com (přes SOCKS!)
2. Získej cookies (viz sekce Autentizace)
3. **⚠️ ZAVŘI Firefox (NE odhlásit se!)**
4. Přidej řádek do `sessions.jsonl`
5. `docker compose restart nitter`

### Hromadná obnova více účtů

Pro každý účet **MUSÍŠ**:
1. Ukončit Firefox úplně
2. Otevřít NOVÉ anonymní okno
3. Přihlásit se k dalšímu účtu
4. Vytáhnout cookies
5. Zavřít Firefox (NE odhlásit se!)

**Špatně:**
```
Přihlásit jako účet1 → Odhlásit → Přihlásit jako účet2  ❌
```

**Správně:**
```
Přihlásit jako účet1 → Zavřít Firefox → Otevřít nový Firefox → Přihlásit jako účet2  ✅
```

### Tipy pro delší životnost účtů

- Použij reálně vypadající profilovou fotku a bio
- Sleduj pár účtů
- Nech účet "vyzrát" několik dní před použitím
- Nepoužívej všechny účty najednou – Nitter rotuje

### Redis optimalizace (volitelné)

```bash
sudo sysctl vm.overcommit_memory=1
echo "vm.overcommit_memory=1" | sudo tee -a /etc/sysctl.conf
```

---

## Troubleshooting

### "Could not authenticate you"

**Příčina:**
- Cookies expirovali
- IP mismatch (cookies získány z jiné IP)
- **Odhlášení z účtu** (invaliduje cookies!)

**Řešení:**
1. Získej nové cookies přes SOCKS proxy
2. **⚠️ Po získání cookies POUZE ZAVŘI Firefox (nikdy se neodhlašuj!)**
3. Aktualizuj `sessions.jsonl`
4. `docker compose restart nitter`

### "User not found"

**Příčina:**
- Účet je soukromý
- Účet neexistuje
- Cache issue

**Řešení:**
- Zkontroluj, že účet existuje na twitter.com
- `docker compose restart nitter` (vyčistí cache)

### 403 Forbidden (z externího přístupu)

**Příčina:** IP není na whitelistu

**Řešení:**
```bash
# Na Nitter serveru
sudo nano /etc/nginx/sites-available/nitter
# Přidej IP do allow
sudo nginx -t
sudo systemctl reload nginx
```

### Connection refused

**Příčina:** Nitter neběží

**Řešení:**
```bash
docker compose ps
docker compose up -d
```

### IPv4 vs IPv6 mismatch

**Příčina:** Cookies získány z jiné IP než Nitter používá

**Řešení:**
1. Použij `network_mode: host` v docker-compose
2. Získej cookies přes SOCKS proxy ze správné IP
3. Ověř IP: ve Firefoxu s proxy jdi na ifconfig.me

### 429 Too Many Requests

**Příčina:** Rate limit

**Řešení:**
- Přidej další burner účty
- Sniž frekvenci pollingu

### "invalid integer" při startu

**Příčina:** User ID není v uvozovkách jako string

**Řešení:**
```jsonl
{"kind":"cookie","id":"123456789",...}  ✅ správně
{"kind":"cookie","id":123456789,...}    ❌ špatně
```

### RSS vrací staré tweety

**Příčina:** RSS cache

**Řešení:**
- Cache TTL je 10 minut (`rssMinutes = 10`)
- Restart Nitteru vyčistí cache: `docker compose restart nitter`

---

## API reference

### Nitter endpointy

| Endpoint | Metoda | Účel |
|----------|--------|------|
| `/{username}/rss` | GET | RSS feed tweetů |
| `/{username}/with_replies/rss` | GET | RSS včetně odpovědí |
| `/{username}/media/rss` | GET | RSS pouze s médii |
| `/{username}` | GET | HTML profil |
| `/{username}/status/{id}` | GET | HTML konkrétního tweetu |
| `/pic/media%2F{path}` | GET | Proxy obrázku |
| `/pic/orig/media%2F{path}` | GET | Full resolution obrázek |
| `/settings` | GET | Settings stránka (pro health check) |

### Příklady volání

```bash
# RSS feed
curl -s "http://xn.zpravobot.news:8080/ct24zive/rss" | head -20

# Konkrétní tweet
curl -s "http://xn.zpravobot.news:8080/ct24zive/status/1234567890"

# Profil (HTML)
curl -s "http://xn.zpravobot.news:8080/ct24zive" | grep profile-card

# Health check
curl -s "http://xn.zpravobot.news:8080/settings" | head -5
```

### RSS formát

```xml
<?xml version="1.0" encoding="UTF-8"?>
<rss xmlns:atom="http://www.w3.org/2005/Atom"
     xmlns:dc="http://purl.org/dc/elements/1.1/"
     version="2.0">
  <channel>
    <title>ČT24 / @CT24zive</title>
    <link>https://xn.zpravobot.news/CT24zive</link>
    <item>
      <title>Tweet text or "RT by @handle:" prefix</title>
      <dc:creator>@username</dc:creator>
      <description><![CDATA[HTML content with media]]></description>
      <pubDate>Thu, 30 Jan 2026 10:00:00 GMT</pubDate>
      <link>https://xn.zpravobot.news/CT24zive/status/123</link>
      <guid>https://xn.zpravobot.news/CT24zive/status/123</guid>
    </item>
  </channel>
</rss>
```
