#!/bin/bash
# ============================================================
# Zpravobot: Sync Test to Production
# ============================================================
# Synchronizuje kód a konfigurace z test prostředí do produkce.
# Vynechává soubory specifické pro prostředí a runtime data.
#
# Umístění: /app/data/zbnw-ng/scripts/sync_test_to_prod.sh
# Použití:  ./scripts/sync_test_to_prod.sh [--dry-run]
# ============================================================

set -e

# Cesty
TEST_DIR="/app/data/zbnw-ng-test"
PROD_DIR="/app/data/zbnw-ng"

# Soubory k vynechání
EXCLUDE_RB="ifttt_webhook.rb"  # Má dual-env konfiguraci v produkci
EXCLUDE_SH="env.sh"            # Prostředí-specifická konfigurace

# Barvy
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Dry run mode
DRY_RUN=false
if [ "$1" == "--dry-run" ]; then
    DRY_RUN=true
    echo -e "${YELLOW}=== DRY RUN MODE ===${NC}"
    echo ""
fi

# Funkce pro kopírování s logem
copy_file() {
    local src="$1"
    local dest="$2"
    local label="$3"
    
    if [ "$DRY_RUN" == true ]; then
        echo -e "  ${YELLOW}[DRY]${NC} $label"
    else
        cp "$src" "$dest"
        echo -e "  ${GREEN}✔${NC} $label"
    fi
}

echo "============================================================"
echo -e "  ${CYAN}Sync: $TEST_DIR → $PROD_DIR${NC}"
echo "============================================================"
echo ""

# ============================================================
# RUBY KÓDY
# ============================================================

# 1. bin/*.rb (kromě EXCLUDE_RB)
echo -e "${CYAN}=== bin/*.rb ===${NC}"
for f in "$TEST_DIR"/bin/*.rb; do
    [ -f "$f" ] || continue
    fname=$(basename "$f")
    if [ "$fname" != "$EXCLUDE_RB" ]; then
        copy_file "$f" "$PROD_DIR/bin/" "bin/$fname"
    else
        echo -e "  ${YELLOW}⭐${NC} bin/$fname (excluded)"
    fi
done
echo ""

# 2. lib/**/*.rb (rekurzivně)
echo -e "${CYAN}=== lib/**/*.rb ===${NC}"
if [ "$DRY_RUN" == true ]; then
    echo -e "  ${YELLOW}[DRY]${NC} rsync lib/ ($(find "$TEST_DIR/lib" -name "*.rb" | wc -l) souborů)"
else
    rsync -av --include='*.rb' --include='*/' --exclude='*' \
        "$TEST_DIR/lib/" "$PROD_DIR/lib/" | grep -E "\.rb$" | while read line; do
        echo -e "  ${GREEN}✔${NC} lib/$line"
    done || true
    echo -e "  ${GREEN}✔${NC} lib/ synced"
fi
echo ""

# ============================================================
# SHELL SKRIPTY
# ============================================================

