<!--
Author: PB and Claude
Date: Tue 08 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/img-processing-workflow-2025-10-08.md
-->

# IMG File Processing Workflow - 2025-10-08

## Purpose

Process 1-2 disk image files through the complete NTT pipeline to:
1. Validate recent improvements (loader safeguards, diagnostic service)
2. Test stale loop cleanup in ntt-mount-helper
3. Generate baseline metrics for Priorities 2-4 planning
4. Exercise full workflow before implementing mount locking

---

## Candidate IMG Files

**Selected for processing:**

### Candidate 1: c9894f1681b5b542eb3a4b75967e9aea (CD-ROM, 456M)
```
medium_human: floppy_20251008_143045_c9894f16
size: 456M
ddrescue status: Trimming phase (mostlyComplete)
recovery: ~474M of 477M (99.4%)
```

### Candidate 2: ece03c6779caa14be2b00d380add8475 (CD-ROM, 478M)
```
medium_human: floppy_20251008_145335_ece03c67
size: 478M
ddrescue status: Trimming phase (mostly complete)
recovery: ~498M of 500M (99.6%)
```

**Why these:**
- Medium size (not too large for testing, not trivial)
- Both in trimming phase (recovery essentially complete)
- Different timestamps (good for testing)
- Already mounted (loop0, loop1)

**Excluded:**
- 9210e78b: Still being imaged by ddrescue (active process)
- Large disks (e5727c34: 150G, 6f9134d5: 94G): too slow for iteration
- Already processed disks

---

## Workflow Phases

### Phase 0: Pre-Flight Checks

**For each medium:**

```bash
HASH=c9894f1681b5b542eb3a4b75967e9aea  # or ece03c6779caa14be2b00d380add8475

# 1. Verify ddrescue complete
ps aux | grep ddrescue | grep $HASH
# Should return: no process

# 2. Check recovery percentage
grep "^0x" /data/fast/img/${HASH}.map | tail -5
# Look for mostly '+' status, minimal '-' or '*'

# 3. Verify image file exists
ls -lh /data/fast/img/${HASH}.img

# 4. Check mount status
mount | grep $HASH || echo "Not mounted"

# 5. Database state
psql -d copyjob -c "
  SELECT medium_hash, enum_done, copy_done, problems
  FROM medium
  WHERE medium_hash = '$HASH'
"
# Should show: enum_done=NULL, copy_done=NULL, problems=NULL
```

---

### Phase 1: Enumeration

**Goal:** Walk filesystem, extract inode metadata

**Command:**
```bash
HASH=c9894f1681b5b542eb3a4b75967e9aea
HASH_SHORT=$(echo $HASH | cut -c1-8)

# Mount if needed (tests mount-helper with new stale cleanup)
sudo bin/ntt-mount-helper status $HASH || \
  sudo bin/ntt-mount-helper mount $HASH /data/fast/img/${HASH}.img

# Run enumeration
sudo bin/ntt-enum /mnt/ntt/$HASH $HASH /tmp/${HASH_SHORT}.raw

# Check output
ls -lh /tmp/${HASH_SHORT}.raw
wc -l /tmp/${HASH_SHORT}.raw
```

**Expected output:**
- Raw file created: `/tmp/${HASH_SHORT}.raw`
- Size: Depends on filesystem content
- No errors in enumeration

**Diagnostics:**
```bash
# Check for duplicate paths
tr '\034' '\n' < /tmp/${HASH_SHORT}.raw | sort | uniq -d
# Should return: empty (no duplicates)

# Count inodes
tr '\034' '\n' < /tmp/${HASH_SHORT}.raw | grep -c "^"
```

**If enumeration fails:**
- Check dmesg for mount errors
- Check disk-read-checklist.md for diagnostic steps
- Record problem in `medium.problems`:
  ```sql
  UPDATE medium SET problems = jsonb_build_object('enum_failed', true, 'error', '<details>')
  WHERE medium_hash = '$HASH';
  ```

---

### Phase 2: Loading

**Goal:** Import enumeration data into PostgreSQL partitions

**Command:**
```bash
HASH=c9894f1681b5b542eb3a4b75967e9aea
HASH_SHORT=$(echo $HASH | cut -c1-8)

# Run loader (with new safeguards: timeout, ANALYZE, timing)
time sudo bin/ntt-loader /tmp/${HASH_SHORT}.raw $HASH

# Expected timing logs:
# - "Deduplication completed in Xs"
# - Should be <10s for most media
```

**Expected output:**
- Partition created: `inode_p_${HASH}`, `path_p_${HASH}`
- Records imported: Check count
- Deduplication runs quickly (<10s due to statement timeout + ANALYZE)
- No hangs (5min timeout)

