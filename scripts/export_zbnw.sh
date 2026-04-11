#!/bin/bash
# ZBNW-NG Export Script
# Exportuje aplikační soubory do jednoho souboru pro analýzu
set -e
cd "$(dirname "$0")/.."
mkdir -p ./tmp

TIMESTAMP=$(date +"%Y%m%d-%H%M")
OUTPUT="./tmp/${TIMESTAMP}-zbnw_ng_full_export.txt"

# Hlavička s UTF-8 indikátory
cat > "$OUTPUT" << 'EOF'
================================================================================
🤖 ZBNW-NG FULL EXPORT
================================================================================
⚠️  ENCODING: UTF-8 (pokud vidíš rozbité znaky, OPRAV SVŮJ EDITOR!)
📅 České znaky: ěščřžýáíéúůďťň ĚŠČŘŽÝÁÍÉÚŮĎŤŇ
🦋 Emoji test: 🦋🔁💬🧵❌⚠️ℹ️🔍🗑️
================================================================================

EOF

# Přidat timestamp
echo "Export time: $(date '+%Y-%m-%d %H:%M:%S')" >> "$OUTPUT"
echo "" >> "$OUTPUT"

# Explicitní seznam adresářů a souborů
{
  # Cron skripty
  find . -maxdepth 1 -name "cron_*.sh" -type f
  # Gemfile
  find . -maxdepth 1 -name "Gemfile" -type f
  # Adresáře
  find ./bin -type f -name "*.rb"
  find ./scripts -type f -name "*.sh" 2>/dev/null
  # find ./docs -type f 2>/dev/null  # docs vynechány z exportu
  find ./test -type f 2>/dev/null
  find ./lib -type f -name "*.rb"
  find ./config -type f \( -name "*.yml" \) | grep -v "/sources/"
  find ./db -type f -name "*.sql"
} | sort | while read file; do
    echo "" >> "$OUTPUT"
    echo "================================================================================" >> "$OUTPUT"
    echo "FILE: ${file#./}" >> "$OUTPUT"
    echo "================================================================================" >> "$OUTPUT"
    echo "" >> "$OUTPUT"
    cat "$file" >> "$OUTPUT"
done

LINES=$(wc -l < "$OUTPUT")
SIZE=$(ls -lh "$OUTPUT" | awk '{print $5}')
echo "✅ Export dokončen: $OUTPUT"
echo "   📊 Řádků: $LINES, Velikost: $SIZE"
echo "   🔤 Encoding: UTF-8"