# 3. *.sh v rootu (kromě EXCLUDE_SH)
echo -e "${CYAN}=== *.sh (root) ===${NC}"
for f in "$TEST_DIR"/*.sh; do
    [ -f "$f" ] || continue
    fname=$(basename "$f")
    if [ "$fname" != "$EXCLUDE_SH" ]; then
        copy_file "$f" "$PROD_DIR/" "$fname"
    else
        echo -e "  ${YELLOW}⭐${NC} $fname (excluded)"
    fi
done
echo ""

# 4. scripts/*.sh
echo -e "${CYAN}=== scripts/*.sh ===${NC}"
mkdir -p "$PROD_DIR/scripts"
for f in "$TEST_DIR"/scripts/*.sh; do
    [ -f "$f" ] || continue
    fname=$(basename "$f")
    copy_file "$f" "$PROD_DIR/scripts/" "scripts/$fname"
done
echo ""

# 5. docs/
echo -e "${CYAN}=== docs/ ===${NC}"
mkdir -p "$PROD_DIR/docs"
if [ "$DRY_RUN" == true ]; then
    echo -e "  ${YELLOW}[DRY]${NC} rsync docs/ ($(find "$TEST_DIR/docs" -type f 2>/dev/null | wc -l) souborů)"
else
    rsync -av --delete "$TEST_DIR/docs/" "$PROD_DIR/docs/" | grep -v '/$' | grep -v '^$' | while read line; do
        echo -e "  ${GREEN}✔${NC} docs/$line"
    done || true
    echo -e "  ${GREEN}✔${NC} docs/ synced"
fi
echo ""

# 6. test/
echo -e "${CYAN}=== test/ ===${NC}"
mkdir -p "$PROD_DIR/test"
if [ "$DRY_RUN" == true ]; then
    echo -e "  ${YELLOW}[DRY]${NC} rsync test/ ($(find "$TEST_DIR/test" -type f 2>/dev/null | wc -l) souborů)"
else
    rsync -av --delete "$TEST_DIR/test/" "$PROD_DIR/test/" | grep -v '/$' | grep -v '^$' | while read line; do
        echo -e "  ${GREEN}✔${NC} test/$line"
    done || true
    echo -e "  ${GREEN}✔${NC} test/ synced"
fi
echo ""

# ============================================================
# KONFIGURACE
# ============================================================

# 7. config/platforms/*.yml
echo -e "${CYAN}=== config/platforms/*.yml ===${NC}"
for f in "$TEST_DIR"/config/platforms/*.yml; do
    [ -f "$f" ] || continue
    fname=$(basename "$f")
    copy_file "$f" "$PROD_DIR/config/platforms/" "config/platforms/$fname"
done
echo ""

# 8. config/global.yml
echo -e "${CYAN}=== config/global.yml ===${NC}"
if [ -f "$TEST_DIR/config/global.yml" ]; then
    copy_file "$TEST_DIR/config/global.yml" "$PROD_DIR/config/" "config/global.yml"
else
    echo -e "  ${YELLOW}⭐${NC} config/global.yml (neexistuje)"
fi
echo ""

# 9. config/test_catalog.yml
echo -e "${CYAN}=== config/test_catalog.yml ===${NC}"
if [ -f "$TEST_DIR/config/test_catalog.yml" ]; then
    copy_file "$TEST_DIR/config/test_catalog.yml" "$PROD_DIR/config/" "config/test_catalog.yml"
else
    echo -e "  ${YELLOW}⭐${NC} config/test_catalog.yml (neexistuje)"
fi
echo ""

# 10. config/broadcast.yml
echo -e "${CYAN}=== config/broadcast.yml ===${NC}"
if [ -f "$TEST_DIR/config/broadcast.yml" ]; then
    copy_file "$TEST_DIR/config/broadcast.yml" "$PROD_DIR/config/" "config/broadcast.yml"
else
    echo -e "  ${YELLOW}⭐${NC} config/broadcast.yml (neexistuje)"
fi
echo ""

# ============================================================
# DATABÁZE
# ============================================================

# 11. db/*.sql
echo -e "${CYAN}=== db/*.sql ===${NC}"
mkdir -p "$PROD_DIR/db"
for f in "$TEST_DIR"/db/*.sql; do
    [ -f "$f" ] || continue
    fname=$(basename "$f")
    copy_file "$f" "$PROD_DIR/db/" "db/$fname"
done
echo ""

# ============================================================
# RUBY ENVIRONMENT
# ============================================================

# 12. Gemfile, Gemfile.lock
echo -e "${CYAN}=== Gemfile* ===${NC}"
for f in Gemfile Gemfile.lock; do
    if [ -f "$TEST_DIR/$f" ]; then
        copy_file "$TEST_DIR/$f" "$PROD_DIR/" "$f"
    else
        echo -e "  ${YELLOW}⭐${NC} $f (neexistuje)"
    fi
done
echo ""

# 13. .ruby-version
echo -e "${CYAN}=== .ruby-version ===${NC}"
if [ -f "$TEST_DIR/.ruby-version" ]; then
    copy_file "$TEST_DIR/.ruby-version" "$PROD_DIR/" ".ruby-version"
else
    echo -e "  ${YELLOW}⭐${NC} .ruby-version (neexistuje)"
fi
echo ""

# ============================================================
# OVĚŘENÍ
# ============================================================

echo "============================================================"
echo -e "  ${CYAN}Ověření${NC}"
echo "============================================================"
echo ""
echo "bin/*.rb: $(ls -1 "$PROD_DIR"/bin/*.rb 2>/dev/null | wc -l) souborů"
echo "lib/**/*.rb: $(find "$PROD_DIR/lib" -name "*.rb" 2>/dev/null | wc -l) souborů"
echo "*.sh (root): $(ls -1 "$PROD_DIR"/*.sh 2>/dev/null | wc -l) souborů"
echo "scripts/*.sh: $(ls -1 "$PROD_DIR"/scripts/*.sh 2>/dev/null | wc -l) souborů"
echo "docs/: $(find "$PROD_DIR/docs" -type f 2>/dev/null | wc -l) souborů"
echo "test/: $(find "$PROD_DIR/test" -type f 2>/dev/null | wc -l) souborů"
echo "config/platforms/*.yml: $(ls -1 "$PROD_DIR"/config/platforms/*.yml 2>/dev/null | wc -l) souborů"
echo "db/*.sql: $(ls -1 "$PROD_DIR"/db/*.sql 2>/dev/null | wc -l) souborů"
echo ""

if [ "$DRY_RUN" == true ]; then
    echo -e "${YELLOW}=== DRY RUN - žádné změny provedeny ===${NC}"
else
    echo -e "${GREEN}=== Synchronizace dokončena ===${NC}"
fi
