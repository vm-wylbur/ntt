#!/usr/bin/env bash
# Cross-Medium Deduplication Analysis - SQL Data Extractor
#
# This script performs expensive analysis queries and exports results to /tmp/
# for consumption by the R Markdown report. Run this infrequently (quarterly
# or when adding new media).
#
# Usage: ./cross-medium-dedup.sql
# Outputs: /tmp/nhardlinks.json, /tmp/sharing_matrix.csv, /tmp/jaccard.json, /tmp/upset_data.csv

set -euo pipefail

DB="postgresql://pball@192.168.86.200/copyjob"

echo "=== Cross-Medium Dedup Analysis Data Extraction ==="
echo "Started: $(date)"
echo ""

# Step 1: Create blob_media_matrix (materialized analysis table)
echo "Step 1/5: Creating blob_media_matrix..."
psql "$DB" <<'EOSQL'
DROP TABLE IF EXISTS blob_media_matrix;
CREATE TABLE blob_media_matrix AS
SELECT DISTINCT i.hash, i.medium_hash, i.size
FROM inode i
JOIN blobs b ON i.hash = b.blobid
WHERE i.copied = true
  AND i.fs_type = 'f'
  AND b.n_hardlinks > 1;

CREATE INDEX ON blob_media_matrix(hash);
CREATE INDEX ON blob_media_matrix(medium_hash);

-- CRITICAL: Analyze to collect statistics
ANALYZE blob_media_matrix;

-- Report
SELECT COUNT(*) as total_rows,
       COUNT(DISTINCT hash) as unique_hashes,
       COUNT(DISTINCT medium_hash) as unique_media
FROM blob_media_matrix;
EOSQL

# Step 2: n_hardlinks distribution (logarithmic histogram)
echo ""
echo "Step 2/5: Analyzing n_hardlinks distribution..."
psql "$DB" -t -A -F',' -q <<'EOSQL' | jq -R -s -c 'split("\n") | map(select(length > 0) | split(",")) | map({lower_bound: .[0]|tonumber, upper_bound: .[1]|tonumber, num_blobs: .[2]|tonumber, total_inodes: .[3]|tonumber})' > /tmp/nhardlinks.json
SELECT
  pow(2, floor(log(2, n_hardlinks)))::int AS lower_bound,
  (pow(2, floor(log(2, n_hardlinks))+1)-1)::int AS upper_bound,
  COUNT(*) as num_blobs,
  SUM(n_hardlinks) as total_inodes
FROM blobs
WHERE n_hardlinks > 1
GROUP BY 1, 2
ORDER BY 1;
EOSQL
echo "Exported to /tmp/nhardlinks.json"

# Step 3: Get list of media for matrix operations
echo ""
echo "Step 3/5: Identifying media..."
MEDIA=$(psql "$DB" -t -A -c "SELECT medium_hash FROM blob_media_matrix GROUP BY medium_hash ORDER BY COUNT(*) DESC")
MEDIA_ARRAY=($MEDIA)
MEDIA_COUNT=${#MEDIA_ARRAY[@]}
echo "Found $MEDIA_COUNT media with duplicated files"

# Step 4: Cross-medium sharing matrix (pairwise INTERSECT)
echo ""
echo "Step 4/5: Computing cross-medium sharing matrix..."
echo "medium_a,medium_b,shared_blobs,shared_bytes" > /tmp/sharing_matrix.csv

for ((i=0; i<MEDIA_COUNT; i++)); do
  for ((j=i+1; j<MEDIA_COUNT; j++)); do
    m1="${MEDIA_ARRAY[$i]}"
    m2="${MEDIA_ARRAY[$j]}"

    echo "  Computing ${m1:0:4}...${m1: -4} ↔ ${m2:0:4}...${m2: -4}"

    psql "$DB" -t -A -F',' <<EOSQL >> /tmp/sharing_matrix.csv
SELECT '$m1', '$m2', COUNT(*), SUM(size)
FROM (
  SELECT hash, size FROM blob_media_matrix WHERE medium_hash = '$m1'
  INTERSECT
  SELECT hash, size FROM blob_media_matrix WHERE medium_hash = '$m2'
) x;
EOSQL
  done
done
echo "Exported to /tmp/sharing_matrix.csv"

# Step 5: Per-medium blob counts and labels (for Jaccard calculation)
echo ""
echo "Step 5/6: Computing per-medium blob counts and labels..."
psql "$DB" -t -A -F',' -q <<'EOSQL' | jq -R -s -c 'split("\n") | map(select(length > 0) | split(",")) | map({medium_hash: .[0], unique_blobs: .[1]|tonumber, label: .[2]}) | INDEX(.medium_hash)' > /tmp/jaccard.json
SELECT
  b.medium_hash,
  COUNT(DISTINCT b.hash) as unique_blobs,
  COALESCE(
    (SELECT substring(p.path from '^(/[^/]+/[^/]+/[^/]+)')
     FROM path p
     WHERE p.medium_hash = b.medium_hash
     GROUP BY substring(p.path from '^(/[^/]+/[^/]+/[^/]+)')
     ORDER BY COUNT(*) DESC
     LIMIT 1),
    b.medium_hash
  ) as label
FROM blob_media_matrix b
GROUP BY b.medium_hash
ORDER BY unique_blobs DESC;
EOSQL
echo "Exported to /tmp/jaccard.json"

# Step 6: Export UpSet data (optional - requires Python)
echo ""
echo "Step 6/6: Exporting UpSet data (optional)..."
if command -v python3 &> /dev/null; then
  python3 << 'EOPY'
import subprocess
import csv

# Query for data
query = "SELECT hash, medium_hash FROM blob_media_matrix"
result = subprocess.run(
    ['psql', 'postgresql://pball@192.168.86.200/copyjob', '-t', '-A', '-F,', '-q', '-c', query],
    capture_output=True, text=True
)

# Build hash -> media set mapping
hash_media = {}
for line in result.stdout.strip().split('\n'):
    if not line or ',' not in line:
        continue
    parts = line.split(',')
    if len(parts) != 2:
        continue
    hash_val, medium = parts
    if hash_val not in hash_media:
        hash_media[hash_val] = set()
    hash_media[hash_val].add(medium)

# Get unique media list (up to 10 for visualization)
all_media = sorted(set(m for media_set in hash_media.values() for m in media_set))[:10]

# Write CSV
with open('/tmp/upset_data.csv', 'w') as f:
    header = ['hash'] + [f'media_{i+1}' for i in range(len(all_media))]
    f.write(','.join(header) + '\n')

    for hash_val, media_set in hash_media.items():
        row = [hash_val] + ['1' if m in media_set else '0' for m in all_media]
        f.write(','.join(row) + '\n')

print(f"Exported {len(hash_media)} unique hashes to /tmp/upset_data.csv")
EOPY
  echo "Exported to /tmp/upset_data.csv"
else
  echo "Python3 not available, skipping UpSet export"
fi

echo ""
echo "=== Analysis Complete ==="
echo "Finished: $(date)"
echo ""
echo "Generated files:"
echo "  - /tmp/nhardlinks.json       (n_hardlinks distribution)"
echo "  - /tmp/sharing_matrix.csv    (cross-medium sharing)"
echo "  - /tmp/jaccard.json          (per-medium blob counts)"
echo "  - /tmp/upset_data.csv        (UpSet visualization data)"
echo ""
echo "Next: Run R Markdown report to generate HTML output"
echo "  Rscript -e \"rmarkdown::render('cross-medium-dedup.Rmd')\""
