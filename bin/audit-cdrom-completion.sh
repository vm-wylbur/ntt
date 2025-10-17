#!/usr/bin/env bash
# Author: PB and Claude
# Date: Sat 12 Oct 2025
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/bin/audit-cdrom-completion.sh
#
# Audit CD-ROM media for load/copy completion
# Identifies media affected by BUG-015 (orchestrator false success reporting)

set -euo pipefail

echo "=========================================="
echo "CD-ROM Completion Audit"
echo "=========================================="
echo

# Query 1: Media with NULL enum_done or copy_done
echo "=== Media with Incomplete Pipeline ==="
echo
sudo -u postgres psql copyjob <<EOF
\pset format wrapped
\pset columns 140

SELECT
    m.medium_hash,
    m.medium_human,
    m.message,
    m.image_path IS NOT NULL as has_image,
    m.enum_done IS NOT NULL as enum_complete,
    m.copy_done IS NOT NULL as copy_complete,
    m.health,
    m.added_at::date as added
FROM medium m
WHERE m.image_path IS NOT NULL  -- Has been imaged
  AND (m.enum_done IS NULL OR m.copy_done IS NULL)
ORDER BY m.added_at;
EOF

echo
echo "=== Checking for Orphaned Raw Files ==="
echo "Raw files without corresponding inode tables:"
echo

# Check each raw file for inode table
found_orphans=0
for raw in /data/fast/raw/*.raw; do
    [[ -f "$raw" ]] || continue

    hash=$(basename "$raw" .raw | cut -d. -f1)

    # Check if inode table exists (using partition prefix)
    if ! sudo -u postgres psql copyjob -tAc "\dt inode_p_${hash:0:8}*" 2>/dev/null | grep -q inode; then
        # Get record count
        records=$(tr '\0' '\n' < "$raw" 2>/dev/null | wc -l)
        size=$(ls -lh "$raw" | awk '{print $5}')

        # Check if archive exists
        archive_exists="NO"
        if [[ -f "/data/cold/img-read/${hash}.tar.zst" ]]; then
            archive_exists="YES"
        fi

        echo "  $hash | Records: $records | Size: $size | Archived: $archive_exists"
        found_orphans=$((found_orphans + 1))
    fi
done

if [[ $found_orphans -eq 0 ]]; then
    echo "  (none found)"
fi

echo
echo "=== Summary ==="
echo "Found $found_orphans raw files without inode tables"
echo "Run 'bin/remediate-incomplete-media.sh <medium_hash>' to fix individual media"
