#!/bin/bash
# ============================================================
# Zpravobot: Profile Sync - Cron Wrapper
# ============================================================
# Synchronizuje profily z Twitteru/Bluesky/RSS na Mastodon.
#
# Usage:
#   ./cron_profile_sync.sh                              # Všechny platformy
#   ./cron_profile_sync.sh --platform twitter           # Jen Twitter
#   ./cron_profile_sync.sh --platform bluesky           # Jen Bluesky
#   ./cron_profile_sync.sh --platform rss               # Jen RSS
#   ./cron_profile_sync.sh --platform twitter --group 0 # Twitter skupina 0
#
# Crontab entries (1x týdně, rotace po dnech):
#   # Pondělí - Bluesky (nativní API)
#   0 2 * * 1    /app/data/zbnw-ng/cron_profile_sync.sh --platform bluesky
#
#   # Úterý - Facebook + Instagram (scraping, šetříme)
#   0 2 * * 2    /app/data/zbnw-ng/cron_profile_sync.sh --platform facebook
#   0 3 * * 2    /app/data/zbnw-ng/cron_profile_sync.sh --platform instagram
#
#   # St/Čt/Pá - X/Twitter, 3 skupiny po jedné (Nitter scraping, šetříme)
#   0 2 * * 3    /app/data/zbnw-ng/cron_profile_sync.sh --platform twitter --group 0
#   0 2 * * 4    /app/data/zbnw-ng/cron_profile_sync.sh --platform twitter --group 1
#   0 2 * * 5    /app/data/zbnw-ng/cron_profile_sync.sh --platform twitter --group 2
#
#   # Sobota - RSS (deleguje na BS/FB/TW/IG syncery)
#   0 2 * * 6    /app/data/zbnw-ng/cron_profile_sync.sh --platform rss
#
#   # Neděle - YouTube
#   0 2 * * 0    /app/data/zbnw-ng/cron_profile_sync.sh --platform youtube
#
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

# Zpracování argumentů
PLATFORM=""
GROUP=""
EXTRA_ARGS=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --platform)
            PLATFORM="$2"
            shift 2
            ;;
        --group)
            GROUP="$2"
            shift 2
            ;;
        *)
            EXTRA_ARGS="$EXTRA_ARGS $1"
            shift
            ;;
    esac
done

# Log soubor
if [ -n "$PLATFORM" ]; then
    LOG_FILE="${ZBNW_LOG_DIR}/profile_sync_${PLATFORM}.log"
    PLATFORM_ARG="--platform $PLATFORM"
else
    LOG_FILE="${ZBNW_LOG_DIR}/profile_sync.log"
    PLATFORM_ARG=""
fi

GROUP_ARG=""
if [ -n "$GROUP" ]; then
    GROUP_ARG="--group $GROUP"
fi

# Logování
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "=== Starting profile sync${PLATFORM:+ ($PLATFORM)}${GROUP:+ (group $GROUP)} ==="

cd "$ZBNW_DIR" || exit 1

# Spusť sync
bundle exec ruby bin/sync_profiles.rb $PLATFORM_ARG $GROUP_ARG $EXTRA_ARGS >> "$LOG_FILE" 2>&1
EXIT_CODE=$?

log "=== Profile sync finished (exit code: $EXIT_CODE) ==="

exit $EXIT_CODE
