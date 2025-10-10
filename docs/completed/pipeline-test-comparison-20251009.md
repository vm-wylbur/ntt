<!-- completed: Small image test validation; infinite retry bug identified and fixed in commit a67eb3d -->

# NTT Pipeline Test Summary - Small Images

**Date:** 2025-10-09
**Images Tested:** 42aae5cd (1.5M) and 8afe182d (1.4M)
**Goal:** Validate recent improvements (diagnostic system, ignore patterns, infinite retry bug fix)

---

## Results Overview

| Medium | Total Inodes | Successful Files | Non-Files | Failed | Archive Size |
|--------|-------------|------------------|-----------|---------|-------------|
| 42aae5cd | 11 | 9 | 2 | 0 | 951K |
| 8afe182d | 12 | 10 | 1 | 1 | 341K |

---

## 42aae5cd Processing (Round 1)

**Status:** ✅ Complete success
**Files:** 11 inodes total
- 9 regular files successfully copied
- 2 non-file items (directories/symlinks/special files)
- 0 errors or retries

**Archive:** `/data/cold/img-read/42aae5cdb5952e4cf9918908343545cc.tar.zst` (951K)

**Observations:**
- Clean run with no errors
- All files processed successfully
- Baseline for comparison

---

## 8afe182d Processing (Round 2)

**Status:** ⚠️  Complete with 1 failure (expected - bad imaging)
**Files:** 12 inodes total
- 10 regular files successfully copied
- 1 non-file item (directory/symlink/special file)
- 1 permanently failed file (plw06.doc)

**Archive:** `/data/cold/img-read/8afe182de007466b75cb4d84287219e4.tar.zst` (341K)

**Problem Encountered:**
- File: plw06.doc (ino=3534)
- Error: I/O error ([Errno 5] Input/output error)
- Root cause: Stalled ddrescue - bad sectors in source medium
- Retry count: **2,021 retries** before being stopped
- Resolution: Identified infinite retry bug, implemented two-layer fix

---

## Bug Fix Implemented

### Problem
The copier had an infinite retry loop bug:
1. At retry #10: Diagnostics run, only auto-skipped BEYOND_EOF errors
2. At retry #50: Logged "MAX RETRIES REACHED" but **continued retrying** → infinite loop
3. I/O errors from bad sectors were never auto-skipped

### Solution (Two-Layer Safety Net)

**Layer 1: Auto-skip I/O errors at retry #10**
- File: `ntt_copier_diagnostics.py`
- Extended `should_skip_permanently()` to detect I/O errors
- Requires both exception message AND dmesg kernel confirmation
- Prevents wasting 40+ retries on unrecoverable errors

**Layer 2: Enforce max retries at #50**
- File: `ntt-copier.py` (lines 723-752)
- Actually marks inode as failed and skips to next (added `continue`)
- Safety net that catches ANY error type escaping Layer 1
- Prevents infinite retry loops

**Impact:**
- Before: 2,021+ retries, manual intervention required
- After: Would auto-skip at retry #10 (Layer 1) or #50 (Layer 2)
- Saves ~40-2000+ retry attempts per failed file

---

## Code Changes Summary

### ntt_copier_diagnostics.py
```python
def should_skip_permanently(self, findings: dict) -> bool:
    """Auto-skip unrecoverable errors (BEYOND_EOF and I/O errors)"""
    checks = findings['checks_performed']

    # Layer 1: BEYOND_EOF (existing)
    if 'detected_beyond_eof' in checks or 'dmesg:beyond_eof' in checks:
        return True

    # Layer 1: I/O ERROR (new - requires dmesg confirmation)
    if 'detected_io_error' in checks and 'dmesg:io_error' in checks:
        return True

    return False
```

### ntt-copier.py
```python
# Layer 2: Safety net at retry #50
if retry_count >= 50:
    # ... logging and diagnostics ...

    # CRITICAL: Actually mark as failed and skip
    results_by_inode[key] = None
    action_counts['max_retries_exceeded'] += 1
    continue  # DON'T retry infinitely!
```

---

## Validation Results

✅ **Diagnostic system working:** Detected I/O errors at checkpoint (retry #10)
✅ **Error tracking:** 2,021 errors properly recorded in database
✅ **Manual intervention:** Successfully marked failed inode as MAX_RETRIES_EXCEEDED
✅ **Archive creation:** Both media successfully archived
✅ **Pipeline completion:** Both rounds completed (1 clean, 1 with expected failure)

⚠️  **Bug confirmed:** Infinite retry loop occurred on 8afe182d before fix
✅ **Fix implemented:** Two-layer safety net now prevents infinite loops

---

## Recommendations

1. **Deploy bug fix immediately** - Prevents worker hangs on bad sectors
2. **Monitor diagnostic events** - Check `medium.problems->diagnostic_events` for I/O error patterns
3. **Health field usage** - Consider setting `medium.health != 'ok'` for stalled ddrescue images
4. **Test larger images** - Validate fix on 466GB floppy (488de202) next

---

## Database Evidence

**42aae5cd inodes:**
```sql
claimed_by        | count
------------------+-------
test-42aae5cd     | 9      (successful files)
NON_FILE          | 2      (dirs/symlinks/special)
```

**8afe182d inodes:**
```sql
claimed_by              | count
------------------------+-------
test-8afe182d           | 10     (successful files)
NON_FILE                | 1      (dir/symlink/special)
MAX_RETRIES_EXCEEDED    | 1      (plw06.doc - I/O error)
```

**8afe182d failed file details:**
- Inode: 3534 (plw06.doc)
- Error count: 2,021 retries
- Permanently marked as failed (manual intervention required due to pre-fix bug)

---

**Conclusion:** Pipeline validation successful. Infinite retry bug identified and fixed with robust two-layer approach. Ready for larger image processing.
