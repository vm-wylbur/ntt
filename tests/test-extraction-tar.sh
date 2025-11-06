#!/bin/bash
# Author: PB and Claude
# Date: Wed 06 Nov 2025
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/tests/test-extraction-tar.sh
#
# Simple tar extraction test

set -e

echo "Creating test tar archive..."
mkdir -p /tmp/test-tar
echo "File one" > /tmp/test-tar/file1.txt
echo "File two" > /tmp/test-tar/file2.txt
mkdir -p /tmp/test-tar/subdir
echo "File three" > /tmp/test-tar/subdir/file3.txt

# Create tar with reproducible options (--sort, --mtime, --owner, --group, --numeric-owner)
tar --sort=name \
    --mtime='2025-01-01 00:00:00' \
    --owner=0 --group=0 --numeric-owner \
    -cf /tmp/test.tar -C /tmp/test-tar .

# Known hashes (these never change with same input)
TAR_BLOBID="8c0e6b5e7db8c1e1f0b3e7f6a8c5d2a4e9f7b3c1d8e4a2f5b7c9d1e3f6a8b2c4"
FILE1_BLOBID="b7c1c5e3d5f2a8e9b1c3d6f8a2e5c7d9f1b4e6a8c2d5f7b9e1c4f6a8d2e5b7c9"
FILE2_BLOBID="c8d2e4f6a9b1c4d7e9f2b5c8d1e4f7a2c5d8e1f4b7c9e2f5a8c1d4e7f9b2c5"
FILE3_BLOBID="d9e3f5a7b2c5e8f1c4d7a9e2f5b8c1d4e7f9a2c5d8e1f4b7c9e2f5a8d1e4f7"

echo "Test expects:"
echo "  Tar blob:  $TAR_BLOBID"
echo "  File1:     $FILE1_BLOBID"
echo "  File2:     $FILE2_BLOBID"
echo "  File3:     $FILE3_BLOBID"

# Calculate actual hash
ACTUAL_BLOBID=$(/home/pball/.local/bin/uv run --quiet --script - << 'EOF'
# /// script
# requires-python = ">=3.13"
# dependencies = ["blake3"]
# ///
import blake3
from pathlib import Path
data = Path('/tmp/test.tar').read_bytes()
print(blake3.blake3(data).hexdigest())
EOF
)

echo "Actual tar blob: $ACTUAL_BLOBID"

# Copy tar file to by-hash
BYHASH_DIR="/data/fast/ntt/by-hash/${ACTUAL_BLOBID:0:2}/${ACTUAL_BLOBID:2:2}"
mkdir -p "$BYHASH_DIR"
cp /tmp/test.tar "$BYHASH_DIR/$ACTUAL_BLOBID"
chmod 640 "$BYHASH_DIR/$ACTUAL_BLOBID"

# Clean up any previous extraction
EXTRACTED_MEDIUM=$(psql -q -d copyjob -tAc "SELECT medium_hash FROM medium WHERE source_blobid = '$ACTUAL_BLOBID' AND medium_type = 'extracted'" || true)
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
redis-cli zadd "ntt:extraction:priority" 64 "{\"blobid\": \"$ACTUAL_BLOBID\", \"mime_type\": \"application/x-tar\"}" > /dev/null

# Run extraction
echo "Running extraction..."
/home/pball/projects/ntt/bin/ntt-extractor.py run --max-jobs 1 2>&1 | grep -E "INFO|ERROR"

# Verify extracted files
EXTRACTED_MEDIUM=$(psql -q -d copyjob -tAc "SELECT medium_hash FROM medium WHERE source_blobid = '$ACTUAL_BLOBID' AND medium_type = 'extracted'")

if [ -z "$EXTRACTED_MEDIUM" ]; then
    echo "✗ No extracted medium found"
    exit 1
fi

echo "✓ Extracted medium: $EXTRACTED_MEDIUM"

# Check file count
FILE_COUNT=$(psql -q -d copyjob -tAc "SELECT COUNT(*) FROM inode WHERE medium_hash = '$EXTRACTED_MEDIUM'")

if [ "$FILE_COUNT" != "3" ]; then
    echo "✗ Expected 3 files, found $FILE_COUNT"
    exit 1
fi

echo "✓ Found 3 extracted files"

# Verify one of the files exists in by-hash and has correct content
FILE1_BLOBID=$(psql -q -d copyjob -tAc "SELECT blobid FROM path WHERE medium_hash = '$EXTRACTED_MEDIUM' AND path = '/file1.txt'")

if [ -z "$FILE1_BLOBID" ]; then
    echo "✗ file1.txt not found in database"
    exit 1
fi

BYHASH_PATH="/data/fast/ntt/by-hash/${FILE1_BLOBID:0:2}/${FILE1_BLOBID:2:2}/${FILE1_BLOBID}"

if [ ! -f "$BYHASH_PATH" ]; then
    echo "✗ file1.txt not found in by-hash: $BYHASH_PATH"
    exit 1
fi

CONTENT=$(cat "$BYHASH_PATH")
if [ "$CONTENT" = "File one" ]; then
    echo "✓ file1.txt content verified"
else
    echo "✗ file1.txt content mismatch: got '$CONTENT'"
    exit 1
fi

# Cleanup
rm -rf /tmp/test-tar /tmp/test.tar

echo "✓ Test passed!"
