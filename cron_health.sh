#!/bin/bash
# ============================================================
# Údržbot - Health Monitor Cron Wrapper
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

cd "$ZBNW_DIR" || exit 1

# Předat všechny argumenty (--alert, --heartbeat, --details, --save)
bundle exec ruby bin/health_monitor.rb "$@" >> "${ZBNW_LOG_DIR}/health_monitor.log" 2>&1
