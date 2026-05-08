# Deployment ZBNW‑NG

Tento dokument popisuje **praktický postup nasazení změn** v systému ZBNW‑NG.

Deployment zahrnuje:
- změny kódu
- změny konfigurace
- změny databáze

---

## Jak tento dokument používat

Použij při:

- nasazení nové verze systému
- změně konfigurace
- aplikaci databázových změn

---

# 🚀 1. Deployment flow (hlavní postup)

Každý deployment má tyto kroky:

---

## 1.1 Příprava změny

Zkontroluj:

- změna je otestovaná (lokálně / test)
- změna neporušuje:
  - `principles.md`
  - `constraints.md`
- pokud jde o změnu chování → existuje záznam v `decisions.md`

---

## 1.2 Nasazení kódu

- aktualizuj kód systému
- zajisti, že je nasazena správná verze

👉 očekávaný stav:
- systém používá novou verzi kódu
- nedošlo k chybě při nasazení

---

## 1.3 Aplikace migrací (pokud existují)

Použij pouze pokud změna obsahuje DB změny.

Zkontroluj:

- migrace jsou idempotentní
- migrace nepoškozují existující data

👉 očekávaný stav:
- schema odpovídá nové verzi systému
- systém se dokáže připojit k DB

---

## 1.4 Restart běhových komponent

Zajisti, že:

- nové procesy používají nový kód
- staré běhy nejsou aktivní

👉 očekávaný stav:
- systém běží v nové verzi
- nedochází ke konfliktu verzí

---

## 1.5 První běh po deployi

Sleduj první běh systému:

- pipeline doběhne
- nevzniknou fatální chyby
- logy jsou konzistentní

👉 toto je nejkritičtější moment deploymentu

---

# ✅ 2. Post-deploy kontrola

Po nasazení vždy ověř:

---

## 2.1 Běh systému

- cron/scheduler běží
- logy se aktualizují

---

## 2.2 Pipeline

- pipeline doběhne bez chyb
- jednotlivé kroky fungují

---

## 2.3 Publikace

- vznikne nový post
- publikace proběhne úspěšně

---

## 2.4 Zdroje

- zdroje nejsou v chybovém stavu
- error_count neroste

---

## 2.5 Queue (doplňkový komponent)

- fronta se zpracovává
- backlog neroste

---

# 🔁 3. Typy deploymentu

---

## 3.1 Code-only deployment

Použij, když:

- měníš logiku systému
- neměníš DB ani config

👉 riziko: nízké

---

## 3.2 Configuration deployment

Použij, když:

- měníš YAML konfiguraci
- přidáváš zdroj

👉 pozor:
- validita konfigurace
- chování pipeline

---

## 3.3 Schema deployment

Použij, když:

- měníš DB schema

👉 riziko: vyšší

Zkontroluj:
- kompatibilitu s existujícími daty
- backward compatibility (pokud potřeba)

---

# ⚠️ 4. Nejčastější problémy po deployi

---

## Problém: Pipeline padá

### Příčina
- nekompatibilní změna
- chyba v kódu

### Řešení
- rollback změny
- opravit chybu

---

## Problém: Nic se nepublikuje

### Příčina
- chyba v pipeline
- špatná konfigurace

### Řešení
- použít troubleshooting
- ověřit první běh

---

## Problém: Zdroje selhávají

### Příčina
- změna adapteru
- změna datového modelu

### Řešení
- ověřit konkrétní zdroj
- případně revert

---

## Problém: DB chyby

### Příčina
- neaplikovaná migrace
- nekompatibilní schema

### Řešení
- aplikovat migraci
- rollback změny

---

# 🔙 5. Rollback

Použij, pokud:

- systém nefunguje po deployi
- nelze rychle opravit chybu

---

## Postup rollbacku

1. vrať předchozí verzi kódu
2. restartuj systém
3. ověř běh (viz Post-deploy kontrola)

---

## Poznámky

- DB změny nemusí být vždy snadno revertovatelné
- rollback musí být rychlý a bezpečný

---

# 🧠 6. Deployment principy

Platí vždy:

- ✅ deployment musí být idempotentní  
- ✅ systém musí přežít restart  
- ✅ změna musí být pozorovatelná (logy)  
- ✅ failure musí být rychle detekovatelný  

---

---

> **Deployment = změna systému.** Pro manuální zásahy při běžném provozu
> (restart, ruční spuštění pipeline, reset zdroje) viz [`runbook.md`](runbook.md).

---

# 🚫 Co do deployment.md nepatří

- konkrétní příkazy (ssh, paths, skripty)
- credentials
- IP adresy
- detailní infra konfigurace

👉 ty patří do:
- private dokumentace
- nebo lokálního runbooku

---

# ✅ Cíl dokumentu

- bezpečný a predikovatelný deployment
- rychlá kontrola po změně
- minimalizace rizika výpadku

---

# 📌 Shrnutí

Deployment odpovídá na:

- „jak nasadit změnu?“
- „jak poznám, že to funguje?“
- „co dělat, když to nefunguje?“