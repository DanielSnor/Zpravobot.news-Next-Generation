# Maintenance ZBNW‑NG

Tento dokument popisuje **pravidelnou údržbu systému ZBNW‑NG**.

Cílem je:
- udržet systém dlouhodobě stabilní
- předcházet problémům
- kontrolovat růst dat a chyb

---

## Jak tento dokument používat

Údržba vychází z dat poskytovaných monitoringem — viz [`../40-tools/monitoring.md`](../40-tools/monitoring.md).
Monitoring říká *co* sledovat, maintenance říká *kdy a jak* reagovat.

Údržba je rozdělena podle frekvence:

- denní → rychlá kontrola
- týdenní → kontrola trendů
- měsíční → hlubší kontrola a cleanup

---

# ✅ 1. Denní údržba (5–10 minut)

Navazuje na runbook – jde o lehké ověření zdraví systému.

---

## 1.1 Kontrola běhu systému

Zkontroluj:

- logy se aktualizují
- běhy probíhají v očekávaných intervalech

✅ OK:
- pravidelné záznamy
- žádné dlouhé pauzy

---

## 1.2 Kontrola publikace

Zkontroluj:

- systém publikuje nové posty
- nevznikla dlouhá pauza bez publikace

✅ OK:
- publikace odpovídá aktivitě zdrojů

---

## 1.3 Kontrola chyb zdrojů

Zkontroluj:

- error_count u zdrojů
- nové chybové zprávy

✅ OK:
- jednotlivé chyby jsou normální  
⚠️ problém:
- stejný zdroj dlouhodobě selhává

---

## 1.4 Kontrola queue (doplňkový komponent)

Zkontroluj:

- zda fronta není dlouhodobě rostoucí

✅ OK:
- backlog je stabilní nebo klesá

---

# 📊 2. Týdenní údržba (15–30 minut)

Zaměřeno na trendy a dlouhodobé odchylky.

---

## 2.1 Kontrola problémových zdrojů

Zkontroluj:

- zdroje s opakovanými chybami
- zdroje bez aktivity

Akce:

- analyzuj příčinu (platforma / konfigurace)
- případně dočasně deaktivuj zdroj

---

## 2.2 Kontrola objemu dat

Zkontroluj:

- růst databáze
- objem logů
- velikost fronty

✅ OK:
- růst odpovídá očekávání  
⚠️ problém:
- nekontrolovaný růst

---

## 2.3 Kontrola výkonu systému

Zkontroluj:

- délku běhů
- zpoždění zpracování

✅ OK:
- stabilní runtime  
⚠️ problém:
- postupné zpomalování

---

## 2.4 Kontrola kvality výstupu

Zkontroluj:

- formát postů
- čitelnost textu

✅ OK:
- výstup odpovídá očekávání  
⚠️ problém:
- systematické chyby (např. rozbitý formatter)

---

# 🧹 3. Měsíční údržba (30–60 minut)

Hloubková kontrola systému.

---

## 3.1 Cleanup starých dat

Zkontroluj a případně proveď:

- odstranění starých logů
- odstranění starých queue položek
- odstranění zastaralých dat

✅ cíl:
- udržet systém „lean“

---

## 3.2 Kontrola databáze

Zkontroluj:

- velikost tabulek
- indexy
- výkon dotazů (pokud dostupné)

✅ OK:
- DB není bottleneck

---

## 3.3 Kontrola konfigurace

Zkontroluj:

- neaktuální zdroje
- duplicity v konfiguraci
- nepoužívané položky

Akce:

- odstranit nevyužívané zdroje
- upravit konfiguraci

---

## 3.4 Kontrola architektury (light audit)

Zkontroluj:

- nevznikl technický dluh
- neobchází se pipeline
- systém stále odpovídá principles/constraints

---

# ⚠️ 4. Signály problémů

Reaguj, pokud se objeví:

---

## 🔴 Kritické

- žádná publikace po dlouhou dobu
- pipeline padá při každém běhu
- queue roste bez limitu

👉 okamžitý zásah

---

## 🟠 Varovné

- jeden zdroj dlouhodobě selhává
- postupné zpomalování systému
- časté chyby publikace

👉 analyzovat a naplánovat opravu

---

## 🟡 Informativní

- občasné chyby
- menší změny ve výstupu

👉 sledovat, ale neřešit okamžitě

---

# 🔧 5. Typické údržbové zásahy

Používej při problémech:

---

## Reset zdroje

Použij, když:

- zdroj je „zaseknutý“
- ignoruje nové příspěvky

---

## Restart komponent

Použij, když:

- webhook nefunguje
- queue nepracuje

---

## Cleanup dat

Použij, když:

- roste disk usage
- data přestávají být relevantní

---

# 📌 6. Principy údržby

Platí vždy:

- ✅ řeš příčinu, ne symptom  
- ✅ changes musí být reverzibilní (pokud možno)  
- ✅ sleduj trendy, ne jednotlivé incidenty  
- ✅ údržba nesmí narušit běh systému  

---

# 🚫 Co do maintenance.md nepatří

- konkrétní příkazy (paths, skripty)
- přístupové údaje
- infrastruktura (IP, hostnames)
- jednorázové „hacky“

👉 ty patří do:
- private dokumentace
- troubleshooting / decisions

---

# ✅ Cíl dokumentu

- dlouhodobá stabilita systému
- předcházení problémům
- jednoduchá a opakovatelná údržba

---

# 📌 Shrnutí

Maintenance odpovídá na:

- „co kontrolovat pravidelně?“
- „kdy zasáhnout?“
- „jak zabránit problémům?“