#!/bin/bash
# Author: PB and Claude
# Date: 2025-10-13
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/bin/ntt-create-backup-dirs.sh
#
# Create fixed directory structure for external backup drive
# Creates 65,536 directories: {00..ff}/{00..ff}

set -euo pipefail

BACKUP_ROOT="${1:-/mnt/ntt-backup/by-hash}"

echo "=== Creating backup directory structure ==="
echo ""
echo "Backup root: $BACKUP_ROOT"
echo "Creating 65,536 directories (256 x 256)..."
echo ""

# Create root
mkdir -p "$BACKUP_ROOT"

# Create all prefix directories
for prefix1 in {00..ff}; do
  for prefix2 in {00..ff}; do
    mkdir -p "$BACKUP_ROOT/$prefix1/$prefix2"
  done
  # Progress indicator every 16 directories (roughly every 6%)
  if [[ $((16#$prefix1 % 16)) -eq 0 ]]; then
    pct=$((16#$prefix1 * 100 / 256))
    echo "Progress: $pct% ($prefix1/ff)"
  fi
done

echo ""
echo "=== Directory structure complete ==="
echo ""
echo "Created: 65,536 blob directories"
echo "Location: $BACKUP_ROOT/{00..ff}/{00..ff}/"
echo ""

# Create pgdump directory
mkdir -p /mnt/ntt-backup/pgdump
echo "✓ Created: /mnt/ntt-backup/pgdump/"
echo ""
echo "Backup drive is ready!"
