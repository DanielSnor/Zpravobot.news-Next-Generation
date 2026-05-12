# Threads

## Platforma (orientace)

Threads v kontextu ZBNW‑NG představuje:

- **Zdroj dat** – příspěvky přes RSS.app bridge
- **Integrační vrstvu** – `RssAdapter` s `ThreadsProcessor` pro rekonstrukci formátování
- **Platform-specific chování** – text-first posty, veřejné profily (cookies nepotřeba)
- **Konfigurační jednotku** – definovanou v YAML (`config/sources/*.yml`)

Platforma je vždy vstupní bod systému, izolovaná adapterem a sjednocená do modelu `Post`.

---

Tento dokument popisuje **integraci platformy Threads** do systému ZBNW‑NG.
Zaměřuje se na specifika textové platformy, charakter obsahu a vztah
k Instagramu, od kterého se integrace odvíjí.

Použité pojmy jsou definovány v [`../00-overview/terminologie.md`](../00-overview/terminologie.md).
Důvody architektonických rozhodnutí jsou popsány v [`../90-meta/decisions.md`](../90-meta/decisions.md).

Příbuzná platforma Instagram je popsána v [`instagram.md`](instagram.md).

---

## 1. Charakteristika platformy

Threads je **text-first sociální platforma** od Meta, kde hlavní nositel obsahu
je krátký text (limit 500 znaků). Média (obrázky, videa) jsou volitelná.

Z pohledu ZBNW‑NG je Threads zdrojem obsahu, kde **textová složka má
primární váhu** — na rozdíl od Instagramu, kde dominuje vizuál.

---

## 2. Postavení Threads v architektuře

Threads je v architektuře ZBNW‑NG považován za **samostatnou platformu**,
ačkoliv sdílí technickou infrastrukturu s Instagramem (Meta Graph API, CDN).

Klíčové vlastnosti z pohledu integrace:

| Vlastnost | Hodnota |
|---|---|
| Zdroj dat | RSS.app scrape |
| Procesor | `ThreadsProcessor` |
| Profile syncer | `ThreadsProfileSyncer` |
| Max délka postu | 500 znaků |
| Cookies pro scraping | nejsou potřeba (veřejné profily) |
| Platform emoji | 🧵 |

---

## 3. Datový tok

```
threads.net/@handle
       ↓
   RSS.app (scrape)
       ↓
   RSS feed (XML)
       ↓
   RssAdapter
       ↓
   ThreadsProcessor   ← rekonstrukce formátování
       ↓
   Post model
       ↓
   Mastodon API
```

---

## 4. RSS.app bridge

Threads nemá veřejné API pro čtení cizích účtů. ZBNW‑NG používá RSS.app
jako bridge — stejný přístup jako u Instagramu a Facebooku.

RSS.app provádí scrape profilu a vrátí RSS feed s položkami:

```xml
<item>
  <title>Obsah postu (truncated)</title>
  <description>Plný text postu</description>
  <link>https://www.threads.net/@handle/post/ID</link>
  <dc:creator>@handle</dc:creator>
  <pubDate>...</pubDate>
  <media:content medium="image" url="..."/>  <!-- pouze pokud post obsahuje médium -->
</item>
```

RSS.app splácne formátování postu do jednoho plochého textového bloku
— odstraní `\n` a odstavce. `ThreadsProcessor` toto formátování
rekonstruuje heuristikami.

---

## 5. ThreadsProcessor

`ThreadsProcessor` rekonstruuje formátování ztracené při RSS.app konverzi.
Je implementován jako tenká vrstva nad `SocialTextHeuristics` — sdílené
heuristiky jsou identické s `InstagramProcessor`.

### Heuristiky (v pořadí aplikace)

