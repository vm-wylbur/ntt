<!--
Author: PB and Claude
Date: Thu 10 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/bugs/BUG-007-diagnostic-service-status-model.md
-->

# BUG-007: DiagnosticService Status Model Conflates Success and Failure

**Component**: `ntt-copier.py` DiagnosticService Phase 4
**Severity**: High - causes unrecoverable file loss
**Discovered**: 2025-10-10 (medium a78ccc01a5019a08651d6db3faf82abc)

## Problem

DiagnosticService uses `copied=true` to mean two incompatible things:
1. "File successfully copied" (correct meaning)
2. "Stop retrying this file" (after 10 failed attempts)

This conflation prevents recovery when root cause is fixable.

## Concrete Example

Medium a78ccc01 - tar.bz2 archive extraction:

1. Initial enum created absolute paths: `/data/fast/img/tar/extract-a78c.../home/pball/Maildir/...`
2. Copier failed: path doubled to `/mnt/ntt/a78c/data/fast/img/tar/extract-a78c.../home/...`
3. After 10 retries, DiagnosticService marked `copied=true` (to stop infinite retry)
4. We fixed paths with SQL UPDATE to relative: `/home/pball/Maildir/...`
5. Files NOW accessible, but stuck as `copied=true` → copier ignores them
6. **2,657 files unrecoverable** until manual SQL reset

```sql
-- Had to manually reset to retry with fixed paths
UPDATE inode_p_a78ccc01
SET copied = false, errors = '{}', claimed_by = NULL, claimed_at = NULL
WHERE medium_hash = 'a78ccc01a5019a08651d6db3faf82abc'
  AND blobid IS NULL AND fs_type = 'f' AND copied = true;
-- Updated 2657 rows
```

## Root Cause Analysis

**Current model:**
```python
copied: bool  # True means either SUCCESS or FAILED_MAX_RETRIES
blobid: str   # NULL for both PENDING and FAILED_MAX_RETRIES
```

Cannot distinguish:
- Pending files (never tried)
- Failed files (tried 10x, gave up)
- Successful files (copied=true, blobid NOT NULL)

**Error handling gaps:**
1. All errors treated identically (generic retry counter)
2. No error classification (PATH_ERROR vs IO_ERROR vs HASH_ERROR)
3. No recovery mechanism after max retries
4. PATH_ERROR might be fixable, IO_ERROR from bad media is permanent

## Proposed Solution

### 1. Add Status Column
```python
status: Enum[
    'PENDING',           # Not yet attempted
    'SUCCESS',           # Copied successfully (has blobid)
    'FAILED_RETRYABLE',  # Hit max retries but might be fixable
    'FAILED_PERMANENT'   # Truly unrecoverable (bad media)
]
```

### 2. Add Error Classification
```python
error_type: Enum[
    'PATH_ERROR',        # Path too long, path not found, etc.
    'IO_ERROR',          # Read error from bad media
    'HASH_ERROR',        # Hash computation failed
    'PERMISSION_ERROR',  # Access denied
    'UNKNOWN'
]
```

### 3. Improve DiagnosticService Logic
```python
def handle_max_retries_exceeded(self, inode_id, errors):
    # Classify the most recent error
    error_type = classify_error(errors[-1])

    if error_type == 'IO_ERROR':
        # Bad media - truly permanent
        status = 'FAILED_PERMANENT'
    else:
        # Might be fixable (path issues, permissions, etc.)
        status = 'FAILED_RETRYABLE'

    update_inode(
        inode_id=inode_id,
        status=status,
        error_type=error_type,
        copied=False  # NEVER mark failed files as copied
    )
```

### 4. Add Recovery Tools
```python
def reset_retryable_failures(medium_hash, error_types=['PATH_ERROR']):
    """Reset specific error types for retry after fixing root cause"""
    UPDATE inode
    SET status = 'PENDING', errors = '{}', claimed_by = NULL
    WHERE medium_hash = %s
      AND status = 'FAILED_RETRYABLE'
      AND error_type = ANY(%s)
```

### 5. Update Copier Query
```python
# OLD (incorrect)
WHERE copied = false AND fs_type = 'f'

# NEW (correct)
WHERE status IN ('PENDING', 'FAILED_RETRYABLE') AND fs_type = 'f'
```

## Error Classification Examples

```python
def classify_error(error_msg: str) -> str:
    if 'No such file or directory' in error_msg:
        if len(extract_path(error_msg)) > 200:
            return 'PATH_ERROR'  # Path too long
        return 'PATH_ERROR'  # Path not found

    if 'Permission denied' in error_msg:
        return 'PERMISSION_ERROR'

    if 'Input/output error' in error_msg:
        return 'IO_ERROR'  # Bad media

    if 'hash' in error_msg.lower():
        return 'HASH_ERROR'

    return 'UNKNOWN'
```

