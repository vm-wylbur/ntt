#!/bin/bash
# Author: PB and Claude
# Date: 2025-10-31
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/bin/ntt-backup-usb.sh
#
# Backup by-hash from fastpool to USB drive using find-diff approach

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

LOG_FILE="/var/log/ntt/backup-usb.jsonl"
LOCK_FILE="/tmp/ntt-backup-usb.lock"

SOURCE="/data/fast/ntt/by-hash"
TARGET="/mnt/ntt-backup/by-hash"
BACKUP_ROOT="/mnt/ntt-backup"
EXPECTED_POOL="ntt-backup"
EXPECTED_POOL_GUID="6672977364352559054"

# Initialize logging
# shellcheck source=../lib/bash-logger.sh
source "$LIB_DIR/bash-logger.sh"
log_init || exit 1  # TODO: Add fallback to stderr-only logging if init fails

# Source common libraries
# shellcheck source=../lib/backup-rsync-common.sh
source "$LIB_DIR/backup-rsync-common.sh"
# shellcheck source=../lib/backup-find-diff.sh
source "$LIB_DIR/backup-find-diff.sh"

# Acquire lock
if ! get_lock "$LOCK_FILE"; then
    exit 1
fi

log_info "Starting USB backup job"

# USB-SPECIFIC: Validate ntt-backup pool is properly mounted
if ! validate_zfs_pool "$EXPECTED_POOL" "$BACKUP_ROOT"; then
    exit 1
fi

# Verify pool GUID to ensure it's the correct USB drive
ACTUAL_GUID=$(zpool get -H -o value guid "$EXPECTED_POOL" 2>/dev/null)
if [[ "$ACTUAL_GUID" != "$EXPECTED_POOL_GUID" ]]; then
    log_error "Pool GUID mismatch! Expected $EXPECTED_POOL_GUID, got $ACTUAL_GUID"
    log_error "This is not the expected ntt-backup USB drive"
    exit 1
fi
log_info "Pool GUID verified: $ACTUAL_GUID"

# Check if writable
if ! touch "$BACKUP_ROOT/.ntt-backup-test" 2>/dev/null; then
    log_error "$BACKUP_ROOT is not writable"
    exit 1
fi
rm -f "$BACKUP_ROOT/.ntt-backup-test"
log_info "$BACKUP_ROOT is writable"

# Ensure target directory exists
mkdir -p "$TARGET"
log_info "Target directory verified: $TARGET"

# Create temp directory for file lists
TEMP_DIR=$(mktemp -d /tmp/ntt-backup-usb.XXXXXX)
trap "cleanup_temp_files '$TEMP_DIR'" EXIT

SOURCE_LIST="$TEMP_DIR/source.txt"
DEST_LIST="$TEMP_DIR/dest.txt"
MISSING_LIST="$TEMP_DIR/missing.txt"

# Capture file lists
if ! capture_file_list "$SOURCE" "$SOURCE_LIST"; then
    exit 1
fi

if ! capture_file_list "$TARGET" "$DEST_LIST"; then
    exit 1
fi

# Find files that need copying (with corruption detection)
if ! diff_and_validate_lists "$SOURCE_LIST" "$DEST_LIST" "$MISSING_LIST" "false"; then
    exit 1
fi

# Rsync missing files
if ! rsync_from_list "$MISSING_LIST" "$SOURCE" "$TARGET"; then
    exit 1
fi

# =============================================================================
# Copy latest pgdump from coldpool
# =============================================================================

log_info "Checking for pgdump to copy from coldpool..."
SOURCE_PGDUMP_DIR="/data/cold/ntt-backup/pgdump"
DEST_PGDUMP_DIR="$BACKUP_ROOT/pgdump"

# Find latest dump from coldpool
LATEST_DUMP=$(ls -t "$SOURCE_PGDUMP_DIR"/copyjob-*.pgdump 2>/dev/null | head -1)

if [ -z "$LATEST_DUMP" ]; then
    log_warn "No pgdump file found in coldpool at $SOURCE_PGDUMP_DIR"
else
    DUMP_NAME=$(basename "$LATEST_DUMP")
    DEST_DUMP="$DEST_PGDUMP_DIR/$DUMP_NAME"
    SOURCE_SIZE=$(stat -c %s "$LATEST_DUMP" 2>/dev/null || echo "0")

    # Check if we already have this exact dump
    if [ -f "$DEST_DUMP" ]; then
        DEST_SIZE=$(stat -c %s "$DEST_DUMP" 2>/dev/null || echo "0")
        if [ "$SOURCE_SIZE" -eq "$DEST_SIZE" ]; then
            log_info "pgdump already up to date: $DUMP_NAME ($(numfmt --to=iec-i --suffix=B $SOURCE_SIZE))"
        else
            log_info "pgdump exists but size differs, re-copying: $DUMP_NAME"
            mkdir -p "$DEST_PGDUMP_DIR"
            if cp "$LATEST_DUMP" "$DEST_DUMP"; then
                log_info "pgdump copied successfully: $DUMP_NAME ($(numfmt --to=iec-i --suffix=B $SOURCE_SIZE))"
            else
                log_warn "Failed to copy pgdump"
            fi
        fi
    else
        log_info "Copying new pgdump: $DUMP_NAME ($(numfmt --to=iec-i --suffix=B $SOURCE_SIZE))"
        mkdir -p "$DEST_PGDUMP_DIR"
        if cp "$LATEST_DUMP" "$DEST_DUMP"; then
            log_info "pgdump copied successfully"
        else
            log_warn "Failed to copy pgdump"
        fi
    fi
fi

log_info "USB backup completed successfully"
