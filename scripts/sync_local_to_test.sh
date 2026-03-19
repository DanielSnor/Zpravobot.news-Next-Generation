#!/bin/bash
# ============================================================
# Zpravobot: Sync Local → Test
# ============================================================
# Synchronizuje lokální kód (Mac) do test prostředí na serveru.
# Vynechává soubory specifické pro prostředí a runtime data.
#
# Použití: ./scripts/sync_local_to_test.sh [--dry-run]
# ============================================================

set -e

LOCAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Načti prostředí-specifické proměnné (není v Gitu)
ENV_FILE="$LOCAL_DIR/env.sh"
if [ ! -f "$ENV_FILE" ]; then
    echo "Chybí $ENV_FILE — zkopíruj env.sh.example a doplň hodnoty."
    exit 1
fi
# shellcheck source=/dev/null
# Dočasně vypni set -e — env.sh má mkdir příkazy pro server cesty (/app/...)
# které na Macu padají (read-only FS). Proměnné se načtou správně i tak.
set +e
source "$ENV_FILE"
set -e

REMOTE="${ZBNW_REMOTE:?ZBNW_REMOTE není nastaveno v env.sh}"
REMOTE_PORT="${ZBNW_REMOTE_PORT:?ZBNW_REMOTE_PORT není nastaveno v env.sh}"
TEST_DIR="${ZBNW_TEST_DIR:?ZBNW_TEST_DIR není nastaveno v env.sh}"
SSH_CTRL="/tmp/zbnw-sync-$$"
SSH_OPTS="-p $REMOTE_PORT -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ControlMaster=auto -o ControlPath=$SSH_CTRL -o ControlPersist=120"

# Otevři master SSH spojení
ssh $SSH_OPTS $REMOTE true 2>/dev/null || true
trap "ssh -O exit -o ControlPath=$SSH_CTRL $REMOTE 2>/dev/null; true" EXIT

# Barvy
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Dry run mode
DRY_RUN=false
RSYNC_DRY=""
if [ "$1" == "--dry-run" ]; then
    DRY_RUN=true
    RSYNC_DRY="--dry-run"
    echo -e "${YELLOW}=== DRY RUN MODE ===${NC}"
    echo ""
fi

# Helper funkce — sudo rsync musí být quoted jako jeden argument
do_rsync() {
    rsync -avz $RSYNC_DRY --exclude='.DS_Store' --rsync-path="sudo rsync" -e "ssh $SSH_OPTS" "$@"
}
do_rsync_delete() {
    rsync -avz $RSYNC_DRY --delete --exclude='.DS_Store' --rsync-path="sudo rsync" -e "ssh $SSH_OPTS" "$@"
}

echo "============================================================"
echo -e "  ${CYAN}Sync: $LOCAL_DIR → $REMOTE:$TEST_DIR${NC}"
echo "============================================================"
echo ""

# ============================================================
# 1. bin/*.rb (kromě ifttt_webhook.rb)
# ============================================================
echo -e "${CYAN}=== bin/*.rb ===${NC}"
do_rsync \
    --include='*.rb' \
    --exclude='ifttt_webhook.rb' \
    --exclude='*' \
    "$LOCAL_DIR/bin/" "$REMOTE:$TEST_DIR/bin/"
echo ""

# ============================================================
# 2. lib/**/*.rb
# ============================================================
echo -e "${CYAN}=== lib/**/*.rb ===${NC}"
do_rsync \
    --include='*/' \
    --include='*.rb' \
    --exclude='*' \
    "$LOCAL_DIR/lib/" "$REMOTE:$TEST_DIR/lib/"
echo ""

# ============================================================
# 3. *.sh v rootu (kromě env.sh)
# ============================================================
echo -e "${CYAN}=== *.sh (root) ===${NC}"
do_rsync \
    --exclude='env.sh' \
    --include='*.sh' \
    --exclude='*' \
    "$LOCAL_DIR/" "$REMOTE:$TEST_DIR/"
echo ""

# ============================================================
# 4. scripts/*.sh
# ============================================================
echo -e "${CYAN}=== scripts/*.sh ===${NC}"
do_rsync \
    --include='*.sh' \
    --exclude='*' \
    "$LOCAL_DIR/scripts/" "$REMOTE:$TEST_DIR/scripts/"
echo ""

# ============================================================
# 5. docs/
# ============================================================
echo -e "${CYAN}=== docs/ ===${NC}"
do_rsync_delete \
    --exclude='*.private.md' \
    "$LOCAL_DIR/docs/" "$REMOTE:$TEST_DIR/docs/"
echo ""

# ============================================================
# 6. test/
# ============================================================
echo -e "${CYAN}=== test/ ===${NC}"
do_rsync_delete \
    "$LOCAL_DIR/test/" "$REMOTE:$TEST_DIR/test/"
echo ""

# ============================================================
# 7. config/platforms/*.yml
# ============================================================
echo -e "${CYAN}=== config/platforms/*.yml ===${NC}"
do_rsync \
    --include='*.yml' \
    --exclude='*' \
    "$LOCAL_DIR/config/platforms/" "$REMOTE:$TEST_DIR/config/platforms/"
echo ""

# ============================================================
# 8. config/test_catalog.yml + config/broadcast.yml
# ============================================================
echo -e "${CYAN}=== config/*.yml (vybrané) ===${NC}"
for f in test_catalog.yml broadcast.yml health_monitor.yml; do
    if [ -f "$LOCAL_DIR/config/$f" ]; then
        do_rsync \
            "$LOCAL_DIR/config/$f" "$REMOTE:$TEST_DIR/config/$f"
    else
        echo -e "  ${YELLOW}⭐${NC} config/$f (neexistuje lokálně)"
    fi
done
echo ""

# ============================================================
# 9. db/*.sql
# ============================================================
echo -e "${CYAN}=== db/*.sql ===${NC}"
do_rsync \
    --include='*.sql' \
    --exclude='*' \
    "$LOCAL_DIR/db/" "$REMOTE:$TEST_DIR/db/"
echo ""

# ============================================================
# 10. Gemfile
# ============================================================
echo -e "${CYAN}=== Gemfile ===${NC}"
do_rsync \
    "$LOCAL_DIR/Gemfile" "$REMOTE:$TEST_DIR/Gemfile"
echo ""

# ============================================================
# HOTOVO
# ============================================================
echo "============================================================"
if [ "$DRY_RUN" == true ]; then
    echo -e "${YELLOW}=== DRY RUN — žádné změny provedeny ===${NC}"
else
    echo -e "${GREEN}=== Synchronizace dokončena ===${NC}"
fi
