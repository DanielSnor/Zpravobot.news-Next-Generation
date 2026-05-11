# 50-operations

## Operations (provozní vrstva)

Tato sekce popisuje, jak systém:

- nasazovat (deployment)
- provozovat (maintenance)
- diagnostikovat (troubleshooting)
- provádět zásahy (runbook)

Nejde o architekturu systému, ale o jeho **provozní realitu**.

---

Na rozdíl od `40-tools` (co systém používá a jak se spouští) se tato sekce zaměřuje na:
**co dělat, když se systém reálně provozuje nebo rozbije**.

Dokumenty jsou veřejně bezpečné — obsahují praktické postupy, ale neobsahují přístupové údaje, IP adresy ani tokeny.

---

## Kdy použít který dokument

| Situace | Dokument |
|---|---|
| Potřebuji zjistit, co se děje (incident, problém) | [`troubleshooting.md`](troubleshooting.md) |
| Potřebuji zasáhnout (restart, reset, oprava) | [`runbook.md`](runbook.md) |
| Nasazuji změnu kódu nebo konfigurace | [`deployment.md`](deployment.md) |
| Pravidelná kontrola a prevence | [`maintenance.md`](maintenance.md) |
| Instalace nebo oprava Nitter instance | [`nitter-setup.md`](nitter-setup.md) |

## Incident workflow

Standardní postup při incidentu:

1. **Detekce** — monitoring alert nebo vlastní pozorování
2. **Diagnostika** → [`troubleshooting.md`](troubleshooting.md) — co se děje, jaká je příčina?
3. **Rozhodnutí:**
   - není potřeba zásah → sledovat
   - potřeba zásah → [`runbook.md`](runbook.md)
4. **Provedení zásahu** — dle runbooku
5. **Ověření** — systém funguje, monitoring green

---

## Dokumenty

- [`runbook.md`](runbook.md) – každodenní provoz: manuální spuštění pipeline, restart komponent, manuální zásahy
- [`troubleshooting.md`](troubleshooting.md) – diagnostika problémů: Twitter/IFTTT, RSS, FB/IG, Nitter, infrastruktura (30+ scénářů)
- [`deployment.md`](deployment.md) – deployment postup: code-only, DB migrace, nový zdroj, rollback
- [`maintenance.md`](maintenance.md) – pravidelná údržba: týdenní kontroly, cleanup logů a DB, obnova cookies
- [`nitter-setup.md`](nitter-setup.md) – instalace Nitter instance: prerekvizity, konfigurace, ověření