| # | Heuristika | Příklad |
|---|---|---|
| 0 | RSS.app encoding artefakty | `U+FFFD` → `\n–` |
| 1 | Emoji oddělovač odstavců | `...realita 🏎️ Další...` → `...realita 🏎️\n\nDalší...` |
| 2 | Exclamation title | `Drama! Antonelli P1...` → `Drama!\n\nAntonelli P1...` |
| 3 | Vlajkový seznam | `: 🇧🇭 14. marc...` → `:\n\n🇧🇭 14. marc...` |
| 4 | Dash seznam | `Patří: - Bod 1 - Bod 2` → `Patří:\n- Bod 1\n- Bod 2` |
| 5 | Citace v uvozovkách | `...závodu. "Jsme spokojeni."` → `...závodu.\n\n"Jsme spokojeni."` |
| 6 | Dlouhý odstavec (>250 znaků) | split na větné hranici |
| 7 | Hashtag blok | `...dramaticky. #f1` → `...dramaticky.\n\n#f1` |

Oproti Instagramu: heuristiky 3–6 se u typického Threads postu
uplatňují méně (kratší text, méně hashtagů, méně vlajkových výčtů).

---

## 6. Profile sync

`ThreadsProfileSyncer` synchronizuje profil z `threads.net/@handle`
do Mastodon účtu.

### Co se synchronizuje

| Pole | Synchronizuje se |
|---|---|
| Bio/description | ✅ ano |
| Avatar | ✅ ano (CDN `cdninstagram.com`) |
| Banner/cover | ❌ Threads nemá |
| Website URL | ❌ Threads nepodporuje web URL na profilu |

### Implementační poznámky

- **Cookies nejsou potřeba** — Threads profily jsou veřejné.
  Browserless je potřeba pouze pro JS render stránky.
- **Bio obsahuje Unicode escape sekvence** (`\uXXXX`) — syncer je dekóduje
  interně (`decode_meta_json_string`).
- **Avatar CDN** je `scontent.cdninstagram.com` (sdílené s Instagramem).
  Download funguje bez speciálních hlaviček.
- Strategie extrakce avataru (v pořadí): `<img alt="[handle]'s profile picture">`,
  `og:image`, JSON `profile_pic_url_hd`/`profile_pic_url`.

### Konfigurace v source YAML

```yaml
profile_sync:
  enabled: true
  retention_days: 90
  social_profile:
    platform: threads
    handle: jirikostaf1
```

---

## 7. Konfigurace zdroje

Příklad minimální konfigurace Threads zdroje:

```yaml
id: jirikostaf1_threads
enabled: true
platform: rss

source:
  feed_url: "https://rss.app/feeds/FEED_ID.xml"

target:
  mastodon_account: jirikostaf1

scheduling:
  priority: normal
  max_posts_per_run: 5

filtering:
  banned_phrases: []
  required_keywords: []

profile_sync:
  enabled: true
  retention_days: 90
  social_profile:
    platform: threads
    handle: jirikostaf1

processing:
  content_replacements:
    - { pattern: "^.+?\\s+(Posted|shared|updated status)$", replacement: "", flags: "i", literal: false }
  url_domain_fixes: []
```

Výchozí hodnoty platformy jsou definovány v
[`config/platforms/threads.yml`](../../config/platforms/threads.yml).

---

## 8. Vztah k Instagramu

Threads a Instagram sdílí:

- Meta Graph API infrastrukturu
- CDN pro média (`cdninstagram.com`)
- Formát embedded JSON v HTML (`biography`, `profile_pic_url`, …)
- Stejné heuristiky pro rekonstrukci formátování
- RSS.app jako bridge pro čtení cizích účtů

Klíčové rozdíly:

| | Instagram | Threads |
|---|---|---|
| Primární obsah | obrázky/video | text |
| Max délka | 2400 znaků | 500 znaků |
| Cookies pro profile sync | ✅ potřeba | ❌ nepotřeba |
| Hashtagy | hojně | minimálně |
| Banner | ❌ | ❌ |

---

## 9. Omezení

- RSS.app je třetí strana — spolehlivost závisí na stabilním scraping API RSS.app.
- Threads API neumožňuje číst cizí účty — RSS.app je jediná dostupná cesta.
- Threads nepodporuje web URL na profilu — pole `web:` v Mastodon profilu
  se synchronizuje z existující hodnoty (nebo zůstane prázdné).
