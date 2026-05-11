# Twitter / X

## Platforma (orientace)

Twitter/X v kontextu ZBNW‑NG představuje:

- **Zdroj dat** – tweety přes IFTTT webhook nebo Nitter RSS polling
- **Integrační vrstvu** – `TwitterAdapter` / `TwitterNitterAdapter` s 5-tierovým fallbackem
- **Platform-specific chování** – vlákna, editace, retweets, quotes, hybridní enrichment (Nitter + Syndication API)
- **Konfigurační jednotku** – definovanou v YAML (`config/sources/*.yml`)

Platforma je vždy vstupní bod systému, izolovaná adapterem a sjednocená do modelu `Post`.

---

Tento dokument popisuje **integraci platformy Twitter/X** do systému ZBNW‑NG.
Zaměřuje se na technický model integrace, specifika dat a chování systému při
zpracování obsahu z této platformy.

Použité pojmy jsou definovány v [`../00-overview/terminologie.md`](../00-overview/terminologie.md).
Důvody konkrétních architektonických voleb jsou popsány v [`../90-meta/decisions.md`](../90-meta/decisions.md).

Provozní problémy a diagnostika jsou popsány v [`../50-operations/troubleshooting.md`](../50-operations/troubleshooting.md).

---

## 1. Charakteristika platformy

Twitter/X je **dynamická, vysoce frekvenční textová platforma** se silným důrazem na:

- krátké textové příspěvky
- vláknovou strukturu (self‑reply chains)
- editace obsahu po publikaci
- časté znovupublikování stejného obsahu

Z pohledu ZBNW‑NG je Twitter/X **nejkomplexnější platforma pro ingest**,
protože kombinuje vysokou variabilitu obsahu, omezenou dostupnost dat
bez oficiálního API a nutnost fallback chování.

---

## 2. Integrační model

Z pohledu platformy je Twitter/X integrován kombinací **trigger a enrichment vrstvy**.

Trigger vrstva má **dva alternativní vstupní kanály**:

| Vrstva | Komponenta | Role | Kdy se použije |
|---|---|---|---|
| Trigger (push) | IFTTT | Push notifikace o novém obsahu | Zdroje s IFTTT appletem |
| Trigger (pull) | Nitter RSS | Periodický polling RSS feedu | Zdroje bez IFTTT; menší projekty |
| Enrichment | Nitter (integrační nástroj) | Kompletní data — plný text, vlákna, média | Pokud `nitter_processing: true` |
| Enrichment | Syndication API | Média bez vlastní infrastruktury | Alternativa nebo fallback |

Základní principy:

- platforma negarantuje plnohodnotný přístup k datům bez oficiálního API
- každý tweet dorazí přes jeden z trigger kanálů, obohacení proběhne podle konfigurace a dostupnosti
- **po vstupu do systému je zpracování obou cest identické** — Tier logika, pipeline, publikování
- downstream zpracování je sjednoceno na úrovni `Post`

Podrobné odůvodnění tohoto modelu je v [`decisions.md`](../90-meta/decisions.md) (ADR‑015, ADR‑017, ADR‑021).

---

## 3. Vstupní kanály

### 3.1 IFTTT webhook a fronta

Twitter/X data přicházejí do systému přes **IFTTT webhook**.

Architektura vstupního kanálu:

```
Twitter API
    │
    ▼
  IFTTT  ──webhook──▶  Webhook Server
                              │
                              ▼
                        Fronta (pending/)
                              │
                              ▼
                      Queue Processor
                              │
                    TwitterTweetProcessor
                    (Tier logika + pipeline)
```

Charakteristiky:

- IFTTT detekuje nové tweety a doručí payload na webhook server
- webhook server data přijme a uloží do fronty (persistentní buffer)
- queue processor frontu periodicky zpracovává
- v tomto kroku dochází k volbě Tieru a případnému enrichmentu

Každý IFTTT zdroj (`bot_id`) je párován s YAML konfigurací zdroje. Toto párování
je klíčové pro správné směrování webhooků — `bot_id` v payloadu musí odpovídat
hodnotě `id:` ve zdrojovém YAML.

Tato architektura se označuje jako **queue-based webhook pipeline** — viz
[`../40-tools/integration.md`](../40-tools/integration.md).

### 3.2 Nitter RSS polling

Alternativní vstupní kanál bez IFTTT — systém **periodicky polluje Nitter RSS feed** zdroje.

```
Nitter instance
    │  (RSS feed)
    ▼
TwitterNitterAdapter
    │
    ▼
TwitterTweetProcessor
(Tier logika + pipeline)
```

