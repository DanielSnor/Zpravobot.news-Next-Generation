# 90-meta

Tato sekce definuje **myšlenkový rámec** systému ZBNW‑NG.

Na rozdíl od ostatních sekcí (které popisují co systém dělá)
tato sekce popisuje **proč je navržen tak, jak je**.

---

## Jak číst tuto sekci

Dokumenty mají logickou posloupnost:

| Dokument | Role | Otázka |
|----------|------|--------|
| [`principles.md`](principles.md) | Pravidla myšlení | Jak přemýšlíme o návrhu? |
| [`constraints.md`](constraints.md) | Guardrails | Co jsme vědomě odmítli? |
| [`scope.md`](scope.md) | Hranice systému | Co systém je a není? |
| [`decisions.md`](decisions.md) | Historie voleb | Proč je systém navržen takto? |

👉 Doporučené pořadí čtení: `principles → constraints → scope → decisions`

---

## Vztahy mezi dokumenty

```
principles          ← základní pravidla (nadčasová)
    ↓
constraints         ← co z principů plyne v praxi (stabilní)
    ↓
scope               ← kde systém začíná a končí (stabilní)
    ↓
decisions           ← konkrétní trade-off volby (historické)
```

---

## Kdy sáhnout do které vrstvy

- **Navrhuješ novou funkci?** → zkontroluj `principles.md` a `constraints.md`
- **Diskutuješ, zda něco patří do systému?** → viz `scope.md`
- **Chceš pochopit, proč je to tak naprogramované?** → viz `decisions.md`
- **Porušuješ constraint vědomě?** → zdokumentuj jako ADR v `decisions.md`

---

## Poznámka k decisions.md

`decisions.md` obsahuje všechny ADR záznamy v jednom souboru organizované
do 12 kategorií s anchor navigací. Při větším množství ADR lze zvážit
rozdělení do samostatných souborů (`decisions/ADR-001.md` atd.) —
aktuální struktura je dostačující pro stávající rozsah.
