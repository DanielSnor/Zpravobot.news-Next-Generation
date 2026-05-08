# 50-operations

Tato sekce popisuje **provozní aspekty systému ZBNW‑NG**.

Na rozdíl od `40-tools` (co systém používá) se tato sekce zaměřuje na:

- jak systém provozovat
- jak řešit problémy
- jak provádět změny

Tyto dokumenty jsou **na pomezí public a private knowledge**:

- obsahují praktické postupy
- ale neobsahují citlivá data (tokeny, IP, credentials)

---

## Dokumenty

- [`runbook.md`](runbook.md) – každodenní provoz: manuální spuštění pipeline, diagnostika, restart komponent
- [`troubleshooting.md`](troubleshooting.md) – řešení problémů: Twitter/IFTTT, RSS, FB/IG, Nitter, infrastruktura (30+ scénářů)
- [`deployment.md`](deployment.md) – deployment postup: code-only, DB migrace, nový zdroj, rollback
- [`maintenance.md`](maintenance.md) – pravidelná údržba: týdenní kontroly, cleanup logů a DB, obnova cookies
- [`nitter-setup.md`](nitter-setup.md) – instalace Nitter instance: prerekvizity, konfigurace, ověření
