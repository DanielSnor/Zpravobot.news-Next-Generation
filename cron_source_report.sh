#!/bin/bash
# Cron wrapper pro source_report.rb
# Spouštět denně v 10:00 po ranním runner cyklu.
#
# Crontab:
#   0 10 * * * /app/data/zbnw-ng/cron_source_report.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

cd "$ZBNW_DIR" || exit 1

ruby bin/source_report.rb >> "${ZBNW_LOG_DIR}/source_report.log" 2>&1
