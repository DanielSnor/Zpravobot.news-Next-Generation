# 40-tools

## Tools (provozní vrstva)

Tato sekce popisuje nástroje a mechanismy potřebné pro:

- spouštění systému (runtime)
- manuální ovládání (CLI)
- integrace s externími systémy
- monitoring a diagnostiku
- testování a validaci

Nejde o architekturu systému, ale o jeho **provozní použití**.

---

Tato sekce popisuje **nástroje a provozní komponenty** systému ZBNW‑NG.
Na rozdíl od jiných sekcí nejde o to, *co systém dělá* (architektura, systém),
ani *kde běží* (infrastruktura) — ale o to, **jak se s ním pracuje v reálu**.

Obecné pojmy jsou definovány v [`../00-overview/terminologie.md`](../00-overview/terminologie.md).

---

## Dokumenty

### Ovládání systému

- [`runtime.md`](runtime.md) – lifecycle běhu, typy běhů, scheduling, failure model
- [`cli.md`](cli.md) – přehled všech bin/ skriptů: argumenty, přepínače, použití

### Provoz a monitoring

- [`monitoring.md`](monitoring.md) – Údržbot: 11 health checků, AlertStateManager, Command Listener, formáty alertů
- [`testing.md`](testing.md) – test runner, katalog testů, typy testů (unit/network/db/e2e), běhový model

### Integrace a nástroje

- [`integration.md`](integration.md) – pull/push modely, queue boundary, integrační nástroje per platforma
- [`nitter.md`](nitter.md) – Nitter jako proxy vrstva pro Twitter/X: architektura, enrichment, profile sync