Charakteristiky:

- funguje jako pull model — stejně jako ostatní RSS‑based platformy
- vhodné pro menší projekty (desítky zdrojů) nebo zdroje bez IFTTT appletu
- žádná závislost na IFTTT infrastruktuře
- mírně vyšší latence oproti IFTTT push (dáno intervalem pollingu)

**Po vstupu do systému je zpracování identické s IFTTT cestou** — volba Tieru,
enrichment, Tier logika, pipeline, publikování.

### IFTTT payload struktura

IFTTT applet posílá JSON body s těmito poli:

```json
{
  "text": "<<<{{Text}}>>>",
  "embed_code": "<<<{{TweetEmbedCode}}>>>",
  "link_to_tweet": "{{LinkToTweet}}",
  "first_link_url": "{{FirstLinkUrl}}",
  "username": "{{UserName}}",
  "bot_id": "nazev_z_yaml_konfigurace"
}
```

| Pole | Obsah |
|---|---|
| `text` | Text tweetu — `<<<>>>` chrání JSON před speciálními znaky |
| `embed_code` | HTML embed kód (detekce médií: `pbs.twimg.com/media` = obrázek) |
| `link_to_tweet` | URL tweetu (zdroj tweet ID) |
| `first_link_url` | První odkaz v tweetu (detekce obrázků/videí) |
| `username` | Twitter username (vyplní IFTTT automaticky) |
| `bot_id` | Statický string — přesně odpovídá hodnotě `id:` v source YAML |

**`bot_id` routing:** Systém hledá YAML konfiguraci v pořadí: explicitní `bot_id` → username → handle fallback → aggregator fallback. Nesprávný `bot_id` způsobí, že post skončí na fallback aggregátoru bez filtrů.

**Více appletů pro jeden účet:** Každý applet musí mít unikátní `bot_id` — umožňuje paralelní sledování jednoho Twitter účtu s různými filtry (např. `ct24_twitter` a `ct24_vystrahy_twitter`).

---

## 4. Pětistupňový Tier systém

Zpracování každého tweetu probíhá v jednom z pěti Tierů, které se liší
zdrojem dat, dostupností médií a počtem HTTP požadavků.

| Tier | Zdroj dat | Média | Plný text | Kdy se použije |
|---|---|---|---|---|
| **1** | IFTTT | ❌ | ✅ krátký | `nitter_processing: true` + krátký tweet bez médií |
| **1.5** | Syndication API | ✅ mp4/foto | ⚠️ možná zkrácený | `nitter_processing: false` |
| **2** | Nitter + Syndication | ✅ mp4/foto | ✅ | `nitter_processing: true` + média/dlouhý text/RT/vlákno |
| **3.5** | Syndication API | ✅ mp4/foto | ⚠️ možná zkrácený | fallback po selhání Nitteru |
| **3** | IFTTT | ❌ | ⚠️ zkrácený | finální fallback (Nitter i Syndication selhaly) |

> Detailní zdůvodnění fallback modelu a volby jednotlivých Tierů viz [`decisions.md`](../90-meta/decisions.md) (ADR‑015, ADR‑021).

### Rozhodovací logika (pro `nitter_processing: true`)

Systém zvolí Tier 2 pokud tweet:
- je retweet (IFTTT zkracuje RT)
- je self‑reply (součást vlákna)
- obsahuje obrázky nebo video
- má zkrácený text (≥ 257 znaků bez přirozeného zakončení nebo s `…`)

Ve všech ostatních případech zvolí Tier 1.

### `nitter_processing` konfigurace

| Nastavení | Výchozí Tier | Typické použití |
|---|---|---|
| `enabled: true` (default) | Tier 1 nebo 2 dle rozhodovací logiky | zpravodajské zdroje, Twitter Blue účty, vlákna |
| `enabled: false` | Tier 1.5 (Syndication) | high‑volume zdroje, sportovní boty, zdroje kde média > text |

Při `nitter_processing: false` odpadá závislost na Nitter instanci a klesá počet
HTTP požadavků, ale systém nezíská plný text pro Twitter Blue tweety.

### Syndication API

Twitter Syndication API je neoficiální endpoint používaný pro embed widgety.
ZBNW‑NG ho využívá jako:

- **Tier 1.5** — primární zdroj pro `nitter_processing: false`
- **Tier 3.5** — záchranný fallback po výpadku Nitteru
- **Video enrichment** — v Tier 2 doplní přehratelné mp4 pokud Nitter poskytl jen thumbnail

