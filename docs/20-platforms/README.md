# 20-platforms

Tato sekce popisuje **jednotlivé zdrojové platformy** systému ZBNW‑NG.

Každý dokument pokrývá jednu platformu: jak se data sbírají, jak se mapují na model `Post`,
jaká jsou omezení a specifika chování.

Společný základ (Post model, pipeline) je popsán v [`../10-system/zbnw-ng-system.md`](../10-system/zbnw-ng-system.md).

---

## Dokumenty

- [`twitter.md`](twitter.md) — IFTTT + Nitter hybridní architektura, 5-tierový fallback, Syndication API, threading, profile sync
- [`bluesky.md`](bluesky.md) — AT Protocol API, feed pagination, thread detection přes AT URI
- [`facebook.md`](facebook.md) — RSS.app bridge, FacebookProcessor, profile sync přes Browserless
- [`instagram.md`](instagram.md) — RSS.app bridge, InstagramProcessor (rekonstrukce captionů), profile sync přes Browserless
- [`youtube.md`](youtube.md) — YouTube RSS, media:group parsing, Shorts filtrování, maintenance window, profile sync
- [`rss.md`](rss.md) — univerzální RSS/Atom, content modes, URL processing
