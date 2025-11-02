#!/bin/bash
# Author: PB and Claude
# Date: 2025-10-31
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/bin/ntt-backup-coldpool.sh
#
# Backup by-hash from fastpool to coldpool using find-diff approach
#
# bash-logger: INTEGRATED (2025-11-02)

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

LOG_FILE="/var/log/ntt/backup-coldpool.jsonl"
LOCK_FILE="/tmp/ntt-backup-coldpool.lock"

SOURCE="/data/fast/ntt/by-hash"
TARGET="/data/cold/ntt-backup/by-hash"

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

log_info "Starting coldpool backup job"

# Validate coldpool is properly mounted
if ! validate_zfs_pool "coldpool" "/data/cold"; then
    exit 1
fi

# =============================================================================
# pg_dump Decision Logic: Check if database has changed since last dump
# =============================================================================

DO_PGDUMP=false
PGDUMP_REASON=""
PGDUMP_DIR="/data/cold/ntt-backup/pgdump"
STATE_FILE="$PGDUMP_DIR/.last_dump_state"

# Get current database state
log_info "Checking database state for pg_dump decision..."
CURRENT_XACT=$(sudo -u postgres psql -tAc "SELECT xact_commit FROM pg_stat_database WHERE datname='copyjob'" 2>/dev/null || echo "0")
CURRENT_MODS=$(sudo -u postgres psql -tAc "SELECT tup_inserted + tup_updated + tup_deleted FROM pg_stat_database WHERE datname='copyjob'" 2>/dev/null || echo "0")

if [ "$CURRENT_XACT" = "0" ] || [ "$CURRENT_MODS" = "0" ]; then
    log_warn "Could not query database state, will skip pg_dump this run"
    DO_PGDUMP=false
    PGDUMP_REASON="Database query failed"
elif [ ! -f "$STATE_FILE" ]; then
    DO_PGDUMP=true
    PGDUMP_REASON="No previous dump state found (initial dump)"
else
    # Load previous state
    source "$STATE_FILE"

    # Check if data has changed
    if [ "$CURRENT_XACT" -ne "${XACT_COMMIT:-0}" ] || [ "$CURRENT_MODS" -ne "${TUP_MODIFIED:-0}" ]; then
        XACT_DIFF=$((CURRENT_XACT - ${XACT_COMMIT:-0}))
        MODS_DIFF=$((CURRENT_MODS - ${TUP_MODIFIED:-0}))
        DO_PGDUMP=true
        PGDUMP_REASON="Database changed: +$XACT_DIFF transactions, +$MODS_DIFF row modifications"
    else
        # No changes, but check age as safety fallback
        if [ -n "${DUMP_TIMESTAMP:-}" ]; then
            DUMP_AGE_SECONDS=$(( $(date +%s) - $(date -d "$DUMP_TIMESTAMP" +%s 2>/dev/null || echo "0") ))
            DUMP_AGE_HOURS=$(( DUMP_AGE_SECONDS / 3600 ))

            if [ $DUMP_AGE_HOURS -gt 168 ]; then  # 7 days
                DO_PGDUMP=true
                PGDUMP_REASON="Dump is ${DUMP_AGE_HOURS} hours old (>7 days), safety refresh"
            else
                DO_PGDUMP=false
                PGDUMP_REASON="No changes since last dump (${DUMP_AGE_HOURS} hours ago)"
            fi
        else
            DO_PGDUMP=false
            PGDUMP_REASON="No changes detected"
        fi
    fi
fi

log_info "pg_dump decision: $DO_PGDUMP - $PGDUMP_REASON"

# Start pg_dump in background if needed
PGDUMP_PID=""
DUMP_FILE=""
DUMP_COMPLETE=false

if [ "$DO_PGDUMP" = "true" ]; then
    TIMESTAMP=$(date -Iseconds)
    DUMP_FILE="$PGDUMP_DIR/copyjob-$TIMESTAMP.pgdump"

    log_info "Starting pg_dump in background to: $DUMP_FILE"
    mkdir -p "$PGDUMP_DIR"

    # Start dump in background
    sudo -u postgres pg_dump -Fc copyjob > "$DUMP_FILE" 2>&1 &
    PGDUMP_PID=$!
    log_info "pg_dump started (PID: $PGDUMP_PID)"
fi

# COLDPOOL-SPECIFIC: Fix ownership (fast on NVMe-backed metadata, ~2-3 minutes)
# This is needed because some processes create files with wrong ownership
log_info "Fixing ownership of /data/cold..."
if sudo chown -R pball:pball /data/cold; then
    log_info "Ownership fix completed"
else
    log_error "chown failed with exit code $?"
    exit 1
fi

# Ensure target directory exists
mkdir -p "$TARGET"
log_info "Target directory verified: $TARGET"

# Create temp directory for file lists
TEMP_DIR=$(mktemp -d /tmp/ntt-backup-coldpool.XXXXXX)

# Enhanced cleanup function to handle incomplete pg_dump
cleanup_backup() {
    cleanup_temp_files "$TEMP_DIR"

    # Clean up incomplete dump if script fails
    if [ "$DUMP_COMPLETE" = "false" ] && [ -n "$DUMP_FILE" ] && [ -f "$DUMP_FILE" ]; then
        log_warn "Cleaning up incomplete dump: $DUMP_FILE"
        rm -f "$DUMP_FILE"
    fi
}
trap cleanup_backup EXIT

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
if ! diff_and_validate_lists "$SOURCE_LIST" "$DEST_LIST" "$MISSING_LIST"; then
    exit 1
fi

# Rsync missing files
if ! rsync_from_list "$MISSING_LIST" "$SOURCE" "$TARGET"; then
    exit 1
fi

# =============================================================================
# Wait for pg_dump to complete and save state
# =============================================================================

if [ -n "$PGDUMP_PID" ]; then
    log_info "Waiting for pg_dump to complete (PID: $PGDUMP_PID)..."

    if wait $PGDUMP_PID; then
        DUMP_COMPLETE=true
        DUMP_SIZE=$(stat -c %s "$DUMP_FILE" 2>/dev/null || echo "0")
        DUMP_SIZE_GB=$(awk "BEGIN {printf \"%.2f\", $DUMP_SIZE / 1024 / 1024 / 1024}")
        log_info "pg_dump completed successfully (${DUMP_SIZE_GB} GB)"

        # Save state for next run
        log_info "Saving dump state to: $STATE_FILE"
        cat > "$STATE_FILE" <<EOF
# Last successful pg_dump state
DUMP_TIMESTAMP=$TIMESTAMP
DUMP_FILE=$(basename "$DUMP_FILE")
XACT_COMMIT=$CURRENT_XACT
TUP_MODIFIED=$CURRENT_MODS
DUMP_SIZE=$DUMP_SIZE
EOF
    else
        DUMP_EXIT=$?
        log_warn "pg_dump failed with exit code $DUMP_EXIT"
        log_warn "File backup succeeded but database dump failed"
        # Don't exit 1 - file backup is more critical
    fi
else
    log_info "pg_dump was skipped this run"
fi

log_info "Coldpool backup completed successfully"
