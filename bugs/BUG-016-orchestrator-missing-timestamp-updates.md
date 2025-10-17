<!--
Author: PB and Claude
Date: Sat 12 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/bugs/BUG-016-orchestrator-missing-timestamp-updates.md
-->

# BUG-016: Orchestrator never sets enum_done/copy_done timestamps

**Filed:** 2025-10-12 13:40
**Filed by:** prox-claude
**Status:** FIXED (commit f9b6057, 2025-10-14)
**Severity:** MEDIUM (bookkeeping failure, not data loss)
**Affected media:** All media processed through orchestrator (74+ media)
**Phase:** Pipeline completion tracking

## Fix Summary

**Fixed in:** commit f9b6057 "Add pipeline timestamps, CD/DVD auto-eject, and diagnostic improvements"
**Date:** 2025-10-14
**Changes:** bin/ntt-orchestrator now sets `enum_done` after load stage completes and `copy_done` after copy stage completes

---

## Observed Behavior

Orchestrator stage functions (stage_enum, stage_load, stage_copy) complete successfully and process all files, but never update the medium table's enum_done and copy_done timestamps. This makes media appear "incomplete" in database queries despite being fully processed.

**Database state for "incomplete" media:**
```sql
-- 74 media show as incomplete
SELECT COUNT(*) FROM medium
WHERE image_path IS NOT NULL
  AND (enum_done IS NULL OR copy_done IS NULL);
-- Returns: 74

-- But their inode tables exist with data:
SELECT COUNT(*) FROM inode_p_da69350a;
-- Returns: 1,161 records (not 0!)

-- And files are copied:
SELECT COUNT(*) FROM inode_p_da69350a WHERE copied = true;
-- Returns: 1,161 (100% copied!)
```

**Example medium: da69350a5b27adf013e02994611cebc3**
- enum_done: NULL
- copy_done: NULL
- Inode table: EXISTS (inode_p_da69350a, 1,161 records)
- Files copied: YES (all have copied=true, blobid assigned)
- Archive: EXISTS (/data/cold/img-read/da69350a*.tar.zst, 104MB)
- **Processing actually succeeded, timestamps just not set**

---

## Root Cause Analysis

**Issue:** Orchestrator stage functions do not update medium table timestamps

**Code review of bin/ntt-orchestrator:**

```bash
# Line 786-821: stage_load() function
stage_load() {
  local medium_hash="$1"

  # ... checks and setup ...

  # Runs loader synchronously (waits for completion)
  if "$NTT_BIN/ntt-loader" "$raw_file" "$medium_hash"; then
    local inode_count=$(psql_as_user "$DB_URL" -tAc "SELECT COUNT(*) FROM inode WHERE medium_hash = '$medium_hash'")
    log load_success "{\"medium_hash\": \"$medium_hash\", \"inode_count\": $inode_count}"
    echo "$inode_count"  # Return inode count
    return 0
  else
    log load_error "{\"medium_hash\": \"$medium_hash\", \"error\": \"loader_failed\"}"
    return 2
  fi
}
# ❌ MISSING: UPDATE medium SET enum_done = NOW() WHERE medium_hash = '$medium_hash'
```

```bash
# Line 823-964: stage_copy() function
stage_copy() {
  local medium_hash="$1"
  local inode_count="${2:-0}"

  # ... smart scheduling logic ...

  if "$NTT_BIN/ntt-copier.py" --medium-hash "$medium_hash"; then
    log copy_success "{\"medium_hash\": \"$medium_hash\"}"
    echo "[...] Copy stage: SUCCESS" >&2
    # ... archive stage ...
    return 0
  else
    log copy_error "{\"medium_hash\": \"$medium_hash\"}"
    return 2
  fi
}
# ❌ MISSING: UPDATE medium SET copy_done = NOW() WHERE medium_hash = '$medium_hash'
```

**What actually happens:**
1. stage_load() calls ntt-loader (blocks until complete)
2. ntt-loader successfully loads all files to inode partition table
3. stage_load() logs "load_success" to JSON log
4. **BUT:** stage_load() never sets enum_done timestamp
5. stage_copy() calls ntt-copier.py (blocks until complete)
6. ntt-copier.py successfully copies all files, sets copied=true
7. stage_copy() logs "copy_success" to JSON log
8. **BUT:** stage_copy() never sets copy_done timestamp

**Evidence this is NOT a subprocess backgrounding issue:**
- Code review shows synchronous calls: `if "$NTT_BIN/ntt-loader" ...` (waits for exit)
- Inode tables exist with complete data (proves loader ran to completion)
- All files show copied=true (proves copier ran to completion)
- Archives created successfully (proves entire pipeline completed)
- No background operators (`&`) in stage function calls

---

## Impact

**Severity:** MEDIUM - Tracking failure, not processing failure

