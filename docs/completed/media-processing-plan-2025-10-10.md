<!--
Author: PB and Claude
Date: Thu 10 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/media-processing-plan-2025-10-10.md
-->

# Media Processing Plan - 2025-10-10

## Purpose

Process unprocessed media through the complete NTT pipeline using recent improvements:

**Recent improvements in place:**
- ✅ DiagnosticService Phase 1-4 (detection + deferred recording)
- ✅ Loader safeguards (5min timeout, ANALYZE, timing logs)
- ✅ Ignore patterns for system files (.Trash, .DS_Store, etc.)
- ✅ Stale loop cleanup in ntt-mount-helper

**Goals:**
1. Clear backlog of 42 unprocessed media
2. Generate metrics on pipeline performance
3. Identify any remaining operational issues
4. Build confidence in production deployment

---

## Current State

**Database summary** (as of 2025-10-10):
```
Imaging (not yet enumerated):  42 media
Loaded (enumerated, not copied): 0 media
Archived (fully complete):      16 media
With problems recorded:         14 media
```

**Storage:**
- `/data/fast/img/` - Contains IMG files being imaged/processed
- `/data/cold/archived/` - Deduplicated file archives (16 media)
- `/data/cold/img-read/` - Compressed IMG archives
- `/data/cold/by-hash/` - Content-addressed file storage

---

## Processing Strategy

### Phase 1: Small/Medium Test Batch (3-5 media)

**Goal:** Validate recent improvements on manageable workload

**Candidate selection criteria:**
- Size: 1M - 100G (not too large, not trivial)
- Status: ddrescue complete or nearly complete (>95% recovered)
- Problems: No existing problems recorded
- Already mounted: Preferred (tests mount stability)

**Recommended candidates** (check current status before processing):

1. **579d3c3a476185f524b77b286c5319f5** (579d3c3a476185f5)
   - Size: 56G
   - Status: Already mounted (loop2p1, loop2p5) - ext3 partitions
   - Good test case for multi-partition disk

2. **Small floppy images** (select 2-3 from):
   - 6ddf5caa (floppy_20251006_073539)
   - 6d89ac9f (floppy_20251006_085316)
   - 3a4b9050 (floppy_20251006_090948)
   - 782e1baf (floppy_20251006_102506)
   - d804ca3d (floppy_20251006_111738)

**Success criteria:**
- All phases complete without manual intervention
- DiagnosticService logs appear if errors encountered
- Loader completes deduplication in <10s
- No infinite retry loops
- Clean archival to /data/cold

**Time estimate:** 2-6 hours depending on disk condition

---

### Phase 2: Large Disk Processing (1-2 media)

**Goal:** Test pipeline on production-scale workloads

**Candidates** (verify ddrescue complete first):

1. **488de202f73bd976de4e7048f4e1f39a** (floppy_20251005_101844_488de202)
   - Size: 466G
   - Status: Check ddrescue completion
   - From superseded plan, never processed

2. **529bfda4af084b592d26e8e115806631** (A1_20250315)
   - Size: 280G
   - Status: Check ddrescue completion

**Considerations:**
- Large disks will take 6-24 hours for full copy phase
- Monitor for I/O errors (DiagnosticService will handle)
- May need multiple copier workers for throughput
- Watch for FAT filesystem issues (common on large media)

**Time estimate:** 1-3 days per disk

---

### Phase 3: Bulk Processing (Remaining ~35 media)

**Goal:** Clear backlog with confidence

**Approach:**
- Process in batches of 5-10 media
- Prioritize by size (small → medium → large)
- Run multiple copier workers in parallel
- Monitor for patterns in problems

**Exclude from processing:**
- Media still being actively imaged by ddrescue
- Media with mount failures (investigate separately)
- Very large disks (>1TB) - defer until Phase 2 complete

**Time estimate:** 2-4 weeks depending on disk sizes and conditions

---

## Detailed Workflow

### Pre-Flight Checks

**For each medium before processing:**

```bash
HASH=<medium_hash>

# 1. Verify ddrescue complete (no active process)
ps aux | grep ddrescue | grep $HASH
# Should return: empty

# 2. Check IMG file exists
ls -lh /data/fast/img/${HASH}.img

# 3. Check recovery status (if mapfile exists)
sudo grep "^#.*rescued" /data/fast/img/${HASH}.map
# Look for high percentage (>95%)

# 4. Database state
psql -d copyjob -c "
  SELECT medium_hash, enum_done, copy_done, problems
  FROM medium
  WHERE medium_hash = '$HASH'
"
# Should show: enum_done=NULL, copy_done=NULL, problems=NULL

# 5. Check mount status
mount | grep $HASH || echo "Not mounted"
```

