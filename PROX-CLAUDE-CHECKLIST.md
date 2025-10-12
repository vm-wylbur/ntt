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

- [ ] **Success:** Archive exists, source files removed, ready for metrics

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

**References:**
- Processing plan: `media-processing-plan-2025-10-10.md`
- Roles: `ROLES.md`
- Bug template: `bugs/TEMPLATE.md`
- Metrics queries: `metrics/QUERIES.md`
