<!--
Author: PB and Claude
Date: Thu 10 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/PROX-CLAUDE-CHECKLIST.md
-->

# Prox-Claude Processing Checklist

**Purpose:** Step-by-step checklist for processing each medium through NTT pipeline

**Created:** 2025-10-10 (based on first processing run learnings)
**Last Updated:** 2025-10-14

---

## CRITICAL: Use Scripts, Never Improvise

**Option A - Full Pipeline (Recommended):**
```bash
sudo bin/ntt-orchestrator --image /data/fast/img/<hash>.img
```
Orchestrator runs everything: mount → enum → load → copy → archive → unmount

**Option B - Manual Control (Individual Scripts):**
Follow the phases below, using the scripts exactly as shown.

**PROHIBITED:**
- ❌ **Manual tar/zstd commands** → Use `ntt-archiver`
- ❌ **Ad-hoc SQL for archiving** → Use scripts
- ❌ **Improvised pipelines** → Use tested tools
- ❌ **Skipping safety checks** → Scripts verify everything

**Trust Issue:** Improvising instead of using scripts breaks automation trust.

---

## Pre-Flight Checks

Before starting any medium:

- [ ] **Query DB for candidates:**
  ```sql
  SELECT medium_hash, medium_human
  FROM medium
  WHERE enum_done IS NULL AND copy_done IS NULL AND problems IS NULL
  ORDER BY medium_human;
  ```

- [ ] **Verify selected medium:**
  - [ ] IMG file exists: `ls -lh /data/fast/img/${HASH}.img`
  - [ ] No ddrescue running: `ps aux | grep ddrescue | grep $HASH`
  - [ ] Database clean: `enum_done=NULL`, `copy_done=NULL`, `problems=NULL`

- [ ] **CRITICAL: Verify IMG files need processing (check archives):**
  ```bash
  # List IMG files and check if archives exist
  cd /data/fast/img
  for img in *.img; do
    hash="${img%.img}"
    short="${hash:0:8}"
    archive="/data/cold/img-read/${hash}.tar.zst"
    if [ -f "$archive" ]; then
      echo "$short ARCHIVED (can remove IMG)"
    else
      echo "$short NEEDS_PROCESSING"
    fi
  done
  ```
  - [ ] Remove IMG files that are already archived (safe to delete)
  - [ ] Only process IMG files that show "NEEDS_PROCESSING"
  - [ ] Cross-check: `ls /data/cold/img-read/*.tar.zst | wc -l` vs IMG files

- [ ] **Update processing-queue.md:**
  - [ ] Add to "Currently Processing" section
  - [ ] Include: hash (short), phase, timestamp, worker, notes

---

## CRITICAL: Script Failure Protocol

**When any NTT script fails:**

- [ ] **STOP immediately** - Do not improvise manual commands
- [ ] **File bug report FIRST** in `bugs/BUG-NNN-<type>-<hash>.md` using `bugs/TEMPLATE.md`
- [ ] **Document in bug report:**
  - Exact command that failed (copy full command line)
  - Complete error output (stderr and stdout)
  - Observable evidence (filesystem state, database queries, system logs)
  - Specific, testable success conditions for verification
  - Context: what phase, what was expected vs observed
- [ ] **Only after bug is filed:** Attempt manual workaround (if urgent and safe)
- [ ] **Document workaround** in bug "Impact" section

**Why this protocol matters:**
- Manual improvisation bypasses safety checks and logging
- Undocumented workarounds create hidden technical debt
- dev-claude needs complete bug reports to identify root causes
- Future automation depends on reliable, self-healing scripts
- Pattern analysis (by metrics-claude) requires filed bugs

**Example workflow:**
```
ntt-mount-helper fails
  ↓
File bugs/BUG-008-mount-helper-*.md with full evidence
  ↓
Try manual mount as workaround (document in bug)
  ↓
Continue processing
  ↓
dev-claude fixes root cause
  ↓
prox-claude verifies fix
```

**Critical rule:** No manual commands until bug is filed. If you find yourself typing `mount`, `losetup`, `tar`, or any improvised command, STOP and file the bug first.

---

## CRITICAL: Before Declaring Data Loss

**When seeing "No such file or directory" errors:**

