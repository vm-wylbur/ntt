<!--
Author: PB and Claude
Date: Sat 12 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/bugs/BUG-015-orchestrator-false-success-reporting.md
-->

# BUG-015: Orchestrator reports stage success before completion

**Filed:** 2025-10-12 12:20
**Filed by:** prox-claude
**Status:** open
**Severity:** CRITICAL
**Affected media:** da69350a5b27adf013e02994611cebc3 (CEH report CD-ROM), potentially all media processed through orchestrator
**Phase:** load/copy pipeline stages

---

## Observed Behavior

Orchestrator logs "load_success" and "copy_success" at the exact same timestamp as stage start, but loader/copier never actually complete. Pipeline proceeds to archive stage, creating tar.zst archive successfully, while database remains in pre-load state.

**Timeline for da69350a5b27adf013e02994611cebc3:**
```
2025-10-10 15:41:03 - Enum completes (1,161 records)
2025-10-10 15:41:03 - load_start
2025-10-10 15:41:03 - load_success ← SAME TIMESTAMP (impossible)
2025-10-10 15:41:03 - copy_start
2025-10-10 15:41:05 - copy_success ← 2 seconds for entire copy (suspicious)
2025-10-10 15:41:05 - archive_start
2025-10-10 15:41:06 - archive_done ← Archive succeeds
```

**Database state (current):**
```sql
SELECT enum_done, copy_done FROM medium WHERE medium_hash = 'da69350a...';
enum_done | copy_done
----------|----------
NULL      | NULL
```

**Inode table state:**
```sql
\dt inode_da69350a*
-- No inode table exists
```

**Loader logs (incomplete execution):**
```json
{"stage":"load_start","ts":"2025-10-10T15:41:03-07:00"}
{"stage":"exclusions","excluded":"0","ts":"2025-10-10T15:41:03-07:00"}
{"stage":"dedupe_start","ts":"2025-10-10T15:41:03-07:00"}
{"stage":"dedupe_complete","duration_sec":0,"ts":"2025-10-10T15:41:03-07:00"}
{"stage":"excluded_inodes","count":"0","ts":"2025-10-10T15:41:03-07:00"}
{"stage":"non_file_inodes","count":"105","ts":"2025-10-10T15:41:03-07:00"}
// LOGS END HERE - no load_success, no error
```

**Expected behavior:** 1,056 file inodes should have been loaded (1,161 total - 105 directories)

**Actual behavior:** Loader started, processed metadata, then stopped. No inode table created. No files loaded. No error logged.

---

## Root Cause Analysis

**Issue:** Orchestrator does not wait for subprocess completion before logging success.

**Evidence of race condition:**

1. **Load stage completes in 0 seconds:**
   ```
   15:41:03 - load_start
   15:41:03 - load_success  ← Impossible for 1,056 records
   ```

2. **Copy stage completes in 2 seconds for entire CD-ROM:**
   ```
   15:41:03 - copy_start
   15:41:05 - copy_success  ← 1,056 files in 2 seconds = 528 files/sec (unrealistic)
   ```

3. **Loader logs show incomplete execution:**
   - Last log entry: "non_file_inodes" (metadata phase)
   - Never reaches actual file loading
   - No error, no success log

4. **Database confirms no work completed:**
   - `enum_done = NULL` (should be timestamp)
   - `copy_done = NULL` (should be timestamp)
   - No inode partition table created

**Hypothesis:** Orchestrator launches loader/copier processes but does not wait for their completion. It logs success immediately after spawning the subprocess, not after subprocess exits.

**Likely code location (bin/ntt-orchestrator):**
```bash
# Suspected pattern:
ntt-loader "$RAW_FILE" "$MEDIUM_HASH" &
log_event "load_success"  # ← Should wait for PID to complete first

# Should be:
ntt-loader "$RAW_FILE" "$MEDIUM_HASH"
wait $!  # Wait for subprocess
log_event "load_success"
```

---

## Impact

**Severity:** CRITICAL - Silent data loss / incomplete processing

**Data integrity:**
- Archive contains raw enumeration data ✓
- Archive contains disk image ✓
- **Database missing all file metadata** ✗
- **by-hash storage missing all file copies** ✗
- **Cannot query, verify, or access file contents** ✗

**Operational:**
- Pipeline reports success but work incomplete
- No error alerts generated
- Requires manual audit to detect
- Unknown how many media affected

**Current known affected media:**
- `da69350a5b27adf013e02994611cebc3` - CEH report CD-ROM (confirmed)
- Potentially all CD-ROM media (need to audit)
- Unknown if hard drives also affected

**Business impact:**
- Loss of deduplication (files not in by-hash storage)
- Loss of queryability (files not in database)
- False confidence in archived data completeness
- May require re-processing all media

---

## Reproduction Steps

