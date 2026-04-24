#!/bin/bash
# ============================================================
# Zpravobot: ZpravobotTOP10 Weekly Hitparáda — Cron Wrapper
# ============================================================
# Generuje a publikuje týdenní hitparádu CZ+SK z účtu @zpravobot.
# Spouštět 1x týdně — neděle 20:00.
#
# Crontab:
#   0 20 * * 0 /app/data/zbnw-ng/cron_stats.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

LOG_FILE="${ZBNW_LOG_DIR}/stats.log"

cd "$ZBNW_DIR" || exit 1
ruby bin/zpravobot_stats.rb --publish --account zpravobot --bluesky >> "$LOG_FILE" 2>&1
