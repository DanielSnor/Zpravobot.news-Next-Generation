#!/bin/bash
# ============================================================
# Zpravobot: Backup produkčního kódu před nasazením
# ============================================================
# Vytvoří timestampovaný tar.gz zálohu kódových souborů z PROD.
# Data (queues, state, logs) se nezálohují — ty jsou na DB/filesystému.
#
# Umístění: /app/data/zbnw-ng/scripts/backup_prod.sh
# Použití:  ./scripts/backup_prod.sh
#           ./scripts/backup_prod.sh --list   (výpis záloh)
#           ./scripts/backup_prod.sh --restore SOUBOR.tar.gz
# ============================================================

set -e

PROD_DIR="/app/data/zbnw-ng"
BACKUP_DIR="/app/data/zbnw-ng-backups"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
BACKUP_FILE="$BACKUP_DIR/prod_backup_${TIMESTAMP}.tar.gz"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

mkdir -p "$BACKUP_DIR"

# ============================================================
# --list: výpis existujících záloh
# ============================================================
if [ "$1" == "--list" ]; then
    echo -e "${CYAN}=== Zálohy v $BACKUP_DIR ===${NC}"
    if ls "$BACKUP_DIR"/prod_backup_*.tar.gz 2>/dev/null | head -20; then
        echo ""
        echo "Celkem: $(ls "$BACKUP_DIR"/prod_backup_*.tar.gz 2>/dev/null | wc -l) záloh"
        echo "Místo:  $(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)"
    else
        echo "  (žádné zálohy)"
    fi
    exit 0
fi

# ============================================================
# --restore: obnovení ze zálohy
# ============================================================
if [ "$1" == "--restore" ]; then
    RESTORE_FILE="$2"
    if [ -z "$RESTORE_FILE" ]; then
        echo -e "${RED}Použití: $0 --restore SOUBOR.tar.gz${NC}"
        exit 1
    fi
    if [ ! -f "$RESTORE_FILE" ]; then
        # zkus relativně k BACKUP_DIR
        RESTORE_FILE="$BACKUP_DIR/$2"
    fi
    if [ ! -f "$RESTORE_FILE" ]; then
        echo -e "${RED}Soubor nenalezen: $2${NC}"
        exit 1
    fi
    echo -e "${YELLOW}=== OBNOVENÍ ZE ZÁLOHY ===${NC}"
    echo "Zdroj:  $RESTORE_FILE"
    echo "Cíl:    $PROD_DIR"
    echo ""
    read -r -p "Opravdu obnovit? Přepíše aktuální prod kód. [ano/NE] " CONFIRM
    if [ "$CONFIRM" != "ano" ]; then
        echo "Zrušeno."
        exit 0
    fi
    tar -xzf "$RESTORE_FILE" -C "$PROD_DIR"
    echo -e "${GREEN}✔ Obnoveno z $RESTORE_FILE${NC}"
    exit 0
fi

# ============================================================
# Vytvoření zálohy
# ============================================================
echo "============================================================"
echo -e "  ${CYAN}Záloha PROD kódu${NC}"
echo "  Zdroj: $PROD_DIR"
echo "  Cíl:   $BACKUP_FILE"
echo "============================================================"
echo ""

# Co zálohujeme (kódové soubory, ne runtime data)
cd "$PROD_DIR"
tar -czf "$BACKUP_FILE" \
    --exclude='./queue' \
    --exclude='./failed' \
    --exclude='./state' \
    --exclude='./logs' \
    --exclude='./tmp' \
    --exclude='./.git' \
    bin/ \
    lib/ \
    scripts/ \
    config/platforms/ \
    config/global.yml \
    config/test_catalog.yml \
    config/broadcast.yml \
    db/ \
    docs/ \
    test/ \
    assets/ \
    *.sh \
    2>/dev/null || true

SIZE=$(du -sh "$BACKUP_FILE" 2>/dev/null | cut -f1)
echo -e "${GREEN}✔ Záloha vytvořena: $BACKUP_FILE ($SIZE)${NC}"
echo ""

# Udržuj max 10 posledních záloh
BACKUP_COUNT=$(ls "$BACKUP_DIR"/prod_backup_*.tar.gz 2>/dev/null | wc -l)
if [ "$BACKUP_COUNT" -gt 10 ]; then
    echo -e "${YELLOW}Mazání starých záloh (>10)...${NC}"
    ls -t "$BACKUP_DIR"/prod_backup_*.tar.gz | tail -n +11 | xargs rm -f
    echo -e "  ${GREEN}✔ Ponecháno posledních 10 záloh${NC}"
fi

echo ""
echo "Pro výpis záloh: ./scripts/backup_prod.sh --list"
echo "Pro obnovení:    ./scripts/backup_prod.sh --restore $(basename "$BACKUP_FILE")"
