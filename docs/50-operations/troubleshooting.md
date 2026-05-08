# Troubleshooting ZBNW‑NG

Tento dokument obsahuje **konkrétní scénáře řešení problémů** v systému ZBNW‑NG.
Organizováno podle domény problému.

Konkrétní příkazy s provozními cestami a přístupy → [`../../docs-private/30-infrastructure/cloudron.private.md`](../../docs-private/30-infrastructure/cloudron.private.md)

---

## Twitter / IFTTT pipeline

### Webhook nepřichází

**Příčiny:**
- Webhook server neběží
- IFTTT applet deaktivován nebo pozastaven
- Firewall blokuje port webhook serveru

**Diagnostika:**
```bash
curl http://localhost:8089/health
curl http://localhost:8089/stats | jq .
tail -f logs/webhook_server.log
```

**Řešení:**
- Zkontrolovat `cron_webhook.sh` — watchdog, který server restartuje pokud neběží
- Ověřit stav IFTTT appletu v dashboardu

---

### Test webhook jde do produkce

**Příčina:** IFTTT testovací applet nemá `?env=test` v URL.

**Řešení:** Ověřit URL testovacího appletu — musí obsahovat `?env=test` parametr. Bez něj jde webhook do produkční fronty.

---

### Webhook směřuje na špatný zdroj / duplicitní posty

**Příčiny:**
- Chybějící nebo špatný `bot_id` v IFTTT payload
- `bot_id` neodpovídá hodnotě `id:` v YAML konfiguraci
- Více appletů pro stejný účet bez rozlišujícího `bot_id`

**Důsledky:**
- Post jde na fallback aggregator místo správného bota
- `published?()` check selže (hledá pod jiným `source_id`) → duplicitní posty
- Filtry a nastavení z YAML konfigurace se neaplikují

**Diagnostika:**
```bash
grep "Looking for config" logs/ifttt_processor.log | tail -20
grep "using default aggregator" logs/ifttt_processor.log | tail -10
```

**Řešení:**
- V IFTTT appletu přidat/opravit `bot_id` v Body — musí přesně odpovídat hodnotě `id:` v YAML
- Pro více appletů sledujících stejný účet: každý applet musí mít **unikátní `bot_id`**

---

### Duplicitní posty (stejný tweet publikován vícekrát)

**Příčina:** Cron spouštěl nové instance queue processoru zatímco předchozí ještě běžel — race condition.

**Diagnostika:**
```bash
# Více "Processing batch" ve stejnou sekundu = race condition
grep "Processing batch" logs/ifttt_processor.log | tail -20
```

**Řešení:** `cron_ifttt.sh` musí obsahovat `flock` lock — chrání před souběžným spuštěním.
Ověřit přítomnost `.ifttt_processor.lock` souboru a `flock` volání v cron skriptu.

---

### Tier 2 selhává (Nitter nedostupný)

**Příčiny:**
- Nitter instance je nedostupná
- Twitter cookies expirovali
- Rate limiting burner účtů

**Diagnostika:**
```bash
curl "$NITTER_INSTANCE/ct24zive/status/1"
docker compose logs nitter --tail 50
```

**Chování systému:** Tier 2 automaticky fallbackuje na Tier 3.5 (Syndication) nebo Tier 3 (IFTTT data).
Post se publikuje s nižší kvalitou dat — žádná akce potřeba pokud je Nitter dočasně nedostupný.

**Řešení trvalého výpadku:** viz [`../../docs-private/40-tools/nitter.private.md`](../../docs-private/40-tools/nitter.private.md)

---

### Tier 1.5 / 3.5 selhává (Syndication API)

**Příčiny:**
- Syndication API dočasně nedostupné
- Tweet byl smazán nebo je soukromý
- Rate limiting

**Diagnostika:**
```bash
curl -A "Googlebot/2.1" "https://cdn.syndication.twimg.com/tweet-result?id=TWEET_ID&token=TOKEN"
```

**Chování systému:**
- Tier 1.5 automaticky fallbackuje na Tier 1 (IFTTT data bez médií)
- Tier 3.5 automaticky fallbackuje na Tier 3 (IFTTT data)

---

### Obrázky se nezobrazují

**Příčiny:**
- `has_image_in_embed?` nedetekuje obrázky správně
- Embed code neobsahuje `pbs.twimg.com/media`
- Media URL processing selhává