**Verification:**
```bash
# Check partition exists
psql -d copyjob -c "\d+ inode_p_${HASH}"

# Count records
psql -d copyjob -c "
  SELECT
    (SELECT COUNT(*) FROM inode WHERE medium_hash = '$HASH') as inodes,
    (SELECT COUNT(*) FROM path WHERE medium_hash = '$HASH') as paths
"

# Check FK indexes
psql -d copyjob -c "
  SELECT indexname
  FROM pg_indexes
  WHERE tablename = 'path_p_${HASH}'
    AND indexname LIKE '%fk%'
"
# Should show: path_p_${HASH}_fk_idx
```

**If loading fails:**
- Check for duplicate paths (Phase 1 diagnostic)
- Check PostgreSQL logs for errors
- Verify partition migration is complete (P2P FKs)

---

### Phase 3: Copying

**Goal:** Deduplicate and archive files to /data/cold

**Command:**
```bash
HASH=c9894f1681b5b542eb3a4b75967e9aea

# Single worker, limited run to test diagnostics
sudo -E bin/ntt-copier.py \
  --medium-hash $HASH \
  --worker-id test-worker \
  --batch-size 50 \
  --limit 500

# Watch for diagnostic logs
# - "🔍 DIAGNOSTIC CHECKPOINT" at retry #10
# - "⏭️ SKIPPED" for BEYOND_EOF errors
# - "Batch completed" messages
```

**Expected behavior:**
- Files copied to `/data/cold/by-hash/{AA}/{BB}/{hash}`
- Hardlinks created in `/data/cold/archived/{medium}/...`
- Deduplication working (some files link to existing by-hash)
- Diagnostic service detects and auto-skips unrecoverable errors

**Monitoring:**
```bash
# Watch progress
watch -n 5 'psql -d copyjob -c "
  SELECT
    COUNT(*) FILTER (WHERE copied = true) as done,
    COUNT(*) FILTER (WHERE copied = false AND claimed_by IS NULL) as pending,
    COUNT(*) FILTER (WHERE copied = false AND claimed_by IS NOT NULL) as claimed
  FROM inode WHERE medium_hash = '"'$HASH'"'
"'

# Check for diagnostic events
grep "DIAGNOSTIC CHECKPOINT\|SKIPPED" /path/to/copier.log

# Check filesystem
du -sh /data/cold/archived/$HASH/
ls -la /data/cold/by-hash/ | head -20
```

**If copying has issues:**
- DiagnosticService should auto-skip BEYOND_EOF errors
- Check dmesg for FAT/I/O errors
- Verify mount is stable (no unmounts mid-copy)
- Check for stale loops after mount (should be cleaned automatically)

---

### Phase 4: Archive

**Goal:** Compress and move img files to cold storage

**Command:**
```bash
HASH=c9894f1681b5b542eb3a4b75967e9aea

# Verify copy complete
psql -d copyjob -c "
  SELECT
    COUNT(*) FILTER (WHERE copied = true) as copied,
    COUNT(*) FILTER (WHERE copied = false) as unclaimed
  FROM inode WHERE medium_hash = '$HASH'
"
# unclaimed should be 0 or only EXCLUDED inodes

# Create archive (IMPORTANT: explicit file list, not wildcards)
cd /data/fast/img
sudo tar -I 'zstd -T0' -cvf /data/cold/img-read/${HASH}.tar.zst \
  ${HASH}.img \
  ${HASH}.map \
  ${HASH}.map.bak \
  ${HASH}.map.stall \
  ${HASH}-ddrescue.log

# Verify archive
sudo tar -I 'zstd -d' -tvf /data/cold/img-read/${HASH}.tar.zst

# Mark complete in database
psql -d copyjob -c "
  UPDATE medium
  SET copy_done = NOW()
  WHERE medium_hash = '$HASH'
"

# Remove source files
sudo rm ${HASH}.img ${HASH}.map ${HASH}.map.bak ${HASH}.map.stall ${HASH}-ddrescue.log
```

**Verification:**
- Archive exists: `/data/cold/img-read/${HASH}.tar.zst`
- Database updated: `copy_done IS NOT NULL`
- Source files removed from /data/fast/img
- Mount point removed: `/mnt/ntt/${HASH}`

---

## Success Criteria

**For each medium processed:**

1. **Enumeration:**
   - ✅ Raw file created
   - ✅ No duplicate paths
   - ✅ Inode count reasonable (>0)

2. **Loading:**
   - ✅ Partitions created (inode_p_*, path_p_*)
   - ✅ Deduplication <10s (new safeguards working)
   - ✅ No hangs (statement timeout working)
   - ✅ FK indexes present

