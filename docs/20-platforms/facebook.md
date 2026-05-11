# Facebook

## Platforma (orientace)

Facebook v kontextu ZBNW‑NG představuje:

- **Zdroj dat** – příspěvky přes RSS.app bridge (veřejné stránky)
- **Integrační vrstvu** – `RssAdapter` s `FacebookProcessor` pro platformně-specifické filtrování
- **Platform-specific chování** – filtrování systémových postů (cover photo, check-in…), link cards
- **Konfigurační jednotku** – definovanou v YAML (`config/sources/*.yml`)

Platforma je vždy vstupní bod systému, izolovaná adapterem a sjednocená do modelu `Post`.

---

Tento dokument popisuje **integraci platformy Facebook** do systému ZBNW‑NG.
Zaměřuje se na vlastnosti platformy jako zdroje obsahu, způsob dosažení dat
v současné architektuře a omezení, která z této kombinace vyplývají.

Použité pojmy jsou definovány v [`../00-overview/terminologie.md`](../00-overview/terminologie.md).
Důvody architektonických rozhodnutí jsou popsány v [`../90-meta/decisions.md`](../90-meta/decisions.md).

Dokument popisuje **aktuální chování systému** a záměrně se vyhýbá historickým
incidentům, interním diskusím a jakýmkoli privátním provozním podkladům.

---

## 1. Charakteristika platformy

Facebook je **sociální platforma orientovaná na kombinaci textu,
odkazů a médií**, používaná jak jednotlivci, tak institucemi.

Typické vlastnosti obsahu:

- textové příspěvky různé délky
- externí odkazy (články, weby)
- obrázky a galerie
- kombinace textu a odkazu

Z pohledu ZBNW‑NG je Facebook zdrojem **kurátorovaného obsahu**, často
směřujícího mimo samotnou platformu.

---

## 2. Postavení Facebooku v architektuře

Facebook je v architektuře ZBNW‑NG považován za **samostatnou platformu**.

Facebook nemá veřejné API ani nativní RSS feed. Obsah je získáván přes **RSS feed generovaný agregátorem RSS.app** — konkrétní volba zprostředkovatele je implementační detail a nemění charakter Facebooku jako zdroje.

Zdroje Facebook mají v konfiguraci `platform: rss` a `rss_source_type: facebook`. `rss_source_type` aktivuje Facebook-specifické zpracování textu (`FacebookProcessor`) a správné filtrování obsahu.

RSS feed zde slouží jako transportní vrstva. Z pohledu systému **není tato integrace považována za RSS platformu** — Facebook zůstává samostatnou platformou s vlastním formátovacím a zpracovatelským chováním.

Toto rozlišení:

- umožňuje dlouhodobou stabilitu dokumentace
- odděluje vlastnosti platformy od aktuální integrační techniky

---

## 3. Získávání obsahu

Zpracování Facebook obsahu vychází z periodického zjišťování nových příspěvků
na sledovaných stránkách nebo profilech.

Z pohledu systému:

- detekce nového obsahu je oddělená od jeho zpracování
- data jsou přijímána jako **zjednodušený textový a mediální popis příspěvku**

Získávaná data typicky obsahují:

- text příspěvku (flattened)
- odkaz (pokud je součástí postu)
- obrázky nebo náhledy

---

## 4. Charakteristika vstupních dat

Facebook data mají oproti nativním API výrazná omezení.

Typické vlastnosti vstupu:

- ztráta původního formátování textu
- omezená informace o struktuře příspěvku
- chybějící metadata o interakcích

ZBNW‑NG s tímto stavem pracuje jako s **normálním a očekávaným vstupem**,
nikoli jako s chybovým stavem.

---

## 5. Mapování na interní model `Post`

Facebook příspěvky jsou mapovány na interní model `Post`.

Typické mapování:

- `text` – text příspěvku
- `url` – externí odkaz (je‑li k dispozici)
- `media` – obrázky nebo náhledy
- `author` – identita zdrojové stránky

Model `Post` zde slouží jako **normalizační vrstva**,
nikoli jako plnohodnotná reprezentace původního příspěvku.