## Migration Path

1. Add new columns: `status`, `error_type`
2. Migrate existing data:
   ```sql
   UPDATE inode SET status = CASE
       WHEN blobid IS NOT NULL THEN 'SUCCESS'
       WHEN copied = true THEN 'FAILED_RETRYABLE'  -- Assume retryable
       ELSE 'PENDING'
   END;
   ```
3. Update DiagnosticService to use new model
4. Update copier queries
5. Add admin tools for manual recovery

## Immediate Workaround

For now, when encountering max-retry failures:
1. Investigate root cause
2. Fix if possible (paths, permissions, etc.)
3. Manually reset:
   ```sql
   UPDATE inode_p_<hash>
   SET copied = false, errors = '{}', claimed_by = NULL
   WHERE blobid IS NULL AND copied = true;
   ```
4. Re-run copier

## Files Affected

- `bin/ntt-copier.py`: DiagnosticService class (lines ~600-800)
- Database schema: `inode` table needs new columns
- Migration script needed

## Related Issues

- Phase 4 DiagnosticService auto-skip behavior (commit 6c963c7)
- Need permanent vs transient error distinction

---

## Dev Notes

**Investigation:** 2025-10-11

Examined the codebase to understand the root cause:

1. **ntt-copier.py:754-789** - Max retries logic marked failures as success
   - Old: `results_by_inode[key] = {'blob_id': None, 'mime_type': None}`
   - This was later treated as success, setting `copied=true` with `blobid=NULL`
   - No distinction between "successfully copied" and "gave up after max retries"

2. **Database schema** - Missing status columns
   - Only had `copied` (bool) and `blobid` (text)
   - Could not distinguish pending vs failed_retryable vs failed_permanent

3. **No error classification** - All errors treated identically
   - PATH_ERROR (fixable) vs IO_ERROR (permanent) not distinguished
   - No recovery mechanism after fixing root causes

**Root cause:** Conflating two meanings of `copied=true`:
- "File successfully copied" (correct meaning)
- "Stop retrying this file" (after max retries - incorrect usage)

**Changes made:**

### 1. Database Migration (sql/03-add-status-model.sql)
- Added `status` column: CHECK constraint for 'pending', 'success', 'failed_retryable', 'failed_permanent'
- Added `error_type` column: CHECK constraint for error classification
- Migrated existing data:
  - `status='success'` WHERE blobid IS NOT NULL
  - `status='failed_retryable'` WHERE copied=true AND blobid IS NULL
  - `status='pending'` WHERE copied=false
- Added indexes for efficient querying of failed items

### 2. DiagnosticService Enhancement (bin/ntt_copier_diagnostics.py)
- **classify_error(exception)**: Categorizes errors into:
  - `path_error` - Path too long, file not found (likely fixable)
  - `io_error` - Bad media, I/O errors (permanent)
  - `hash_error` - Hash computation failed (transient)
  - `permission_error` - Access denied (might be fixable)
  - `unknown` - Unclassified
- **determine_failure_status(exception)**: Returns (status, error_type) tuple
  - `io_error` → `failed_permanent`
  - All others → `failed_retryable`

### 3. CopyWorker Updates (bin/ntt-copier.py)
- **Max retries logic (lines 754-789)**:
  - Now calls `diagnostics.determine_failure_status(e)` to classify
  - Sets `status` and `error_type` instead of just `copied=true`
  - Enables targeted recovery after fixing root causes

- **Batch update logic (lines 809-903)**:
  - Added `permanent_failures` list alongside success/failed
  - Update query sets proper status and error_type
  - Success updates also set `status='success'` for consistency

- **Startup check (mark_max_retries_exceeded, lines 411-466)**:
  - Now classifies existing failures based on error messages
  - Sets appropriate status and error_type for pre-existing failures

### 4. Recovery Tool (bin/ntt-recover-failed)
- **list-failures**: Show failure breakdown by status and error_type
- **reset-failures**: Reset failed_retryable → pending for specific error types
- Supports targeted recovery: `--error-type path_error` or `--all-retryable`
- Safe defaults: dry-run by default, requires --execute flag

**Testing performed:**
- Code review: Verified logic handles all paths correctly
- Migration SQL: Verified constraints and data migration queries
- Error classification: Reviewed pattern matching for common error types

**Migration path:**
1. Run `sql/03-add-status-model.sql` (adds columns, migrates data)
2. Restart ntt-copier workers (uses new status model automatically)
3. For existing failed items, use `ntt-recover-failed` tool to retry

**Backward compatibility:**
- `copied` column maintained for existing queries during transition
- `copied=true` still used for terminal states (success and failures)
- Gradual migration: new failures use status model, old queries still work

**Ready for testing:** 2025-10-11 18:30