**Data integrity:** ✅ **NO DATA LOSS**
- Files enumerated: ✅ YES
- Files loaded to database: ✅ YES
- Files copied to by-hash storage: ✅ YES
- Archives created: ✅ YES
- **Only problem:** Completion timestamps not set

**Operational impact:**
- Pipeline monitoring shows 74 "incomplete" media (false negative)
- Hard to distinguish truly incomplete from timestamp-missing media
- Cleanup scripts may skip media with NULL timestamps
- Manual SQL needed to verify actual completion status
- Affects 74+ media (25 complete, 74 missing timestamps)

**Current workaround:**
- Check for inode table existence: `\dt inode_p_{hash:0:8}*`
- Check copied count: `SELECT COUNT(*) WHERE copied=true`
- Verify physical archive: `ls /data/cold/img-read/{hash}.tar.zst`

---

## Evidence Summary

**Pattern A: enum_done=NULL, copy_done=NULL (42 media)**
- Archive: EXISTS
- Raw file: EXISTS
- Inode table: EXISTS with data
- Files copied: YES (copied=true, blobid assigned)
- Example: da69350a (1,161 files, all copied)

**Pattern B: enum_done=NULL, copy_done=SET (32 media)**
- Archive: EXISTS
- Raw file: CLEANED UP (normal after archive)
- Inode table: EXISTS with data
- Files copied: YES (copied=true, blobid assigned)
- copy_done timestamp: MANUALLY SET (batch update 2025-10-10 22:02:55)
- Example: c84c8780 (6,236 files, all copied)

**Only 25 media have both timestamps set correctly**

---

## Expected Behavior

**Correct stage_load() implementation:**
```bash
stage_load() {
  local medium_hash="$1"
  local raw_file="$RAW_ROOT/${medium_hash}.raw"

  # Run loader synchronously
  if "$NTT_BIN/ntt-loader" "$raw_file" "$medium_hash"; then
    local inode_count=$(psql_as_user "$DB_URL" -tAc "SELECT COUNT(*) FROM inode WHERE medium_hash = '$medium_hash'")
    log load_success "{\"medium_hash\": \"$medium_hash\", \"inode_count\": $inode_count}"

    # ✅ ADD THIS: Update completion timestamp
    psql_as_user "$DB_URL" -c "
      UPDATE medium
      SET enum_done = NOW()
      WHERE medium_hash = '$medium_hash';" 2>/dev/null || true

    echo "$inode_count"
    return 0
  else
    log load_error "{\"medium_hash\": \"$medium_hash\", \"error\": \"loader_failed\"}"
    return 2
  fi
}
```

**Correct stage_copy() implementation:**
```bash
stage_copy() {
  local medium_hash="$1"
  local inode_count="${2:-0}"

  # ... copy logic ...

  if "$NTT_BIN/ntt-copier.py" --medium-hash "$medium_hash"; then
    log copy_success "{\"medium_hash\": \"$medium_hash\"}"

    # ✅ ADD THIS: Update completion timestamp
    psql_as_user "$DB_URL" -c "
      UPDATE medium
      SET copy_done = NOW()
      WHERE medium_hash = '$medium_hash';" 2>/dev/null || true

    # Continue to archive stage...
    return 0
  else
    log copy_error "{\"medium_hash\": \"$medium_hash\"}"
    return 2
  fi
}
```

---

## Recommended Fix

**Priority 1: Add timestamp updates to stage functions**

**File:** `bin/ntt-orchestrator`
**Locations:**
- stage_load(): Line ~810-820 (after successful load)
- stage_copy(): Line ~843-890 (after successful copy)

**Changes:**

1. **In stage_load() function:**
```bash
# After line 813: log load_success
# ADD:
psql_as_user "$DB_URL" -c "UPDATE medium SET enum_done = NOW() WHERE medium_hash = '$medium_hash';" 2>/dev/null || true
```

2. **In stage_copy() function:**
```bash
# After successful copy completion (line ~844 or ~916)
# Before archive stage
# ADD:
psql_as_user "$DB_URL" -c "UPDATE medium SET copy_done = NOW() WHERE medium_hash = '$medium_hash';" 2>/dev/null || true
```

**Priority 2: Backfill missing timestamps for existing media**