**Abort if:**
- ddrescue still running
- IMG file missing
- Recovery <90% (unless intentional)
- Database already shows processing started

---

### Phase 1: Enumeration

**Goal:** Walk filesystem, extract inode metadata

```bash
HASH=<medium_hash>
HASH_SHORT=$(echo $HASH | cut -c1-8)

# Mount if needed
sudo bin/ntt-mount-helper status $HASH || \
  sudo bin/ntt-mount-helper mount $HASH /data/fast/img/${HASH}.img

# Run enumeration
sudo bin/ntt-enum /mnt/ntt/$HASH $HASH /tmp/${HASH_SHORT}.raw

# Verify output
ls -lh /tmp/${HASH_SHORT}.raw
tr '\034' '\n' < /tmp/${HASH_SHORT}.raw | wc -l
```

**Expected:**
- Raw file created: `/tmp/${HASH_SHORT}.raw`
- Size depends on filesystem content
- Inode count >0

**Diagnostics:**
```bash
# Check for duplicate paths (should be empty)
tr '\034' '\n' < /tmp/${HASH_SHORT}.raw | sort | uniq -d
```

**On failure:**
- Check `dmesg | tail -50` for mount/filesystem errors
- Consult `docs/disk-read-checklist.md`
- Record problem:
  ```sql
  UPDATE medium SET problems = jsonb_build_object(
    'enum_failed', true,
    'error', '<error details>'
  ) WHERE medium_hash = '$HASH';
  ```

---

### Phase 2: Loading

**Goal:** Import enumeration data into PostgreSQL partitions

```bash
HASH=<medium_hash>
HASH_SHORT=$(echo $HASH | cut -c1-8)

# Run loader with safeguards
time sudo bin/ntt-loader /tmp/${HASH_SHORT}.raw $HASH
```

**Expected:**
- Partitions created: `inode_p_${HASH}`, `path_p_${HASH}`
- Log: "Deduplication completed in Xs" (should be <10s)
- No hangs (5min timeout will abort if issues)

**Verification:**
```bash
# Check partition exists
psql -d copyjob -c "\\d+ inode_p_${HASH}"

# Count records
psql -d copyjob -c "
  SELECT
    (SELECT COUNT(*) FROM inode WHERE medium_hash = '$HASH') as inodes,
    (SELECT COUNT(*) FROM path WHERE medium_hash = '$HASH') as paths
"

# Verify FK indexes exist
psql -d copyjob -c "
  SELECT indexname
  FROM pg_indexes
  WHERE tablename = 'path_p_${HASH}'
    AND indexname LIKE '%fk%'
"
# Should show: path_p_${HASH}_fk_idx
```

**On failure:**
- Check for duplicate paths (Phase 1 diagnostic)
- Review PostgreSQL logs
- If timeout: investigate why deduplication is slow

---

### Phase 3: Copying

**Goal:** Deduplicate and archive files to /data/cold

**Single worker (for testing):**
```bash
HASH=<medium_hash>

sudo -E bin/ntt-copier.py \
  --medium-hash $HASH \
  --worker-id test-worker \
  --batch-size 50 \
  --limit 500  # Optional: for initial test run
```

**Multiple workers (for production):**
```bash
# Start 3-5 workers in parallel
for i in {1..3}; do
  sudo -E bin/ntt-copier.py \
    --medium-hash $HASH \
    --worker-id "worker-$i" \
    --batch-size 50 &
done
```

**Expected behavior:**
- Files copied to `/data/cold/by-hash/{AA}/{BB}/{hash}`
- Hardlinks created in `/data/cold/archived/${HASH}/...`
- Deduplication working (some files link to existing by-hash)
- DiagnosticService auto-skips unrecoverable errors

