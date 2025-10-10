#!/bin/bash
# Archive verification script for 579d3c3a476185f524b77b286c5319f5
# Author: PB and Claude
# Date: 2025-10-10
#
# Run this script in background for full integrity testing:
#   nohup bash /data/fast/tmp/verify-archive-579d3c3a.sh > /data/fast/tmp/verify-log.txt 2>&1 &

set -euo pipefail

ARCHIVE="/data/cold/img-read/579d3c3a476185f524b77b286c5319f5.tar.zst"
OUTPUT_DIR="/data/fast/tmp"
HASH="579d3c3a"

echo "=== Archive Verification Started: $(date) ==="
echo "Archive: $ARCHIVE"
echo ""

# Test 1: zstd integrity
echo "Test 1/3: Testing zstd compression integrity..."
START=$(date +%s)
if zstd -t "$ARCHIVE"; then
    END=$(date +%s)
    DURATION=$((END - START))
    echo "✓ PASS - zstd integrity test (${DURATION}s)"
else
    echo "✗ FAIL - zstd integrity test failed"
    exit 1
fi
echo ""

# Test 2: List contents
echo "Test 2/3: Listing archive contents..."
START=$(date +%s)
if zstdcat "$ARCHIVE" | tar -t > "$OUTPUT_DIR/archive-contents-$HASH.txt"; then
    END=$(date +%s)
    DURATION=$((END - START))
    FILE_COUNT=$(wc -l < "$OUTPUT_DIR/archive-contents-$HASH.txt")
    echo "✓ PASS - Listed $FILE_COUNT files (${DURATION}s)"
    echo "Contents saved to: $OUTPUT_DIR/archive-contents-$HASH.txt"
else
    echo "✗ FAIL - Failed to list archive contents"
    exit 1
fi
echo ""

# Test 3: Detailed listing
echo "Test 3/3: Getting detailed file information..."
START=$(date +%s)
if zstdcat "$ARCHIVE" | tar -tv > "$OUTPUT_DIR/archive-details-$HASH.txt"; then
    END=$(date +%s)
    DURATION=$((END - START))
    echo "✓ PASS - Detailed listing generated (${DURATION}s)"
    echo "Details saved to: $OUTPUT_DIR/archive-details-$HASH.txt"
else
    echo "✗ FAIL - Failed to generate detailed listing"
    exit 1
fi
echo ""

echo "=== All Tests Passed: $(date) ==="
echo ""
echo "Summary:"
cat "$OUTPUT_DIR/archive-contents-$HASH.txt"
echo ""
echo "Details:"
cat "$OUTPUT_DIR/archive-details-$HASH.txt"
