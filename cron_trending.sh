#!/bin/bash
# ============================================================
# Zpravobot: Trending Post - Cron Wrapper
# ============================================================
# Zkontroluje nové trendy a publikuje quote posty z @zpravobot.
# Event-driven: pokud nejsou nové trendy, skript tiše odejde.
#
# Crontab:
#   45 * * * * /app/data/zbnw-ng/cron_trending.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

LOG_FILE="${ZBNW_LOG_DIR}/trending.log"

cd "$ZBNW_DIR" || exit 1
bundle exec ruby bin/trending_post.rb --bluesky >> "$LOG_FILE" 2>&1