3. **Copying:**
   - ✅ Files archived to /data/cold/archived/{medium}/
   - ✅ Deduplication working (check by-hash reuse)
   - ✅ Diagnostic service logs visible
   - ✅ Auto-skip working for unrecoverable errors
   - ✅ No infinite retry loops

4. **Archive:**
   - ✅ Compressed archive created
   - ✅ Database marked complete
   - ✅ Source files cleaned up

**Metrics to collect:**
- Enumeration time
- Load time (especially deduplication phase)
- Copy throughput (MB/s)
- Deduplication rate (% of files already in by-hash)
- Diagnostic checkpoint triggers (if any)
- Auto-skip events (if any)

---

## Testing New Features

### Test 1: Stale Loop Cleanup

**Setup:**
Before running Phase 1 enumeration, the stale loop27 device should still exist.

**Expected:**
When `ntt-mount-helper mount` is called, it should:
1. Detect loop27 pointing to deleted bb226d2a inode
2. Log: "Cleaning up stale loop device: /dev/loop27 (deleted inode)"
3. Attempt detach
4. Create new clean mount

**Verification:**
```bash
sudo losetup -l | grep deleted
# Should return: empty (no stale loops)
```

### Test 2: Loader Safeguards

**Expected:**
- Deduplication completes in <10s (new ANALYZE working)
- Logs show: "Deduplication completed in Xs"
- No 12.5-minute hangs

**If it hangs:**
- Statement timeout (5min) should abort with error
- Indicates problem needing investigation

### Test 3: Diagnostic Service

**Expected:**
- If any files trigger I/O errors:
  - Retry tracked in-memory
  - At retry #10: diagnostic checkpoint logs
  - If BEYOND_EOF detected: auto-skip at retry #10
  - Logs show: "⏭️ SKIPPED ino=X reason=DIAGNOSTIC_SKIP:BEYOND_EOF"

**If no errors:**
- No diagnostic logs (good - clean disk)
- Proceed normally

---

## Rollback Plan

If issues occur:

**Enumeration failed:**
- Delete raw file: `rm /tmp/${HASH_SHORT}.raw`
- Unmount: `sudo bin/ntt-mount-helper unmount $HASH`
- Investigate with disk-read-checklist.md

**Loading failed:**
- Drop partitions:
  ```sql
  DROP TABLE IF EXISTS inode_p_${HASH} CASCADE;
  DROP TABLE IF EXISTS path_p_${HASH} CASCADE;
  ```
- Reset medium: `UPDATE medium SET enum_done = NULL WHERE medium_hash = '$HASH'`

**Copying failed mid-stream:**
- Inodes stay claimed (next worker will retry or skip)
- Check diagnostics: `grep DIAGNOSTIC /path/to/copier.log`
- Restart copier with same medium

**No rollback needed for:**
- Archive phase (just retry tar command)

---

## Execution Checklist

### Medium 1: c9894f1681b5b542eb3a4b75967e9aea

- [ ] Pre-flight checks
- [ ] Phase 1: Enumeration
- [ ] Phase 2: Loading
- [ ] Phase 3: Copying (first 500 inodes)
- [ ] Phase 3: Copying (complete)
- [ ] Phase 4: Archive
- [ ] Collect metrics
- [ ] Document any issues

### Medium 2: ece03c6779caa14be2b00d380add8475

- [ ] Pre-flight checks
- [ ] Phase 1: Enumeration
- [ ] Phase 2: Loading
- [ ] Phase 3: Copying (first 500 inodes)
- [ ] Phase 3: Copying (complete)
- [ ] Phase 4: Archive
- [ ] Collect metrics
- [ ] Document any issues

---

## Next Steps After Processing

1. **Review metrics** - Compare to baseline, identify bottlenecks
2. **Analyze diagnostic logs** - Did auto-skip work? Any new error patterns?
3. **Check stale loop cleanup** - Did it work automatically?
4. **Update workplan** - Adjust Priorities 2-4 based on findings
5. **Decide on mount locking** - Did we see any mount race indicators?

---

## References

- **Disk read checklist**: `docs/disk-read-checklist.md`
- **Loader safeguards**: `docs/loader-hang-investigation-2025-10-07.md`
- **Diagnostic service**: `docs/copier-diagnostic-ideas.md`
- **Mount cleanup**: `docs/mount-arch-cleanups.md`
- **Overall workplan**: `docs/workplan-2025-10-08.md`

---

**Status:** Ready for execution
**Created:** 2025-10-08
**Priority:** High (validates all recent improvements)
