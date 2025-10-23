#!/bin/bash
# Test script for dry-run mode of ntt-copier.py

echo "Testing ntt-copier.py in dry-run mode"
echo "======================================"

# Create log directory if needed
sudo mkdir -p /var/log/ntt

echo ""
echo "Test 1: Dry-run with 5 file limit"
echo "----------------------------------"
sudo env PATH="$PATH" bin/ntt-copier.py --dry-run=5

echo ""
echo "Test 2: Dry-run with environment variable (10 files)"
echo "-----------------------------------------------------"
export NTT_DRY_RUN=true
export NTT_DRY_RUN_LIMIT=10
export NTT_SAMPLE_SIZE=100  # Small sample for testing
sudo -E env PATH="$PATH" bin/ntt-copier.py

echo ""
echo "Test complete. Check logs at:"
echo "  /var/log/ntt/copier-dryrun.jsonl"
echo ""
echo "To view formatted logs:"
echo "  sudo tail -n 20 /var/log/ntt/copier-dryrun.jsonl | jq ."
echo ""
echo "To verify no files were modified:"
echo "  ls -la /data/fast/ntt/by-hash/ 2>/dev/null | head -5"
echo "  ls -la /data/fast/ntt/archived/ 2>/dev/null | head -5"