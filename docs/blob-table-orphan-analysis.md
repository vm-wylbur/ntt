# NTT Blob Table Orphan Analysis

**Date:** 2025-10-21
**Analyst:** dev-claude
**Status:** Investigation Complete - Root Cause Identified

## Problem Statement

ntt-backup reports "No more pending blobs" despite recent file copies. Investigation reveals 559,570 blobids exist in `inode` table but are missing from `blobs` table.

## Database State

### Summary Statistics
```sql
-- Total blobs registered
SELECT COUNT(*) FROM blobs;
-- Result: 6,252,591

-- Inodes with blobids
SELECT COUNT(*) FROM inode WHERE blobid IS NOT NULL;
-- Result: 48,124,963

-- Unique blobids in inode table
SELECT COUNT(DISTINCT blobid) FROM inode WHERE blobid IS NOT NULL;
-- Result: 6,405,707

-- Orphaned blobids (in inode but not in blobs)
SELECT COUNT(DISTINCT i.blobid)
FROM inode i LEFT JOIN blobs b ON i.blobid = b.blobid
WHERE i.blobid IS NOT NULL AND b.blobid IS NULL;
-- Result: 262,071 unique blobids (559,570 total inode rows affected)
```

### Orphan Characteristics
```sql
-- All orphaned blobids have:
- fs_type = 'f' (regular files)
- status = 'success' (marked as successfully copied)
- copied = true
- processed_at = NULL (key indicator!)
```

### Most Affected Media
```
97239906f88d6799e3b4f22127b6905c (ST3300831A-3NF01XEE-dd):     262,610 orphaned
4b871132e06f83375c42fd7f8e5cd437 (4b871132e06f8337):          254,081 orphaned
carved_sda_20251013 (PhotoRec carved):                         42,681 orphaned
```

## Root Cause

### Code Analysis

The copier has TWO execution paths:

**Path 1: Single-Inode Mode (OLD)**
- Function: `process_work_unit()` → `execute_plan()` → `update_db_for_file()`
- Location: `ntt-copier.py:1662-1692`
- **DOES** insert into blobs table (line 1688):
```python
cur.execute("""
    INSERT INTO blobs (blobid, n_hardlinks)
    VALUES (%s, %s)
    ON CONFLICT (blobid) DO UPDATE
    SET n_hardlinks = blobs.n_hardlinks + EXCLUDED.n_hardlinks
""", (hash_val, num_links))
```

**Path 2: Batch Mode (CURRENT DEFAULT)**
- Function: `process_batch()`
- Location: `ntt-copier.py:633-1060`
- Updates inode table (line 937-944):
```python
cur.execute("""
    UPDATE inode SET copied = true, blobid = updates.blob_id,
                     mime_type = COALESCE(updates.mime_type, inode.mime_type),
                     status = 'success'
    FROM unnest(%s::bigint[], %s::text[], %s::text[]) AS updates(id, blob_id, mime_type)
    WHERE inode.id = updates.id
      AND inode.medium_hash = %s
""", (success_ids, success_blob_ids, success_mime_types, self.medium_hash))
```
- **MISSING**: No INSERT INTO blobs statement!
- **MISSING**: Does not set `processed_at` timestamp
- **MISSING**: Does not set `by_hash_created` flag

### Default Configuration
```python
# ntt-copier.py line 1759
batch_size: int = typer.Option(100, "--batch-size", "-b", ...)
```
Batch mode is the default (batch_size=100), so all recent processing uses the broken path.

## Impact Timeline

### Evidence from processed_at Field
```sql
SELECT
  COUNT(*) as total_success_files,
  COUNT(*) FILTER (WHERE processed_at IS NOT NULL) as old_path,
  COUNT(*) FILTER (WHERE processed_at IS NULL) as batch_path
FROM inode
WHERE status = 'success' AND fs_type = 'f';

Result:
  total: 39,332,513
  old_path: 6,558,119 (has processed_at, likely from single-inode mode)
  batch_path: 32,774,394 (no processed_at, from batch mode)
```

This suggests:
- ~6.6M files processed before batch mode became default
- ~32.8M files processed after (missing blobs entries)
- But only 559K are actually orphaned (likely due to hardlinks/deduplication)

## Git History
```
a14997b - Optimize worker throughput and memory usage
```
This commit appears to be when the optimization was introduced that broke blobs table population.

## Why Backup Says "No Pending"

The backup script queries:
```python
SELECT blobid FROM blobs
WHERE (external_copied IS FALSE OR external_copied IS NULL)
  AND (external_copy_failed IS FALSE OR external_copy_failed IS NULL)
```

Since orphaned blobids don't exist in `blobs` table, they're invisible to the backup process.

