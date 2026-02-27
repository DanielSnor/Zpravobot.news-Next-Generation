#!/bin/bash
# ============================================================
# Zpravobot: Content Sync Runner - Cron Wrapper
# ============================================================
# Spouští hlavní ZBNW runner pro synchronizaci obsahu.
#
# Usage:
#   ./cron_zbnw.sh                      # Všechny platformy
#   ./cron_zbnw.sh --platform twitter   # Jen Twitter
#   ./cron_zbnw.sh --exclude-platform twitter  # Vše kromě Twitteru
#
# Crontab entries:
#   */8 * * * *  /app/data/zbnw-ng-test/cron_zbnw.sh --exclude-platform twitter
#   */15 * * * * /app/data/zbnw-ng-test/cron_zbnw.sh --platform twitter
#
# Location: /app/data/zbnw-ng-test/cron_zbnw.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

# Parsování argumentů
PLATFORM_ARG=""
LOG_SUFFIX="all"
EXTRA_ARGS=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --platform)
            PLATFORM_ARG="--platform $2"
            LOG_SUFFIX="$2"
            shift 2
            ;;
        --exclude-platform)
            PLATFORM_ARG="--exclude-platform $2"
            LOG_SUFFIX="non_$2"
            shift 2
            ;;
        *)
            EXTRA_ARGS="$EXTRA_ARGS $1"
            shift
            ;;
    esac
done

LOG_FILE="${ZBNW_LOG_DIR}/runner_$(date '+%Y%m%d').log"

# Logování
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "=== Starting ZBNW runner (${LOG_SUFFIX}) ==="

cd "$ZBNW_DIR" || exit 1

# Spusť runner
# --test flag se přidá automaticky pokud ZBNW_SCHEMA=zpravobot_test
if [ "$ZBNW_SCHEMA" = "zpravobot_test" ]; then
    SCHEMA_ARG="--test"
else
    SCHEMA_ARG=""
fi

bundle exec ruby bin/run_zbnw.rb $PLATFORM_ARG $SCHEMA_ARG $EXTRA_ARGS >> "$LOG_FILE" 2>&1
EXIT_CODE=$?

log "=== ZBNW runner finished (exit code: $EXIT_CODE) ==="

exit $EXIT_CODE