Limitace Syndication API: neoficiální; pro Twitter Blue tweety text zkracuje na ~280 znaků; bez thread kontextu.

---

## 5. Získávání obsahu

Získávání Twitter/X obsahu probíhá vícefázově.

Z pohledu architektury:

- systém obdrží informaci o existenci nového postu (IFTTT)
- podle konfigurace a zvoleného Tieru se pokusí získat kompletní kontext
- získaná data jsou sjednocena do modelu `Post`

Ne všechny vstupy poskytují:

- kompletní text
- všechna média
- informace o vláknech

Integrace je proto navržena tak, aby:

- maximálně využila dostupná data
- degradovala kvalitu obsahu řízeným způsobem
- **nikdy nezablokovala celý běh systému**

---

## 6. Mapování na interní model `Post`

Bez ohledu na Tier jsou Twitter/X příspěvky mapovány na jednotný objekt `Post`.

Typicky vyplňované atributy zahrnují:

- `id`
- `text`
- `url`
- `author`
- `media`
- příznaky typů postů (`is_reply`, `is_repost`, `is_quote`, `is_thread_post`)

Ne všechny atributy jsou vždy dostupné.
Model `Post` je proto navržen tak, aby:

- měl rozumné default hodnoty
- umožňoval downstream zpracování i při částečných datech

---

## 7. Vlákna (Threading)

Twitter/X vlákna nejsou poskytována ve strukturované podobě.

ZBNW‑NG k nim přistupuje jako k:

- sekvenci samostatných postů
- které mohou, ale nemusí tvořit souvislý řetězec

Výsledkem může být:

- plně rekonstruované vlákno
- částečné vlákno
- samostatný post bez návazností

Z hlediska architektury:

- threading je best‑effort
- případné nespojení vlákna není považováno za chybu
- systém preferuje publikaci neúplného obsahu před jeho ztrátou

Threading vyžaduje `nitter_processing: true` — Syndication API thread context neposkytuje.

---

## 8. Editace obsahu

Twitter/X umožňuje editaci již publikovaných postů do 1 hodiny od zveřejnění.

IFTTT zachytí jak původní tweet, tak editovanou verzi jako samostatné triggery.
Bez detekce by systém publikoval obě verze jako nezávislé posty.

ZBNW‑NG s editacemi pracuje takto:

- `EditDetector` porovnává obsah nově příchozího tweetu s bufferem posledních publikací
- při detekci podobnosti ≥ 80 % je tweet označen jako editace

Strategie aktualizace závisí na přítomnosti médií:

| Situace | Akce |
|---|---|
| Editace bez médií | `UPDATE` — Mastodon edit (zachová historii verzí) |
| Editace s médii | `DELETE` + `PUBLISH` — Mastodon Update API neumožňuje změnu médií |

Detekce editací probíhá v rámci queue pipeline a je oddělena od běžné deduplikace.
Konkrétní prahy a TTL bufferu jsou popsány v [`decisions.md`](../90-meta/decisions.md) (ADR‑012, ADR‑013).

---

## 9. Média

Twitter/X posty mohou obsahovat obrázky, videa nebo jejich kombinace.

Specifika práce s médii:

- obrázky jsou stahovány přímo z Nitteru nebo přes Syndication API
- videa jsou obohacena o přehratelné mp4 (Tier 2 video enrichment, Tier 1.5)
- kombinace více než 4 médií je ořezána (limit Mastodon API)
- pokud post obsahuje video, obrázky jsou zahozeny (Mastodon odmítá mixed-media)

---

## 10. Formátování výstupu

`TwitterFormatter` transformuje `Post` na text pro Mastodon. Výstupní formát závisí na typu postu:

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

**Video (Tier 3 fallback — bez přímého mp4):**
```
Text tweetu…

🎬 + 📖➡️ https://xcancel.com/user/status/123
```

URL cíle je konfigurováno přes `url_domain` — výchozí hodnota je `xcancel.com` (veřejná Twitter proxy).

---

## 11. Mentions transformace

Twitter mentions (`@username`) může systém transformovat do různých formátů
dle platformového nastavení.

| Typ | Výstup pro lokální handle | Výstup pro cizí handle |
|---|---|---|
| `none` | `@ct24zive` | `@ct24zive` |
| `domain_suffix` | `@ct24zive@twitter.com` | `@ct24zive@twitter.com` |
| `domain_suffix_with_local` | `@ct24@zpravobot.news` | `@ct24zive@twitter.com` |
| `local_or_domain_suffix` | `@ct24` (holý — Mastodon resolvne lokálně) | `@ct24zive@twitter.com` |