**Diagnostika:**
```bash
grep "embed_code check:" logs/ifttt_processor.log | tail -10
```

Zkontrolovat raw IFTTT payload — ověřit, že `embed_code` obsahuje `pbs.twimg.com/media`.

---

### Tweet smazán mezi IFTTT triggerem a Nitter fetchem

**Příčina:** Autor smazal tweet v okně 1–2 minut mezi zachycením IFTTT a Tier 2 Nitter fetchem.

**Diagnostika:**
```bash
grep "empty content\|tweet likely deleted" logs/ifttt_processor.log | tail -20
```

**Očekávané logy:**
```
⚠️ Nitter HTML structure found but tweet content is empty for 123456 (tweet likely deleted between IFTTT trigger and Nitter fetch)
⚠️ Nitter returned empty content for post 123456 (tweet likely deleted)
Tier 2: ⚠️ Nitter returned HTTP 200 but tweet content is empty for 123456 (tweet likely deleted)
```

**Řešení:** Žádná akce — systém pracuje správně. Post se nepublikuje, `⚠️` log pouze informuje.

---

### Newlines zmizely z textu tweetu

**Příčina:** `clean_text` metoda používá `/\s+/` místo `/[ \t]+/` — zachycuje i znaky nového řádku.

**Řešení:** Ověřit regex v `clean_text` — musí být `[ \t]+`, ne `\s+`. Totéž platí pro všechny whitespace operace v Twitter processorech.

---

### Text obsahuje nežádoucí URL (`/photo/N`, `/video/N`, `#m`)

**Příčina:** `extract_text` neodstraňuje tyto URL patterny.

**Řešení:** Ověřit, že `extract_text` v `twitter_adapter.rb` obsahuje správné regex patterny pro `/photo/N`, `/video/N` a quote marker `#m`.

---

### Threading nefunguje (posty nejsou propojené)

**Diagnostika:**
```bash
grep "Threading.*Cached\|in_reply_to\|chain extraction" logs/ifttt_processor.log | tail -20
```

**Typický chybový log:**
```
[14:32:34] ⚠️  [source_id] 🧵 Thread detected but chain extraction failed
[14:32:34] ℹ️  [IftttQueue] Thread detected, in_reply_to: none (thread start)
```

**Poznámky k implementaci:**
- Thread cache používá dvouúrovňovou strukturu `{source_id => {username => mastodon_id}}`
- Threading vyžaduje `nitter_processing: true` — Syndication API thread context neposkytuje
- `mark_published()` ukládá `platform_uri` pro Bluesky reply chain lookup

---

### Encoding crash při zpracování thread chain

**Chybová hláška:** `incompatible character encodings: UTF-8 and BINARY (ASCII-8BIT)`

**Příčina:** `Net::HTTP` vrací `response.body` jako `ASCII-8BIT`. Správná konverze je `.encode('UTF-8', 'binary', invalid: :replace, undef: :replace, replace: '?')` — ne `force_encoding('UTF-8')`, které pouze přetaguje string bez validace bajtů.

**Diagnostika:**
```bash
grep "incompatible character encodings" logs/ifttt_processor.log | tail -20
# 100% korelace: každý encoding error je předcházen "Thread chain found: N tweets"
grep "Thread chain found" logs/ifttt_processor.log | tail -20
```

---

## RSS zdroje

### Nové posty se nepublikují — zpoždění agregátoru

**Příznak:** Runner hlásí `Fetched 0 posts` přestože feed obsahuje nové články.

**Příčina — race condition s aggregátory (RSS.app, Feedly, apod.):**
```
13:41  Runner check → since = 13:21 → 0 nových → last_success = 13:41
13:50  Článek publikován (pubDate = 13:50)
14:01  Runner → since = 13:41 → pubDate 13:50 > 13:41 ✓ → hledá v feedu... RSS.app ještě nemá
       → Fetched 0 posts → last_success = 14:01
14:21  RSS.app přidá článek s pubDate = 13:50
       Runner → since = 14:01 → pubDate 13:50 < 14:01 ✗ → PŘESKOČEN navždy
```

**Řešení (implementováno):** Pro RSS platformu se `since` filtr záměrně nepoužívá — stahují se vždy všechny položky feedu:

```ruby
# lib/orchestrator.rb
since = source.platform == 'rss' ? nil : extract_since_time(state)
```

Deduplikace je zajištěna GUID-based kontrolou v `published_posts`.

---

### HTTP 301/308 redirect

