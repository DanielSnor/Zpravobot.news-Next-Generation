#!/bin/bash
# ============================================================
# Zpravobot: Katalog (build_catalog.rb) — Cron Wrapper
# ============================================================
# Generuje a nahrává katalog zdrojů (katalog.zpravobot.news).
# Argumenty se předávají rovnou bin/build_catalog.rb.
#
# Usage:
#   ./cron_catalog.sh                 # plný build (Účty + web) + upload na PROD
#   ./cron_catalog.sh --posts-only    # jen posts.json (Posty + Vyhledávání) + upload na PROD
#   ./cron_catalog.sh --upload-test   # plný build na TEST (ruční)
#   ./cron_catalog.sh --posts-only --upload-test   # posty na TEST (ruční)
#
# Crontab (PROD, od 25. 9. 2026):
#   # Účty + web — denně ráno po syncu profilů (avatary mají čerstvé URL)
#   17 6 * * *        /app/data/zbnw-ng/cron_catalog.sh
#   # Posty + Vyhledávání (sdílený posts.json) — 3× denně
#   17 0,12,18 * * *  /app/data/zbnw-ng/cron_catalog.sh --posts-only
#   # Týdenní plný build (Ne 20:30) zůstal, denní ho ale pokrývá
#   30 20 * * 0       /app/data/zbnw-ng/cron_catalog.sh
#
# TEST (/app/data/zbnw-ng-test) spouštíme jen ručně s --upload-test.
#
# Location: <projekt>/cron_catalog.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

# Režim pro pojmenování logu: posts-only vs plný build.
if [[ "$*" == *--posts-only* ]]; then
    MODE="posts"
else
    MODE="full"
fi

LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/catalog_${MODE}_$(date '+%Y%m%d').log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "=== Katalog start (${MODE}) args: $* ==="

cd "$SCRIPT_DIR" || exit 1

bundle exec ruby bin/build_catalog.rb "$@" >> "$LOG_FILE" 2>&1
EXIT_CODE=$?

log "=== Katalog hotovo (${MODE}, exit code: $EXIT_CODE) ==="

exit $EXIT_CODE
