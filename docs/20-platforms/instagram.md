# Instagram

## Platforma (orientace)

Instagram v kontextu ZBNW‑NG představuje:

- **Zdroj dat** – příspěvky přes RSS.app bridge
- **Integrační vrstvu** – `RssAdapter` s `InstagramProcessor` pro rekonstrukci captionů
- **Platform-specific chování** – caption rekonstrukce z embed kódu, cookies pro profile sync přes Browserless
- **Konfigurační jednotku** – definovanou v YAML (`config/sources/*.yml`)

Platforma je vždy vstupní bod systému, izolovaná adapterem a sjednocená do modelu `Post`.

---

Tento dokument popisuje **integraci platformy Instagram** do systému ZBNW‑NG.
Zaměřuje se na specifika obrazově orientované platformy, charakter obsahu
(Caption + média) a omezení, která z této povahy vyplývají.

Použité pojmy jsou definovány v [`../00-overview/terminologie.md`](../00-overview/terminologie.md).
Důvody architektonických rozhodnutí jsou popsány v [`../90-meta/decisions.md`](../90-meta/decisions.md).

Dokument popisuje **aktuální chování systému** a záměrně se vyhýbá historickým
incidentům, interním diskusím a privátním provozním podkladům.

---

## 1. Charakteristika platformy

Instagram je **image‑first sociální platforma**, kde hlavní nositel obsahu
tvoří:

- obrázky (single image / carousel)
- krátká videa

Text (caption) je sekundární a slouží převážně jako:

- doprovodný popis
- kontext k médiím
- nosič hashtagů a zmínek

Z pohledu ZBNW‑NG je Instagram zdrojem obsahu, kde **vizuální složka má
vyšší prioritu než struktura textu**.

---

## 2. Postavení Instagramu v architektuře

Instagram je v architektuře ZBNW‑NG považován za **samostatnou platformu**.

Instagram nemá veřejné API ani nativní RSS feed. Obsah je získáván přes **RSS feed generovaný agregátorem RSS.app** — konkrétní volba zprostředkovatele je implementační detail a není součástí platform‑specific dokumentace.

Zdroje Instagram mají v konfiguraci `platform: rss` a `rss_source_type: instagram`. `rss_source_type` aktivuje Instagram-specifické zpracování captionů (`InstagramProcessor`).

RSS feed zde slouží jako transportní vrstva. Z pohledu systému **není tato integrace považována za RSS platformu** — Instagram zůstává samostatnou platformou s vlastním adaptérem a konfigurací.

Toto rozdělení umožňuje:

- dlouhodobou stabilitu dokumentace
- nezávislost na konkrétní integrační technice

---

## 3. Získávání obsahu

Zpracování Instagram obsahu vychází z pravidelného zjišťování nových
příspěvků na sledovaných profilech.

Z pohledu systému:

- každý příspěvek je zpracován jako samostatná jednotka
- data jsou přijímána jako kombinace médií a textového popisu

Získávaná data typicky obsahují:

- caption (flattened text)
- jednu nebo více mediálních položek
- základní identitu autora

---

## 4. Charakteristika vstupních dat

Instagram data mají oproti textovým platformám výrazná omezení:

- ztráta původního formátování captionu
- absence explicitní struktury odstavců
- sloučení textu, emoji a hashtagů do jednoho bloku

ZBNW‑NG tyto vlastnosti považuje za **očekávaný stav vstupu**, nikoli chybu.

---

## 5. Heuristiky pro práci s captiony

RSS.app vrací Instagram caption jako **jeden plochý textový blok** bez odstavců — `InstagramProcessor` heuristicky rekonstruuje původní formátování.

Heuristiky se aplikují v pevném pořadí:

| # | Heuristika | Co dělá |
|---|---|---|
| 1 | Obnova odstavců | Emoji + mezera + velké písmeno → nový odstavec za emoji |
| 2 | Výkřičníkový titulek | První věta zakončená `!` → nadpis s odstavcem za ní |
| 3 | Vlajkový seznam | Vlajkové emoji jako seznam → každá vlajka na vlastní řádek |
| 4 | Bullet seznam | Slepené `- odrážky` → každá položka na vlastní řádek |
| 5 | Citace | Text v uvozovkách → vlastní odstavec |
| 6 | Dlouhý odstavec | Blok >250 znaků bez odstavce → split na větné hranici |
| 7 | Hashtag blok | Tag blok na konci (hashtagy + mentions) → vlastní odstavec; hashtagy na prvním řádku, mentions na druhém |