- [ ] **Verify at least ONE file actually missing** - Check filesystem directly, try alternate paths (base path, `/p1/`, etc.)
- [ ] **If enumeration succeeded, data exists somewhere** - Find WHERE, not accept it's lost. Tool misconfiguration is more likely than mass corruption.
- [ ] **Review recent mount/path changes** - Path mismatches from mount point changes cause `ENOENT` without actual data loss
- [ ] **Test before generalizing** - One verified missing file before declaring thousands corrupt

**See:** `docs/lessons/diagnosing-file-not-found-43fda374-2025-10-11.md` for full diagnostic procedure.

---

## Phase 1: Enumeration

**Goal:** Extract inode metadata from mounted filesystem

- [ ] **Mount if needed:**
  ```bash
  sudo bin/ntt-mount-helper mount $HASH /data/fast/img/${HASH}.img
  ```

- [ ] **Run enumeration:**
  ```bash
  sudo bin/ntt-enum /mnt/ntt/$HASH $HASH /tmp/${HASH_SHORT}.raw
  ```

- [ ] **Monitor enumeration rate (HFS+ catalog corruption detection):**
  - [ ] Wait 1-2 minutes after enum starts
  - [ ] If HFS+ filesystem AND enumeration rate < 1000 files/s:
    ```bash
    # Stop enumeration (Ctrl+C)
    # Run fsck to repair catalog corruption
    sudo fsck.hfsplus -r /data/fast/img/${HASH}.img
    # Remount
    sudo bin/ntt-mount-helper unmount $HASH
    sudo bin/ntt-mount-helper mount $HASH /data/fast/img/${HASH}.img
    # Restart enumeration
    sudo bin/ntt-enum /mnt/ntt/$HASH $HASH /tmp/${HASH_SHORT}.raw
    ```
  - [ ] See: `docs/lessons/hfs-catalog-corruption-fsck-recovery-8e61cad2-2025-10-12.md`

- [ ] **Verify output:**
  - [ ] Raw file created: `/tmp/${HASH_SHORT}.raw`
  - [ ] Record count matches log: `tr '\034' '\n' < /tmp/${HASH_SHORT}.raw | wc -l`

- [ ] **Success:** Enumeration log shows completion

---

## Phase 2: Loading

**Goal:** Import enumeration data into PostgreSQL

- [ ] **Run loader:**
  ```bash
  time sudo bin/ntt-loader /tmp/${HASH_SHORT}.raw $HASH
  ```

- [ ] **Verify:**
  - [ ] Partitions created: `inode_p_${HASH_SHORT}`, `path_p_${HASH_SHORT}`
  - [ ] Deduplication completed in <10s (check log)
  - [ ] Record counts match:
    ```sql
    SELECT
      (SELECT COUNT(*) FROM inode WHERE medium_hash = '$HASH') as inodes,
      (SELECT COUNT(*) FROM path WHERE medium_hash = '$HASH') as paths;
    ```
  - [ ] **Check enum_done timestamp (BUG-016 fix verification):**
    ```sql
    SELECT enum_done FROM medium WHERE medium_hash = '$HASH';
    ```
    - Should be NOT NULL if using ntt-orchestrator (auto-set as of 2025-10-14)
    - If NULL and using individual scripts, set manually

- [ ] **Success:** Loader log shows "Loading complete"

---

## Phase 3: Copying

**Goal:** Deduplicate and archive files

**CRITICAL: Always use ntt-copy-workers (NOT ntt-copier.py directly)**

- [ ] **Run copy workers with --wait flag:**
  ```bash
  # For small/medium batches (<10K files) - 4 workers:
  sudo bin/ntt-copy-workers --medium-hash $HASH --workers 4 --wait

  # For large batches (≥10K files) - 16 workers:
  sudo bin/ntt-copy-workers --medium-hash $HASH --workers 16 --wait
  ```

- [ ] **What --wait does:**
  - Blocks until all workers complete
  - Shows progress every 30s ("N files remaining")
  - Returns when copying is done
  - Handles tmpfs mount/unmount automatically
  - Cleans up on ^C interrupt

- [ ] **Monitor during execution:**
  - [ ] Progress updates show decreasing file count
  - [ ] Workers complete without errors
  - [ ] DiagnosticService auto-skips appear if needed (check worker logs in /tmp/ntt-worker-*.log)

- [ ] **Verify completion:**
  ```sql
  SELECT
    COUNT(*) FILTER (WHERE copied = true) as copied,
    COUNT(*) FILTER (WHERE copied = false AND claimed_by IS NULL) as unclaimed
  FROM inode WHERE medium_hash = '$HASH';
  ```
  - [ ] `unclaimed = 0` (all files processed)

