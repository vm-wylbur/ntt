#!/usr/bin/env bash
# Author: PB and Claude
# Date: Thu 10 Oct 2025
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/verify-archived-media.sh
#
# Verify that archived media have their blobids in by-hash storage
# before marking copy_done

set -euo pipefail

DB_URL="${NTT_DB_URL:-postgres:///copyjob}"

echo "Finding archived media missing copy_done..."

# Get list of all archived hashes
archived_hashes=$(ls /data/cold/img-read/*.tar.zst | sed 's|.*/||;s|\.tar\.zst$||')

verified_count=0
failed_count=0
declare -a failed_hashes

for hash in $archived_hashes; do
  # Check if copy_done is NULL
  has_copy=$(psql -q "$DB_URL" -tAc "SELECT copy_done IS NOT NULL FROM medium WHERE medium_hash = '$hash'" 2>/dev/null || echo "missing")

  if [[ "$has_copy" != "f" ]]; then
    # Skip: already marked or not in database
    continue
  fi

  # Get medium_human for reporting
  human=$(psql -q "$DB_URL" -tAc "SELECT medium_human FROM medium WHERE medium_hash = '$hash'" 2>/dev/null || echo "unknown")

  echo ""
  echo "Verifying: $hash ($human)"

  # Get stats
  stats=$(psql -q "$DB_URL" -tAc "
    SELECT
      COUNT(*) || '|' ||
      COUNT(*) FILTER (WHERE blobid IS NOT NULL AND fs_type = 'f') || '|' ||
      COUNT(*) FILTER (WHERE copied = true)
    FROM inode
    WHERE medium_hash = '$hash'
  ")

  IFS='|' read -r total_inodes files_with_blobid marked_copied <<< "$stats"

  echo "  Inodes: $total_inodes total, $files_with_blobid files with blobid, $marked_copied marked copied"

  # Determine sample size (max 1000 or all if fewer)
  sample_size=1000
  if [[ $files_with_blobid -lt $sample_size ]]; then
    sample_size=$files_with_blobid
  fi

  if [[ $sample_size -eq 0 ]]; then
    echo "  ✗ SKIP: No files with blobids"
    failed_count=$((failed_count + 1))
    failed_hashes+=("$hash: no blobids")
    continue
  fi

  echo "  Sampling $sample_size blobids..."

  # Get sample blobids and verify in by-hash
  verified=0
  missing=0

  while IFS= read -r blobid; do
    [[ -z "$blobid" ]] && continue
    path="/data/cold/by-hash/${blobid:0:2}/${blobid:2:2}/$blobid"
    if [[ -f "$path" ]]; then
      verified=$((verified + 1))
    else
      missing=$((missing + 1))
      echo "    ✗ MISSING: $blobid"
    fi
  done < <(psql -q "$DB_URL" -tAc "
    SELECT blobid
    FROM inode
    WHERE medium_hash = '$hash'
      AND blobid IS NOT NULL
      AND fs_type = 'f'
    ORDER BY random()
    LIMIT $sample_size
  ")

  echo "  Verified: $verified/$sample_size exist in by-hash"

  if [[ $missing -eq 0 ]]; then
    echo "  ✓ PASS: All sampled blobids exist"
    verified_count=$((verified_count + 1))
  else
    echo "  ✗ FAIL: $missing blobids missing from by-hash"
    failed_count=$((failed_count + 1))
    failed_hashes+=("$hash: $missing/$sample_size missing")
  fi
done

echo ""
echo "=== VERIFICATION SUMMARY ==="
echo "Verified: $verified_count media"
echo "Failed: $failed_count media"

if [[ $failed_count -gt 0 ]]; then
  echo ""
  echo "Failed hashes:"
  for failure in "${failed_hashes[@]}"; do
    echo "  - $failure"
  done
  exit 1
else
  echo ""
  echo "All verified media can be marked copy_done ✓"
  exit 0
fi