**Monitoring:**
```bash
# Watch progress (don't use `watch` - breaks terminal)
while true; do
  psql -d copyjob -c "
    SELECT
      COUNT(*) FILTER (WHERE copied = true) as done,
      COUNT(*) FILTER (WHERE copied = false AND claimed_by IS NULL) as pending,
      COUNT(*) FILTER (WHERE copied = false AND claimed_by IS NOT NULL) as claimed
    FROM inode WHERE medium_hash = '$HASH'
  "
  sleep 5
done

# Check for diagnostic events
sudo grep "DIAGNOSTIC CHECKPOINT\|SKIPPED" /var/log/ntt-copier.log

# Check filesystem
du -sh /data/cold/archived/$HASH/
ls -la /data/cold/by-hash/ | head -20
```

**Expected diagnostic logs** (if errors occur):
- `🔍 DIAGNOSTIC CHECKPOINT` - At retry #10 for any inode
- `⏭️ SKIPPED ino=X reason=DIAGNOSTIC_SKIP:BEYOND_EOF` - Auto-skip unrecoverable

**On issues:**
- DiagnosticService should handle most errors automatically
- Check `dmesg | tail -100` for I/O errors
- Verify mount still active: `mount | grep $HASH`
- For persistent errors: check `medium.problems` for diagnostics

---

### Phase 4: Archive

**Goal:** Compress and move IMG files to cold storage

**Only proceed if copying is complete:**
```bash
HASH=<medium_hash>

# Verify all copyable files are copied
psql -d copyjob -c "
  SELECT
    COUNT(*) FILTER (WHERE copied = true) as copied,
    COUNT(*) FILTER (WHERE copied = false AND skip_reason IS NULL) as unclaimed
  FROM inode WHERE medium_hash = '$HASH'
"
# unclaimed should be 0
```

**Create archive:**
```bash
cd /data/fast/img

# IMPORTANT: Use explicit file list, not wildcards
sudo tar -I 'zstd -T0' -cvf /data/cold/img-read/${HASH}.tar.zst \
  ${HASH}.img \
  ${HASH}.map \
  ${HASH}.map.bak \
  ${HASH}.map.stall \
  ${HASH}-ddrescue.log

# Verify archive
sudo tar -I 'zstd -d' -tvf /data/cold/img-read/${HASH}.tar.zst | head -20

# Mark complete in database
psql -d copyjob -c "
  UPDATE medium
  SET copy_done = NOW()
  WHERE medium_hash = '$HASH'
"

# Remove source files
sudo rm ${HASH}.img ${HASH}.map ${HASH}.map.bak ${HASH}.map.stall ${HASH}-ddrescue.log

# Unmount if mounted
sudo bin/ntt-mount-helper unmount $HASH
```

**Verification:**
- Archive exists: `/data/cold/img-read/${HASH}.tar.zst`
- Database: `copy_done IS NOT NULL`
- Source files removed from /data/fast/img
- Mount point cleaned up

---

## Success Metrics

### Per-Medium Metrics

Track for each processed medium:

1. **Enumeration:**
   - ✅ Raw file created
   - ✅ No duplicate paths
   - ✅ Inode count >0
   - ⏱️ Time to complete

2. **Loading:**
   - ✅ Partitions created
   - ✅ Deduplication <10s
   - ✅ FK indexes present
   - ⏱️ Total load time

3. **Copying:**
   - ✅ Files archived to /data/cold/archived/
   - ✅ Deduplication working
   - 📊 Deduplication rate (% files already in by-hash)
   - 📊 Copy throughput (MB/s)
   - 📊 Diagnostic events (if any)
   - 📊 Auto-skip events (if any)
   - ⏱️ Total copy time

4. **Archive:**
   - ✅ Compressed archive created
   - ✅ Database marked complete
   - ✅ Source files cleaned up
   - 📊 Compression ratio

### Aggregate Metrics

Track across all processed media:

- **Success rate:** % media completed without manual intervention
- **Error patterns:** Common diagnostic events/skip reasons
- **Performance:** Average throughput by media size
- **Deduplication:** Overall % of files deduplicated
- **Storage efficiency:** Compression ratios, space saved

---

## Rollback Procedures

### Enumeration Failed

```bash
HASH=<medium_hash>
HASH_SHORT=$(echo $HASH | cut -c1-8)

# Clean up
rm /tmp/${HASH_SHORT}.raw
sudo bin/ntt-mount-helper unmount $HASH

# Investigate with disk-read-checklist.md
# Record problem in database
```

### Loading Failed

```sql
-- Drop partitions
DROP TABLE IF EXISTS inode_p_<hash> CASCADE;
DROP TABLE IF EXISTS path_p_<hash> CASCADE;

-- Reset medium
UPDATE medium SET enum_done = NULL WHERE medium_hash = '<hash>';
```

