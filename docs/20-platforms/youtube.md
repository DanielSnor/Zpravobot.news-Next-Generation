# YouTube

Tento dokument popisuje **integraci platformy YouTube** do systému ZBNW‑NG.
Zaměřuje se na specifika práce s video‑centrickým obsahem, rozdíly oproti
textovým platformám a omezení, která z této povahy vyplývají.

Použité pojmy jsou definovány v [`../00-overview/terminologie.md`](../00-overview/terminologie.md).
Důvody architektonických rozhodnutí jsou popsány v [`../90-meta/decisions.md`](../90-meta/decisions.md).

Dokument popisuje **aktuální chování systému** a záměrně se vyhýbá historickým
incidentům, interním diskusím a privátním podkladům.

---

## 1. Charakteristika platformy

YouTube je **video‑first publikační platforma**, jejíž obsah je tvořen primárně:

- dlouhými i krátkými videi
- doprovodným textem (title, description)
- náhledovými obrázky

Na rozdíl od sociálních sítí orientovaných na text:

- video je vždy hlavním nositelem informace
- text slouží převážně jako kontext a metadata

---

## 2. Integrační model

Integrace YouTube v ZBNW‑NG je postavena na **polling modelu**.

Základní vlastnosti integrace:

- neexistují webhooky pro nové příspěvky
- obsah je získáván periodickým pollingem veřejného **RSS/Atom feedu kanálu**
- nevyžaduje autentizaci ani YouTube Data API klíč

RSS/Atom feed zde slouží jako transportní vrstva. YouTube je přesto považován za **samostatnou platformu** kvůli odlišné povaze obsahu (video‑first) a specifickému modelu mapování na `Post`.

Konfigurace zdroje vyžaduje `channel_id` kanálu — přímá rezoluce YouTube handle je blokována YouTube CDN a není spolehlivá.

Integrace je navržena tak, aby:

- detekovala nové publikované položky
- minimalizovala duplicitní zpracování
- nezávisela na autentizaci ani YouTube Data API klíči

---

## 3. Získávání obsahu

Zpracování YouTube obsahu vychází z **Atom feedu kanálu**, který YouTube veřejně poskytuje.

Feed URL se tvoří z `channel_id`:

| Varianta | Feed URL |
|---|---|
| Všechna videa | `https://www.youtube.com/feeds/videos.xml?channel_id={UC...}` |
| UULF (bez Shorts) | `https://www.youtube.com/feeds/videos.xml?playlist_id={UULF...}` |
| Konkrétní playlist | `https://www.youtube.com/feeds/videos.xml?playlist_id={PL...}` |

### media:group parsing

YouTube Atom feed obsahuje `media:group` namespace s rozšířenými metadaty. `YouTubeAdapter` parsuje XML dvakrát:
1. Standardní `RSS::Parser` pro základní strukturu (title, link, pubDate)
2. `REXML` pro `<media:group>` namespace — získá description, thumbnail URL (nejvyšší kvalita), views count

### Video ID extrakce

Video ID se extrahuje v tomto pořadí:
1. `yt:videoId` element
2. Z entry ID (formát `yt:video:VIDEO_ID`)
3. Z URL (`watch?v=`, `/shorts/`, `youtu.be/`)

### Thumbnail fallback

```
# Preferovaná: z media:thumbnail (nejvyšší dostupná kvalita)
https://i.ytimg.com/vi/{VIDEO_ID}/maxresdefault.jpg

# Fallback: standardní kvalita
https://i.ytimg.com/vi/{VIDEO_ID}/hqdefault.jpg
```

### Ranní maintenance window

YouTube RSS API má pravidelný ranní výpadek (~05:00–09:00 CET). Adapter to řeší:
- Parametr `skip_hours: [5, 6, 7, 8]` v platform defaults — orchestrátor přeskočí YouTube zdroje v těchto hodinách
- HTTP 404/500/502/503 od YouTube jsou logovány jako WARN (ne ERROR) a **nesčítají se** do `error_count` zdroje

