# 90-meta

## Meta dokumentace (orientace)

Tato sekce popisuje **jak přemýšlet o systému ZBNW‑NG**.

Nejde o implementaci ani o runtime — ale o **mentální model**: proč systém vypadá tak, jak vypadá, a jaká pravidla ho drží konzistentním.

---

Tato sekce definuje **myšlenkový rámec** systému ZBNW‑NG.

Na rozdíl od ostatních sekcí (které popisují co systém dělá)
tato sekce popisuje **proč je navržen tak, jak je**.

---

## Jak číst tuto sekci

Doporučené pořadí — od kontextu k detailu:

| # | Dokument | Role | Otázka |
|---|----------|------|--------|
| 1 | [`scope.md`](scope.md) | Hranice systému | Co systém je a není? |
| 2 | [`principles.md`](principles.md) | Pravidla myšlení + design rules | Jak přemýšlíme o návrhu? |
| 3 | [`constraints.md`](constraints.md) | Guardrails | Co jsme vědomě odmítli? |
| 4 | [`decisions.md`](decisions.md) | Historie voleb (ADR) | Proč je systém navržen takto? |

---

## Vztahy mezi dokumenty

```
scope               ← co systém je a není (vstupní kontext)
    ↓
principles          ← základní pravidla a design rules (nadčasová)
    ↓
constraints         ← co z principů plyne v praxi (stabilní)
    ↓
decisions           ← konkrétní trade-off volby (historické)
```

## Účel

Tyto dokumenty:

- nepopisují implementaci
- nepopisují runtime
- ale definují **mentální model systému** — rámec, se kterým jsou konzistentní všechna ostatní rozhodnutí

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
