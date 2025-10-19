<!--
Author: PB and Claude
Date: Fri 18 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/drive-identification-status-2025-10-18.md
-->

# Drive Identification Status - October 18, 2025

## What We're Doing

Building a drive identification system to match physical drives against database records by computing all historical hash formats.

**Primary tool**: `bin/identify-drive-by-hash.sh`
- Auto-detects recently connected drives from dmesg
- Computes three hash formats: v0 (buggy Oct 7-9), v1 (correct content-only), v2 (hybrid Oct 10+)
- Extracts hardware info bypassing USB bridges (MODEL, SERIAL)
- Analyzes partition layout and filesystems
- Checks database for v0/v2 hash matches
- Logs all results to `/var/log/ntt/drive-identification.jsonl`

## Why We're Doing This

### 1. Find Orphaned Media
Media like **3033499e** (Time Machine backup, enumerated Oct 2) has raw file but deleted IMG file - need to find physical disk to re-image.

### 2. Verify Oct 7-11 Processing
Need to confirm drives processed Oct 7-11 match database records and imaging was successful.

### 3. Support Re-Imaging Workflow
When physical disk is found, need correct hash to name IMG file so orchestrator recognizes existing enumeration data.

## What We've Learned

### Critical Bug Discovery: Oct 7-9 Hash Computation

**Problem**: When testing 5 drives processed Oct 7-9, NONE matched database hashes.

**Investigation**:
- Extracted IMG file `e5727c34` from archive
- Compared file contents between IMG and live device - **identical** (MD5 matched)
- IMG hashes to `53b3a6bd` (correct v1 format)
- Live device hashes to `53b3a6bd` (matches IMG)
- Database has `e5727c34` (wrong!)

**Root Cause**: `dd` command with both `oflag=append` and `conv=noerror,sync` causes append to fail silently.

Oct 7-9 hash computation code:
```bash
dd if="$DEVICE" of="$SIG_FILE" bs=512 count=2048 conv=noerror,sync
dd if="$DEVICE" of="$SIG_FILE" bs=512 skip=$SKIP_SECTORS count=2048 conv=noerror,sync oflag=append
```

**Bug**: Second dd with `oflag=append` + `conv=noerror,sync` doesn't append - only first 1MB written instead of 2MB.

**Evidence**:
- Buggy method produces 1,048,576 bytes (1MB only)
- Correct method produces 2,097,152 bytes (2MB = first 1MB + last 1MB)
- Buggy hash: `e5727c34` (matches database)
- Correct hash: `53b3a6bd` (matches IMG file)

**Fix**: Oct 10 commit (5d0b821) introduced v2 format AND fixed the bug:
- Comment: "Use >> redirection instead of oflag=append (which doesn't work with conv=noerror,sync)"
- Changed to `>>` redirection instead of `oflag=append`

### Hash Format Timeline

1. **v0 (legacy buggy)**: Oct 7-9, 2025
   - BLAKE3(first_1MB only) - unintentional bug
   - All Oct 7-9 database records use this format

2. **v1 (content-only correct)**: Never used in production
   - BLAKE3(first_1MB + last_1MB) - correct content-only hash
   - IMG files hash to this format
   - Used for verification/reference

3. **v2 (hybrid)**: Oct 10+, 2025
   - BLAKE3(SIZE:|MODEL:|SERIAL:| + first_1MB + last_1MB)
   - Fixed the append bug
   - Current production format

### Solution

**Don't fix the database** - existing hashes are what they are.

**Make identify-drive-by-hash.sh reproduce all formats**:
- Compute v0 hash by reproducing the bug (for Oct 7-9 matches)
- Compute v1 hash for reference
- Compute v2 hash (for Oct 10+ matches)

This allows matching physical drives to database regardless of when they were processed.

## Current Status

### Tools Ready
- ✅ `bin/identify-drive-by-hash.sh` - computes all three hash formats, checks database
- ✅ `/var/log/ntt/drive-identification.jsonl` - persistent log of all drive scans
- ✅ Database lookup integration - shows "MATCH v0 (e5727c)" or "MATCH v2 (488de2)"

### Example Output
```
Device:      /dev/sde
Size:        500107862016 bytes (466GiB)
Model:       Hitachi_HTS545050B9A300
Serial:      090713PB4400Q7HB7ASG

Partition Table: gpt
2 partition(s):
  sde1: 200MiB, vfat [EFI]
  sde2: 466GiB, hfsplus [Time Machine Backups]

Hash (v0/legacy buggy Oct 7-9):   22b122c51bbc60bd31fdb4bdadcf5da9
Hash (v1/content-only correct):   dd7d939b45de18565306427796a16fd6
Hash (v2/hybrid Oct 10+):         d6c63baf2ab797fbb7cc8a744d01e861

Database: No match found
```

### Workflow
1. Connect drive in USB housing
2. Run `sudo bin/identify-drive-by-hash.sh` (auto-detects from dmesg)
3. Check for database match
4. If new drive, image with: `sudo bin/ntt-imager /dev/sdX /data/fast/img/<v2_hash>.img /data/fast/img/<v2_hash>.map`
5. Process with: `sudo bin/ntt-orchestrator --image /data/fast/img/<v2_hash>.img`

### Next Steps
1. Image new drives found (starting with Hitachi d6c63baf)
2. Continue scanning for orphaned media 3033499e
3. Verify all Oct 7-11 drives against database

## Files Modified/Created
- `bin/identify-drive-by-hash.sh` - new drive identification tool
- `docs/hardware-info-3033499e-for-re-imaging.md` - orphaned media documentation
- `/var/log/ntt/drive-identification.jsonl` - drive scan log

## References
- Hash bug investigation: `/tmp/test-oct7-hash.sh`, `/tmp/test-append-methods.sh`
- Hash format docs: `docs/hash-format.md`
- Oct 10 commit fixing bug: 5d0b821
