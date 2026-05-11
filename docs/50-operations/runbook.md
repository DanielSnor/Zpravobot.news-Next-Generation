# Runbook ZBNW‑NG

Tento dokument slouží pro **konkrétní provozní zásahy** — co dělat a jak.

Slouží pro:
- ověření, že systém funguje správně (každodenní kontrola)
- manuální zásahy — restart, reset stavu, ruční spuštění

Pro diagnostiku problémů (co se děje a proč) → [`troubleshooting.md`](troubleshooting.md).

---

## Jak tento dokument používat

Použití podle situace:

- ✅ „Chci vědět, jestli je všechno OK“ → sekce *Každodenní kontrola*
- ✅ „Nic se nepublikuje“ → sekce *Diagnostika*
- ✅ „Potřebuji něco opravit“ → sekce *Manuální zásahy*

---

# ✅ 1. Každodenní kontrola (5 minut)

Toto je základní kontrola stavu systému.

## 1.1 Ověření, že běh systému probíhá

Zkontroluj:

- existují nové záznamy v logu
- čas posledního běhu není „příliš starý“

👉 očekávaný stav:
- logy přibývají pravidelně
- běh odpovídá nastavenému intervalu (cron)

---

## 1.2 Ověření publikace obsahu

Zkontroluj:

- existují nové publikované posty
- timestamp poslední publikace je rozumný

👉 očekávaný stav:
- publikace probíhá průběžně
- není dlouhá mezera bez publikace

---

## 1.3 Ověření chyb zdrojů

Zkontroluj:

- počet zdrojů v chybovém stavu
- trend error_count

👉 očekávaný stav:
- jednotlivé chyby jsou normální
- trvale selhávající zdroje jsou výjimka

---

## 1.4 Ověření queue (doplňkový komponent)

Zkontroluj:

- backlog fronty není rostoucí
- fronta se zpracovává

👉 očekávaný stav:
- krátkodobé špičky OK
- dlouhodobý růst = problém

---

# 🔍 2. Diagnostika problémů (quick triage)

Identifikuj symptom a přejdi na [`troubleshooting.md`](troubleshooting.md) pro detailní postup řešení.

| Symptom | Pravděpodobná příčina |
|---------|----------------------|
| Nic se nepublikuje | scheduler, pipeline, deduplikace |
| Jeden zdroj nefunguje | error_count, konfigurace, platforma |
| Queue backlog roste | queue processor nefunguje nebo je pomalý |
| Publikace selhává | publisher error, API cílové platformy |
| Nitter / Twitter bez dat | Nitter instance nedostupná nebo změna HTML |

👉 Pro krok-za-krokem postup viz [`troubleshooting.md`](troubleshooting.md).

---

# 🛠️ 3. Manuální zásahy

---

## 3.1 Manuální spuštění systému

Použij v případě:
- testování změn
- diagnostiky
- restartu pipeline

Typické použití:

- spustit celý systém
- spustit konkrétní zdroj

👉 cíl:
ověřit, jestli pipeline funguje nezávisle na scheduleru

---

## 3.2 Spuštění v „dry‑run“ režimu

Použij v případě:
- ladění
- ověření chování

👉 výsledek:
- pipeline běží
- nic se nepublikuje

---

## 3.3 Reset stavu zdroje

Použij v případě:
- zdroj je „zaseknutý“
- systém ignoruje nové příspěvky

👉 efekt:
- systém znovu zpracuje obsah

---

## 3.4 Restart běhových komponent

Použij v případě:
- webhook neodpovídá
- queue nefunguje

👉 efekt:
- obnoví běh bez změny dat

---

# 📊 4. Co je „normální chování“

Je důležité vědět, co je OK:

---

## ✅ Chyby jednotlivých zdrojů

- externí platformy nejsou stabilní
- jednotlivé chyby jsou normální

---

## ✅ Nepravidelná publikace

- závisí na aktivitě zdrojů
- krátké pauzy jsou OK

---

## ✅ Neúplná data

- chybějící fields jsou normální
- pipeline musí být tolerantní

---

## ✅ Dočasné výpadky integrací

- očekávané chování
- systém by měl pokračovat dál

---

# ⚠️ 5. Kdy zasáhnout

Zásah je potřeba, pokud:

- ❌ dlouhodobě žádná publikace
- ❌ kontinuální růst error_count
- ❌ neustále rostoucí queue
- ❌ pipeline padá v každém běhu

---

# 🚫 Co do runbooku nepatří

- konkrétní příkazy s citlivými daty
- přístupové údaje (tokeny, cookies)
- IP adresy a infrastruktura
- ad‑hoc debug poznámky

👉 tyto informace patří do:
- private dokumentace
- lokálních runbooků

---

# ✅ Cíl runbooku

- rychlá orientace v systému
- minimální čas do diagnostiky
- bezpečné sdílení (public‑safe)

---

# 📌 Shrnutí

Runbook má odpovědět na:

- „běží to?“
- „pokud ne, proč?“
- „co mám udělat?“

…bez nutnosti znát implementační detaily.