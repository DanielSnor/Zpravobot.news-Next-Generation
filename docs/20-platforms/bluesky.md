# Bluesky

## Platforma (orientace)

Bluesky v kontextu ZBNW‑NG představuje:

- **Zdroj dat** – příspěvky z AT Protocolu přes veřejné API
- **Integrační vrstvu** – `BlueskyAdapter` převádí data na `Post`
- **Platform-specific chování** – vlákna, replies, AT URI threading, delete+repost místo editací
- **Konfigurační jednotku** – definovanou v YAML (`config/sources/*.yml`)

Platforma je vždy vstupní bod systému, izolovaná adapterem a sjednocená do modelu `Post`.

---

Tento dokument popisuje **integraci platformy Bluesky** do systému ZBNW‑NG.
Zaměřuje se na technický model integrace, strukturu dat a rozdíly oproti jiným
sociálním platformám.

Použité pojmy jsou definovány v [`../00-overview/terminologie.md`](../00-overview/terminologie.md).
Důvody architektonických rozhodnutí jsou popsány v [`../90-meta/decisions.md`](../90-meta/decisions.md).

Dokument popisuje **aktuální chování systému** a záměrně se vyhýbá historickým
incidentům, interním diskusím a privátním podkladům.

---

## 1. Charakteristika platformy

Bluesky je **decentralizovaná sociální platforma** postavená na
**AT Protocolu**.

Z pohledu ZBNW‑NG se Bluesky vyznačuje zejména:

- dobře strukturovaným veřejným API
- explicitní podporou vláken
- konzistentním datovým modelem
- absencí editací již publikovaných postů

Oproti Twitter/X poskytuje Bluesky **čistší a úplnější vstupní data**.

---

## 2. Integrační model

Integrace Bluesky v ZBNW‑NG je realizována **přímo pomocí AT Protocol API**.

Základní vlastnosti:

- není využíván RSS feed ani webhooky třetích stran
- data jsou získávána přímo z veřejných API endpointů
- systém pracuje ve dvou zdrojových módech

Tento model umožňuje:

- jednotný způsob získávání obsahu
- deterministické chování integrace
- minimální potřebu fallback mechanismů

> Bluesky je v ZBNW‑NG **jak zdrojem, tak cílem publikace** — viz sekci 8.

---

## 3. Získávání obsahu

Bluesky adaptér pracuje ve dvou módech:

| Mód | AT Protocol endpoint | Kdy se použije |
|---|---|---|
| **Profile feed** | `app.bsky.feed.getAuthorFeed` | Sledování konkrétního uživatelského účtu |
| **Custom feed** | `app.bsky.feed.getFeed` | Sledování tematického feed generátoru |

Oba módy poskytují strukturovaná JSON data. Získávaná data typicky obsahují:

- plný text postu
- metadata o autorovi
- reference na předchozí části vlákna (`reply.parent.uri`, `reply.root.uri`)
- strukturovaný popis médií

Díky tomu není nutná dodatečná rekonstrukce obsahu — Bluesky API vrací data kompletní.

---

## 4. Mapování na interní model `Post`

Bluesky posty jsou mapovány na interní objekt `Post`.

Mapování je zpravidla přímé a kompletní, zejména pro:

- `id`
- `text`
- `url`
- `author`
- `media`
- příznaky reply / repost

Model `Post` je zde využit jako **sjednocující mezivrstva**, nikoli jako
kompenzace chybějících dat.

---

## 5. Formátování výstupu

`BlueskyFormatter` transformuje `Post` na text pro Mastodon. Výstupní formát závisí na typu postu:

| Typ postu | Prefix | Příklad hlavičky |
|---|---|---|
| Standardní post (feed zdroj) | — | `Jméno Autora (@handle.bsky.social) 🦋:` |
| Repost | `🦋🔁` | `🦋🔁 Jméno Autora:` |
| Citace | `🦋💬` | `🦋💬 Jméno Autora cituje svůj post:` |
| Vlákno (thread) | — | text + `🧵` na konci |

Mentions transformace: Bluesky `@handle.bsky.social` → `https://bsky.app/profile/handle.bsky.social` (type `prefix` v platform defaults).

---

## 6. Vlákna (Threading)

Bluesky poskytuje **explicitní informace o vláknové struktuře**.

Každý post může obsahovat:

- `reply.parent.uri` – odkaz na bezprostředního parenta
- `reply.root.uri` – odkaz na kořen vlákna

### Self-reply detection

ZBNW‑NG detekuje **self-reply** (vlastní vlákno autora) porovnáním DID autorů:

```ruby
parent_did = extract_did_from_uri(reply.dig('parent', 'uri'))
author_did = author_data['did']
is_self_reply = parent_did == author_did
```

AT URI má formát `at://did:plc:xxx/app.bsky.feed.post/rkey` — DID je fixní identifikátor účtu v AT Protocolu.

### Konfigurace threading

