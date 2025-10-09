<!--
Author: PB and Claude
Date: Wed 09 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/media-processing-goals-488de202.md
-->

# Media Processing Goals - 488de202f73bd976de4e7048f4e1f39a

**Purpose:** Process 466GB floppy through complete pipeline with validation of recent improvements.

**Context:** Following successful processing of e5727c34 (150GB Mac Time Machine backup), we've completed:
- ✅ DiagnosticService Phase 4 (deferred write pattern)
- ✅ Added ignore patterns for LaTeX/TextMate problematic filenames
- ✅ Full pipeline validated: enum → load → copy → archive

**Medium Details:**
- Hash: `488de202f73bd976de4e7048f4e1f39a`
- Human: `floppy_20251005_101844_488de202`
- Size: 466GB
- Status: ddrescue complete, not yet enumerated
- Location: `/data/fast/img/488de202f73bd976de4e7048f4e1f39a.img`

---

## Goal 1: Complete Full Pipeline Processing

**Objective:** Process 488de202 through enum → load → copy → archive with no manual intervention.

### Tasks

#### 1.1 Pre-flight Checks
```bash
HASH="488de202f73bd976de4e7048f4e1f39a"

# Verify ddrescue complete
sudo grep "Finished" /data/fast/img/${HASH}.map

# Check database status
psql -d copyjob -c "SELECT medium_hash, enum_done, copy_done FROM medium WHERE medium_hash = '$HASH'"

# Verify not mounted
mount | grep $HASH

# Confirm ddrescue not running
pgrep -f "ddrescue.*${HASH}"
```

**Success condition:**
- ✅ Map shows "Finished"
- ✅ Database shows: enum_done=null, copy_done=null
- ✅ Not mounted
- ✅ No ddrescue process

#### 1.2 Mount and Enumerate
```bash
HASH="488de202f73bd976de4e7048f4e1f39a"
HASH_SHORT="488de202"

# Mount (may need manual if mount-helper fails)
sudo bin/ntt-mount-helper mount $HASH /data/fast/img/${HASH}.img

# If mount-helper fails, manual mount:
# LOOP=$(sudo losetup -f --show -r /data/fast/img/${HASH}.img)
# sudo blkid $LOOP  # Check filesystem type
# sudo mkdir -p /mnt/ntt/$HASH
# sudo mount -t [TYPE] -o ro,nosuid,nodev,noatime $LOOP /mnt/ntt/$HASH

# Verify mount
mount | grep $HASH
sudo ls /mnt/ntt/$HASH

# Run enumeration
time sudo bin/ntt-enum /mnt/ntt/$HASH $HASH /tmp/${HASH_SHORT}.raw

# Check output
ls -lh /tmp/${HASH_SHORT}.raw
tr '\034' '\n' < /tmp/${HASH_SHORT}.raw | wc -l
```

**Success condition:**
- ✅ Mounted successfully (check mount | grep)
- ✅ Enumeration complete (check for "✓ Enumeration complete" message)
- ✅ Raw file created in /tmp
- ✅ Inode count > 0

**Expected:** 466GB floppy is unusual size - may be a disk image collection or USB drive mislabeled as floppy.

#### 1.3 Load to Database
```bash
HASH="488de202f73bd976de4e7048f4e1f39a"
HASH_SHORT="488de202"

# Load with ntt-loader
time sudo bin/ntt-loader /tmp/${HASH_SHORT}.raw $HASH

# Verify load results
psql -d copyjob -c "
SELECT
  COUNT(*) FILTER (WHERE copied = false AND claimed_by IS NULL) as pending,
  COUNT(*) FILTER (WHERE copied = false AND claimed_by = 'NON_FILE') as non_file,
  COUNT(*) FILTER (WHERE copied = false AND claimed_by = 'EXCLUDED') as excluded,
  COUNT(*) FILTER (WHERE copied = true) as completed,
  COUNT(*) as total
FROM inode
WHERE medium_hash = '$HASH'
"
```

**Success condition:**
- ✅ Load completes without errors
- ✅ Database shows: enum_done = timestamp
- ✅ Pending count > 0
- ✅ Excluded count shows ignore patterns working (if LaTeX/TextMate files present)

**Watch for:** Loader should apply new ignore patterns (`\\left-\\right`, `/\\n\.plist`, `\\newenvironment\{`)

#### 1.4 Test Batch Copy
```bash
HASH="488de202f73bd976de4e7048f4e1f39a"

# Run small test batch (500 files)
sudo bin/ntt-copier.py \
  --medium-hash $HASH \
  --worker-id test-488de202 \
  --batch-size 50 \
  --limit 500

# Check results
psql -d copyjob -c "
SELECT
  COUNT(*) FILTER (WHERE copied = true) as copied,
  COUNT(*) FILTER (WHERE copied = false AND claimed_by IS NULL) as remaining
FROM inode
WHERE medium_hash = '$HASH'
"
```