Typicky získávaná data zahrnují:

- identifikátor videa
- název videa
- popis videa (z `media:description`)
- URL videa
- náhledový obrázek (z `media:thumbnail`)
- počet zhlédnutí (z `media:statistics`)

Obsah videa samotného (stream) **není zpracováván**.

---

## 4. Mapování na interní model `Post`

YouTube videa jsou mapována na interní model `Post`.

Základní mapování:

- `text` je tvořen kombinací title a description
- `url` odkazuje na video
- `media` obsahuje náhled (thumbnail)

Model `Post` zde slouží jako:

- reprezentace jednoho video‑příspěvku
- vstup do standardní pipeline zpracování

---

## 5. Vlákna a návaznosti

YouTube **neposkytuje vláknovou strukturu** srovnatelnou s textovými platformami.

ZBNW‑NG proto:

- publikuje každé video jako samostatný post
- nevytváří reply chain
- neřeší hierarchii komentářů

Každé video je z pohledu systému **atomická jednotka obsahu**.

---

## 6. Editace obsahu

YouTube umožňuje:

- změnu názvu videa
- změnu popisu videa

Tyto změny jsou v ZBNW‑NG považovány za:

- potenciální aktualizaci již publikovaného obsahu

Zpracování editací:

- probíhá v rámci běžné pipeline
- je omezeno na změny metadat
- netýká se samotného video obsahu

---

## 7. Média

YouTube integrace pracuje s médii v omezené podobě.

Zpracovávaná média:

- náhledový obrázek videa

Nezpracovávaná média:

- samotné video soubory

Toto rozhodnutí:

- udržuje pipeline jednoduchou
- eliminuje vysoké nároky na úložiště a přenosy

---

## 8. Filtrování Shorts

YouTube Shorts (krátká videa) lze vyfiltrovat přes **UULF playlist**.

YouTube automaticky spravuje dva typy playlistů pro každý kanál:

| Prefix | Obsah |
|---|---|
| `UC…` | Všechna videa (včetně Shorts a livestreamů) |
| `UULF…` | Pouze long-form videa (bez Shorts a livestreamů) |

Per-source konfigurace `content.no_shorts: true` přepne feed URL na UULF playlist.

I při použití UULF mohou Shorts ojediněle proniknout — adaptér detekuje jejich přítomnost v URL (`/shorts/`) pro případné logování.

---

## 9. Profile sync

YouTube profily jsou synchronizovány přes **Browserless.io** (headless browser). Důvodem je EU GDPR consent redirect, který blokuje přímé HTTP stažení profilu.

Synchronizuje se: avatar, banner, bio, metadata pole.

---

## 10. Konfigurace

### Platform defaults (`config/platforms/youtube.yml`)

```yaml
formatting:
  platform_emoji: "▶️"
  move_url_to_end: false

mentions:
  type: none

processing:
  max_length: 2400
  trim_strategy: smart

scheduling:
  priority: normal
```

### Klíčové per-source parametry

| Parametr | Popis |
|---|---|
| `source.channel_id` | YouTube Channel ID (povinné) |
| `source.playlist_id` | Konkrétní playlist místo celého kanálu |
| `content.no_shorts` | `true` = použít UULF playlist (filtruje Shorts) |
| `content.description_lines` | Max počet řádků popisu videa |

---

## 11. Limity integrace

Známé architektonické limity YouTube integrace:

- žádný real‑time push model
- závislost na periodickém pollingu
- omezená granularita změn obsahu

Tyto limity jsou:

- inherentní povaze platformy
- zohledněné v plánování běhu systému

---

## 12. Shrnutí

YouTube integrace v ZBNW‑NG:

- je odlišná od textových platforem
- považuje video za primární obsah
- používá zjednodušený integrační model
- minimalizuje rozsah zpracovávaných médií

Díky tomu zůstává integrace YouTube stabilní a provozně nenáročná
v rámci celkové architektury ZBNW‑NG.

Všechny platformní rozdíly končí na hranici modelu `Post`, který je vstupem do jednotné pipeline.
