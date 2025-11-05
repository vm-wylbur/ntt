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
# bash-logger: INTEGRATED (2025-11-05)

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

LOG_FILE="/var/log/ntt/backup-wrapper.jsonl"
BACKUP_ROOT="/mnt/ntt-backup"
MAX_RETRIES=3
BACKUP_SCRIPT="$SCRIPT_DIR/ntt-backup"

# Initialize logging
# shellcheck source=../lib/bash-logger.sh
source "$LIB_DIR/bash-logger.sh"
log_init || exit 1

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
    log_info "Attempting to remount $BACKUP_ROOT..."

    # Force unmount (lazy unmount to handle stale mounts)
    sudo umount -l "$BACKUP_ROOT" 2>/dev/null || true
    sleep 2

    # Mount
    if sudo mount "$BACKUP_ROOT"; then
        log_info "Remount successful"
        sleep 2
        return 0
    else
        log_error "Remount failed"
        return 1
    fi
}

# Main retry loop
for attempt in $(seq 1 $MAX_RETRIES); do
    log_info "Backup attempt $attempt/$MAX_RETRIES"

    # Check if mount is accessible
    if ! check_mount; then
        log_warn "Mount check failed - $BACKUP_ROOT not accessible"

        if ! remount_drive; then
            if [ $attempt -eq $MAX_RETRIES ]; then
                log_error "Failed to remount after $MAX_RETRIES attempts"
                exit 1
            fi
            log_info "Waiting 10 seconds before retry..."
            sleep 10
            continue
        fi
    else
        log_info "Mount check passed"
    fi

    # Run backup
    log_info "Starting backup..."
    if "$BACKUP_SCRIPT" "$@"; then
        log_info "Backup completed successfully"
        exit 0
    else
        exit_code=$?
        log_error "Backup failed with exit code $exit_code"

        if [ $attempt -eq $MAX_RETRIES ]; then
            log_error "Backup failed after $MAX_RETRIES attempts"
            exit $exit_code
        fi

        log_info "Waiting 30 seconds before retry..."
        sleep 30
    fi
done

log_error "Backup failed after $MAX_RETRIES attempts"
exit 1