**Success condition:**
- ✅ 500 files processed successfully
- ✅ No infinite retry loops
- ✅ Diagnostic system logs appear (if errors encountered)

#### 1.5 Full Copy (Background)
```bash
HASH="488de202f73bd976de4e7048f4e1f39a"

# Start full copy in background
sudo nohup bin/ntt-copier.py \
  --medium-hash $HASH \
  --worker-id overnight-488de202 \
  --batch-size 100 \
  > /var/log/ntt/copier-488de202-full.log 2>&1 &

# Verify started
ps aux | grep overnight-488de202 | grep -v grep

# Monitor (optional)
sudo tail -f /var/log/ntt/copier-488de202-full.log
```

**Success condition:**
- ✅ Copier running in background
- ✅ Log file being written
- ✅ Database shows increasing copied count

**Expected duration:** Several hours (depends on file count and size distribution)

#### 1.6 Archive After Completion
```bash
HASH="488de202f73bd976de4e7048f4e1f39a"

# Check if copy complete
psql -d copyjob -c "
SELECT
  COUNT(*) FILTER (WHERE copied = false AND claimed_by IS NULL) as remaining,
  COUNT(*) FILTER (WHERE copied = true) as completed
FROM inode
WHERE medium_hash = '$HASH'
"

# If remaining ~= 0 (or only unrecoverable files):

# Stop copier if still looping on failures
ps aux | grep overnight-488de202 | grep -v grep
# If found: sudo kill [PID]

# Create archive
cd /data/fast/img
sudo tar -I 'zstd -T0' -cvf /data/cold/img-read/${HASH}.tar.zst \
  ${HASH}.img ${HASH}.map

# Update database
psql -d copyjob -c "UPDATE medium SET copy_done = NOW() WHERE medium_hash = '$HASH'"

# Remove source files
sudo rm ${HASH}.img ${HASH}.map ${HASH}.map.bak 2>/dev/null || true

# Unmount
sudo bin/ntt-mount-helper unmount $HASH

# Verify archive
ls -lh /data/cold/img-read/${HASH}.tar.zst
```

**Success condition:**
- ✅ Archive exists in /data/cold/img-read/
- ✅ Database: copy_done = timestamp
- ✅ Source files removed from /data/fast/img/
- ✅ Medium unmounted

---

## Goal 2: Validate Ignore Patterns

**Objective:** Confirm new ignore patterns work correctly and don't over-exclude.

### Tasks

#### 2.1 Check Exclusion Counts
```bash
HASH="488de202f73bd976de4e7048f4e1f39a"

# Count excluded paths by reason
psql -d copyjob -c "
SELECT
  COUNT(*) as excluded_count,
  COUNT(*) FILTER (WHERE path ~ '\\\\left-\\\\right') as latex_delimiters,
  COUNT(*) FILTER (WHERE path ~ '/\\\\n\\.plist') as backslash_n,
  COUNT(*) FILTER (WHERE path ~ '\\\\newenvironment\\{') as latex_env
FROM path
WHERE medium_hash = '$HASH'
  AND exclude_reason = 'pattern_match'
"
```

**Success condition:**
- ✅ Excluded count reasonable (not excluding everything)
- ✅ If LaTeX/TextMate files present, patterns caught them
- ✅ No false positives (check sample of excluded paths)

#### 2.2 Sample Excluded Paths
```bash
HASH="488de202f73bd976de4e7048f4e1f39a"

# Get sample of excluded paths
psql -d copyjob -c "
SELECT encode(path, 'escape') as path
FROM path
WHERE medium_hash = '$HASH'
  AND exclude_reason = 'pattern_match'
LIMIT 10
"
```

**Success condition:**
- ✅ Excluded paths contain problematic characters (backslashes, braces)
- ✅ No normal files excluded by mistake

#### 2.3 Compare with e5727c34
```bash
# e5727c34 had 12 failed paths (6 inodes) before patterns added
# 488de202 should exclude these proactively

# Check if 488de202 has similar files
psql -d copyjob -c "
SELECT
  COUNT(*) as similar_patterns
FROM path
WHERE medium_hash = '488de202f73bd976de4e7048f4e1f39a'
  AND (path ~ '\\\\left-\\\\right' OR
       path ~ '/\\\\n\\.plist' OR
       path ~ '\\\\newenvironment\\{')
"
```

**Success condition:**
- ✅ If patterns found, they're excluded (not causing copy failures)
- ✅ Zero retry loops on LaTeX/TextMate files

---

## Goal 3: Collect Diagnostic Data

**Objective:** Gather diagnostic metrics to validate Phase 4 recording and analyze error patterns.

### Tasks

