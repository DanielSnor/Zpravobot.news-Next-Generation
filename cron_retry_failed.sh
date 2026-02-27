#!/bin/bash
# ============================================================
# Zpravobot: IFTTT Failed Queue Retry - Cron Wrapper
# ============================================================
# Zkusí znovu zpracovat soubory z queue/ifttt/failed/.
# Spouštět 1x za hodinu.
#
# Crontab:
#   0 * * * * /app/data/zbnw-ng/cron_retry_failed.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

LOG_FILE="${ZBNW_LOG_DIR}/ifttt_processor.log"
FAILED_DIR="${IFTTT_QUEUE_DIR}/failed"

# Spustit jen pokud jsou kandidáti (*.json bez DEAD_ prefixu)
CANDIDATE_COUNT=$(find "$FAILED_DIR" -name "*.json" ! -name "DEAD_*" 2>/dev/null | wc -l)

if [ "$CANDIDATE_COUNT" -eq 0 ]; then
    exit 0
fi

cd "$ZBNW_DIR" || exit 1
ruby bin/retry_failed_queue.rb >> "$LOG_FILE" 2>&1
