#!/usr/bin/env bash
# Author: PB and Claude
# Date: 2025-10-06
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/test/test-detach-attach-pattern.sh
#
# Test script to validate DETACH → TRUNCATE → Load → ATTACH pattern
# Tests the solution recommended by all 3 external AIs (Gemini, Web-Claude, ChatGPT)
#
# Critical test: Does CHECK constraint requirement (Web-Claude's emphasis) actually matter?
#
# Usage:
#   ./test-detach-attach-pattern.sh test_final_100k    # Small test (100K paths)
#   ./test-detach-attach-pattern.sh baseline_1m        # Medium test (1M paths)
#   ./test-detach-attach-pattern.sh bb226d2ae226b3e048f486e38c55b3bd  # Full test (11.2M paths)

set -euo pipefail

MEDIUM_HASH=${1:?Usage: $0 <medium_hash>}
DB_URL=${NTT_DB_URL:-postgres:///copyjob}

# Look up partition names by checking pg_partitioned_table
# This uses PostgreSQL's partition catalog to find which partition holds this medium_hash
INODE_PARTITION=$(psql "$DB_URL" -qt -A << EOF | tr -d ' '
SELECT c.relname
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_inherits i ON i.inhrelid = c.oid
JOIN pg_catalog.pg_class p ON p.oid = i.inhparent
WHERE p.relname = 'inode'
  AND c.relname ~ '^inode_p_'
  AND (
    SELECT count(*) FROM inode
    WHERE tableoid = c.oid
      AND medium_hash = '$MEDIUM_HASH'
  ) > 0
LIMIT 1;
EOF
)

PATH_PARTITION=$(psql "$DB_URL" -qt -A << EOF | tr -d ' '
SELECT c.relname
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_inherits i ON i.inhrelid = c.oid
JOIN pg_catalog.pg_class p ON p.oid = i.inhparent
WHERE p.relname = 'path'
  AND c.relname ~ '^path_p_'
  AND (
    SELECT count(*) FROM path
    WHERE tableoid = c.oid
      AND medium_hash = '$MEDIUM_HASH'
  ) > 0
LIMIT 1;
EOF
)

if [[ -z "$INODE_PARTITION" ]] || [[ -z "$PATH_PARTITION" ]]; then
    echo "ERROR: Could not find partitions for medium_hash: $MEDIUM_HASH"
    echo "Available media:"
    psql "$DB_URL" -c "SELECT medium_hash, added_at FROM medium ORDER BY added_at;"
    exit 1
fi

echo "=========================================="
echo "DETACH/ATTACH Pattern Test"
echo "=========================================="
echo "Medium hash: $MEDIUM_HASH"
echo "Inode partition: $INODE_PARTITION"
echo "Path partition: $PATH_PARTITION"
echo ""

# ---------- Verify partition exists ----------
echo "[1] Verifying partition exists..."
PARTITION_EXISTS=$(psql "$DB_URL" -qt -A -c "
SELECT count(*) FROM pg_class
WHERE relname IN ('$INODE_PARTITION', '$PATH_PARTITION')
" | tr -d ' ')

if [[ "$PARTITION_EXISTS" != "2" ]]; then
    echo "ERROR: Partitions do not exist. Found '$PARTITION_EXISTS' (expected 2)"
    exit 1
fi
echo "✓ Both partitions exist"
echo ""

# ---------- Get current row counts ----------
echo "[2] Getting current row counts..."
INODE_COUNT=$(psql "$DB_URL" -qt -A -c "SELECT count(*) FROM $INODE_PARTITION" | tr -d ' ')
PATH_COUNT=$(psql "$DB_URL" -qt -A -c "SELECT count(*) FROM $PATH_PARTITION" | tr -d ' ')
echo "Current data: $INODE_COUNT inodes, $PATH_COUNT paths"
echo ""

# ---------- Step 1: DETACH partitions ----------
echo "[3] DETACH partitions (removes FK temporarily)..."
START_DETACH=$(date +%s)

psql "$DB_URL" << EOF
-- DETACH CONCURRENTLY allows queries to continue during detach
-- Should take 1-2 seconds according to Gemini
ALTER TABLE inode DETACH PARTITION $INODE_PARTITION CONCURRENTLY;
ALTER TABLE path DETACH PARTITION $PATH_PARTITION CONCURRENTLY;
EOF

END_DETACH=$(date +%s)
DETACH_TIME=$((END_DETACH - START_DETACH))
echo "✓ DETACH completed in ${DETACH_TIME}s"
echo ""

# ---------- Step 2: TRUNCATE (clear old data) ----------
echo "[4] TRUNCATE partitions (metadata-only operation)..."
START_TRUNCATE=$(date +%s)

psql "$DB_URL" -c "TRUNCATE $INODE_PARTITION, $PATH_PARTITION CASCADE;"

END_TRUNCATE=$(date +%s)
TRUNCATE_TIME=$((END_TRUNCATE - START_TRUNCATE))
echo "✓ TRUNCATE completed in ${TRUNCATE_TIME}s"
echo ""

# ---------- Step 3: Load new data ----------
echo "[5] Loading data (simulating fresh load)..."
echo "    In production, this would be: ntt-loader /data/fast/raw/file.raw $MEDIUM_HASH"
echo "    For this test, we'll copy data back from inode_old/path_old..."
START_LOAD=$(date +%s)

psql "$DB_URL" << EOF
-- Restore data from backup tables (simulates fresh load)
INSERT INTO $INODE_PARTITION (medium_hash, dev, ino, nlink, size, mtime)
SELECT medium_hash, dev, ino, nlink, size, mtime
FROM inode_old
WHERE medium_hash = '$MEDIUM_HASH';

INSERT INTO $PATH_PARTITION (medium_hash, dev, ino, path, broken, blobid, exclude_reason)
SELECT medium_hash, dev, ino, path, broken, blobid, exclude_reason
FROM path_old
WHERE medium_hash = '$MEDIUM_HASH';
EOF

END_LOAD=$(date +%s)
LOAD_TIME=$((END_LOAD - START_LOAD))
NEW_INODE_COUNT=$(psql "$DB_URL" -qt -A -c "SELECT count(*) FROM $INODE_PARTITION" | tr -d ' ')
NEW_PATH_COUNT=$(psql "$DB_URL" -qt -A -c "SELECT count(*) FROM $PATH_PARTITION" | tr -d ' ')
echo "✓ Load completed in ${LOAD_TIME}s"
echo "  Loaded: $NEW_INODE_COUNT inodes, $NEW_PATH_COUNT paths"
echo ""

# ---------- Step 4a: ATTACH WITHOUT CHECK constraint (baseline) ----------
echo "[6a] TEST 1: ATTACH WITHOUT CHECK constraint (baseline timing)..."
echo "     This should take 3-5 minutes according to Gemini (full table scan)"
START_ATTACH_NO_CHECK=$(date +%s)

psql "$DB_URL" << EOF
-- Re-attach inode partition first (path FK depends on it)
ALTER TABLE inode ATTACH PARTITION $INODE_PARTITION
  FOR VALUES IN ('$MEDIUM_HASH');
EOF

END_ATTACH_INODE=$(date +%s)
ATTACH_INODE_NO_CHECK=$((END_ATTACH_INODE - START_ATTACH_NO_CHECK))
echo "  ✓ Inode ATTACH completed in ${ATTACH_INODE_NO_CHECK}s"

psql "$DB_URL" << EOF
ALTER TABLE path ATTACH PARTITION $PATH_PARTITION
  FOR VALUES IN ('$MEDIUM_HASH');
EOF

END_ATTACH_NO_CHECK=$(date +%s)
ATTACH_PATH_NO_CHECK=$((END_ATTACH_NO_CHECK - END_ATTACH_INODE))
TOTAL_ATTACH_NO_CHECK=$((END_ATTACH_NO_CHECK - START_ATTACH_NO_CHECK))
echo "  ✓ Path ATTACH completed in ${ATTACH_PATH_NO_CHECK}s"
echo "✓ Total ATTACH time (no CHECK): ${TOTAL_ATTACH_NO_CHECK}s"
echo ""

# ---------- Verify data integrity ----------
echo "[7] Verifying data integrity after ATTACH..."
VERIFY_RESULT=$(psql "$DB_URL" -qt -A << EOF
-- Check all paths have valid inode references
SELECT count(*) FROM $PATH_PARTITION p
WHERE NOT EXISTS (
  SELECT 1 FROM $INODE_PARTITION i
  WHERE i.medium_hash = p.medium_hash AND i.ino = p.ino
);
EOF
)

if [[ "$VERIFY_RESULT" = "0" ]]; then
    echo "✓ All FK constraints validated correctly"
else
    echo "ERROR: Found $VERIFY_RESULT orphaned paths"
    exit 1
fi
echo ""

# ---------- Now test WITH CHECK constraint ----------
echo "[8] Preparing for TEST 2: ATTACH WITH CHECK constraint..."
echo "    Detaching again to repeat test with CHECK constraints..."

START_DETACH2=$(date +%s)
psql "$DB_URL" << EOF
ALTER TABLE inode DETACH PARTITION $INODE_PARTITION CONCURRENTLY;
ALTER TABLE path DETACH PARTITION $PATH_PARTITION CONCURRENTLY;
EOF
END_DETACH2=$(date +%s)
DETACH2_TIME=$((END_DETACH2 - START_DETACH2))
echo "✓ Second DETACH completed in ${DETACH2_TIME}s"
echo ""

# ---------- Step 4b: Add CHECK constraints ----------
echo "[9] Adding CHECK constraints (Web-Claude's critical requirement)..."
START_CHECK=$(date +%s)

psql "$DB_URL" << EOF
-- Add CHECK constraint matching partition bounds
-- This tells PostgreSQL: "I guarantee all rows have this medium_hash"
ALTER TABLE $INODE_PARTITION ADD CONSTRAINT check_medium_hash_inode
  CHECK (medium_hash = '$MEDIUM_HASH');

ALTER TABLE $PATH_PARTITION ADD CONSTRAINT check_medium_hash_path
  CHECK (medium_hash = '$MEDIUM_HASH');
EOF

END_CHECK=$(date +%s)
CHECK_TIME=$((END_CHECK - START_CHECK))
echo "✓ CHECK constraints added in ${CHECK_TIME}s"
echo ""

# ---------- Step 4c: ATTACH WITH CHECK constraint ----------
echo "[10] TEST 2: ATTACH WITH CHECK constraint (optimized timing)..."
echo "     This should take 1-2 seconds according to Gemini (constraint inference)"
START_ATTACH_WITH_CHECK=$(date +%s)

psql "$DB_URL" << EOF
-- Re-attach inode partition
ALTER TABLE inode ATTACH PARTITION $INODE_PARTITION
  FOR VALUES IN ('$MEDIUM_HASH');
EOF

END_ATTACH_INODE2=$(date +%s)
ATTACH_INODE_WITH_CHECK=$((END_ATTACH_INODE2 - START_ATTACH_WITH_CHECK))
echo "  ✓ Inode ATTACH completed in ${ATTACH_INODE_WITH_CHECK}s"

psql "$DB_URL" << EOF
ALTER TABLE path ATTACH PARTITION $PATH_PARTITION
  FOR VALUES IN ('$MEDIUM_HASH');
EOF

END_ATTACH_WITH_CHECK=$(date +%s)
ATTACH_PATH_WITH_CHECK=$((END_ATTACH_WITH_CHECK - END_ATTACH_INODE2))
TOTAL_ATTACH_WITH_CHECK=$((END_ATTACH_WITH_CHECK - START_ATTACH_WITH_CHECK))
echo "  ✓ Path ATTACH completed in ${ATTACH_PATH_WITH_CHECK}s"
echo "✓ Total ATTACH time (with CHECK): ${TOTAL_ATTACH_WITH_CHECK}s"
echo ""

# ---------- Step 5: Cleanup CHECK constraints ----------
echo "[11] Cleaning up CHECK constraints (no longer needed)..."
psql "$DB_URL" << EOF
ALTER TABLE $INODE_PARTITION DROP CONSTRAINT check_medium_hash_inode;
ALTER TABLE $PATH_PARTITION DROP CONSTRAINT check_medium_hash_path;
EOF
echo "✓ CHECK constraints removed"
echo ""

# ---------- Final verification ----------
echo "[12] Final verification..."
FINAL_INODE_COUNT=$(psql "$DB_URL" -qt -A -c "SELECT count(*) FROM inode WHERE medium_hash = '$MEDIUM_HASH'" | tr -d ' ')
FINAL_PATH_COUNT=$(psql "$DB_URL" -qt -A -c "SELECT count(*) FROM path WHERE medium_hash = '$MEDIUM_HASH'" | tr -d ' ')
echo "Final counts: $FINAL_INODE_COUNT inodes, $FINAL_PATH_COUNT paths"

if [[ "$FINAL_INODE_COUNT" = "$NEW_INODE_COUNT" ]] && [[ "$FINAL_PATH_COUNT" = "$NEW_PATH_COUNT" ]]; then
    echo "✓ Row counts match expected values"
else
    echo "WARNING: Row count mismatch!"
    echo "  Expected: $NEW_INODE_COUNT inodes, $NEW_PATH_COUNT paths"
    echo "  Got: $FINAL_INODE_COUNT inodes, $FINAL_PATH_COUNT paths"
fi
echo ""

# ---------- Summary ----------
echo "=========================================="
echo "TEST RESULTS SUMMARY"
echo "=========================================="
echo "Dataset: $MEDIUM_HASH ($NEW_PATH_COUNT paths, $NEW_INODE_COUNT inodes)"
echo ""
echo "Operation Timings:"
echo "  DETACH (1st):              ${DETACH_TIME}s"
echo "  TRUNCATE:                  ${TRUNCATE_TIME}s"
echo "  Load data:                 ${LOAD_TIME}s"
echo "  ATTACH without CHECK:      ${TOTAL_ATTACH_NO_CHECK}s"
echo "    - Inode:                 ${ATTACH_INODE_NO_CHECK}s"
echo "    - Path:                  ${ATTACH_PATH_NO_CHECK}s"
echo ""
echo "  DETACH (2nd):              ${DETACH2_TIME}s"
echo "  Add CHECK constraints:     ${CHECK_TIME}s"
echo "  ATTACH with CHECK:         ${TOTAL_ATTACH_WITH_CHECK}s"
echo "    - Inode:                 ${ATTACH_INODE_WITH_CHECK}s"
echo "    - Path:                  ${ATTACH_PATH_WITH_CHECK}s"
echo ""
echo "Key Findings:"
SPEEDUP=$((TOTAL_ATTACH_NO_CHECK - TOTAL_ATTACH_WITH_CHECK))
if [[ $SPEEDUP -gt 0 ]]; then
    PERCENT=$((SPEEDUP * 100 / TOTAL_ATTACH_NO_CHECK))
    echo "  ✓ CHECK constraint speedup: ${SPEEDUP}s faster (${PERCENT}% improvement)"
else
    echo "  ⚠ CHECK constraint did not provide expected speedup"
fi
echo ""
echo "Expected Production Performance (11.2M paths):"
TOTAL_WITHOUT_COPY=$((DETACH_TIME + TRUNCATE_TIME + TOTAL_ATTACH_WITH_CHECK))
echo "  DETACH + TRUNCATE + ATTACH: ~${TOTAL_WITHOUT_COPY}s"
echo "  COPY from .raw file:        ~300s (5 min, from investigation doc)"
echo "  Load/transform:             ~180s (3 min, from investigation doc)"
TOTAL_PROD=$((TOTAL_WITHOUT_COPY + 300 + 180))
echo "  Total estimated time:       ~${TOTAL_PROD}s (~$((TOTAL_PROD / 60)) min)"
echo ""
echo "=========================================="
