#!/bin/bash
# Author: PB and Claude
# Date: 2025-10-14
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/bin/ntt-backup-wrapper.sh
#
# Wrapper for ntt-backup with mount validation and auto-recovery
#
# TODO: Migrate to bash-logger.sh (see ntt-backup-usb.sh for pattern)
#       1. Add LOG_FILE variable with .jsonl extension
#       2. Source bash-logger.sh and call log_init
#       3. Replace log() calls with log_info/log_warn/log_error

set -euo pipefail

BACKUP_ROOT="/mnt/ntt-backup"
MAX_RETRIES=3
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="$SCRIPT_DIR/ntt-backup"

log() {
    echo "[$(date -Iseconds)] $*"
}

check_mount() {
    # Try to access the backup directories with timeout
    if timeout 5 test -d "$BACKUP_ROOT/by-hash" 2>/dev/null && \
       timeout 5 test -d "$BACKUP_ROOT/pgdump" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

remount_drive() {
    log "Attempting to remount $BACKUP_ROOT..."

    # Force unmount (lazy unmount to handle stale mounts)
    sudo umount -l "$BACKUP_ROOT" 2>/dev/null || true
    sleep 2

    # Mount
    if sudo mount "$BACKUP_ROOT"; then
        log "Remount successful"
        sleep 2
        return 0
    else
        log "Remount failed"
        return 1
    fi
}

# Main retry loop
for attempt in $(seq 1 $MAX_RETRIES); do
    log "Backup attempt $attempt/$MAX_RETRIES"

    # Check if mount is accessible
    if ! check_mount; then
        log "Mount check failed - $BACKUP_ROOT not accessible"

        if ! remount_drive; then
            if [ $attempt -eq $MAX_RETRIES ]; then
                log "ERROR: Failed to remount after $MAX_RETRIES attempts"
                exit 1
            fi
            log "Waiting 10 seconds before retry..."
            sleep 10
            continue
        fi
    else
        log "Mount check passed"
    fi

    # Run backup
    log "Starting backup..."
    if "$BACKUP_SCRIPT" "$@"; then
        log "Backup completed successfully"
        exit 0
    else
        exit_code=$?
        log "Backup failed with exit code $exit_code"

        if [ $attempt -eq $MAX_RETRIES ]; then
            log "ERROR: Backup failed after $MAX_RETRIES attempts"
            exit $exit_code
        fi

        log "Waiting 30 seconds before retry..."
        sleep 30
    fi
done

log "ERROR: Backup failed after $MAX_RETRIES attempts"
exit 1