**Chování:** Adapter automaticky sleduje redirecty (301, 302, 307, 308) až do 5 hopů. Redirect je logován jako WARNING.

**Příklad logu:**
```
WARN: [RssAdapter] Redirect 301: https://cestina20.cz/rss → https://cestina20.cz/feed
INFO: [RssAdapter] Followed to final URL: https://cestina20.cz/feed
```

**Doporučení:** Permanentní redirecty (301, 308) naznačují, že by se měl aktualizovat `feed_url` v YAML konfiguraci — adapter si poradí automaticky, ale přímá URL je efektivnější.

---

### HTTP 403/404 při stahování feedu

**Příčiny:**
- Feed URL je neplatná nebo stará
- Server blokuje User-Agent

**Diagnostika:**
```bash
curl -H "User-Agent: Zpravobot/1.0" "https://example.com/rss.xml"
```

---

### Duplicitní posty (RSS feed)

**Příčina:** Feed nemá stabilní GUID/ID — každý fetch generuje nové identifikátory.

**Řešení:** ZBNW-NG používá `entry_id` (GUID → link fallback) pro deduplikaci. Pokud ani link není stabilní, zdroj není vhodný pro RSS polling.

---

### Obrázky z RSS.app se nepublikují

**Příčina:** RSS.app používá `<media:content>` namespace místo standardního `<enclosure>`. `RssAdapter` to podporuje přes `@media_content_map` (double-parse přes REXML), ale pouze pokud XML parsing proběhne správně.

**Diagnostika:**
```bash
curl -s "https://rss.app/feeds/xxx.xml" | grep "media:content"
```

---

## Facebook / Instagram (RSS.app zdroje)

### Duplicitní text — "Text… — Text…"

**Příčina:** Zdroj nemá nastaveno `rss_source_type: facebook` — chybí `FacebookProcessor` který odstraňuje em-dash duplicitu.

**Řešení:**
```yaml
rss_source_type: facebook
```

---

### Noise posty ("updated their cover photo", "přidal fotky" apod.)

**Příčina:** Chybějící `banned_phrases` v konfiguraci zdroje.

**Řešení:** Přidat odpovídající seznam banned_phrases. Vzory pro FB/IG noise jsou standardizované v `bin/create_source.rb` konstantách.

---

### Profile sync — website shows "messenger.com" nebo jiná doména zápatí

**Příčina:** `FacebookProfileSyncer` dříve fetchoval hlavní FB stránku — ta obsahuje pouze zápatí s obecnými doménami. Opraveno 2026-03-09.

**Aktuální chování:** Syncer fetchuje `/about` URL a aplikuje `FOOTER_DOMAINS` filtr.

**Diagnostika:**
```bash
ruby bin/sync_profiles.rb --source <source_id> --dry-run
```

---

### Profile sync — IG cookies vypršely

**Příčina:** Instagram cookies mají životnost ~90 dní.

**Příznak:** Profile sync selže s chybou o autentizaci nebo vrátí prázdný profil.

**Řešení:** Přihlásit se do Instagramu v prohlížeči, zkopírovat aktuální cookies (`DS_USER_ID`, `SESSIONID`, `CSRFTOKEN`, `MID`) do `env.sh` na serveru.

---

### IG handle nenalezen / špatný profil

**Příčina:** Mastodon handle používá podtržítka (`kimi_antonelli`), Instagram profil má tečky (`kimi.antonelli`). Jsou to různé znaky — je třeba použít skutečný IG handle s tečkami.

**Diagnostika:**
```bash
curl "https://www.instagram.com/<skutecny.handle>/" -L | head -20
```

---

### Bio Instagramu je prázdné

**Příčina:** JSON pole `biography` v page source bývá prázdné nebo chybí. `InstagramProfileSyncer` čte bio z `<meta content="..." name="description" />` — pozor, atribut `content` je před `name`.

---

### Profile sync vyžaduje produkční server

**Problém:** `bin/sync_profiles.rb` vyžaduje `pg` gem — lokálně typicky chybí. Spouštět pouze na produkčním Cloudron serveru.

---

## Nitter

### "Could not authenticate you"

**Příčina:** Twitter cookies expirovali nebo IP mismatch (cookies získány z jiné IP než Nitter používá).

**Řešení:** Obnovit cookies přes SOCKS5 tunel ze správné IP. Viz [`../../docs-private/40-tools/nitter.private.md`](../../docs-private/40-tools/nitter.private.md) — sekce "Obnova cookies — SOCKS5 postup".

