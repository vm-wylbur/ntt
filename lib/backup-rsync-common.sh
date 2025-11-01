#!/bin/bash
# Author: PB and Claude
# Date: 2025-10-31
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/lib/backup-rsync-common.sh
#
# Common functions for NTT backup scripts (rsync-based)

# Logging function with timestamp
log() {
    echo "[$(date -Iseconds)] $*" | tee -a "${LOG_FILE:-/dev/stderr}"
}

# Acquire exclusive lock using flock
# Usage: get_lock /tmp/my-script.lock
# Returns: 0 on success, 1 if already locked
get_lock() {
    local lock_file="$1"

    # Open file descriptor 200 for the lock file
    exec 200>"$lock_file"

    # Try to acquire non-blocking lock
    if ! flock -n 200; then
        log "ERROR: Another instance is already running (lock: $lock_file)"
        return 1
    fi

    log "INFO: Lock acquired (lock: $lock_file)"
    return 0
}

# Release lock (cleanup)
# Note: Lock is automatically released when script exits,
# but this can be called explicitly if needed
release_lock() {
    # Close file descriptor 200
    exec 200>&-
    log "INFO: Lock released"
}

# Validate ZFS pool is imported, mounted, and at expected mountpoint
# Usage: validate_zfs_pool <pool_name> <expected_mountpoint>
# Returns: 0 if valid, 1 if invalid
validate_zfs_pool() {
    local pool_name="$1"
    local expected_mountpoint="$2"

    # Check pool is imported
    if ! zpool list "$pool_name" &>/dev/null; then
        log "ERROR: Pool '$pool_name' is not imported"
        return 1
    fi
    log "INFO: Pool '$pool_name' is imported"

    # Check pool is mounted
    local mounted
    mounted="$(zfs get -H -o value mounted "$pool_name")"
    if [[ "$mounted" != "yes" ]]; then
        log "ERROR: Pool '$pool_name' is not mounted"
        return 1
    fi
    log "INFO: Pool '$pool_name' is mounted"

    # Check mountpoint matches expected
    local actual_mountpoint
    actual_mountpoint="$(zfs get -H -o value mountpoint "$pool_name")"
    if [[ "$actual_mountpoint" != "$expected_mountpoint" ]]; then
        log "ERROR: Pool '$pool_name' mountpoint is '$actual_mountpoint', expected '$expected_mountpoint'"
        return 1
    fi
    log "INFO: Pool '$pool_name' mountpoint verified at $expected_mountpoint"

    return 0
}

# Run rsync in append-only mode (never delete)
# Usage: run_rsync_append_only <source> <dest>
# Returns: rsync exit code
run_rsync_append_only() {
    local source="$1"
    local dest="$2"

    log "INFO: Starting rsync from $source to $dest"

    # rsync options:
    # -a: archive (recursive, preserve permissions/times/etc)
    # -v: verbose
    # --partial: keep partially transferred files
    # --ignore-existing: skip files that exist in destination (append-only)
    # --info=progress2: show progress
    if rsync -av \
        --partial \
        --ignore-existing \
        --info=progress2 \
        "$source" \
        "$dest" \
        2>&1 | tee -a "${LOG_FILE:-/dev/stderr}"; then
        log "INFO: rsync completed successfully"
        return 0
    else
        local exit_code=$?
        log "ERROR: rsync failed with exit code $exit_code"
        return $exit_code
    fi
}
