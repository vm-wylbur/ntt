#!/bin/bash
# Author: PB and Claude
# Date: Wed 06 Nov 2025
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/tests/test-extraction-gzip.sh
#
# Simple gzip extraction test

set -e

echo "Creating test file..."
TEST_CONTENT="Hello from NTT archive extraction!"
echo "$TEST_CONTENT" > /tmp/test.txt
gzip -n -c /tmp/test.txt > /tmp/test.txt.gz

# Known hashes (these never change with same input)
GZ_BLOBID="2820dad522e30f1d3741f4c4fc4c677dfd7377f797ba1e97f4002a1b8167f595"
DECOMPRESSED_BLOBID="f54618ff229069b96aa7a18c17b1aba0d8af96f4561f8f4ec90d402d02214f2b"

echo "Test expects:"
echo "  Gzipped blob:      $GZ_BLOBID"
echo "  Decompressed blob: $DECOMPRESSED_BLOBID"

# Copy gzip file to by-hash
BYHASH_DIR="/data/fast/ntt/by-hash/${GZ_BLOBID:0:2}/${GZ_BLOBID:2:2}"
mkdir -p "$BYHASH_DIR"
cp /tmp/test.txt.gz "$BYHASH_DIR/$GZ_BLOBID"
chmod 640 "$BYHASH_DIR/$GZ_BLOBID"

# Clean up any previous extraction
EXTRACTED_MEDIUM=$(psql -q -d copyjob -tAc "SELECT medium_hash FROM medium WHERE source_blobid = '$GZ_BLOBID' AND medium_type = 'extracted'" || true)
if [ -n "$EXTRACTED_MEDIUM" ]; then
    echo "Cleaning up previous extraction..."
    psql -q -d copyjob << EOF
    DELETE FROM inode WHERE medium_hash = '$EXTRACTED_MEDIUM';
    DELETE FROM path WHERE medium_hash = '$EXTRACTED_MEDIUM';
    DROP TABLE IF EXISTS inode_$EXTRACTED_MEDIUM;
    DROP TABLE IF EXISTS path_$EXTRACTED_MEDIUM;
    DELETE FROM medium WHERE medium_hash = '$EXTRACTED_MEDIUM';
EOF
fi

# Queue for extraction
redis-cli del "ntt:extraction:processed" > /dev/null
redis-cli zadd "ntt:extraction:priority" 64 "{\"blobid\": \"$GZ_BLOBID\", \"mime_type\": \"application/gzip\"}" > /dev/null

# Run extraction
echo "Running extraction..."
/home/pball/projects/ntt/bin/ntt-extractor.py run --max-jobs 1 2>&1 | grep -E "INFO|ERROR"

# Verify decompressed blob exists with correct content
BYHASH_PATH="/data/fast/ntt/by-hash/${DECOMPRESSED_BLOBID:0:2}/${DECOMPRESSED_BLOBID:2:2}/${DECOMPRESSED_BLOBID}"

if [ ! -f "$BYHASH_PATH" ]; then
    echo "✗ Decompressed file not found: $BYHASH_PATH"
    exit 1
fi

CONTENT=$(cat "$BYHASH_PATH")
if [ "$CONTENT" = "$TEST_CONTENT" ]; then
    echo "✓ Decompressed file content verified"
else
    echo "✗ Content mismatch"
    echo "  Expected: $TEST_CONTENT"
    echo "  Got: $CONTENT"
    exit 1
fi

echo "✓ Test passed!"
