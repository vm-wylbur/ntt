#!/usr/bin/env bash
# Author: PB and Claude
# Date: Sat 12 Oct 2025
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/bin/audit-cdrom-report.sh
#
# Generate comprehensive CD-ROM audit report
# Identifies media affected by BUG-015

set -euo pipefail

REPORT_FILE="/tmp/cdrom-audit-$(date +%Y%m%d-%H%M%S).txt"

{
    echo "=========================================="
    echo "CD-ROM Archive Completeness Audit Report"
    echo "Generated: $(date)"
    echo "=========================================="
    echo

    echo "=== AFFECTED MEDIA (Incomplete Pipeline) ==="
    echo
    sudo -u postgres psql copyjob -tAc "
        SELECT
            medium_hash || ' | ' ||
            COALESCE(medium_human, 'UNKNOWN') || ' | ' ||
            CASE
                WHEN enum_done IS NULL THEN 'LOAD_MISSING'
                WHEN copy_done IS NULL THEN 'COPY_MISSING'
                ELSE 'UNKNOWN'
            END || ' | ' ||
            COALESCE(message, 'NO_MESSAGE')
        FROM medium
        WHERE image_path IS NOT NULL
          AND (enum_done IS NULL OR copy_done IS NULL)
        ORDER BY added_at;"

    echo
    echo "=== ARCHIVE INVENTORY ==="
    echo "CD-ROM sized archives (<1GB):"
    echo
    find /data/cold/img-read -name "*.tar.zst" -size -1G -printf "%TY-%Tm-%Td %TH:%TM | %10s bytes | %f\n" 2>/dev/null | sort || echo "(none found)"

    echo
    echo "=== RAW FILE INVENTORY ==="
    echo "Enumeration files without inode tables:"
    echo
    orphan_count=0
    for raw in /data/fast/raw/*.raw; do
        [[ -f "$raw" ]] || continue
        hash=$(basename "$raw" .raw | cut -d. -f1)
        if ! sudo -u postgres psql copyjob -tAc "\dt inode_p_${hash:0:8}*" 2>/dev/null | grep -q inode; then
            records=$(tr '\0' '\n' < "$raw" 2>/dev/null | wc -l)
            size=$(ls -lh "$raw" | awk '{print $5}')
            echo "$hash | Records: $records | Size: $size | MISSING_INODE_TABLE"
            orphan_count=$((orphan_count + 1))
        fi
    done

    if [[ $orphan_count -eq 0 ]]; then
        echo "(none found)"
    fi

    echo
    echo "=== STATISTICS ==="
    echo "Total orphaned raw files: $orphan_count"

    affected_count=$(sudo -u postgres psql copyjob -tAc "
        SELECT COUNT(*)
        FROM medium
        WHERE image_path IS NOT NULL
          AND (enum_done IS NULL OR copy_done IS NULL);")
    echo "Total affected media in database: $affected_count"

    echo
    echo "=== RECOMMENDATIONS ==="
    echo "1. Review affected media list above"
    echo "2. For each affected medium, run: bin/remediate-incomplete-media.sh <medium_hash>"
    echo "3. Verify BUG-015 fix is deployed before processing new media"
    echo "4. Consider re-imaging media if raw files are missing"
    echo "5. Stop all orchestrator runs until BUG-015 is fixed"

} | tee "$REPORT_FILE"

echo
echo "=========================================="
echo "Report saved to: $REPORT_FILE"
echo "=========================================="