1. **Insert CD-ROM media**
2. **Run orchestrator:**
   ```bash
   sudo bin/ntt-orchestrator --message "test CD" /dev/sr0
   ```
3. **Wait for completion**
4. **Check database:**
   ```sql
   SELECT medium_hash, enum_done, copy_done
   FROM medium
   WHERE medium_hash = '<hash>';
   ```
5. **Expected:** Both timestamps populated
6. **Actual:** Both NULL despite orchestrator reporting success

---

## Diagnostic Queries

**Find all media with this issue:**
```sql
-- Media that were archived but never loaded/copied
SELECT
    m.medium_hash,
    m.medium_human,
    m.message,
    m.enum_done,
    m.copy_done
FROM medium m
WHERE m.enum_done IS NULL
  AND m.copy_done IS NULL
  AND EXISTS (
      -- Archive exists in cold storage
      SELECT 1 FROM ...
  );
```

**Check if raw file exists but no inode table:**
```bash
# For each suspicious medium:
HASH="da69350a5b27adf013e02994611cebc3"

# Check raw file
ls -lh /data/fast/raw/${HASH}.raw

# Check inode table
sudo -u postgres psql copyjob -c "\dt inode_*${HASH:0:8}*"

# Count records in raw vs DB
tr '\0' '\n' < /data/fast/raw/${HASH}.raw | wc -l
# Should match row count in inode table (doesn't exist = 0)
```

---

## Expected Behavior

**Correct orchestrator flow:**

1. **Spawn subprocess AND wait:**
   ```bash
   log_event "load_start"
   bin/ntt-loader "$RAW_FILE" "$MEDIUM_HASH"
   LOADER_EXIT=$?

   if [[ $LOADER_EXIT -eq 0 ]]; then
       log_event "load_success"
   else
       log_event "load_error" "exit_code=$LOADER_EXIT"
       exit 1  # Stop pipeline
   fi
   ```

2. **Verify database state before proceeding:**
   ```bash
   # After loader claims success, verify:
   DB_CHECK=$(psql -c "SELECT enum_done FROM medium WHERE medium_hash='$HASH'")

   if [[ -z "$DB_CHECK" ]]; then
       log_event "load_verification_failed"
       exit 1
   fi
   ```

3. **Log actual timings:**
   ```bash
   START=$(date +%s)
   bin/ntt-loader ...
   END=$(date +%s)
   DURATION=$((END - START))

   log_event "load_success" "duration_sec=$DURATION"
   # 0 second duration = red flag
   ```

---

## Recommended Fix

**Priority 1: Add process synchronization**

**File:** `bin/ntt-orchestrator`
**Location:** Load and copy stage handlers

**Changes needed:**

1. **Remove background execution if present:**
   ```bash
   # WRONG:
   bin/ntt-loader "$RAW" "$HASH" &

   # CORRECT:
   bin/ntt-loader "$RAW" "$HASH"
   # Blocks until complete
   ```

2. **Check exit codes:**
   ```bash
   bin/ntt-loader "$RAW" "$HASH"
   if [[ $? -ne 0 ]]; then
       log_error "Loader failed"
       exit 1
   fi
   ```

3. **Add verification checks:**
   ```bash
   # After load stage
   verify_inode_table_exists "$HASH" || {
       log_error "Load claimed success but no inode table"
       exit 1
   }

   # After copy stage
   verify_copy_done_timestamp "$HASH" || {
       log_error "Copy claimed success but copy_done still NULL"
       exit 1
   }
   ```

**Priority 2: Add pipeline state validation**

Create `bin/ntt-validate-pipeline-state` to audit media:
```bash
#!/usr/bin/env bash
# Check for media with inconsistent state

# Find media archived but not loaded
psql copyjob -c "
    SELECT medium_hash, medium_human
    FROM medium
    WHERE enum_done IS NULL
      AND image_path IS NOT NULL
"
```

---

## Workaround

**For da69350a specifically:**

Since raw enumeration file exists and is complete:

1. **Manually run loader:**
   ```bash
   sudo bin/ntt-loader \
       /data/fast/raw/da69350a5b27adf013e02994611cebc3.raw \
       da69350a5b27adf013e02994611cebc3
   ```

2. **Verify inode table created:**
   ```sql
   SELECT COUNT(*) FROM inode_p_da69350a;
   -- Should show 1,056 files
   ```

3. **Manually run copier:**
   ```bash
   sudo bin/ntt-copier.py \
       --medium-hash da69350a5b27adf013e02994611cebc3 \
       --workers 4
   ```

4. **Verify completion:**
   ```sql
   SELECT enum_done, copy_done
   FROM medium
   WHERE medium_hash = 'da69350a5b27adf013e02994611cebc3';
   -- Both should have timestamps
   ```

