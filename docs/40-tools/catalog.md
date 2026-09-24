# Katalog zdrojů

Statický web [katalog.zpravobot.news](https://katalog.zpravobot.news), který zveřejňuje všechny zdroje běžící na instanci a umožňuje je procházet, filtrovat a sdílet. Generuje se dávkově (plný build denně, posty 3× denně) jako sada statických souborů a nahrává na Surfer (Cloudron static hosting).

Použité pojmy viz [`../00-overview/terminologie.md`](../00-overview/terminologie.md).

---

## Systém jednou větou

```
config/mastodon_accounts.yml ┐
config/sources/*.yml         ├─→ DataAggregator → records → Renderer → statické soubory → Surfer
Mastodon API + DB snapshot   ┘
```

Žádný runtime server, žádný build step, žádný framework. Frontend je vanilla JS nad jedním `data.json`; filtrování i řazení ~540 záznamů běží celé v prohlížeči.

---

## Architektura

Tři zdroje pravdy spojuje [`Catalog::DataAggregator`](../../lib/catalog/data_aggregator.rb) do jednoho pole záznamů; [`Catalog::Renderer`](../../lib/catalog/renderer.rb) z nich vyrobí statické soubory. Upload řeší [`bin/build_catalog.rb`](#nástroje).

| Zdroj | Co poskytuje |
|---|---|
| `config/mastodon_accounts.yml` | `type`, `family`, `categories`, `instance`, `aggregator` |
| `config/sources/*.yml` | `language` (default `cs`), `source_details` (platforma + handle + URL na originální profil) |
| Mastodon API (`verify_credentials`) | `avatar`, `display_name`, `bio` (note), `created_at` |
| DB `account_stats_snapshot` | `followers`, `posts_week`, týdenní delty (skokani), fallback `created_at` |

**Efektivní platforma** zohledňuje `rss_source_type` — FB/IG/Threads feedy přicházející přes RSS.app se hlásí jako `instagram`/`facebook`, ne generické `rss`.

### Co projde do katalogu

[`include_account?`](../../lib/catalog/data_aggregator.rb) propustí účet, jen pokud:

- běží na **zpravobot.news** (cizí Mastodon instance se vynechávají), a
- má vyplněnou **`family`** (nekategorizované/sběrné boty jako `betabot` vypadnou).

**Agregátory (`aggregator: true`) v katalogu zůstávají** — v našem pojetí je agregátor plnohodnotný samostatný zdroj, jen obohacený z více vstupů (např. DVTVcz = X + YT videa DVTV).

---

## Datový model

Každý záznam v `data.json` (z [`build_record`](../../lib/catalog/data_aggregator.rb)):

| Pole | Zdroj / poznámka |
|---|---|
| `id`, `display_name` | account_id; jméno z API (fallback na id) |
| `type` | `person` \| `media` \| `institution` \| `team` \| `other` |
| `family` | tématická oblast (`sport`, `news`, `culture`, …) |
| `language` | `cs` \| `sk` \| `en` (víc jazyků zdroje → default `cs`) |
| `categories` | tagy účtu (filtr + skryté full-text vyhledávání) |
| `avatar`, `bio` | z Mastodon API (bio = HTML, sanitizace na klientovi) |
| `followers`, `posts_week` | nejnovější DB snapshot |
| `followers_delta`, `activity_delta` | týdenní nárůst (skokani); `null` bez předchozího snapshotu |
| `created_at` | z `verify_credentials` (datum vzniku účtu); fallback nejstarší snapshot, jinak `null` |
| `profile_url` | `https://zpravobot.news/@<id>` |
| `source_platforms` | dedup. seznam platforem (odvozeno ze `source_details`) |
| `source_details` | `[{ platform, handle, url }]` — odkazy na originální profily |

---

## Funkce webu

Frontend ([`templates/app.js`](../../lib/catalog/templates/app.js), `app.css`, `index.html.erb`):

- **Filtry** — oblast (rodina), typ účtu, jazyk, tag (autocomplete + dynamické chips); AND mezi sekcemi, OR uvnitř.
- **Full-text** — jméno + handle + **skrytě tagy** (hledání „f1" najde i otagované účty).
- **Řezy / žebříčky** (lišta záložek): platforma (X/Bluesky/FB/IG/Threads/YT/RSS), Top 10/50 sledovaných/aktivních, **skokani týdne** (nárůst sledujících / aktivity), nedávno přidané (<90 dní). Top N respektuje jen oblast a přepisuje ostatní filtry.
- **Detail** — hover preview (jen hover-capable zařízení) + klik otevře modal (`<dialog>`) s bio, odkazy na originální profily, statistikami a „přidán před X". Zavírá Escape / klik mimo / ×.
- **Kontextové štítky typu** — `institution` se podle oblasti zobrazí jako „Instituce" (vláda/kultura) nebo „Organizace"; týmy mají vlastní typ `team` → „Tým".
- **Řazení** — abecedně / sledující / aktivita / přidání.
- **Stav v URL hash** — `#family=…&type=…&slice=…&sort=…` (sdílitelné, přežije refresh).
- **Responsivita** — pod 640px jednosloupcový seznam + sidebar jako accordion.
- **SEO / sdílení** — OG/Twitter card, canonical, `sitemap.xml`, `robots.txt`; **per-účet stuby** `zdroj/<id>.html` s vlastním OG (avatar/bio) → redirect do katalogu s otevřeným modalem (`#account=<id>`).
- **I18n** — přepínač **CZ \| EN** v hlavičce. Default čeština, EN je jen UI shell (obsah zůstává v původním jazyce). Volba v `localStorage` + `?lang=en`.

---

## Build & deploy

URL katalogu je v `config/global.yml`:

```yaml
infrastructure:
  catalog_prod_url: https://katalog.zpravobot.news
  catalog_test_url: https://katalog-test.zpravobot.news
```

Tokeny pro zápis na Surfer jsou v `env.sh` (jen na produkci):

| Proměnná | Účel |
|---|---|
| `SURFER_TOKEN` | prod access token (zápis na katalog.zpravobot.news) |
| `SURFER_TEST_TOKEN` | test access token (katalog-test.zpravobot.news) |
| `SURFER_URL` / `SURFER_TEST_URL` | volitelný env override URL z global.yml |

Token se generuje v **Surfer adminu** (Access Tokens); upload jde přes Surfer HTTP API `PUT /api/files/<path>` (token jako `Authorization: Bearer` i `?access_token=`). Doména a samotná Surfer app žijí v Cloudronu, ne v repu.

### Výstupní soubory

`data.json`, `index.html`, `app.js`, `app.css`, `header.jpg`, `sitemap.xml`, `robots.txt` a `zdroj/<id>.html` (~540 per-účet stubů). `data.json` je samostatný kvůli cache-friendly rebuildu.

---

## Nástroje

### `build_catalog.rb`

Vygeneruje katalog a nahraje na Surfer.

```bash
ruby bin/build_catalog.rb                 # build + upload na PRODUKCI
ruby bin/build_catalog.rb --upload-test   # build + upload na TEST instanci
ruby bin/build_catalog.rb --no-upload     # jen build do tmp/catalog (lokální náhled)
ruby bin/build_catalog.rb --no-stubs      # bez per-účet sdílecích stubů
```

| Přepínač | Default | Popis |
|---|---|---|
| `--no-upload` | upload zapnut | Jen build, bez uploadu (lokální náhled) |
| `--upload-test` | prod | Upload na katalog-test instanci (test token) |
| `--no-stubs` | stuby zapnuty | Přeskočit per-účet stuby `zdroj/<id>.html` |
| `--output DIR` | `tmp/catalog` | Build adresář |
| `--test` | `false` | Použít schéma `zpravobot_test` |

### `catalog_dump.rb`

Vytiskne agregované záznamy (JSON) na stdout — kontrola spojení tří zdrojů před generací HTML.

```bash
ruby bin/catalog_dump.rb               # pretty JSON na stdout
ruby bin/catalog_dump.rb --count       # jen počty + souhrn rodin/typů/jazyků
ruby bin/catalog_dump.rb --no-mastodon # přeskočit Mastodon API (rychlé, bez avatarů)
```

---

## Cron

Přes wrapper `cron_catalog.sh` (sourcuje `env.sh`, loguje do `logs/catalog_full_YYYYMMDD.log` / `catalog_posts_YYYYMMDD.log`). Od 25. 9. 2026 plný build **denně ráno po syncu profilů** (2:00), aby katalog nesl čerstvé URL avatarů; posty a vyhledávání 3× denně:

```cron
17 6 * * *        /app/data/zbnw-ng/cron_catalog.sh                # účty + web
17 0,12,18 * * *  /app/data/zbnw-ng/cron_catalog.sh --posts-only   # posts.json
30 20 * * 0       /app/data/zbnw-ng/cron_catalog.sh                # týdenní, denní ho pokrývá
```

Snapshot z `zpravobot_stats.rb` (neděle 20:00) se bere nejnovější dostupný; skokani týdne se počítají proti snapshotu o týden starším než ten nejnovější, ne než datum buildu.

---

## Provozní poznámky

- **Skokani týdne** potřebují alespoň 2 týdenní snapshoty v `account_stats_snapshot`, jinak jsou prázdní.
- **Per-účet stuby** = ~540 malých souborů uploadovaných přes Surfer API jednotlivě → build trvá pár minut navíc. Vypínatelné `--no-stubs`.
- Lokální náhled: `ruby bin/build_catalog.rb --no-upload && cd tmp/catalog && python3 -m http.server`.

---

## Soubory

```
bin/build_catalog.rb           # build + upload na Surfer
bin/catalog_dump.rb            # kontrolní výpis agregovaných dat
lib/catalog/
  data_aggregator.rb           # spojení tří zdrojů → records
  renderer.rb                  # records → statické soubory (+ OG, sitemap, stuby)
  templates/
    index.html.erb             # layout + SEO meta + i18n data-atributy
    app.js                     # filtry, řezy, modal, i18n, URL stav
    app.css                    # styly (light/dark, responsivní)
    header.jpg                 # hlavičkový obrázek (i OG náhled)
config/global.yml              # infrastructure.catalog_*_url
test/test_catalog_aggregator.rb
```
