# Architektonické principy ZBNW‑NG

Tento dokument definuje **architektonické principy** systému ZBNW‑NG.

Principy jsou:
- **nadčasové** (platí i při změně implementace),
- **obecné** (nejsou to konkrétní rozhodnutí),
- **normativní** (nové změny by s nimi neměly být v rozporu bez vědomé výjimky).

> Konkrétní rozhodnutí a trade‑offy jsou v [`decisions.md`](decisions.md).
> Význam pojmů je v [`../00-overview/terminologie.md`](../00-overview/terminologie.md).

---

## Jak tento dokument používat

Používej principy jako kontrolní seznam při návrhu změn:

- „Je tento návrh v souladu s principy?“
- „Který princip tento návrh zlepšuje a který zhoršuje?“
- „Je porušení principu vědomé a zdokumentované v [`decisions.md`](decisions.md)?”

Pokud je potřeba udělat výjimku, zdokumentuj ji jako ADR.

---

## Principy

### P1 — Jedna odpovědnost na komponentu

**Motto:** Každá část systému má mít jasně vymezenou roli.

**Popis:**
ZBNW‑NG stojí na oddělení odpovědností: orchestrátor koordinuje běh,
adaptéry získávají data, pipeline transformuje a publisher publikuje.

**Důsledky v praxi:**
- nové funkce přidávej tam, kde patří odpovědnostně
- vyhýbej se „god object“ třídám
- platformní specifika nepatří do core pipeline

---

### P2 — Unifikace dat přes mezimodel `Post`

**Motto:** Downstream kód nesmí být platformně závislý.

**Popis:**
Veškerý obsah z různých platforem se převádí na jednotný mezimodel `Post`.
Pipeline pracuje s jedním typem vstupu bez platformních větvení.

**Důsledky v praxi:**
- nový adaptér vždy vrací `Post`
- přidání platformy nemá vyžadovat přepis pipeline
- platformní fields mají defaulty, ne `respond_to?` obrany

---

### P3 — Explicitní, kroková pipeline

**Motto:** Pořadí zpracování musí být viditelné.

**Popis:**
Pipeline je sekvence jasných kroků, které lze testovat izolovaně.
Kroky mají definované vstupy/výstupy a podporují early‑return.

**Důsledky v praxi:**
- nový „krok“ = nová izolovaná komponenta
- logika se nesmí schovávat do vedlejších efektů
- pipeline je čitelná i bez znalosti detailů platforem

---

### P4 — Robustnost a graceful degradation

**Motto:** Lepší publikovat „méně dokonalé“ než ztratit obsah.

**Popis:**
Externí platformy jsou nestabilní a nekontrolovatelné.
Systém musí umět degradovat kvalitu výstupu řízeně,
aniž by zablokoval běh nebo způsobil ztrátu kontinuity.

**Důsledky v praxi:**
- fallback je normální stav, ne výjimka
- chyby jedné části nesmí zastavit celý běh
- kvalita může klesnout, ale tok práce musí pokračovat

---

### P5 — Evidence‑based změny (bez preemptivních optimalizací)

**Motto:** Komplexitu přidáváme až na základě reálné potřeby.

**Popis:**
Změny a refaktory se dělají kvůli konkrétně pozorovanému problému,
ne „pro jistotu“.

**Důsledky v praxi:**
- optimalizace bez evidence jsou podezřelé
- velké refaktory musí mít jasný benefit
- technický dluh se eviduje, ale neřeší automaticky

---

### P6 — Batch‑first běhový model

**Motto:** Dávkový model je výchozí, real‑time je výjimka.

**Popis:**
ZBNW‑NG je navržen jako systém spouštěný periodicky.
Procesní stav je krátkožijící; dlouhodobý stav je v perzistenci.

**Důsledky v praxi:**
- návrhy předpokládají restartovatelnost
- cache nesmí růst bez hranic v long‑running scénáři
- plánování běhu je oddělené od zpracování obsahu

---

### P7 — Konfigurace jako data (YAML), ne jako kód

**Motto:** Nový zdroj = konfigurace, ne změna programu.

**Popis:**
Chování systému je řízeno konfigurací zdrojů a platform defaults.
Konfigurace je verzovatelná a auditovatelná.

**Důsledky v praxi:**
- změny chování preferuj přes konfiguraci
- validace konfigurace je důležitá
- secrets nikdy nepatří do veřejných konfiguračních souborů

---

### P8 — Bezpečnost by default

**Motto:** Předpokládej nedůvěryhodný vstup.

**Popis:**
Systém zpracovává data z externích platforem a webhooků.
Musí mít obrany proti zneužití (limity, sanitizace, SSRF ochrany, apod.).

**Důsledky v praxi:**
- validace velikosti a formátu vstupů
- sanitizace názvů souborů a cest
- síťové fetch operace s ochrannými pravidly

---

### P9 — Minimal dependencies

**Motto:** Závislosti přidáváme pouze, když přinášejí jasnou hodnotu.

**Popis:**
Systém preferuje jednoduchost a kontrolu.
Externí služby nebo velké frameworky přidávají riziko a provozní náklady.

**Důsledky v praxi:**
- preferuj standardní knihovny a malé gemy
- nové externí služby vyžadují silné odůvodnění
- kde to jde, volitelný (opt‑in) režim místo povinné závislosti

---

### P10 — Observability bez „vývoje pro monitoring“

**Motto:** Monitoring má být užitečný, ale nesmí diktovat architekturu.

**Popis:**
Systém má mít srozumitelné logy a diagnostické výstupy.
Monitoring je doplňková vrstva oddělená od core logiky.

**Důsledky v praxi:**
- logy musí být čitelné a konzistentní
- monitoring nesmí měnit chování pipeline
- diagnostika má být dostupná bez zásahu do produkčního toku

---

### P11 — Veřejná dokumentace je „public‑safe“

**Motto:** Dokumentujeme tak, aby nebylo nutné publikovat citlivé informace.

**Popis:**
Veřejná dokumentace popisuje principy, architekturu a chování systému,
nikoli konkrétní credentials, interní topologii či privátní provozní detaily.

**Důsledky v praxi:**
- žádné tokeny, cookies, IP, interní hostnames
- implementační detaily hostingu jsou oddělené a abstrahované
- private podklady nejsou mapované 1:1 do veřejných docs

---

## ❌ Co do tohoto dokumentu nepatří

- konkrétní rozhodnutí a trade‑offy (→ `decisions.md`)
- historické příběhy a incidenty
- implementační detaily (konkrétní skripty, cesty, IP, tokeny)
- seznam aktuálních konfiguračních hodnot

---

## Jak přidat nový princip

Nový princip přidej jen pokud:

- je skutečně nadčasový
- bude platit napříč více částmi systému
- pomůže rozhodovat v budoucnu

Pokud jde o jednorázovou volbu, patří to do [`decisions.md`](decisions.md).
