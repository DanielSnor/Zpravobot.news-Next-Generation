#!/bin/bash
# ============================================================
# Zpravobot Bot Cron Wrapper
# ============================================================
# Runs both bot processes:
#   1. Udrzbot  — command listener (polls mentions, responds)
#   2. Tlambot  — broadcast queue processor (broadcasts queued messages)
#
# Cron:
#   */5 * * * * /app/data/zbnw-ng/cron_command_listener.sh
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

cd "$ZBNW_DIR" || exit 1

# 1. Udrzbot — command listener
ruby bin/command_listener.rb "$@" >> "${ZBNW_LOG_DIR}/command_listener.log" 2>&1

# 2. Tlambot — broadcast queue processor
ruby bin/process_broadcast_queue.rb >> "${ZBNW_LOG_DIR}/broadcast_queue.log" 2>&1
