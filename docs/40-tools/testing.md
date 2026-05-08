# Testování ZBNW‑NG

Tento dokument popisuje **testovací vrstvu** systému ZBNW‑NG: jaké typy testů existují, jak jsou organizované a jaký je jejich běhový model.

Testování odpovídá na otázku:

> „Jak ověřujeme správnost komponent systému bez toho, aby testy zasahovaly do produkčního běhu?"

Použité pojmy jsou definovány v [`../00-overview/terminologie.md`](../00-overview/terminologie.md).

---

## 1. Role testování v architektuře

Testování je **podpůrná vrstva mimo runtime**.

- Testy nejsou součástí běžných cron běhů.
- Testy se spouští manuálně (lokálně / v CI) nebo cíleně při změnách.
- Testy ověřují komponenty izolovaně i v kombinacích, ale **nesmí měnit produkční data**.

Testování je navrženo tak, aby bylo:

- deterministické (kde to jde)
- bezpečné při opakovaném spuštění
- použitelné i bez externích gem závislostí

---

## 2. Test runner (tool)

ZBNW‑NG používá **vlastní test runner** (bez Minitest/RSpec).

- CLI vstupní bod: `bin/run_tests.rb`
- registr testů: `config/test_catalog.yml`
- implementace runneru: `lib/test_runner/`

Test runner zajišťuje:

- výběr testů podle kategorie / tagu / názvu
- spouštění testů jako izolovaných subprocessů
- timeouts a sběr výsledků
- generování Markdown reportu

> Detailní používání CLI přepínačů patří do [`cli.md`](cli.md).

---

## 3. Typy testů (kategorie)

Testy jsou rozdělené do kategorií podle toho, jaké závislosti vyžadují.

### 3.1 `unit` (offline)

- offline (bez sítě a DB)
- rychlé a deterministické
- primární testovací vrstva

Použití:
- refaktoring
- změny pipeline kroků
- změny formatterů / processorů

### 3.2 `network`

- vyžadují přístup k síti
- ověřují integrační chování (např. feedy / API)

Použití:
- změny adapterů
- změny integrační logiky

### 3.3 `db`

- vyžadují PostgreSQL (test schema)
- ověřují state management a migrace

Použití:
- změny v DB schématu
- změny repository vrstvy

### 3.4 `e2e`

- end‑to‑end testy
- mohou být interaktivní
- typicky publikují do test cíle

Použití:
- změny publisheru
- ověření celého flow

---

## 4. Katalog testů (`config/test_catalog.yml`)

Každý test je zaregistrován v katalogu s metadaty:

- `file` – cesta k test souboru
- `category` – `unit` / `network` / `db` / `e2e`
- `tags` – štítky pro filtrování
- `description` – krátký popis
- volitelně: `timeout`, `interactive`, `args`

Katalog plní dvě role:

1. Je to autoritativní seznam testů.
2. Umožňuje jednotný výběr a reportování bez ohledu na to, jak je test napsán.

---

## 5. Běhový model testů

Test runner spouští každý test jako **samostatný proces**.

Výhody:

- izolace globálního stavu
- žádné „sdílení" side‑effectů mezi testy
- robustní timeouts

Typický tok:

1. Runner vybere testy podle katalogu.
2. Pro každý test spustí subprocess a aplikuje timeout.
3. Výstup se zpracuje heuristickým parserem.
4. Vygeneruje se přehled a report.

---

## 6. Vyhodnocení výsledků (status model)

Test runner používá jednotné stavy:

- `pass` – test prošel
- `fail` – test selhal (asserty / validace)
- `error` – test spadl (výjimka, syntax error)
- `timeout` – test překročil limit
- `skip` – test přeskočen (např. chybí závislost pro danou kategorii)

Tyto stavy jsou úmyslně jednodušší než detailní frameworky — cílem je
**rychlá orientace a automatizovatelný výsledek**.

---

## 7. Reportování

Test runner generuje Markdown report do `tmp/` (časově označený soubor).

Report typicky obsahuje:

- souhrn (passed / failed / errors / timeouts / skipped)
- výsledky po kategoriích
- detail selhání (výběr relevantních částí stdout/stderr)

---

## 8. Jak přidat nový test

1. Vytvoř test soubor (např. `test/test_<nazev>.rb`).
2. Přidej záznam do `config/test_catalog.yml`.
3. Ověř, že jde test selektovat (např. filtrem podle názvu nebo tagu).

Doporučení:

- nové logiky pokrývej primárně `unit` testy
- `network` a `e2e` používej střídmě (jsou dražší a méně deterministické)

---

## 9. Vztah k ostatním dokumentům

- [`cli.md`](cli.md) — jak test runner spouštět a filtrovat
- [`../50-operations/deployment.md`](../50-operations/deployment.md) — jak ověřit změny po nasazení
- [`../50-operations/troubleshooting.md`](../50-operations/troubleshooting.md) — když testy odhalí regresi v produkci

---

## Co tento dokument záměrně neobsahuje

- konkrétní secrets / přístupové údaje
- konkrétní síťové endpointy
- detailní „kuchařku" pro všechny CLI přepínače

Cílem je popsat **testovací vrstvu jako nástroj**, ne kopírovat implementační detaily.
