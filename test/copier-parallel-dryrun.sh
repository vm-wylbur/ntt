#!/bin/bash
# Test script for parallel dry-run mode of ntt-copier.py
# Runs 8 workers simultaneously, each processing up to 500 files

echo "Testing ntt-copier.py with 8 parallel workers (--dry-run=500 each)"
echo "=================================================================="

# Create log directory if needed
sudo mkdir -p /var/log/ntt

# Clean up any previous dry-run logs
echo "Cleaning previous dry-run logs..."
sudo rm -f /var/log/ntt/copier-dryrun.jsonl*

echo ""
echo "Starting 8 workers in parallel..."
echo "---------------------------------"

# Start time for measuring total duration
START_TIME=$(date +%s)

# Launch 8 workers in background with unique worker IDs
for i in {1..8}; do
    echo "Starting worker $i..."
    NTT_WORKER_ID="worker_$i" sudo -E env PATH="$PATH" bin/ntt-copier.py --dry-run=500 &
done

echo ""
echo "All workers launched. Waiting for completion..."
echo ""

# Wait for all background jobs to complete
wait

# End time
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo "All workers completed in ${DURATION} seconds"
echo ""

# Show statistics from logs
echo "Worker Statistics:"
echo "------------------"
echo "Total log entries:"
sudo wc -l /var/log/ntt/copier-dryrun.jsonl

echo ""
echo "Files processed per worker:"
sudo grep "Worker complete" /var/log/ntt/copier-dryrun.jsonl | \
    jq -r '.record.extra | "\(.worker_id): \(.stats.copied) files, \(.stats.bytes) bytes, \(.stats.errors) errors"' | \
    sort

echo ""
echo "Total files processed:"
sudo grep "Worker complete" /var/log/ntt/copier-dryrun.jsonl | \
    jq -s 'map(.record.extra.stats.copied) | add'

echo ""
echo "Total bytes (would be) processed:"
sudo grep "Worker complete" /var/log/ntt/copier-dryrun.jsonl | \
    jq -s 'map(.record.extra.stats.bytes) | add | . / 1024 / 1024 | round | "\(.) MB"'

echo ""
echo "Check for any errors:"
sudo grep -i error /var/log/ntt/copier-dryrun.jsonl | wc -l

echo ""
echo "Sample of processed files (first 5):"
sudo grep "Would copy to temp" /var/log/ntt/copier-dryrun.jsonl | \
    head -5 | \
    jq -r '.record | "\(.extra.worker_id): ino=\(.extra.ino // "N/A") size=\(.extra.size // "N/A")"'

echo ""
echo "Full logs available at: /var/log/ntt/copier-dryrun.jsonl"
echo "To view formatted: sudo tail -n 100 /var/log/ntt/copier-dryrun.jsonl | jq ."