**For other affected media:**
- Audit all CD-ROM sized archives (<1GB)
- Re-run load/copy for any with NULL timestamps
- Document which media required reprocessing

---

## Testing Requirements

**Test cases after fix:**

1. **Basic CD-ROM processing:**
   ```bash
   # Insert test CD, run orchestrator
   sudo bin/ntt-orchestrator /dev/sr0

   # Verify all stages complete:
   # - Raw file has records
   # - Inode table exists with matching count
   # - enum_done timestamp set
   # - Files copied to by-hash
   # - copy_done timestamp set
   # - Archive created
   ```

2. **Error handling:**
   ```bash
   # Simulate loader failure
   # Orchestrator should:
   # - Log error event
   # - Stop pipeline (not proceed to copy)
   # - NOT create archive
   # - Set health status appropriately
   ```

3. **Timing validation:**
   ```bash
   # Process 1000+ file CD-ROM
   # Verify logged durations are realistic:
   # - load_duration > 0 seconds
   # - copy_duration matches file count (not instant)
   ```

4. **Concurrent processing:**
   ```bash
   # Run 2 orchestrators simultaneously
   # Ensure both complete correctly
   # No race conditions in logging/DB updates
   ```

---

## Success Criteria

**Fix is successful when:**

- [ ] Orchestrator waits for subprocess completion before logging success
- [ ] Exit codes properly checked and errors halt pipeline
- [ ] Load stage creates inode table with all files before reporting success
- [ ] Copy stage sets copy_done timestamp before reporting success
- [ ] Archive stage only runs after load/copy verifiably complete
- [ ] Logged durations reflect actual work (not 0 seconds)
- [ ] Test CD-ROM processes end-to-end with all data in DB
- [ ] Re-processing da69350a completes successfully
- [ ] Audit of existing media identifies all affected archives

---

## Related Issues

**Similar subprocess handling:**
- Review enum stage - does it have same issue?
- Review archive stage - appears to work correctly
- Review imaging stage - appears to wait correctly

**Architectural:**
- Need subprocess lifecycle management best practices
- Consider using `set -e` and `set -o pipefail` in orchestrator
- Add pipeline state machine validation

---

## Files Requiring Modification

**Primary: bin/ntt-orchestrator**
- Load stage handler (around line 300-400)
- Copy stage handler (around line 400-500)
- Add subprocess wait and exit code checking
- Add state verification before stage transition

**Secondary: Create validation tool**
- `bin/ntt-validate-pipeline-state` - audit media for inconsistencies

**Documentation:**
- Document expected subprocess exit codes
- Document stage verification requirements

---

## Audit Plan

**Find all affected media:**

1. **Query database for incomplete media:**
   ```sql
   SELECT
       medium_hash,
       medium_human,
       message,
       image_path,
       enum_done,
       copy_done
   FROM medium
   WHERE image_path IS NOT NULL  -- Has been imaged
     AND (enum_done IS NULL OR copy_done IS NULL)
   ORDER BY added_at;
   ```

2. **Check for orphaned raw files:**
   ```bash
   # Raw files without corresponding inode tables
   for raw in /data/fast/raw/*.raw; do
       hash=$(basename "$raw" .raw)
       if ! sudo -u postgres psql copyjob -c "\dt inode_*${hash:0:8}*" | grep -q inode; then
           echo "MISSING: $hash"
       fi
   done
   ```

3. **Check archives in cold storage:**
   ```bash
   # List all CD-ROM sized archives
   find /data/cold/img-read -name "*.tar.zst" -size -1G -ls | sort

   # For each, verify database has complete data
   ```

**Remediation for affected media:**
1. Manually run loader for each medium
2. Manually run copier for each medium
3. Verify completion in database
4. Document which media were affected
5. Consider re-imaging if raw files missing

---

## Dev Notes

**Analysis by:** prox-claude
**Date:** 2025-10-12 12:20

This is a critical silent failure mode. The orchestrator creates archives that appear complete but are missing the database indexing and by-hash deduplication. The data is preserved in the archive (can be recovered) but is not accessible through the normal query/retrieval mechanisms.

The bug was discovered while investigating why da69350a archive existed in cold storage but the current orchestrator run failed with "archive_exists". Database query revealed enum_done and copy_done were NULL despite the archive being 2 days old.

**Priority:** CRITICAL - Fix immediately before processing more media. Audit all existing media to identify affected archives. Establish testing protocol to catch similar issues.

**Immediate actions:**
1. Stop all orchestrator runs until fix deployed
2. Audit existing archives for completeness
3. Create list of media requiring reprocessing
4. Fix orchestrator subprocess handling
5. Test fix thoroughly with multiple media types
6. Resume processing with monitoring

**Root cause:** Likely missing `wait` statement or backgrounding subprocess without waiting. Need to review orchestrator bash script for all subprocess invocations.