```bash
# Clean up raw file
rm /tmp/<hash_short>.raw
```

### Copying Failed Mid-Stream

```bash
# No special rollback needed - copier is idempotent
# Inodes remain claimed, next worker will retry or skip

# Check diagnostics
sudo grep DIAGNOSTIC /var/log/ntt-copier.log | grep <hash>

# Restart copier for same medium
sudo -E bin/ntt-copier.py --medium-hash <hash> --worker-id retry-worker
```

### Archive Failed

```bash
# No rollback needed - just retry tar command
# Source files still in /data/fast/img
```

---

## Risk Mitigation

### Known Risks

1. **FAT filesystem corruption** (common on old floppies/USBs)
   - Mitigation: DiagnosticService auto-skips BEYOND_EOF errors
   - Monitor: Check `medium.problems` for FAT_ERROR patterns

2. **I/O errors on damaged sectors**
   - Mitigation: ddrescue already recovered what it could
   - DiagnosticService detects and skips unrecoverable
   - Monitor: `dmesg` for kernel I/O errors

3. **Large disk timeouts**
   - Mitigation: Loader safeguards (5min timeout)
   - Monitor: "Deduplication completed" log messages
   - Escalate: If timeout fires, investigate slow queries

4. **Mount instability**
   - Mitigation: Stale loop cleanup in mount-helper
   - Monitor: Check for unmounts during copying
   - Escalate: If recurring, implement Priority 4 (mount locking)

5. **Disk space exhaustion**
   - Monitor: `/data/fast` and `/data/cold` usage
   - Mitigation: Archive completed media promptly
   - Emergency: Stop processing, archive existing, free space

### Monitoring Commands

```bash
# Disk space
df -h /data/fast /data/cold

# Active processes
ps aux | grep -E 'ddrescue|ntt-enum|ntt-loader|ntt-copier'

# Recent errors
sudo dmesg | tail -50
sudo tail -100 /var/log/ntt-copier.log

# Database state
psql -d copyjob -c "
  SELECT
    COUNT(*) FILTER (WHERE enum_done IS NULL) as imaging,
    COUNT(*) FILTER (WHERE enum_done IS NOT NULL AND copy_done IS NULL) as loaded,
    COUNT(*) FILTER (WHERE copy_done IS NOT NULL) as archived
  FROM medium
"
```

---

## Multi-Claude Workflow

**Three Claudes work together on this plan:**

- **prox-claude:** Runs all commands, monitors execution, files bugs, verifies fixes
- **dev-claude:** Fixes bugs filed by prox-claude, improves code
- **metrics-claude:** Collects per-medium and aggregate metrics, identifies patterns

**Key infrastructure:**
- `ROLES.md` - Role definitions and communication protocols (READ THIS FIRST)
- `processing-queue.md` - Processing log (not a plan, prox-claude re-evaluates from DB)
- `bugs/` - Bug reports and fixes
- `metrics/` - Per-medium and aggregate metrics

**Workflow:** prox-claude runs this plan → files bugs when issues occur → dev-claude fixes → prox-claude verifies → metrics-claude analyzes → all iterate

---

## Bug Filing Criteria

prox-claude should file a bug report (`bugs/TEMPLATE.md`) when:

### 1. Command Failure
- Expected: command succeeds
- Observed: command exits with error or hangs >5min

**Example:** Loader runs for 8 minutes with no output (expected: <10s completion)

### 2. Success Criteria Violation
- Expected: "Deduplication completed in <10s" (from this plan)
- Observed: Takes 5 minutes

**Example:** Dedup query takes 4min 23s instead of <10s

### 3. Data Integrity Issues
- Duplicate paths in enumeration (loader will fail)
- Missing partitions after load
- FK indexes not created

**Example:** Query shows 0 rows for `pg_tables` where `tablename = 'inode_p_<hash>'`

### 4. Unexpected Behavior
- DiagnosticService not triggering at retry #10 (expected per Phase 3)
- Mount succeeds but ls fails
- Files copied but not in by-hash/

**Example:** 500 files show copied=true but `/data/cold/by-hash/` has only 50 files

### 5. New Error Patterns
- Error message not in `docs/disk-read-checklist.md`
- Behavior not covered by rollback procedures

**Example:** New dmesg error: "ext3: journal commit failed" not in checklist

### Filing Process