---

### "No guest accounts" / "Rate limited"

**Příčina:** Burner účty byly vyčerpány nebo dočasně omezeny Twitterem.

**Řešení:**
1. `docker compose restart nitter` — resetuje session rotaci
2. Pokud přetrvává: obnovit cookies nebo přidat nové burner účty

---

### 403 z ZBNW-NG (přístup k Nitter instanci odmítnut)

**Příčina:** IP adresa Cloudron serveru není v nginx whitelistu Nitter VPS.

**Řešení:** Na Nitter VPS přidat IP do nginx konfigurace. Viz `nitter.private.md` — sekce Nginx konfigurace.

---

### Connection refused (Nitter)

**Příčina:** Nitter container neběží.

**Diagnostika:**
```bash
docker compose ps
docker compose logs nitter --tail 20
```

**Řešení:** `docker compose up -d`

---

### "invalid integer" při startu Nitteru

**Příčina:** User ID v `sessions.jsonl` je číslo místo stringu.

**Oprava:**
```
"id":"123456789"   ✅
"id":123456789     ❌
```

---

## Infrastruktura

### DB nepřipojuje (`PG::ConnectionBad`)

**Diagnostika:**
```bash
echo $CLOUDRON_POSTGRESQL_URL
psql "$CLOUDRON_POSTGRESQL_URL" -c "SELECT 1"
```

---

### Webhook server neběží

**Diagnostika:**
```bash
curl http://localhost:8089/health
tail -f logs/ifttt_webhook.log
```

**Řešení:** Spustit watchdog: `./cron_webhook.sh` — ten server nastartuje, pokud neběží.

---

### Queue se hromadí (pending fronta roste)

**Diagnostika:**
```bash
find queue/ifttt/pending -name "*.json" | wc -l
```

**Příčiny:**
- `cron_ifttt.sh` neběží (zkontrolovat cron konfiguraci v Cloudron Dashboardu)
- Chybí `flock` lock → race condition → procesor se sám blokuje

**Manuální spuštění processoru:**
```bash
ruby lib/webhook/ifttt_queue_processor.rb
```

---

### Schema neexistuje (`ERROR: schema "zpravobot" does not exist`)

**Řešení:**
```bash
psql "$CLOUDRON_POSTGRESQL_URL" -f db/migrate_cloudron.sql
```

---

### Cron neběží

Cloudron spravuje cron přes Dashboard — ne přes `crontab`. Zkontrolovat stav v **Cloudron Dashboard → Cron**.

Manuální spuštění pro ověření:
```bash
ruby bin/run_zbnw.rb --exclude-platform twitter
```

---

### Zdroj je zaseknutý (ignoruje nové posty)

**Příčina:** `last_check` timestamp je v budoucnosti nebo chybí.

**Řešení:**
```bash
ruby bin/force_update_source.rb <source_id>
```

---

## Obecné postupy

### Ověření funkčnosti po změně kódu

```bash
ruby bin/run_zbnw.rb --dry-run                    # celý run bez publikace
ruby bin/run_zbnw.rb --source <id> --dry-run      # izolovaný zdroj
ruby bin/run_tests.rb                             # unit testy
ruby bin/run_tests.rb --network                   # síťové testy
```

### Zdraví systému

```bash
ruby bin/health_monitor.rb --details
ruby bin/instance_status.rb                       # JSON snapshot stavu
ruby bin/log_report.rb                            # report z logů
```

### Stav zdrojů s chybami

```bash
ruby bin/log_report.rb --source <source_id>       # slim report pro jeden zdroj
```

Konkrétní DB dotazy → `cloudron.private.md` — sekce Diagnostika.

---

## Reference

- Konkrétní příkazy s produkčními cestami a přístupy: [`../../docs-private/30-infrastructure/cloudron.private.md`](../../docs-private/30-infrastructure/cloudron.private.md)
- Nitter provoz a obnova cookies: [`../../docs-private/40-tools/nitter.private.md`](../../docs-private/40-tools/nitter.private.md)
- Architektura systému: [`../10-system/zbnw-ng-system.md`](../10-system/zbnw-ng-system.md)
- Twitter integrace: [`../20-platforms/twitter.md`](../20-platforms/twitter.md)
- Nitter setup: [`nitter-setup.md`](nitter-setup.md)