## Implications

1. **Data Integrity**: 559,570 files successfully copied but not tracked in blobs table
2. **Backup Gap**: These files won't be backed up to external drive
3. **Hardlink Tracking**: n_hardlinks counts are incorrect (missing orphaned files)
4. **Verification**: Can't verify expected vs actual hardlinks for orphaned blobs

## Recommended Fix Strategy

### Phase 1: Stop the Bleeding (Immediate)
Fix batch mode to insert into blobs table during UPDATE phase

### Phase 2: Backfill (Next)
Populate missing blobs from existing inode data:
```sql
INSERT INTO blobs (blobid, n_hardlinks)
SELECT blobid, COUNT(*) as n_hardlinks
FROM inode
WHERE blobid IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM blobs WHERE blobs.blobid = inode.blobid)
GROUP BY blobid
ON CONFLICT (blobid) DO UPDATE
SET n_hardlinks = blobs.n_hardlinks + EXCLUDED.n_hardlinks;
```

### Phase 3: Verification (Final)
1. Verify blob counts match actual filesystem hardlinks
2. Run backup to catch up on missed blobs
3. Audit external_copied status

## Files to Investigate/Fix

1. `bin/ntt-copier.py` - Add INSERT INTO blobs in process_batch()
2. Check if ntt-copy-workers uses same broken code path
3. Verify any other tools that might populate blobs table

## Questions for PB

1. When was commit a14997b deployed? Does timing match orphaned data?
2. Should backfill happen before or after fixing the code?
3. Are there any other tools that populate the blobs table?
4. Should we add a database constraint to prevent this in future?

---

## Resolution

### Backfill Completed: 2025-10-21

**Script:** `bin/archive/backfill-orphaned-blobs.sql`

**Results:**
- **262,078 blobids** inserted into blobs table
- **0 orphaned blobids** remaining
- All orphaned files now visible to ntt-backup

**Verification:**
```sql
-- Before: 262,078 orphaned
-- After: 0 orphaned

SELECT COUNT(*) FROM blobs;
-- Total blobs: 6,514,669 (was 6,252,591)
-- New blobs: 262,078 now pending backup
```

**Next Steps:**
1. ✓ Fix batch mode in ntt-copier.py to prevent future orphans
2. Run ntt-backup to catch up on 262K new blobs (129 GB)
3. Consider adding database trigger to prevent blobs/inode inconsistency

---

## Code Fix Applied: 2025-10-21

### Changes to bin/ntt-copier.py

**1. Added processed_at timestamp (line 941)**
```python
UPDATE inode SET copied = true, blobid = updates.blob_id,
                 mime_type = COALESCE(updates.mime_type, inode.mime_type),
                 status = 'success',
                 processed_at = NOW()  # <-- ADDED
```

**2. Added blobs table INSERT (lines 949-961)**
```python
# Insert/update blobs table (grouped to handle duplicate blobids in batch)
t_blobs_start = time.time()
cur.execute("""
    INSERT INTO blobs (blobid, n_hardlinks)
    SELECT blobid, COUNT(*) as n_hardlinks
    FROM unnest(%s::text[]) AS t(blobid)
    WHERE blobid IS NOT NULL
    GROUP BY blobid
    ON CONFLICT (blobid) DO UPDATE
    SET n_hardlinks = blobs.n_hardlinks + EXCLUDED.n_hardlinks
""", (success_blob_ids,))
t_blobs_end = time.time()
logger.debug(f"TIMING: INSERT blobs: {t_blobs_end-t_blobs_start:.3f}s for {len(success_blob_ids)} blobids")
```

### What Was NOT Fixed (Future Work)

**by_hash_created field** - Batch mode still doesn't track this properly. Would require:
- Capturing return value from `execute_copy_new_file_fs()` (line 605)
- Changing `process_inode_for_batch()` signature to return tuple
- Collecting and passing to UPDATE statement

Decision: Leave as default (False) for now. Field exists but batch mode won't populate accurately until future refactor.

### Testing Required

**Verification query** (check for new orphans):
```sql
SELECT COUNT(*) as orphaned_count
FROM inode i
LEFT JOIN blobs b ON i.blobid = b.blobid
WHERE i.copied = true
  AND i.blobid IS NOT NULL
  AND b.blobid IS NULL;
-- Should return 0
```

**Test plan:**
1. Pick small medium (Zip disk or recent floppy)
2. Reset a few files: `UPDATE inode SET copied=false WHERE medium_hash='...' LIMIT 10`
3. Run copier: `sudo -E bin/ntt-copier.py -m <hash> --batch-size 100`
4. Verify: blobs populated, processed_at set, no orphans
