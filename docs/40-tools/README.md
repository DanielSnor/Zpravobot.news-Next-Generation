# 40-tools

Tato sekce popisuje **nástroje používané v rámci ZBNW‑NG**.
Nejde o samotnou architekturu systému, ale o **pomocné komponenty,
skripty a utility**, které podporují jeho provoz, monitoring a údržbu.

Dokumentace je rozdělena podle typu nástrojů:

- runtime nástroje (spouštění, orchestrace)
- CLI nástroje (manuální operace)
- monitoring a diagnostika
- integrační nástroje (např. webhooky)

---

## Dokumenty

- [`runtime.md`](runtime.md) – cron model, scheduling priorit, IFTTT queue, profil sync rotace
- [`cli.md`](cli.md) – přehled všech bin/ skriptů: argumenty, přepínače, použití
- [`monitoring.md`](monitoring.md) – Údržbot: 11 health checků, AlertStateManager, Command Listener, formáty alertů
- [`integration.md`](integration.md) – Browserless.io, RSS.app, IFTTT integrace
- [`nitter.md`](nitter.md) – Nitter instance: architektura, burner účty, sessions.jsonl, RSS vs HTML scraping
- [`testing.md`](testing.md) – test runner, katalog testů, typy testů (unit/network/db/e2e), běhový model
