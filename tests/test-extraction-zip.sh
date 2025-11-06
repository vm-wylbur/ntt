#!/bin/bash
# Author: PB and Claude
# Date: Wed 06 Nov 2025
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/tests/test-extraction-zip.sh
#
# Simple zip extraction test

set -e

echo "Creating test zip archive..."
mkdir -p /tmp/test-zip
echo "Zip file one" > /tmp/test-zip/file1.txt
echo "Zip file two" > /tmp/test-zip/file2.txt

# Set reproducible timestamps
touch -t 202501010000 /tmp/test-zip/file1.txt /tmp/test-zip/file2.txt

# Create zip with reproducible options (-X = no extra attributes)
cd /tmp/test-zip
zip -X -q /tmp/test.zip file1.txt file2.txt
cd -

# Calculate actual hash
ACTUAL_BLOBID=$(/home/pball/.local/bin/uv run --quiet --script - << 'EOF'
# /// script
# requires-python = ">=3.13"
# dependencies = ["blake3"]
# ///
import blake3
from pathlib import Path
data = Path('/tmp/test.zip').read_bytes()
print(blake3.blake3(data).hexdigest())
EOF
)

echo "Test expects zip blob: $ACTUAL_BLOBID"

# Copy zip file to by-hash
BYHASH_DIR="/data/fast/ntt/by-hash/${ACTUAL_BLOBID:0:2}/${ACTUAL_BLOBID:2:2}"
mkdir -p "$BYHASH_DIR"
cp /tmp/test.zip "$BYHASH_DIR/$ACTUAL_BLOBID"
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
redis-cli zadd "ntt:extraction:priority" 64 "{\"blobid\": \"$ACTUAL_BLOBID\", \"mime_type\": \"application/zip\"}" > /dev/null

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

if [ "$FILE_COUNT" != "2" ]; then
    echo "✗ Expected 2 files, found $FILE_COUNT"
    exit 1
fi

echo "✓ Found 2 extracted files"

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
if [ "$CONTENT" = "Zip file one" ]; then
    echo "✓ file1.txt content verified"
else
    echo "✗ file1.txt content mismatch: got '$CONTENT'"
    exit 1
fi

# Cleanup
rm -rf /tmp/test-zip /tmp/test.zip

echo "✓ Test passed!"