| Parametr | Hodnota | Chování |
|---|---|---|
| `include_self_threads: false` | API: `posts_no_replies` | Jen samostatné posty |
| `include_self_threads: true` | API: `posts_and_author_threads` | Posty + self-replies |

Profile feed (sledování účtu) threading zapíná; custom feed threading vypíná.

### DB schema pro threading

`published_posts.platform_uri` uchovává AT URI publikovaného postu.
Při zpracování navazujícího dílu vlákna systém vyhledá Mastodon `status_id` podle `platform_uri` a publikuje s `in_reply_to_id`.

Threading u Bluesky je považován za **spolehlivý a deterministický**.

---

## 7. Editace obsahu — delete+repost vzor

Bluesky **nativně nepodporuje editaci** (AT Protocol neumožňuje měnit existující záznamy).

V praxi však autoři editace emulují:

1. publikují post s chybou
2. smažou ho
3. publikují opravenou verzi s novým ID

Pokud ZBNW‑NG zpracuje první verzi před smazáním, vznikne duplicita. Proto je pro Bluesky aktivní **EditDetector**.

### Jak EditDetector funguje

- porovnává nový post s nedávno publikovanými (okno 1 hodiny)
- používá Jaccard + Containment podobnost (práh 80 %)
- při nalezení podobného postu → UPDATE existujícího Mastodon statusu

### Bluesky TID

Bluesky ID (`3lhtptd7apc2i`) je **base32 string**, nikoli číselné Snowflake ID.
EditDetector detekuje formát automaticky a používá lexikografické porovnání (ne numerické).

Příklad z logu:
```
[EditDetector] Similar post found: 3lhtqwe1abc2j ~ 3lhtptd7apc2i (83.6%)
[denikn_bluesky] Detected edit: updates 3lhtptd7apc2i → UPDATE Mastodon
```

---

## 8. Média

Bluesky posty mohou obsahovat:

- obrázky
- video náhledy
- další mediální embed struktury

Média jsou poskytována jako:

- samostatné entity
- s jasnými metadaty a MIME typy

To umožňuje spolehlivé zpracování v mediálních krocích pipeline.

---

## 9. Bluesky jako cíl publikace

Vedle role zdroje dat slouží Bluesky v ZBNW‑NG také jako **doplňkový cíl publikace**.

`BlueskyPublisher` publikuje paralelně s Mastodonem v těchto doplňkových subsystémech:

| Subsystém | Co publikuje |
|---|---|
| Stats / Reporting | Týdenní statistiky účtů |
| Trending | Trending posty + AI komentář |
| Friendly Follow | Doporučení sledovaných účtů (vlákno per účet, ≤300 grafémů) |
| Source Report | Přehled přidaných/odebraných zdrojů |

Klíčové vlastnosti `BlueskyPublisher`:

- **není součástí hlavní pipeline** — cross-posting běží pouze v doplňkových cron skriptech
- při auth selhání vrátí `nil` a přeskočí Bluesky publikaci — Mastodon publikace proběhne vždy
- URL text limit: 300 grafémů (ne bytes); delší texty jsou automaticky chunkovány do vlákna
- Mastodon `@handle@instance` mentions jsou konvertovány na URL (Bluesky federovaným handles nerozumí)

Tato architektura odpovídá ADR‑031 (Bluesky mimo hlavní pipeline).

---

## 10. Profile sync

Bluesky profily jsou synchronizovány **1× týdně** přes nativní AT Protocol API.

Synchronizuje se: avatar, banner, bio a metadata pole Mastodon profilu.

Nativní API (na rozdíl od Nitteru u Twitteru) znamená stabilní a spolehlivou synchronizaci.

---

## 11. Konfigurace

### Platform defaults (`config/platforms/bluesky.yml`)

```yaml
filtering:
  skip_replies: true
  skip_retweets: false
  skip_quotes: false

formatting:
  platform_emoji: "🦋"
  prefix_repost: "🦋🔁"
  prefix_quote: "🦋💬"
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

### Klíčové per-source parametry

| Parametr | Popis |
|---|---|
| `source.handle` | Bluesky handle (profile mód) |
| `source.feed_url` | URL custom feed generátoru (custom feed mód) |
| `profile_sync.enabled` | Zapnutí profile syncu |

---

## 12. Limity integrace

Známé limity Bluesky integrace:

- závislost na stabilitě AT Protocol API
- případné změny schémat odpovědí API

Tyto limity jsou:

- monitorovatelné
- řešitelné úpravou adaptéru
- izolované mimo core pipeline

---

## 13. Shrnutí

Bluesky integrace v ZBNW‑NG:

- je nejčistší a nejpřímočařejší ze všech platforem
- poskytuje kompletní a strukturovaná vstupní data
- vyžaduje minimum fallback logiky
- podporuje plnohodnotné vláknování

Díky tomu slouží Bluesky jako **referenční implementace integrace platformy**
v architektuře ZBNW‑NG.

Všechny platformní rozdíly končí na hranici modelu `Post`, který je vstupem do jednotné pipeline.