- [ ] **Check for problems:**
  ```sql
  SELECT jsonb_pretty(problems) FROM medium WHERE medium_hash = '$HASH';
  ```

- [ ] **Check copy_done timestamp (BUG-016 fix verification):**
  ```sql
  SELECT copy_done FROM medium WHERE medium_hash = '$HASH';
  ```
  - Should be NOT NULL if using ntt-orchestrator (auto-set as of 2025-10-14)
  - If NULL and using individual scripts, set manually

- [ ] **Success:** ntt-copy-workers reports "All workers completed", unclaimed = 0

**Why use ntt-copy-workers:**
- Parallel processing (4-16x faster than single copier)
- Automatic tmpfs management per worker
- Signal handling and cleanup
- Progress monitoring
- --wait flag ensures completion before continuing

---

## Phase 4: Archiving

**Goal:** Archive IMG files and mark complete

**CRITICAL: Use ntt-archiver script, NOT manual tar commands**

- [ ] **Run archiver:**
  ```bash
  sudo bin/ntt-archiver $HASH
  ```

**What ntt-archiver does automatically:**
- ✅ Verifies all inodes `copied=true` (safety check, fails if incomplete)
- ✅ Creates compressed archive: `/data/cold/img-read/${HASH}.tar.zst`
- ✅ Verifies archive integrity (non-zero size, exists)
- ✅ Removes source IMG files from `/data/fast/img/`
- ✅ Logs to `/var/log/ntt/archiver.jsonl` for audit trail
- ✅ Sets proper file ownership and permissions

- [ ] **Verify archiver succeeded:**
  ```bash
  ls -lh /data/cold/img-read/${HASH}.tar.zst
  # Should exist with size > 0

  ls /data/fast/img/${HASH}.*
  # Should show "No such file or directory" (source files removed)
  ```

- [ ] **Verify archived files exist in by-hash storage:**
  ```bash
  sudo bin/ntt-verify-archived-media $HASH
  ```
  - [ ] Samples random blobids from database
  - [ ] Verifies physical files exist in `/data/cold/by-hash/`
  - [ ] Reports verification percentage and any missing files

- [ ] **Update database timestamps:**
  ```sql
  -- ntt-archiver doesn't set enum_done, set it manually if needed
  UPDATE medium
  SET enum_done = COALESCE(enum_done, NOW() - interval '10 minutes')
  WHERE medium_hash = '$HASH' AND enum_done IS NULL;
  ```

- [ ] **Unmount:**
  ```bash
  sudo bin/ntt-mount-helper unmount $HASH
  ```

- [ ] **Success:** Archive exists, source files removed, verification passed, ready for metrics

**Why use ntt-archiver:**
- Prevents archiving incomplete media (copy verification)
- Ensures audit trail (archiver.jsonl)
- Handles edge cases (missing files, partial sets)
- Atomic operation (archive + cleanup together)

---

## Post-Processing

- [ ] **Update processing-queue.md:**
  - [ ] Move from "Currently Processing" to "Completed Today"
  - [ ] Include: completion time, duration, issues, size, notes

- [ ] **Verify final state:**
  ```sql
  SELECT medium_hash, enum_done, copy_done, problems IS NOT NULL as has_problems
  FROM medium WHERE medium_hash = '$HASH';
  ```
  - [ ] `enum_done IS NOT NULL`
  - [ ] `copy_done IS NOT NULL`

---

## Audit Tools (Batch Operations)

### Check CD/DVD Completion Status

**When:** Periodically check all optical media for completion

```bash
# Check completion status for all CD/DVD media
sudo bin/audit-cdrom-completion.sh

# Generate detailed report
sudo bin/audit-cdrom-report.sh
```

**Reports:**
- Media with incomplete processing (enum_done or copy_done NULL)
- Media with inode tables but missing timestamps
- Archive verification status
- Recommendations for remediation

### Remediate Incomplete Media

**When:** After audit shows media with orphaned data or missing timestamps

```bash
# Fix media with missing timestamps but complete data
sudo bin/remediate-incomplete-media.sh
```

**What it does:**
- Identifies media with inode tables but NULL timestamps
- Verifies files are actually copied (checks `copied=true`, blobid assigned)
- Backfills `enum_done` and `copy_done` timestamps
- Reports media that need manual intervention

**See:** `bugs/BUG-016-orchestrator-missing-timestamp-updates.md` for context

