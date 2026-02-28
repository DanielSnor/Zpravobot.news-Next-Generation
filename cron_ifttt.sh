#!/bin/bash
# ============================================================
# Zpravobot: IFTTT Queue Processor - Cron Script
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK_FILE="${SCRIPT_DIR}/.ifttt_processor.lock"

# === LOCK - prevent multiple instances ===
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Another instance is running, skipping..."
    exit 0
fi

source "${SCRIPT_DIR}/env.sh"

# ============================================================
# Process a single queue (prod or test)
# Usage: process_queue <queue_dir> <log_file> <label>
# ============================================================
process_queue() {
    local queue_dir="$1"
    local log_file="$2"
    local label="$3"

    local pending_dir="${queue_dir}/pending"
    local pending_count
    pending_count=$(find "$pending_dir" -name "*.json" 2>/dev/null | wc -l)

    if [ "$pending_count" -eq 0 ]; then
        return 0
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${label}] Processing ${pending_count} pending webhooks..."

    IFTTT_QUEUE_DIR="$queue_dir" bundle exec ruby lib/webhook/ifttt_queue_processor.rb 2>&1 | tee -a "$log_file"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${label}] Queue processing complete"
}

cd "$ZBNW_DIR" || exit 1

# Prod queue
process_queue \
    "${IFTTT_QUEUE_DIR}" \
    "${ZBNW_LOG_DIR}/ifttt_processor.log" \
    "prod"

# Test queue
process_queue \
    "${IFTTT_QUEUE_DIR_TEST}" \
    "${ZBNW_LOG_DIR}/ifttt_processor_test.log" \
    "test"