Create remediation script:
```bash
#!/usr/bin/env bash
# bin/backfill-completion-timestamps.sh

# For each medium with NULL timestamps but complete processing:
for hash in $(psql copyjob -tAc "SELECT medium_hash FROM medium WHERE enum_done IS NULL AND image_path IS NOT NULL"); do
  # Check if inode table exists with data
  table=$(psql copyjob -tAc "SELECT tablename FROM pg_tables WHERE tablename LIKE 'inode_p_${hash:0:8}%';" | head -1)

  if [[ -n "$table" ]]; then
    count=$(psql copyjob -tAc "SELECT COUNT(*) FROM $table;")

    if [[ $count -gt 0 ]]; then
      echo "Setting enum_done for $hash ($count files)"
      psql copyjob -c "UPDATE medium SET enum_done = NOW() WHERE medium_hash = '$hash';"

      # Check if all files copied
      copied=$(psql copyjob -tAc "SELECT COUNT(*) FROM $table WHERE copied = true;")

      if [[ $copied -eq $count ]]; then
        echo "Setting copy_done for $hash (all files copied)"
        psql copyjob -c "UPDATE medium SET copy_done = NOW() WHERE medium_hash = '$hash';"
      fi
    fi
  fi
done
```

---

## Testing Requirements

**Test that timestamps are set:**

1. **Process test medium:**
```bash
sudo bin/ntt-orchestrator --image /path/to/test.img
```

2. **Verify timestamps immediately after:**
```sql
SELECT medium_hash, enum_done, copy_done
FROM medium
WHERE medium_hash = '<test_hash>';

-- Both should be non-NULL immediately after pipeline completes
```

3. **Verify timestamps reflect stage completion:**
```sql
-- enum_done should be set after load stage
-- copy_done should be set after copy stage
-- copy_done should be >= enum_done (copy happens after load)
```

---

## Success Criteria

**Fix is successful when:**

- [ ] stage_load() sets enum_done timestamp after successful load
- [ ] stage_copy() sets copy_done timestamp after successful copy
- [ ] New test media processed shows both timestamps populated
- [ ] Timestamps reflect actual stage completion times (not backdated)
- [ ] Backfill script successfully updates 74 existing media
- [ ] Database queries show 99+ complete media (25 + 74 backfilled)
- [ ] No new media processed with NULL timestamps

---

## Remediation Plan for Existing Media

**Affected:** 74 media with NULL timestamps but complete processing

**Action:**
1. Deploy timestamp update fix to orchestrator
2. Run backfill script to set timestamps for existing media
3. Verify all 74 media have timestamps after backfill
4. Monitor new media processing to ensure timestamps set correctly

**Verification queries:**
```sql
-- Before backfill:
SELECT COUNT(*) FROM medium WHERE enum_done IS NULL;  -- 74

-- After backfill:
SELECT COUNT(*) FROM medium WHERE enum_done IS NULL;  -- 0 (ideally)

-- Verify no truly incomplete media missed:
SELECT m.medium_hash, COUNT(i.id) as file_count
FROM medium m
LEFT JOIN inode i ON i.medium_hash = m.medium_hash
WHERE m.enum_done IS NOT NULL
GROUP BY m.medium_hash
HAVING COUNT(i.id) = 0;
-- Should return 0 rows (all media with enum_done have files)
```

---

## Related Issues

**Previous investigation:**
- BUG-015: Incorrectly diagnosed as subprocess backgrounding issue
- Actually: Timestamps never set, processing succeeded

**Architectural:**
- Need comprehensive pipeline state validation
- Consider separating "stage attempted" from "stage completed"
- Add sanity checks: if copy_done set, verify inode table exists

---

## Files Requiring Modification

**Primary: bin/ntt-orchestrator**
- `stage_load()` function: ~line 786-821
- `stage_copy()` function: ~line 823-964
- Add `UPDATE medium SET enum_done = NOW()` after load success
- Add `UPDATE medium SET copy_done = NOW()` after copy success

**Secondary: Create backfill script**
- `bin/backfill-completion-timestamps.sh` - set timestamps for existing media

**Verification:**
- `bin/audit-cdrom-completion.sh` - already exists, will show improvement

---

## Dev Notes

**Analysis by:** prox-claude
**Date:** 2025-10-12 13:40

**Discovery process:**
1. User asked if da69350a img files could be removed after archiving
2. Found enum_done and copy_done were NULL despite archive existing
3. Initially assumed (incorrectly) that loader/copier never ran → Filed BUG-015
4. Deeper investigation revealed inode tables exist with full data
5. Verified all files copied with blobids assigned
6. Code review showed synchronous execution (not backgrounding issue)
7. **Real issue:** Stage functions log JSON events but don't update SQL timestamps

**Key insight:** NULL timestamps don't mean work wasn't done - they mean work was done but not recorded in medium table. Always verify actual state (inode tables, copied flags, physical files) before diagnosing failure.

**Priority:** MEDIUM - Not data loss, but affects monitoring and cleanup automation. Should fix before processing more media, but existing data is safe.

**Immediate actions:**
1. Add timestamp updates to orchestrator stage functions
2. Create and run backfill script for 74 existing media
3. Verify all media updated correctly
4. Continue 8e61cad2 enumeration (unrelated to this bug)
