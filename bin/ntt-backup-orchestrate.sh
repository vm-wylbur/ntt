#!/bin/bash
# Author: PB and Claude
# Date: 2025-11-17
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/bin/ntt-backup-orchestrate.sh
#
# Orchestrate daily backup: coldpool → (chll || usb)
#
# Runs coldpool backup first, then if successful, runs chll and usb in parallel.
# Intended for daily cron at 00:15.

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

LOG_FILE="/var/log/ntt/backup-orchestrate.jsonl"
LOCK_FILE="/tmp/ntt-backup-orchestrate.lock"

COLDPOOL_SCRIPT="$SCRIPT_DIR/ntt-backup-coldpool.sh"
CHLL_SCRIPT="$SCRIPT_DIR/ntt-backup-chll.sh"
USB_SCRIPT="$SCRIPT_DIR/ntt-backup-usb.sh"

# Initialize logging
# shellcheck source=../lib/bash-logger.sh
source "$LIB_DIR/bash-logger.sh"
if ! log_init; then
  # Fallback to stderr-only logging if JSONL init fails
  echo "[$(date -Iseconds)] WARNING: JSONL logging unavailable, falling back to stderr" >&2
  log_info() { echo "[$(date -Iseconds)] INFO: $*" >&2; }
  log_warn() { echo "[$(date -Iseconds)] WARN: $*" >&2; }
  log_error() { echo "[$(date -Iseconds)] ERROR: $*" >&2; }
fi

# Source common libraries
# shellcheck source=../lib/backup-rsync-common.sh
source "$LIB_DIR/backup-rsync-common.sh"

# Acquire lock
if ! get_lock "$LOCK_FILE"; then
    exit 1
fi

log_info "Starting orchestrated backup job"

# =============================================================================
# Phase 1: Run coldpool backup
# =============================================================================

log_info "Phase 1: Running coldpool backup..."
if "$COLDPOOL_SCRIPT" >> /var/log/ntt/backup-coldpool-cron.log 2>&1; then
    log_info "Coldpool backup completed successfully"
else
    COLDPOOL_EXIT=$?
    log_error "Coldpool backup failed with exit code $COLDPOOL_EXIT"
    log_error "Aborting orchestration - chll and usb will not run"
    exit $COLDPOOL_EXIT
fi

# =============================================================================
# Phase 2: Run chll and usb in parallel
# =============================================================================

log_info "Phase 2: Running chll and usb backups in parallel..."

# Start both backups in background
"$CHLL_SCRIPT" >> /var/log/ntt/backup-chll-cron.log 2>&1 &
CHLL_PID=$!

"$USB_SCRIPT" >> /var/log/ntt/backup-usb-cron.log 2>&1 &
USB_PID=$!

log_info "Started chll (PID: $CHLL_PID) and usb (PID: $USB_PID)"

# Wait for both to complete
CHLL_EXIT=0
USB_EXIT=0
FAILURES=0

if wait $CHLL_PID; then
    log_info "chll backup completed successfully"
else
    CHLL_EXIT=$?
    log_warn "chll backup failed with exit code $CHLL_EXIT"
    FAILURES=$((FAILURES + 1))
fi

if wait $USB_PID; then
    log_info "usb backup completed successfully"
else
    USB_EXIT=$?
    log_warn "usb backup failed with exit code $USB_EXIT"
    FAILURES=$((FAILURES + 1))
fi

# =============================================================================
# Summary
# =============================================================================

if [ $FAILURES -eq 0 ]; then
    log_info "Orchestrated backup completed successfully (coldpool + chll + usb)"
    exit 0
elif [ $FAILURES -eq 1 ]; then
    log_warn "Orchestrated backup completed with 1 failure"
    exit 1
else
    log_error "Orchestrated backup completed with $FAILURES failures"
    exit 1
fi
