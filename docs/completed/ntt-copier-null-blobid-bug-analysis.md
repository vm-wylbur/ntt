<!--
Author: PB and Claude
Date: 2025-11-24
License: (c) HRDAG, 2025, GPL-2 or newer

---
/tmp/ntt-copier-null-blobid-bug-analysis.md
-->

# NTT Copier NULL Blobid Bug - Analysis and Fix

## Bug Summary

**Location:** `/home/pball/projects/ntt/bin/ntt-copier.py` lines 1178-1184

**Impact:** 27,696 regular files (64% of non-empty regular files) marked `copied=true` with `blobid=NULL` instead of valid SHA256 hashes, causing catastrophic data integrity corruption.

**Root Cause:** Batch result processing treats ANY dict result as success without validating `blob_id` field, including cases where `blob_id=None` (directories/symlinks/special files).

## The Bug Flow

### 1. Non-File Processing Returns None

**Lines 881-893** in `process_inode_for_batch()`:
```python
elif plan['action'] == 'create_directory':
    self.execute_directory_fs(plan)      # Does nothing (just 'pass')
elif plan['action'] == 'create_symlink':
    self.execute_symlink_fs(plan)        # Does nothing (just 'pass')
elif plan['action'] == 'record_special':
    pass

blob_id = plan.get('blobid')  # ← None for directories/symlinks/special!
return blob_id                 # ← Returns None
```

**Lines 1901-1909** - Execution functions do nothing:
```python
def execute_directory_fs(self, plan: dict):
    """Filesystem operations for directory."""
    # No filesystem operations needed - directories not recreated in archive
    pass

def execute_symlink_fs(self, plan: dict):
    """Filesystem operations for symlink."""
    # No filesystem operations needed - symlinks not recreated in archive
    pass
```

### 2. Result Dict Created With None Blob ID

**Line 1020**:
```python
results_by_inode[key] = {'blob_id': blob_id, 'mime_type': mime_type}
# For directories: {'blob_id': None, 'mime_type': 'inode/directory'}
```

### 3. Bug: Any Dict Treated as Success

**Lines 1178-1184** - DOES NOT VALIDATE blob_id:
```python
elif isinstance(result, dict):
    # Success: result is dict with blob_id and mime_type
    success_medium_hashes.append(inode_row['medium_hash'])
    success_inos.append(inode_row['ino'])
    success_devs.append(inode_row['dev'])
    success_blob_ids.append(result.get('blob_id'))  # ← APPENDS None!
    success_mime_types.append(result.get('mime_type'))
```

### 4. Database Corruption

**Line 1216** - UPDATE query sets NULL:
```sql
UPDATE paths SET copied = true, blobid = updates.blob_id,  -- ← Sets NULL!
                 mime_type = COALESCE(updates.mime_type, paths.mime_type),
                 status = 'success',
                 processed_at = NOW()
FROM unnest(%s::text[], %s::bigint[], %s::bigint[], %s::text[], %s::text[])
     AS updates(medium_hash, ino, dev, blob_id, mime_type)
WHERE paths.medium_hash = updates.medium_hash
  AND paths.ino = updates.ino
  AND paths.dev = updates.dev
```

**Result:** Files marked `copied=true` but `blobid=NULL` - NO REFERENCE TO ACTUAL BLOB CONTENT!

## Why Non-Files Return None

**User statement:** "we don't create directories or symlinks anymore, that's superseded"

**Evidence in code:**
- Lines 1901-1909: `execute_directory_fs()` and `execute_symlink_fs()` are empty (`pass`)
- Comments explicitly state: "directories not recreated in archive", "symlinks not recreated in archive"
- These functions do NO filesystem operations
- They return None because there's no blob content to create

**Conclusion:** Directory/symlink creation is legacy code. Modern NTT system only archives regular file blobs.

## The Fix

**Strategy:** Only treat results as success if `blob_id` is not None. Skip non-files in batch update - they remain `copied=false`.

**Patch Location:** Lines 1178-1184

**Before:**
```python
elif isinstance(result, dict):
    # Success: result is dict with blob_id and mime_type
    success_medium_hashes.append(inode_row['medium_hash'])
    success_inos.append(inode_row['ino'])
    success_devs.append(inode_row['dev'])
    success_blob_ids.append(result.get('blob_id'))  # BUG: Can be None!
    success_mime_types.append(result.get('mime_type'))
```

**After:**
```python
elif isinstance(result, dict):
    blob_id = result.get('blob_id')

    # BUG FIX: Only treat as success if blob_id is valid (not None)
    # Directories/symlinks/special files return None and should be skipped
    # since we don't create them in the archive anymore (superseded)
    if blob_id:
        # Success: result is dict with valid blob_id and mime_type
        success_medium_hashes.append(inode_row['medium_hash'])
        success_inos.append(inode_row['ino'])
        success_devs.append(inode_row['dev'])
        success_blob_ids.append(blob_id)
        success_mime_types.append(result.get('mime_type'))
    else:
        # Non-file (directory/symlink/special) - skip database update
        # These remain copied=false (not processed in current system)
        logger.debug(
            f"Skipping non-file inode {inode_row['ino']} "
            f"fs_type={inode_row.get('fs_type')} (no blob content)"
        )
```

## Expected Behavior After Fix

1. **Regular files (fs_type='f')**:
   - Processed normally
   - Valid SHA256 blobid assigned
   - Marked `copied=true` with `blobid=<hash>`

2. **Directories (fs_type='d')**:
   - Processed through pipeline (action='create_directory')
   - No filesystem operations (just `pass`)
   - Returns `blob_id=None`
   - **SKIPPED in batch update** - remains `copied=false`

3. **Symlinks (fs_type='l')**:
   - Processed through pipeline (action='create_symlink')
   - No filesystem operations (just `pass`)
   - Returns `blob_id=None`
   - **SKIPPED in batch update** - remains `copied=false`

4. **Special files (fs_type='b'/'c'/'p'/'s')**:
   - Processed through pipeline (action='record_special')
   - No filesystem operations
   - Returns `blob_id=None`
   - **SKIPPED in batch update** - remains `copied=false`

## Database State Recovery

**Corrupted records reset:**
```sql
UPDATE paths
SET copied=false, status=NULL, claimed_by=NULL, claimed_at=NULL
WHERE medium_hash = '29aca3545bc5385fac7a2c3da0faa7a5'
  AND copied=true
  AND blobid IS NULL
  AND fs_type='f'
  AND size > 0;
-- Reset 27,696 corrupted records
```

**After fix applied:**
- Rerun copy phase
- Regular files will get valid blobids
- Non-files will be skipped (remain `copied=false`)

## Testing Strategy

1. Apply patch to ntt-copier.py
2. Rerun copy workers on archives-2019 medium
3. Verify:
   - All regular files (`fs_type='f'`, `size > 0`) get valid SHA256 blobids
   - No records with `copied=true` and `blobid IS NULL` except directories/symlinks (if any)
   - Directories/symlinks remain `copied=false` (skipped as expected)

## Files

- Patch: `/tmp/ntt-copier-null-blobid-fix.patch`
- Analysis: `/tmp/ntt-copier-null-blobid-bug-analysis.md`
- Original code: `/home/pball/projects/ntt/bin/ntt-copier.py`