Heuristiky jsou best‑effort — navrženy tak, aby nezpůsobily selhání pipeline.
Detailní zdůvodnění viz [`decisions.md`](../90-meta/decisions.md) (ADR‑023).

### Mention handling

Instagram `@handle` v textu jsou přepsány na **plné URL profilu** (`https://www.instagram.com/handle/`) a `@` v textu je nahrazeno fullwidth `＠`. Mastodon by jinak interpretoval Instagram handle jako federovanou mention.

Handles s tečkou (`@kimi.antonelli`) jsou ošetřeny samostatně.

---

## 6. Mapování na interní model `Post`

Instagram příspěvky jsou mapovány na interní model `Post`.

Typické mapování:

- `text` – heuristicky upravený caption
- `media` – jedna nebo více mediálních položek
- `author` – identita zdrojového účtu

Model `Post` zde funguje jako **normalizační a stabilizační vrstva** pro
obrazově orientovaný obsah.

---

## 7. Vlákna a návaznosti

Instagram neposkytuje vláknovou strukturu odpovídající
reply‑based modelu.

ZBNW‑NG proto:

- publikuje každý Instagram příspěvek jako samostatný post
- nevytváří návaznosti mezi příspěvky
- neřeší komentářová vlákna

Každý příspěvek je považován za **atomickou jednotku obsahu**.

---

## 8. Editace obsahu

Instagram umožňuje editaci captionu po publikaci.

Zpracování editací:

- je omezené dostupností změněných dat
- nevztahuje se na média
- je řešeno v rámci standardní pipeline

Editace jsou považovány za **aktualizaci existujícího obsahu**,
nikoli za nový příspěvek.

---

## 9. Média

Média jsou **klíčovou složkou Instagram obsahu**.

Typická média:

- obrázky
- carousely
- video obsah

Zpracování médií:

- má vyšší prioritu než text
- je integrováno do jednotného mediálního zpracování pipeline

Cílem je publikovat konzistentní a validní výstup na cílovou platformu.

---

## 10. Profile sync

Instagram profily jsou synchronizovány přes **Browserless.io** (headless browser) s autentizací přes Instagram cookies (`IG_COOKIE_*` z ENV).

Synchronizuje se: avatar, bio, metadata pole. Banner Instagram neposkytuje.

Frekvence: 1× týdně — viz [`../40-tools/runtime.md`](../40-tools/runtime.md).

Aktivace je opt-in per source (`profile_sync.enabled: true`).

---

## 11. Konfigurace

### Platform defaults (`config/platforms/instagram.yml`)

```yaml
formatting:
  platform_emoji: "📸"

mentions:
  type: domain_suffix
  value: "instagram.com"

scheduling:
  priority: normal
  max_posts_per_run: 5

profile_sync:
  enabled: false
  sync_avatar: true
  sync_banner: false   # Instagram nemá cover photo
  sync_bio: true
  sync_fields: true
```

### Klíčové per-source parametry

| Parametr | Popis |
|---|---|
| `source.feed_url` | URL RSS.app feedu |
| `source.handle` | Instagram handle — povinné pro profile sync |
| `rss_source_type` | Musí být `instagram` pro aktivaci InstagramProcessor |
| `profile_sync.enabled` | Opt-in (default: false) |

---

## 12. Limity integrace

Známé architektonické limity Instagram integrace:

- ztráta původní struktury captionu
- omezená možnost detekce významových hranic v textu
- žádný real‑time push model

Tyto limity jsou:

- inherentní povaze platformy
- akceptované návrhem systému

---

## 13. Vztah k Threads

Meta provozuje Threads jako textový pendant Instagramu. Obě platformy
sdílí infrastrukturu (CDN, Meta Graph JSON), ale liší se v charakteru obsahu.

Threads integrace v ZBNW‑NG je popsána v [`threads.md`](threads.md).
`ThreadsProcessor` a `ThreadsProfileSyncer` jsou přímé deriváty
IG ekvivalentů — sdílí stejné heuristiky přes `SocialTextHeuristics`.

Klíčový rozdíl: Threads profily jsou **veřejné** — profile sync
nevyžaduje session cookies.

---

## 14. Shrnutí

Instagram integrace v ZBNW‑NG:

- zachází s Instagramem jako se samostatnou platformou
- upřednostňuje vizuální složku obsahu
- používá heuristiky ke zlepšení čitelnosti textu
- pracuje s redukovaným, ale stabilním modelem dat

Tím zůstává architektura ZBNW‑NG robustní a konzistentní
napříč rozdílnými typy platforem.

Všechny platformní rozdíly končí na hranici modelu `Post`, který je vstupem do jednotné pipeline.
