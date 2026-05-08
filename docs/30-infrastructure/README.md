# 30-infrastructure

Tato sekce popisuje infrastrukturu ZBNW‑NG ve dvou vrstvách:

1. **`infrastructure.md` (public, normativní)** – požadavky systému na infrastrukturu a hranice odpovědnosti.
2. **`cloudron.md` (public, implementační)** – jak vypadá aktuální produkční nasazení na Cloudronu, *bez citlivých údajů*.

> Citlivé provozní detaily (IP adresy, tokeny, cookies, interní topologie) do veřejné dokumentace nepatří.

---

## Dokumenty

- [`infrastructure.md`](infrastructure.md) — požadavky systému na infrastrukturu, hranice odpovědnosti (Cloudron + Nitter VPS)
- [`cloudron.md`](cloudron.md) — produkční nasazení: adresářová struktura, env.sh, cron model, DB schema
