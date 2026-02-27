#!/bin/bash
# ============================================================
# Údržbot - Heartbeat s publikací na Mastodon
# ============================================================
# Spustí health monitor v heartbeat režimu a publikuje
# výsledek na @udrzbot@zpravobot.news.
#
# Umístění: /app/data/zbnw-ng/scripts/heartbeat.sh
# Použití:  ./scripts/heartbeat.sh [--save] [--details]
#
# Volby:
#   --save      Uloží report do logs/health/
#   --details   Zobrazí detailní výstup na konzoli
#
# Cron (denní heartbeat v 8:00):
#   0 8 * * * /app/data/zbnw-ng/scripts/heartbeat.sh --save
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZBNW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "${ZBNW_ROOT}/env.sh"

cd "$ZBNW_DIR" || exit 1

# Předat --heartbeat + případné další argumenty (--save, --details)
ruby bin/health_monitor.rb --heartbeat "$@" >> "${ZBNW_LOG_DIR}/health_monitor.log" 2>&1
