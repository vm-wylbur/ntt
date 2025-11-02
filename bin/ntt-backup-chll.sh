#!/bin/bash
# Author: PB and Claude
# Date: 2025-10-31
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/bin/ntt-backup-chll.sh
#
# Backup by-hash to remote server (chll) using find-diff approach
#
# Usage: ntt-backup-chll.sh [--force]
#   --force: Overwrite files with size mismatches (use when recovering from corruption)
#
# TODO: Migrate to bash-logger.sh (DEFERRED: waiting for current 36h+ run to complete)
#       See ntt-backup-usb.sh for migration pattern

set -euo pipefail

# Parse arguments
FORCE_OVERWRITE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE_OVERWRITE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--force]"
            exit 1
            ;;
    esac
done

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

LOG_FILE="/var/log/ntt/backup-chll.log"
LOCK_FILE="/tmp/ntt-backup-chll.lock"

SOURCE="/data/fast/ntt/by-hash"
REMOTE_HOST="chll"
REMOTE_PATH="/storage/pball/by-hash"
REMOTE_POOL="deep_chll"
REMOTE_MOUNTPOINT="/storage"

# Source common libraries
# shellcheck source=../lib/backup-rsync-common.sh
source "$LIB_DIR/backup-rsync-common.sh"
# shellcheck source=../lib/backup-find-diff.sh
source "$LIB_DIR/backup-find-diff.sh"

# Acquire lock
if ! get_lock "$LOCK_FILE"; then
    exit 1
fi

log "INFO: Starting remote backup job to $REMOTE_HOST"
if [[ "$FORCE_OVERWRITE" == "true" ]]; then
    log "WARNING: Force mode enabled - will overwrite files with size mismatches"
fi

# REMOTE-SPECIFIC: Validate remote ZFS pool is mounted
log "INFO: Checking remote pool $REMOTE_POOL..."
REMOTE_MOUNTED=$(ssh "$REMOTE_HOST" "zfs get -H -o value mounted '$REMOTE_POOL'" 2>/dev/null)
if [[ "$REMOTE_MOUNTED" != "yes" ]]; then
    log "ERROR: Remote pool '$REMOTE_POOL' is not mounted on $REMOTE_HOST"
    exit 1
fi
log "INFO: Remote pool '$REMOTE_POOL' is mounted"

# Verify remote mountpoint
REMOTE_MP=$(ssh "$REMOTE_HOST" "zfs get -H -o value mountpoint '$REMOTE_POOL'" 2>/dev/null)
if [[ "$REMOTE_MP" != "$REMOTE_MOUNTPOINT" ]]; then
    log "ERROR: Remote pool mountpoint is '$REMOTE_MP', expected '$REMOTE_MOUNTPOINT'"
    exit 1
fi
log "INFO: Remote pool mountpoint verified at $REMOTE_MOUNTPOINT"

# Ensure remote target directory exists
log "INFO: Ensuring remote directory exists: $REMOTE_PATH"
if ! ssh "$REMOTE_HOST" "mkdir -p '$REMOTE_PATH'"; then
    log "ERROR: Failed to create remote directory"
    exit 1
fi

# Create temp directory for file lists
TEMP_DIR=$(mktemp -d /tmp/ntt-backup-chll.XXXXXX)
trap "cleanup_temp_files '$TEMP_DIR'" EXIT

SOURCE_LIST="$TEMP_DIR/source.txt"
DEST_LIST="$TEMP_DIR/dest.txt"
MISSING_LIST="$TEMP_DIR/missing.txt"

# Capture local file list
if ! capture_file_list "$SOURCE" "$SOURCE_LIST"; then
    exit 1
fi

# Capture remote file list (streaming through SSH)
if ! capture_remote_file_list "$REMOTE_HOST" "$REMOTE_PATH" "$DEST_LIST"; then
    exit 1
fi

# Find files that need copying (with corruption detection)
if ! diff_and_validate_lists "$SOURCE_LIST" "$DEST_LIST" "$MISSING_LIST" "$FORCE_OVERWRITE"; then
    exit 1
fi

# Rsync missing files to remote
if ! rsync_from_list "$MISSING_LIST" "$SOURCE" "$REMOTE_PATH" "$REMOTE_HOST"; then
    exit 1
fi

# =============================================================================
# Copy latest pgdump to remote
# =============================================================================

log "INFO: Checking for pgdump to copy to remote..."
SOURCE_PGDUMP_DIR="/data/cold/ntt-backup/pgdump"
REMOTE_PGDUMP_DIR="$REMOTE_MOUNTPOINT/pball/pgdump"

# Find latest dump from coldpool
LATEST_DUMP=$(ls -t "$SOURCE_PGDUMP_DIR"/copyjob-*.pgdump 2>/dev/null | head -1)

if [ -z "$LATEST_DUMP" ]; then
    log "WARNING: No pgdump file found in coldpool at $SOURCE_PGDUMP_DIR"
else
    DUMP_NAME=$(basename "$LATEST_DUMP")
    SOURCE_SIZE=$(stat -c %s "$LATEST_DUMP" 2>/dev/null || echo "0")

    # Check if remote already has this dump (by name and size)
    REMOTE_SIZE=$(ssh "$REMOTE_HOST" "stat -c %s '$REMOTE_PGDUMP_DIR/$DUMP_NAME' 2>/dev/null" || echo "0")

    if [ "$REMOTE_SIZE" -eq "$SOURCE_SIZE" ] && [ "$REMOTE_SIZE" -gt "0" ]; then
        log "INFO: pgdump already up to date on remote: $DUMP_NAME ($(numfmt --to=iec-i --suffix=B $SOURCE_SIZE))"
    else
        log "INFO: Copying pgdump to remote: $DUMP_NAME ($(numfmt --to=iec-i --suffix=B $SOURCE_SIZE))"

        # Ensure remote directory exists
        if ! ssh "$REMOTE_HOST" "mkdir -p '$REMOTE_PGDUMP_DIR'"; then
            log "WARNING: Failed to create remote pgdump directory"
        elif rsync -av --partial "$LATEST_DUMP" "$REMOTE_HOST:$REMOTE_PGDUMP_DIR/" 2>&1 | tee -a "${LOG_FILE:-/dev/stderr}"; then
            log "INFO: pgdump copied successfully to remote"
        else
            log "WARNING: Failed to copy pgdump to remote"
        fi
    fi
fi

log "INFO: Remote backup to $REMOTE_HOST completed successfully"
