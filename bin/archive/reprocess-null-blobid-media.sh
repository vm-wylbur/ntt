#!/usr/bin/env bash
# Author: PB and Claude
# Date: 2025-11-21
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/bin/reprocess-null-blobid-media.sh
#
# Re-process media with null blobids where archives are available
# Usage: bin/reprocess-null-blobid-media.sh

set -euo pipefail

# Media with available archives in /data/cold/img-read
HASHES=(
  "4b871132e06f83375c42fd7f8e5cd437"  # 6,070 files, 316 MB
  "97239906f88d6799e3b4f22127b6905c"  # 5,761 files, 233 MB
  "bb98aecafc8d0f57d755abe0172887c3"  # 4 files, 651 KB
  "af1349b9f5f9a1a6a0404dea36dcc949"  # 3 files, 655 KB
  "b74dff654f21db1e0976b8b2baaed0af"  # 2 files, 3.3 GB
)

RECOVERY_DIR="/data/fast/img-read-recovery"
LOG_FILE="/var/log/ntt/reprocess-null-blobid-$(date +%Y%m%d-%H%M%S).log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "=========================================="
log "Re-processing ${#HASHES[@]} media with null blobids"
log "Recovery directory: $RECOVERY_DIR"
log "Log file: $LOG_FILE"
log "=========================================="
log ""

mkdir -p "$RECOVERY_DIR"
mkdir -p "$(dirname "$LOG_FILE")"

SUCCESS_COUNT=0
FAIL_COUNT=0

for hash in "${HASHES[@]}"; do
  log "=== Processing $hash ==="

  # Check archive exists
  ARCHIVE="/data/cold/img-read/${hash}.tar.zst"
  if [ ! -f "$ARCHIVE" ]; then
    log "❌ ERROR: Archive not found: $ARCHIVE"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi

  # Count null blobids before processing
  NULL_BEFORE=$(sudo -u postgres psql copyjob -tAc "
    SELECT COUNT(*)
    FROM paths
    WHERE medium_hash = '$hash'
      AND blobid IS NULL
      AND fs_type = 'f';
  " 2>&1 | grep -E '^[0-9]+$' || echo "0")

  log "  Files with null blobid: $NULL_BEFORE"

  if [ "$NULL_BEFORE" -eq "0" ]; then
    log "  ⏭️  SKIP: No null blobids found (already fixed?)"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    continue
  fi

  # Step 1: Reset copied flags for null blobid files
  log "  Step 1: Resetting copied flags..."
  sudo -u postgres psql copyjob -c "
    UPDATE paths
    SET copied = false,
        claimed_by = NULL,
        claimed_at = NULL
    WHERE medium_hash = '$hash'
      AND blobid IS NULL
      AND fs_type = 'f';
  " >> "$LOG_FILE" 2>&1

  # Step 2: Extract archive
  log "  Step 2: Extracting archive..."
  EXTRACT_DIR="${RECOVERY_DIR}/${hash}"
  mkdir -p "$EXTRACT_DIR"

  if tar -xf "$ARCHIVE" -C "$EXTRACT_DIR" >> "$LOG_FILE" 2>&1; then
    log "  ✓ Archive extracted to $EXTRACT_DIR"
  else
    log "  ❌ ERROR: Failed to extract archive"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    rm -rf "$EXTRACT_DIR"
    continue
  fi

  # Step 3: Run copier
  log "  Step 3: Running copier..."
  if sudo bin/ntt-copier.py --medium-hash "$hash" --workers 4 >> "$LOG_FILE" 2>&1; then
    log "  ✓ Copier completed"
  else
    EXIT_CODE=$?
    log "  ❌ ERROR: Copier failed with exit code $EXIT_CODE"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    rm -rf "$EXTRACT_DIR"
    continue
  fi

  # Step 4: Verify completion
  log "  Step 4: Verifying..."
  NULL_AFTER=$(sudo -u postgres psql copyjob -tAc "
    SELECT COUNT(*)
    FROM paths
    WHERE medium_hash = '$hash'
      AND blobid IS NULL
      AND fs_type = 'f';
  " 2>&1 | grep -E '^[0-9]+$' || echo "999999")

  log "  Files with null blobid after: $NULL_AFTER"

  if [ "$NULL_AFTER" -eq "0" ]; then
    log "  ✅ SUCCESS: All $NULL_BEFORE blobids restored"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  else
    REMAINING=$NULL_AFTER
    FIXED=$((NULL_BEFORE - NULL_AFTER))
    log "  ⚠️  PARTIAL: Fixed $FIXED, still have $REMAINING null blobids"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi

  # Step 5: Cleanup
  log "  Step 5: Cleaning up..."
  rm -rf "$EXTRACT_DIR"
  log ""
done

log "=========================================="
log "Summary:"
log "  ✅ Success: $SUCCESS_COUNT media"
log "  ❌ Failed/Partial: $FAIL_COUNT media"
log "=========================================="
log ""
log "Check detailed log: $LOG_FILE"

# Exit with error if any failures
if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