#### 3.1 Monitor Diagnostic Events During Copy
```bash
# While copier is running, check for diagnostic events
sudo grep "DIAGNOSTIC CHECKPOINT\|SKIPPED\|MAX RETRIES" /var/log/ntt/copier-488de202-full.log | tail -20

# Or use the detailed log analysis
sudo tail -1000 /var/log/ntt/copier-488de202-full.log | grep -E "ERROR|WARNING|diagnostic"
```

**Success condition:**
- ✅ If errors occur, diagnostic checkpoint triggers at retry #10
- ✅ BEYOND_EOF errors auto-skip (not infinite loop)
- ✅ Diagnostic events logged clearly

#### 3.2 Check Database Diagnostic Recording
```bash
HASH="488de202f73bd976de4e7048f4e1f39a"

# After copy completes, check if diagnostic events were recorded
psql -d copyjob -c "
SELECT
  problems
FROM medium
WHERE medium_hash = '$HASH'
"
```

**Success condition:**
- ✅ If errors occurred, `problems` column populated
- ✅ Diagnostic events array exists: `problems->'diagnostic_events'`
- ✅ Medium-level summaries recorded (beyond_eof_detected, high_error_rate)

#### 3.3 Analyze Error Patterns
```bash
HASH="488de202f73bd976de4e7048f4e1f39a"

# Get failed inodes
psql -d copyjob -c "
SELECT
  i.ino,
  i.copied,
  i.claimed_by,
  array_length(i.errors, 1) as error_count,
  i.errors[array_length(i.errors, 1)] as last_error
FROM inode i
WHERE i.medium_hash = '$HASH'
  AND i.copied = false
  AND i.claimed_by IS NULL
ORDER BY error_count DESC NULLS LAST
LIMIT 10
"
```

**Success condition:**
- ✅ Failed inodes have clear error messages
- ✅ Error patterns documented (BEYOND_EOF, I/O error, missing file)
- ✅ Retry counts reasonable (not 20K+ like e5727c34 before patterns)

#### 3.4 Export Diagnostic Data
```bash
HASH="488de202f73bd976de4e7048f4e1f39a"

# Export diagnostic summary for documentation
psql -d copyjob -c "
SELECT
  m.medium_hash,
  m.medium_human,
  COUNT(*) FILTER (WHERE i.copied = true) as copied_count,
  COUNT(*) FILTER (WHERE i.copied = false AND i.claimed_by IS NULL) as failed_count,
  COUNT(*) FILTER (WHERE i.claimed_by = 'DIAGNOSTIC_SKIP:BEYOND_EOF') as auto_skipped,
  m.problems
FROM medium m
LEFT JOIN inode i ON m.medium_hash = i.medium_hash
WHERE m.medium_hash = '$HASH'
GROUP BY m.medium_hash, m.medium_human, m.problems
" > /tmp/488de202-diagnostic-summary.txt
```

**Success condition:**
- ✅ Summary exported to /tmp
- ✅ Data available for analysis and documentation

---

## Goal 4: Document New Error Patterns

**Objective:** Document any new error patterns discovered during processing for future ignore pattern improvements.

### Tasks

#### 4.1 Identify Unique Error Patterns
```bash
HASH="488de202f73bd976de4e7048f4e1f39a"

# Get unique error patterns
psql -d copyjob -c "
SELECT
  DISTINCT substring(i.errors[array_length(i.errors, 1)] from 1 for 100) as error_pattern,
  COUNT(*) as occurrences
FROM inode i
WHERE i.medium_hash = '$HASH'
  AND i.copied = false
  AND array_length(i.errors, 1) > 0
GROUP BY error_pattern
ORDER BY occurrences DESC
"
```

**Success condition:**
- ✅ Error patterns categorized
- ✅ Distinguish: BEYOND_EOF, I/O errors, filename issues, corruption

#### 4.2 Sample Failed File Paths
```bash
HASH="488de202f73bd976de4e7048f4e1f39a"

# Get paths of failed files
psql -d copyjob -c "
SELECT
  i.ino,
  encode(p.path, 'escape') as path,
  i.errors[array_length(i.errors, 1)] as error
FROM inode i
JOIN path p ON i.medium_hash = p.medium_hash AND i.ino = p.ino
WHERE i.medium_hash = '$HASH'
  AND i.copied = false
  AND i.claimed_by IS NULL
LIMIT 20
"
```

**Success condition:**
- ✅ Failed paths examined for patterns
- ✅ Identify if new ignore patterns needed

