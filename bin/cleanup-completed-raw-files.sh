#!/usr/bin/env bash
# Author: PB and Claude
# Date: Fri 18 Oct 2025
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/bin/cleanup-completed-raw-files.sh
#
# Remove raw enumeration files for completed media
# A medium is considered complete when both enum_done and copy_done are set

set -euo pipefail

RAW_DIR="/data/fast/raw"

echo "=========================================="
echo "Raw File Cleanup - Completed Media"
echo "=========================================="
echo

# Get list of completed media hashes
echo "=== Querying for completed media ==="
COMPLETED_HASHES=$(sudo -u postgres psql -d copyjob -tAc "
    SELECT medium_hash
    FROM medium
    WHERE enum_done IS NOT NULL
      AND copy_done IS NOT NULL
    ORDER BY medium_hash;
")

total_completed=$(echo "$COMPLETED_HASHES" | wc -l)
echo "Found $total_completed completed media"
echo

# Check which have raw files
echo "=== Checking for raw files to remove ==="
removed_count=0
missing_count=0
total_bytes=0

for hash in $COMPLETED_HASHES; do
    raw_file="$RAW_DIR/${hash}.raw"

    if [[ -f "$raw_file" ]]; then
        size=$(stat -c %s "$raw_file")
        total_bytes=$((total_bytes + size))

        echo "Removing: ${hash:0:8}.raw ($(numfmt --to=iec-i --suffix=B $size))"
        rm "$raw_file"
        removed_count=$((removed_count + 1))
    else
        missing_count=$((missing_count + 1))
    fi
done

echo
echo "=========================================="
echo "Cleanup Complete"
echo "=========================================="
echo "Total completed media: $total_completed"
echo "Raw files removed: $removed_count"
echo "Already missing: $missing_count"
echo "Space freed: $(numfmt --to=iec-i --suffix=B $total_bytes)"
echo

# Show remaining raw files
remaining=$(ls "$RAW_DIR"/*.raw 2>/dev/null | wc -l || echo 0)
echo "Remaining raw files: $remaining"

if [[ $remaining -gt 0 ]]; then
    echo
    echo "=== Remaining raw files belong to: ==="
    for raw in "$RAW_DIR"/*.raw; do
        [[ -f "$raw" ]] || continue
        hash=$(basename "$raw" .raw)

        # Check medium status
        status=$(sudo -u postgres psql -d copyjob -tAc "
            SELECT
                CASE
                    WHEN enum_done IS NULL AND copy_done IS NULL THEN 'NOT_PROCESSED'
                    WHEN enum_done IS NOT NULL AND copy_done IS NULL THEN 'ENUM_ONLY'
                    ELSE 'UNKNOWN'
                END
            FROM medium
            WHERE medium_hash = '$hash';
        " 2>/dev/null || echo "NO_RECORD")

        echo "  ${hash:0:8} - $status"
    done | head -20

    if [[ $remaining -gt 20 ]]; then
        echo "  ... and $((remaining - 20)) more"
    fi
fi
