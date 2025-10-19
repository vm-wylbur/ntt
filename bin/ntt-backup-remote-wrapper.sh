#!/bin/bash
# Author: PB and Claude
# Date: 2025-10-17
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/bin/ntt-backup-remote-wrapper.sh
#
# Wrapper for ntt-backup-remote with SSH connectivity validation and auto-recovery

set -euo pipefail

REMOTE_HOST="pball@chll-script"
REMOTE_PATH="/storage/pball"
SSH_KEY="/home/pball/.ssh/id_ed25519"
MAX_RETRIES=3
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="$SCRIPT_DIR/ntt-backup-remote"

log() {
    echo "[$(date -Iseconds)] $*"
}

check_ssh() {
    # Try to connect to remote host with timeout
    if timeout 10 ssh -i "$SSH_KEY" -o ConnectTimeout=10 "$REMOTE_HOST" 'echo connected' >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

check_remote_dirs() {
    # Check if remote directories exist and are writable
    if ssh -i "$SSH_KEY" "$REMOTE_HOST" "test -d $REMOTE_PATH/by-hash && test -d $REMOTE_PATH/pgdump && test -w $REMOTE_PATH" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Main retry loop
for attempt in $(seq 1 $MAX_RETRIES); do
    log "Remote backup attempt $attempt/$MAX_RETRIES"

    # Check SSH connectivity
    if ! check_ssh; then
        log "SSH connectivity check failed to $REMOTE_HOST"

        if [ $attempt -eq $MAX_RETRIES ]; then
            log "ERROR: Failed to connect after $MAX_RETRIES attempts"
            exit 1
        fi

        log "Waiting 30 seconds before retry..."
        sleep 30
        continue
    else
        log "SSH connectivity check passed"
    fi

    # Check remote directories
    if ! check_remote_dirs; then
        log "Remote directories check failed at $REMOTE_HOST:$REMOTE_PATH"

        if [ $attempt -eq $MAX_RETRIES ]; then
            log "ERROR: Remote directories not accessible after $MAX_RETRIES attempts"
            exit 1
        fi

        log "Waiting 10 seconds before retry..."
        sleep 10
        continue
    else
        log "Remote directories check passed"
    fi

    # Run backup
    log "Starting remote backup..."
    if "$BACKUP_SCRIPT" "$@"; then
        log "Remote backup completed successfully"
        exit 0
    else
        exit_code=$?
        log "Remote backup failed with exit code $exit_code"

        if [ $attempt -eq $MAX_RETRIES ]; then
            log "ERROR: Remote backup failed after $MAX_RETRIES attempts"
            exit $exit_code
        fi

        log "Waiting 30 seconds before retry..."
        sleep 30
    fi
done

log "ERROR: Remote backup failed after $MAX_RETRIES attempts"
exit 1