#### 4.3 Create Error Pattern Summary Document
```bash
# Create summary in /tmp for review
cat > /tmp/488de202-error-patterns.md << 'EOF'
# Error Patterns - 488de202

## Summary
- Total inodes: [COUNT]
- Copied successfully: [COUNT] ([PERCENT]%)
- Failed: [COUNT] ([PERCENT]%)
- Auto-skipped (BEYOND_EOF): [COUNT]

## Error Categories

### Category 1: [NAME]
- Count: [N]
- Example error: [ERROR MESSAGE]
- Example paths: [PATHS]
- Root cause: [ANALYSIS]
- Recommendation: [IGNORE PATTERN / FIX / DOCUMENT]

### Category 2: [NAME]
...

## Proposed Ignore Patterns

If new patterns identified:
```
# Add to /home/pball/.config/ntt/ignore-patterns.txt

# Description
pattern1
pattern2
```

## Notes
- Compare to e5727c34 patterns
- Check if filesystem-specific (HFS+ vs FAT vs ext4)
EOF

# Fill in the template with actual data
```

**Success condition:**
- ✅ Error patterns documented
- ✅ New ignore patterns proposed (if needed)
- ✅ Comparison with e5727c34 patterns

#### 4.4 Update Documentation
```bash
# Add findings to main diagnostic documentation
# Location: docs/copier-diagnostic-ideas.md

# Document this test case:
# - Medium type (466GB "floppy" - likely USB/disk image)
# - Error patterns found
# - Ignore patterns effectiveness
# - Phase 4 diagnostic recording validation
```

**Success condition:**
- ✅ Test results added to copier-diagnostic-ideas.md
- ✅ New patterns documented in ignore-patterns-guide.md (if created)
- ✅ Lessons learned captured

---

## Overall Success Criteria

**Goal 1 Success:**
- ✅ 488de202 fully processed (enum, load, copy, archive)
- ✅ Copy completion rate > 99.9%
- ✅ Archive in /data/cold/img-read/
- ✅ Database updated (copy_done timestamp)
- ✅ Source files cleaned up

**Goal 2 Success:**
- ✅ Ignore patterns working correctly
- ✅ No false positives (normal files excluded)
- ✅ LaTeX/TextMate problematic files excluded proactively
- ✅ Zero 20K+ retry loops on filename issues

**Goal 3 Success:**
- ✅ Diagnostic events recorded in medium.problems
- ✅ Phase 4 deferred write pattern validated
- ✅ Diagnostic data exported for analysis
- ✅ No lock conflicts during recording

**Goal 4 Success:**
- ✅ Error patterns documented
- ✅ New ignore patterns proposed (if applicable)
- ✅ Findings added to main documentation
- ✅ Comparison with e5727c34 complete

---

## Reference Information

**Previous successful processing:**
- e5727c34fb46e18c87153d576388ea32 (150GB HFS+ Time Machine)
- 1,005,315 files copied (99.9994% success)
- 6 files failed (LaTeX/TextMate with problematic filenames)
- Led to ignore pattern additions

**Key commands:**
- Enum: `sudo bin/ntt-enum [MOUNT] [HASH] [OUTPUT]`
- Load: `sudo bin/ntt-loader [RAW_FILE] [HASH]`
- Copy: `sudo bin/ntt-copier.py --medium-hash [HASH] --worker-id [ID] --batch-size [SIZE]`
- Archive: `sudo tar -I 'zstd -T0' -cvf [DEST] [FILES]`

**Ignore patterns file:**
- Location: `/home/pball/.config/ntt/ignore-patterns.txt`
- Applied during ntt-loader (marks paths as excluded)
- Current count: 45 patterns

**Diagnostic system:**
- Phase 1: Detection (checkpoint at retry #10)
- Phase 2: Auto-skip (BEYOND_EOF errors)
- Phase 4: Recording (deferred writes to medium.problems)
- Logs: `/var/log/ntt/copier-*.log`

**Database queries:**
- See: `docs/diagnostic-queries.md` (20 example queries)
- Connection: `psql -d copyjob`

---

## Troubleshooting

**If mount fails:**
- Try manual loop + mount (see Task 1.2)
- Check filesystem type: `sudo blkid /dev/loopX`
- For partitioned disks: `sudo losetup -P` and mount partition

**If enumeration hangs:**
- Check mount still valid: `mount | grep [HASH]`
- Check filesystem errors: `dmesg | tail -50`
- May need to remount or skip medium

**If copy has infinite loops:**
- Check diagnostic logs: `sudo grep "MAX RETRIES" /var/log/ntt/copier-*.log`
- Should auto-skip at retry #10 for BEYOND_EOF
- If not, may need new ignore patterns

**If Phase 4 recording fails:**
- Check database connection: `psql -d copyjob -c "SELECT 1"`
- Check for lock conflicts: Should see "TIMING: diagnostic_events" in logs
- Verify problems column: `\d medium` in psql

---

**Created:** 2025-10-09
**For:** Processing 488de202f73bd976de4e7048f4e1f39a (466GB floppy)
**Status:** Ready for execution
