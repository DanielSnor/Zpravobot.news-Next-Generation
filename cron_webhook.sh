#!/bin/bash
# ============================================================
# Zpravobot: IFTTT Webhook Server - Cron Watchdog
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

LOG_FILE="${ZBNW_LOG_DIR}/webhook_server.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

is_running() {
    curl -s --max-time 2 "http://localhost:${IFTTT_PORT}/health" | grep -q "healthy"
    return $?
}

start_server() {
    log "Starting IFTTT webhook server..."
    cd "$ZBNW_DIR" || exit 1
    nohup bundle exec ruby bin/ifttt_webhook.rb >> "$LOG_FILE" 2>&1 &
    log "Server started with PID $!"
}

if is_running; then
    exit 0
else
    log "Webhook server not running, starting..."
    start_server
fi