**Aktuální nastavení pro Twitter platformu:** `local_or_domain_suffix`

Lokální zpravobot.news účty tak dostávají holý `@mastodon_id`, který Mastodon
resolvne jako klikatelný lokální profil a případně vytvoří notifikaci.
Ostatní Twitter handles jsou formátovány jako `@handle@twitter.com`.

Mapa lokálních handles se automaticky sestavuje z Twitter zdrojů s `mastodon_instance: https://zpravobot.news`.

### Profile card blocker

Mastodon zobrazuje profile card prvního zmíněného profilu v postu pokud nemá jiné přílohy.
Toto chování by zakrývalo link card článku.

Řešení: pipeline automaticky přidá **bílý proužek 1280×1 px** jako dummy přílohu
pokud post obsahuje mention, ale žádná jiná média. Mastodon pak upřednostní link card
před profile card. (Průhledný 1×1 px byl dříve v Elk klientu renderován jako zelený čtverec.)

---

## 12. Profile sync

Twitter profily (avatar, banner, bio, metadata pole) jsou synchronizovány přes Nitter
do příslušných Mastodon botů.

Charakteristiky:

- synchronizace probíhá periodicky, nezávisle na hlavní pipeline
- profily jsou rozděleny do **3 skupin** rotujících po dnech týdne
- přiřazení do skupiny je deterministické (z `source_id`)
- každá skupina se synchronizuje **1× týdně** — rozložení zátěže na Nitter

Metadata pole Mastodon profilu obsahují odkaz na originální Twitter profil,
příznak správy systémem (`spravuje:`) a nastavení retence (`retence:`).

Cron konfigurace profile syncu viz [`../40-tools/runtime.md`](../40-tools/runtime.md).

---

## 13. Konfigurace

### Platform defaults (`config/platforms/twitter.yml`)

```yaml
platform: twitter

filtering:
  skip_replies: true
  skip_retweets: false
  skip_quotes: false

formatting:
  platform_emoji: "𝕏"
  prefix_repost: "𝕏🔁"
  prefix_quote: "𝕏💬"
  prefix_video: "🎬"
  move_url_to_end: true

mentions:
  type: local_or_domain_suffix
  value: "twitter.com"

processing:
  max_length: 2400
  trim_strategy: smart

url:
  domain: "xcancel.com"
  rewrite_domains:
    - twitter.com
    - x.com

scheduling:
  priority: normal
```

### Per-source konfigurace

Klíčové per-source přepisy:

| Parametr | Popis |
|---|---|
| `source.handle` | Twitter handle sledovaného účtu |
| `target.mastodon_account` | Cílový Mastodon účet |
| `nitter_processing.enabled` | `true` (default) nebo `false` (Syndication only) |
| `profile_sync.enabled` | Zapnutí/vypnutí profile syncu |
| `profile_sync.language` | Jazyk metadata polí (`cs`, `sk`, `en`) |
| `profile_sync.retention_days` | Retence dat v Mastodon profilu (7/30/90/180 dní) |
| `thread_handling.enabled` | Zapnutí/vypnutí rekonstrukce vláken |
| `monitoring.ok_if_idle` | `true` = nealertovat na idle (pro příležitostné zdroje); chyby se stále reportují |

---

## 14. Limity integrace

Známé architektonické limity Twitter/X integrace:

- ne vždy dostupný kompletní kontext vlákna
- Syndication API není oficiální — může se změnit bez varování
- Nitter je best‑effort — výpadky jsou normální součástí provozu
- změny chování platformy bez předchozího oznámení

Tyto limity jsou:

- akceptované
- ošetřené fallback mechanismy (Tier systém)
- dokumentované formou ADR

---

## 15. Shrnutí

Twitter/X integrace v ZBNW‑NG:

- je technologicky nejnáročnější ze všech platforem
- je navržena jako tolerantní vůči chybám
- preferuje konzistentní chování systému před dokonalostí obsahu
- nezavádí platformně‑specifickou logiku do core pipeline

Hybridní model (IFTTT + Nitter + Syndication) maximalizuje dostupnost dat
při zachování provozní odolnosti.

> Bez ohledu na zdroj dat nebo kvalitu vstupu jsou všechny příspěvky převedeny
> na model `Post`, který vstupuje do jednotné pipeline.

Nitter infrastruktura viz [`../40-tools/nitter.md`](../40-tools/nitter.md).
Provozní problémy viz [`../50-operations/troubleshooting.md`](../50-operations/troubleshooting.md).
