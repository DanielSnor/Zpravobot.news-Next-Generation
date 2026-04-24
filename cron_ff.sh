#!/bin/bash
# ============================================================
# Zpravobot: Friendly Follow (#FF) — Cron Wrapper
# ============================================================
# Publikuje denní #FF post od @zpravobot doporučující 3 účty.
# Spouštět 1x denně — čas TBD.
#
# Crontab (zakomentováno — Daniel rozhodne čas):
#   # 15 15 * * * /app/data/zbnw-ng/cron_ff.sh
#   # 15 16 * * * /app/data/zbnw-ng/cron_ff.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

LOG_FILE="${ZBNW_LOG_DIR}/friendly_follow.log"

cd "$ZBNW_DIR" || exit 1
ruby bin/friendly_follow.rb --bluesky >> "$LOG_FILE" 2>&1
