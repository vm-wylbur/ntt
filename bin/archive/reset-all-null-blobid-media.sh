#!/usr/bin/env bash
# Author: PB and Claude
# Date: 2025-11-21
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/bin/reset-all-null-blobid-media.sh
#
# Reset ALL media with null blobids to prepare for systematic re-processing
# This resets both:
#   - 17 media with copied=true (not yet reset)
#   - 46 media with copied=false (already reset, but verifying state)
#
# Usage: bin/reset-all-null-blobid-media.sh

set -euo pipefail

LOG_FILE="$HOME/tmp/reset-null-blobid-$(date +%Y%m%d-%H%M%S).log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "=========================================="
log "Resetting ALL media with null blobids"
log "Log file: $LOG_FILE"
log "=========================================="
log ""

# Get current counts
log "Current status:"
COPIED_TRUE=$(sudo -u postgres psql copyjob -tAc "
  SELECT COUNT(DISTINCT medium_hash)
  FROM paths
  WHERE blobid IS NULL AND copied = true AND fs_type = 'f';
")
COPIED_FALSE=$(sudo -u postgres psql copyjob -tAc "
  SELECT COUNT(DISTINCT medium_hash)
  FROM paths
  WHERE blobid IS NULL AND copied = false AND fs_type = 'f';
")
TOTAL_FILES=$(sudo -u postgres psql copyjob -tAc "
  SELECT COUNT(*)
  FROM paths
  WHERE blobid IS NULL AND fs_type = 'f';
")

log "  Media with copied=true: $COPIED_TRUE"
log "  Media with copied=false: $COPIED_FALSE"
log "  Total files with null blobid: $TOTAL_FILES"
log ""

# Confirm with user
log "This will reset copied=false for ALL $TOTAL_FILES files across $((COPIED_TRUE + COPIED_FALSE)) media."
read -p "Continue? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
  log "Aborted by user"
  exit 1
fi

log ""
log "Performing reset..."

# Reset all null blobid files to copied=false
sudo -u postgres psql copyjob -c "
  UPDATE paths
  SET copied = false,
      claimed_by = NULL,
      claimed_at = NULL
  WHERE blobid IS NULL
    AND fs_type = 'f';
" >> "$LOG_FILE" 2>&1

log "Reset completed"
log ""

# Verify
log "Verifying reset..."
AFTER_TRUE=$(sudo -u postgres psql copyjob -tAc "
  SELECT COUNT(DISTINCT medium_hash)
  FROM paths
  WHERE blobid IS NULL AND copied = true AND fs_type = 'f';
")
AFTER_FALSE=$(sudo -u postgres psql copyjob -tAc "
  SELECT COUNT(DISTINCT medium_hash)
  FROM paths
  WHERE blobid IS NULL AND copied = false AND fs_type = 'f';
")

log "After reset:"
log "  Media with copied=true: $AFTER_TRUE (should be 0)"
log "  Media with copied=false: $AFTER_FALSE (should be $((COPIED_TRUE + COPIED_FALSE)))"
log ""

if [ "$AFTER_TRUE" -eq 0 ]; then
  log "✅ SUCCESS: All null blobid files reset to copied=false"
  log ""
  log "Next step: Use ntt-copier.py to reprocess media one at a time"
  log "The copier will claim work from the reset files and properly record I/O errors"
  exit 0
else
  log "❌ ERROR: Still have $AFTER_TRUE media with copied=true"
  exit 1
fi