1. **Copy `bugs/TEMPLATE.md`** to `bugs/BUG-NNN-<type>-<hash>.md`
   - NNN: Next sequential number (check existing bugs/)
   - type: loader-timeout | mount-fail | dedup-slow | etc.
   - hash: Short hash (first 8 chars)

2. **Fill all sections** with observable evidence:
   - Commands run (exact bash)
   - Output/errors (actual stdout/stderr)
   - Database state (query + results)
   - Filesystem state (ls/mount/df output)
   - NO CODE READING - only what you observe from running commands

3. **Define success conditions** (must be testable):
   - ✅ "Command completes in <10s"
   - ✅ "Query returns 1 row"
   - ❌ "It works better" (not testable)

4. **Update `processing-queue.md`:**
   - Move medium to "Blocked" section
   - Reference bug number

5. **Continue with other media** if possible

### When NOT to File Bugs

- **Expected failures:** Media with boot sector corruption (archive with problems, don't file bug)
- **Already documented:** Error pattern in `docs/disk-read-checklist.md` with known handling
- **Transient issues:** One-time network blip, immediately retrying succeeds

---

## Bug Verification Process

After dev-claude marks bug as "ready for testing" (in "Dev Notes" section):

### 1. Re-run Original Failure Case

Use exact commands from bug report:
```bash
# Example from BUG-001
time sudo bin/ntt-loader /tmp/579d3c3a.raw 579d3c3a476185f524b77b286c5319f5
```

Compare output to expected behavior from success conditions.

### 2. Check All Success Conditions

Run each test from "Success Condition" section:
- [ ] Test 1: Command completes in <10s
- [ ] Test 2: Query returns expected result
- [ ] Test 3: File exists with correct properties

ALL must pass.

### 3. Test Edge Cases (if applicable)

- Try with different media if bug affects multiple
- Verify no regressions in related functionality

**Example:** If bug fixed loader for large disks, test on medium 579d3c3a (56G) AND small floppy (1M) to ensure both work.

### 4. Document Results

Append "Fix Verification" section to bug report:
```markdown
## Fix Verification

**Tested:** YYYY-MM-DD HH:MM
**Medium:** <hash>

**Results:**
- [x] Success condition 1: PASS - completed in 3.2s
- [x] Success condition 2: PASS - query returned 1 row
- [ ] Success condition 3: FAIL - file missing

**Outcome:** REOPENED - file creation still failing
```

### 5. Take Action

**If all pass:**
- Status: fixed
- Move to `bugs/fixed/BUG-NNN-*.md`
- Update `processing-queue.md`: remove from "Blocked", medium back to fresh evaluation

**If any fail:**
- Status: reopened
- Append detailed findings to bug report
- dev-claude re-investigates

### 6. Resume Processing

- Update processing-queue.md to unblock medium
- Fresh DB query will include unblocked media in candidates
- Continue from failed phase

---

## Timeline

### Phase 1: Test Batch (Week 1)
- **Days 1-2:** Process 579d3c3a (56G disk)
- **Days 3-5:** Process 2-3 small floppy images
- **Days 6-7:** Review metrics, document issues

### Phase 2: Large Disks (Weeks 2-3)
- **Week 2:** Process 488de202 (466G)
- **Week 3:** Process 529bfda4 (280G) or similar
- Review performance at scale

### Phase 3: Bulk Processing (Weeks 4-7)
- Process remaining ~35 media in batches
- Prioritize by size (small first, build confidence)
- Adjust approach based on Phase 1-2 learnings

### Ongoing
- Archive completed media immediately (free /data/fast space)
- Monitor for new media from ddrescue
- Update this plan based on findings

---

## Next Steps

1. **Verify ddrescue status** for Phase 1 candidates
2. **Select 3-5 media** for initial test batch
3. **Process through pipeline** following detailed workflow
4. **Collect metrics** per Success Metrics section
5. **Review and adjust** before Phase 2

---

## References

- **Disk read checklist:** `docs/disk-read-checklist.md`
- **DiagnosticService:** `docs/completed/workplan-2025-10-08.md` (Phase 1-4)
- **Loader safeguards:** `docs/loader-hang-investigation-2025-10-07.md`
- **Ignore patterns:** `bin/ntt_copier_ignore_patterns.py`
- **Database schema:** `input/schema.sql`

---

**Status:** Ready for Phase 1 execution
**Created:** 2025-10-10
**Priority:** High (clear backlog, validate improvements)
