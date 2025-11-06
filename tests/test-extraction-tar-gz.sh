#!/bin/bash
# Author: PB and Claude
# Date: Wed 06 Nov 2025
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/tests/test-extraction-tar-gz.sh
#
# Tar.gz extraction test - tests nested archive handling

set -e

echo "Creating test tar.gz archive..."
mkdir -p /tmp/test-targz
echo "Nested file one" > /tmp/test-targz/nested1.txt
echo "Nested file two" > /tmp/test-targz/nested2.txt

# Create tar with reproducible options
tar --sort=name \
    --mtime='2025-01-01 00:00:00' \
    --owner=0 --group=0 --numeric-owner \
    -cf /tmp/test.tar -C /tmp/test-targz .

# Compress with gzip (deterministic with -n flag)
gzip -n -c /tmp/test.tar > /tmp/test.tar.gz

# Calculate actual hash
ACTUAL_BLOBID=$(/home/pball/.local/bin/uv run --quiet --script - << 'EOF'
# /// script
# requires-python = ">=3.13"
# dependencies = ["blake3"]
# ///
import blake3
from pathlib import Path
data = Path('/tmp/test.tar.gz').read_bytes()
print(blake3.blake3(data).hexdigest())
EOF
)

echo "Test expects tar.gz blob: $ACTUAL_BLOBID"

# Copy tar.gz file to by-hash
BYHASH_DIR="/data/fast/ntt/by-hash/${ACTUAL_BLOBID:0:2}/${ACTUAL_BLOBID:2:2}"
mkdir -p "$BYHASH_DIR"
cp /tmp/test.tar.gz "$BYHASH_DIR/$ACTUAL_BLOBID"
chmod 640 "$BYHASH_DIR/$ACTUAL_BLOBID"

# Clean up any previous extractions (both gzip decompression and tar extraction)
echo "Cleaning up previous extractions..."
EXTRACTED_MEDIA=$(psql -q -d copyjob -tAc "
    SELECT medium_hash
    FROM medium
    WHERE (source_blobid = '$ACTUAL_BLOBID' OR
           source_blobid IN (SELECT blobid FROM inode WHERE medium_hash IN
                            (SELECT medium_hash FROM medium WHERE source_blobid = '$ACTUAL_BLOBID')))
      AND medium_type = 'extracted'
")

for MEDIUM in $EXTRACTED_MEDIA; do
    if [ -n "$MEDIUM" ]; then
        psql -q -d copyjob << EOF
        DELETE FROM inode WHERE medium_hash = '$MEDIUM';
        DELETE FROM path WHERE medium_hash = '$MEDIUM';
        DROP TABLE IF EXISTS inode_$MEDIUM;
        DROP TABLE IF EXISTS path_$MEDIUM;
        DELETE FROM medium WHERE medium_hash = '$MEDIUM';
EOF
    fi
done

# Queue for extraction
redis-cli del "ntt:extraction:processed" > /dev/null
redis-cli zadd "ntt:extraction:priority" 64 "{\"blobid\": \"$ACTUAL_BLOBID\", \"mime_type\": \"application/gzip\"}" > /dev/null

# Run extraction (should process gzip, then detect nested tar and process that too)
echo "Running extraction (expecting nested archive processing)..."
/home/pball/projects/ntt/bin/ntt-extractor.py run --max-jobs 10 2>&1 | grep -E "INFO|ERROR"

# Verify we got TWO extracted media (gzip decompression + tar extraction)
EXTRACTED_COUNT=$(psql -q -d copyjob -tAc "
    SELECT COUNT(*)
    FROM medium
    WHERE source_blobid = '$ACTUAL_BLOBID'
       OR source_blobid IN (
           SELECT blobid FROM inode
           WHERE medium_hash IN (
               SELECT medium_hash FROM medium WHERE source_blobid = '$ACTUAL_BLOBID'
           )
       )
")

if [ "$EXTRACTED_COUNT" -lt "2" ]; then
    echo "✗ Expected at least 2 extracted media (gzip→tar→files), found $EXTRACTED_COUNT"
    echo "  This suggests nested archive processing didn't work"
    exit 1
fi

echo "✓ Found $EXTRACTED_COUNT extracted media (nested processing worked)"

# Find the final tar extraction (should have 2 files)
TAR_MEDIUM=$(psql -q -d copyjob -tAc "
    SELECT m.medium_hash
    FROM medium m
    JOIN inode i ON i.medium_hash = m.medium_hash
    WHERE m.source_blobid IN (
        SELECT blobid FROM inode
        WHERE medium_hash IN (
            SELECT medium_hash FROM medium WHERE source_blobid = '$ACTUAL_BLOBID'
        )
    )
    GROUP BY m.medium_hash
    HAVING COUNT(*) > 1
    LIMIT 1
")

if [ -z "$TAR_MEDIUM" ]; then
    echo "✗ Could not find tar extraction medium with multiple files"
    exit 1
fi

echo "✓ Found tar extraction medium: $TAR_MEDIUM"

# Check file count in tar extraction
FILE_COUNT=$(psql -q -d copyjob -tAc "SELECT COUNT(*) FROM inode WHERE medium_hash = '$TAR_MEDIUM'")

if [ "$FILE_COUNT" != "2" ]; then
    echo "✗ Expected 2 files in tar, found $FILE_COUNT"
    exit 1
fi

echo "✓ Found 2 files extracted from tar"

# Verify one of the files has correct content
FILE1_BLOBID=$(psql -q -d copyjob -tAc "SELECT blobid FROM path WHERE medium_hash = '$TAR_MEDIUM' AND path = '/nested1.txt' LIMIT 1")

if [ -z "$FILE1_BLOBID" ]; then
    echo "✗ nested1.txt not found in database"
    exit 1
fi

BYHASH_PATH="/data/fast/ntt/by-hash/${FILE1_BLOBID:0:2}/${FILE1_BLOBID:2:2}/${FILE1_BLOBID}"

if [ ! -f "$BYHASH_PATH" ]; then
    echo "✗ nested1.txt not found in by-hash: $BYHASH_PATH"
    exit 1
fi

CONTENT=$(cat "$BYHASH_PATH")
if [ "$CONTENT" = "Nested file one" ]; then
    echo "✓ nested1.txt content verified"
else
    echo "✗ nested1.txt content mismatch: got '$CONTENT'"
    exit 1
fi

# Cleanup
rm -rf /tmp/test-targz /tmp/test.tar /tmp/test.tar.gz

echo "✓ Test passed! Nested archive extraction working."