---

## 6. Vlákna a návaznosti

Facebook **neposkytuje vláknovou strukturu** vhodnou pro přímé mapování
na Mastodon reply chain.

ZBNW‑NG proto:

- publikuje každý Facebook příspěvek jako samostatný post
- nevytváří návaznosti mezi příspěvky
- neřeší komentátová vlákna

Každý příspěvek je z pohledu systému **samostatná jednotka obsahu**.

---

## 7. Editace obsahu

Facebook umožňuje editaci příspěvků po publikaci.

ZBNW‑NG tyto změny:

- může detekovat
- může je považovat za aktualizaci existujícího obsahu

Rozsah editací je omezený dostupností vstupních dat
a je zpracováván v rámci standardní pipeline.

---

## 8. Média

Facebook příspěvky často obsahují:

- jednu nebo více fotografií
- náhled odkazu

Zpracování médií:

- je součástí jednotného mediálního řešení pipeline
- nevyužívá žádná Facebook‑specifická API

Cílem je publikovat **validní a čitelný výstup** na cílové platformě.

---

## 9. Zpracování textu

Facebook RSS.app feedy mají specifický problém: pro Reels (a některé standardní posty) vrací RSS.app identický text v `<title>` i `<description>`. `RssFormatter` v combined mode by pak vytvořil duplikát:

```
Text příspěvku — Text příspěvku
```

`FacebookProcessor` tento vzor detekuje a vrátí pouze jednu verzi (delší). Detekce duplikátu kombinuje: přesnou shodu, prefix shodu a Jaccard podobnost slov.

Procesor se aktivuje automaticky pro zdroje s `rss_source_type: facebook`.

---

## 10. Mentions a profile card

Facebook zdroje mají **mentions transformaci nastavenou na `domain_suffix`** (`@handle@facebook.com`). Tím nevzniká klikatelný Mastodon profil, ale zabraňuje se zobrazení nežádoucí profile card u postů bez příloh.

---

## 11. Profile sync

Facebook profily jsou synchronizovány přes **Browserless.io** (headless browser), který scrapuje veřejnou stránku profilu včetně sekce `/about`.

Synchronizuje se: avatar (profilový obrázek), banner (cover photo), bio, metadata pole.

Frekvence: 1× týdně — viz [`../40-tools/runtime.md`](../40-tools/runtime.md).

---

## 12. Konfigurace

### Platform defaults (`config/platforms/facebook.yml`)

```yaml
formatting:
  platform_emoji: "📘"

mentions:
  type: domain_suffix
  value: "facebook.com"

scheduling:
  priority: normal
  max_posts_per_run: 5

profile_sync:
  enabled: false       # opt-in per source
  sync_avatar: true
  sync_banner: true
  sync_bio: true
  sync_fields: true
```

### Klíčové per-source parametry

| Parametr | Popis |
|---|---|
| `source.feed_url` | URL RSS.app feedu |
| `source.handle` | Facebook handle — povinné pro profile sync |
| `rss_source_type` | Musí být `facebook` pro aktivaci FacebookProcessor |
| `profile_sync.enabled` | Opt-in (default: false) |

---

## 13. Limity integrace

Známé architektonické limity Facebook integrace:

- omezená strukturovanost vstupních dat
- ztráta původního formátu a kontextu
- žádný real‑time push model

Tyto limity jsou:

- inherentní povaze platformy a zvolenému integračnímu kanálu
- akceptované návrhem systému

---

## 14. Shrnutí

Facebook integrace v ZBNW‑NG:

- zachází s Facebookem jako se samostatnou platformou
- abstrahuje způsob získávání dat jako implementační detail
- pracuje s redukovaným, ale stabilním modelem obsahu
- preferuje konzistentní chování systému před úplností dat

Tím zůstává architektura ZBNW‑NG robustní i při změnách
integračních mechanismů nebo chování platformy Facebook.

Všechny platformní rozdíly končí na hranici modelu `Post`, který je vstupem do jednotné pipeline.