### External Backup

**When:** Periodically backup database and deduplicated blobs

```bash
# Full backup (database + blobs)
sudo bin/ntt-backup

# Skip database dump (faster, for testing)
sudo bin/ntt-backup --skip-pgdump

# With wrapper (recommended, handles mount validation)
sudo bin/ntt-backup-wrapper.sh
```

**Status:** Phase 5 in progress (~152K files backed up as of 2025-10-14)

**See:** `docs/external-backup-plan.md` for full details

---

## Troubleshooting

### Incomplete Previous Processing

If you find a medium that's 99% done (files in by-hash, but DB timestamps NULL):

1. **Check what's actually done:**
   - [ ] Files in by-hash: Sample from `path` table with `blobid IS NOT NULL`
   - [ ] Hardlinks exist: `sudo du -sh /data/cold/archived/mnt/ntt/$HASH`
   - [ ] IMG archived: `ls -lh /data/cold/img-read/${HASH}.tar.zst`
   - [ ] Source files removed: `ls /data/fast/img/${HASH}.*`

2. **Complete missing steps:**
   - [ ] If hardlinks missing: Run hardlink recreation script
   - [ ] If IMG not archived: Run archiving phase
   - [ ] If source files remain: Clean up after verifying archive

3. **Set database timestamps:**
   ```sql
   UPDATE medium
   SET
     enum_done = '<timestamp>',  -- Use archive timestamp - 10min
     copy_done = '<timestamp>'   -- Use IMG archive timestamp
   WHERE medium_hash = '$HASH';
   ```

---

## Common Issues

### Missing Hardlinks

**Symptom:** `du -sh /data/cold/archived/mnt/ntt/$HASH` shows only 2K

**Cause:** Copier created directories but not hardlinks

**Fix:** Run hardlink recreation script (see `fix-579d3c3a-hardlinks.py` as example)

### DiagnosticService Not Triggering

**Symptom:** Infinite retry loop on errors

**Expected:** "DIAGNOSTIC CHECKPOINT" at retry #10, auto-skip for BEYOND_EOF

**Action:** File bug with example inode and error

### Loader Timeout

**Symptom:** Loader hangs >5min

**Expected:** Deduplication <10s for most media

**Action:** File bug with medium size and timing

---

---

## Recent Fixes and Lessons (2025-10-11 to 2025-10-14)

### BUG-016: Missing Timestamp Updates (FIXED 2025-10-14)
- **Issue:** ntt-orchestrator never set `enum_done` or `copy_done` timestamps
- **Fix:** Orchestrator now sets timestamps automatically after stages complete
- **Impact:** 74 media had NULL timestamps despite being fully processed
- **Verification:** Check new media have both timestamps set after processing

### BUG-018: Copier Infinite Retry Loop (FIXED 2025-10-13)
- **Issue:** Copier retried indefinitely when result was None (not dict)
- **Fix:** Added explicit None checks and safety nets in result processing
- **Impact:** f43ecd69 floppy stuck for 7+ hours with 188K+ retries per file
- **Lesson:** Always populate results_by_inode dict, handle None explicitly

### Lesson: File-Not-Found != Data Loss
- **Situation:** Copier reported "No such file or directory" for 1,161 files on 43fda374
- **Root cause:** Enumeration used `/p1/` base path, copier tried `/` (mount point changed)
- **Resolution:** All files found at original path, zero actual data loss
- **Lesson:** Verify ONE file missing before declaring thousands corrupt
- **See:** `docs/lessons/diagnosing-file-not-found-43fda374-2025-10-11.md`

### Lesson: HFS+ Catalog Corruption
- **Symptom:** Enumeration extremely slow (<100 files/s) on HFS+ media
- **Cause:** Catalog B-tree corruption from improper unmount
- **Fix:** Run `sudo fsck.hfsplus -r` on image file before mounting
- **Result:** Enumeration rate improved from 50 files/s to normal speed
- **See:** `docs/lessons/hfs-catalog-corruption-fsck-recovery-8e61cad2-2025-10-12.md`

---

**References:**
- Processing plan: `media-processing-plan-2025-10-10.md`
- Roles: `ROLES.md`
- Bug template: `bugs/TEMPLATE.md`
- Metrics queries: `metrics/QUERIES.md`
- Diagnostic procedures: `docs/disk-read-checklist.md`
- Lessons learned: `docs/lessons/`
