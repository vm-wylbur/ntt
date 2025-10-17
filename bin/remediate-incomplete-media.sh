#!/usr/bin/env bash
# Author: PB and Claude
# Date: Sat 12 Oct 2025
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/bin/remediate-incomplete-media.sh
#
# Manually run load and copy for incomplete medium
# Usage: bin/remediate-incomplete-media.sh <medium_hash>

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <medium_hash>"
    exit 1
fi

MEDIUM_HASH="$1"
RAW_FILE="/data/fast/raw/${MEDIUM_HASH}.raw"

if [[ ! -f "$RAW_FILE" ]]; then
    echo "ERROR: Raw file not found: $RAW_FILE"
    echo "Cannot remediate without enumeration data"
    exit 1
fi

echo "=========================================="
echo "Remediating Medium: $MEDIUM_HASH"
echo "=========================================="
echo

# Step 1: Check current state
echo "=== Current Database State ==="
sudo -u postgres psql copyjob -c "
    SELECT medium_hash, medium_human, enum_done, copy_done, message
    FROM medium
    WHERE medium_hash = '$MEDIUM_HASH';"

# Step 2: Run loader
echo
echo "=== STEP 1: Running Loader ==="
echo "Loading from: $RAW_FILE"
echo

if sudo bin/ntt-loader "$RAW_FILE" "$MEDIUM_HASH"; then
    echo "✓ Loader completed successfully"
else
    EXIT_CODE=$?
    echo "✗ Loader failed with exit code $EXIT_CODE"
    exit 1
fi

# Step 3: Verify inode table created
echo
echo "=== STEP 2: Verifying Inode Table ==="
TABLE_NAME=$(sudo -u postgres psql copyjob -tAc "\dt inode_p_${MEDIUM_HASH:0:8}*" 2>/dev/null | head -1 | awk '{print $3}')

if [[ -z "$TABLE_NAME" ]]; then
    echo "✗ ERROR: No inode table created!"
    echo "Loader reported success but table is missing"
    exit 1
fi

echo "✓ Found inode table: $TABLE_NAME"

# Count records
FILE_COUNT=$(sudo -u postgres psql copyjob -tAc "SELECT COUNT(*) FROM $TABLE_NAME WHERE typ='f';")
DIR_COUNT=$(sudo -u postgres psql copyjob -tAc "SELECT COUNT(*) FROM $TABLE_NAME WHERE typ='d';")
TOTAL_COUNT=$(sudo -u postgres psql copyjob -tAc "SELECT COUNT(*) FROM $TABLE_NAME;")

echo "  Total records: $TOTAL_COUNT"
echo "  Files: $FILE_COUNT"
echo "  Directories: $DIR_COUNT"

# Step 4: Check if medium is mounted
echo
echo "=== STEP 3: Checking Mount ==="
MOUNT_POINT=""

if findmnt "/mnt/ntt/${MEDIUM_HASH}" >/dev/null 2>&1; then
    echo "✓ Medium is mounted at /mnt/ntt/${MEDIUM_HASH}"
    MOUNT_POINT="/mnt/ntt/${MEDIUM_HASH}"
elif findmnt "/mnt/ntt/${MEDIUM_HASH}/p1" >/dev/null 2>&1; then
    echo "✓ Medium is mounted (multi-partition at /p1)"
    MOUNT_POINT="/mnt/ntt/${MEDIUM_HASH}/p1"
else
    echo "! Medium not mounted - mounting now..."
    IMG_FILE="/data/fast/img/${MEDIUM_HASH}.img"

    if [[ ! -f "$IMG_FILE" ]]; then
        echo "✗ ERROR: Image file not found: $IMG_FILE"
        echo "Cannot proceed with copy without mounted filesystem"
        exit 1
    fi

    if sudo bin/ntt-mount-helper mount "$MEDIUM_HASH" "$IMG_FILE"; then
        echo "✓ Mounted successfully"
        # Recheck mount point
        if findmnt "/mnt/ntt/${MEDIUM_HASH}" >/dev/null 2>&1; then
            MOUNT_POINT="/mnt/ntt/${MEDIUM_HASH}"
        elif findmnt "/mnt/ntt/${MEDIUM_HASH}/p1" >/dev/null 2>&1; then
            MOUNT_POINT="/mnt/ntt/${MEDIUM_HASH}/p1"
        else
            echo "✗ ERROR: Mount succeeded but cannot find mount point"
            exit 1
        fi
    else
        echo "✗ Mount failed - cannot proceed with copy"
        exit 1
    fi
fi

echo "  Mount point: $MOUNT_POINT"

# Step 5: Run copier
echo
echo "=== STEP 4: Running Copier ==="
echo "This may take a while depending on file count ($FILE_COUNT files)..."
echo

if sudo bin/ntt-copier.py --medium-hash "$MEDIUM_HASH" --workers 4; then
    echo "✓ Copier completed successfully"
else
    EXIT_CODE=$?
    echo "✗ Copier failed with exit code $EXIT_CODE"
    exit 1
fi

# Step 6: Verify completion
echo
echo "=== STEP 5: Verification ==="
sudo -u postgres psql copyjob -c "
    SELECT
        medium_hash,
        enum_done IS NOT NULL as enum_done,
        copy_done IS NOT NULL as copy_done,
        message
    FROM medium
    WHERE medium_hash = '$MEDIUM_HASH';"

# Final check
ENUM_DONE=$(sudo -u postgres psql copyjob -tAc "SELECT enum_done IS NOT NULL FROM medium WHERE medium_hash = '$MEDIUM_HASH';")
COPY_DONE=$(sudo -u postgres psql copyjob -tAc "SELECT copy_done IS NOT NULL FROM medium WHERE medium_hash = '$MEDIUM_HASH';")

echo
if [[ "$ENUM_DONE" == "t" ]] && [[ "$COPY_DONE" == "t" ]]; then
    echo "=========================================="
    echo "✓ Remediation Complete for $MEDIUM_HASH"
    echo "=========================================="
    exit 0
else
    echo "=========================================="
    echo "✗ Remediation Incomplete"
    echo "  enum_done: $ENUM_DONE"
    echo "  copy_done: $COPY_DONE"
    echo "=========================================="
    exit 1
fi
