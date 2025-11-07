<!--
Author: PB and Claude
Date: 2025-11-07
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/redis-queue-dup-bug-20251107T1038.md
-->

# Redis-PostgreSQL State Mismatch Bug

## Status
- **Discovered:** 2025-11-07 12:42:59 UTC
- **Status:** TO BE FIXED (see Resolution section below)
- **Severity:** Critical (worker crash, data inconsistency)
- **Test:** 1000-archive stress test, blob 712/1000

## Summary

Worker crashes when attempting to re-extract already-processed blobs due to state mismatch between Redis and PostgreSQL after queue reset. The `--reset` flag clears Redis deduplication state but leaves PostgreSQL extraction records intact, causing already-extracted blobs to be re-queued and triggering duplicate key constraint violations.

## Investigation Timeline

### Discovery (2025-11-07 12:42:59 UTC)

1. **100-archive test (earlier)**: Blob `d5c009f684531003e6307cd67983d5015697fa3822a1aceafa792ccd379e5a6e` successfully extracted
   - Medium `86bdf2e99302b5b6` created with 6 inodes
   - Blob marked `extraction_status = 'completed'` in PostgreSQL
   - Blob added to Redis `PROCESSED` set

2. **1000-archive init**: `./bin/ntt-extractor.py init --from-file /tmp/pilot-batch-1000.txt --reset=True`
   - Cleared all Redis data (including `PROCESSED` set)
   - PostgreSQL data remained intact
   - Re-queued blob `d5c009f6...` (appeared in both test files)

3. **1000-archive run**: Worker processed blob at 12:42:59
   - `create_extracted_medium()`: ON CONFLICT updated timestamp to 20:42:59
   - Attempted to insert 6 inodes via COPY
   - **ERROR**: "duplicate key value violates unique constraint" on line 1 (first row)
   - Transaction aborted
   - Attempted `mark_extraction_failed()` → failed (transaction aborted)
   - Worker crashed, leaving blob stuck in Redis `IN_PROGRESS`

### Evidence

```sql
-- Blob marked completed in DB
SELECT extraction_status FROM blobs
WHERE blobid = 'd5c009f684531003e6307cd67983d5015697fa3822a1aceafa792ccd379e5a6e';
-- Result: completed

-- Medium exists with 6 inodes from first extraction
SELECT COUNT(*) FROM inode WHERE medium_hash = '86bdf2e99302b5b6';
-- Result: 6

-- Medium timestamp shows second attempt
SELECT extracted_at FROM medium WHERE medium_hash = '86bdf2e99302b5b6';
-- Result: 2025-11-06 20:42:59 (time of crash)

-- Inodes that exist (successfully inserted in first extraction)
SELECT ino, blobid, size FROM inode
WHERE medium_hash = '86bdf2e99302b5b6'
ORDER BY ino;
--          ino          |                              blobid                              | size
-- ----------------------+------------------------------------------------------------------+-------
--  -8477271928466449600 | 61153aebbda4104d5c1b035b7c3e93bad0b887f2089e41fae67b90ea2fc9b432 | 41322
--  -4802622414924561482 | b83ffdb4fd1d909040209ab5358243edeaa43c3a59c4df82c4aba4d0469f86f1 |    81
--  -3237052401255183370 | e6bc9cd66f82a7951b9f6f99273f932efdf6dd43c61d2a664870c6c1d6ecc660 |  6249
--   -568714427711742158 | 182d8cfe992905d328a72468222dfa41cd1cbaa69501ca5964d10f7bb4dfba14 | 41046
--   6417207746622981693 | a6aa5dc805da44c6e3f43dd38999dd98c47d7388024fdd6491c8773a7d979e22 |   850
--   6760437720504846141 | d2ec580483fc96d0f9db0dac84993a006d66bcfefca97e384e46a2960742fe05 |  1171
```

```bash
# But NOT in Redis PROCESSED set (cleared by reset)
redis-cli SISMEMBER ntt:extraction:processed d5c009f684531003e6307cd67983d5015697fa3822a1aceafa792ccd379e5a6e
# Returns: 0 (not present)

# Stuck in IN_PROGRESS
redis-cli HGET ntt:extraction:in_progress d5c009f684531003e6307cd67983d5015697fa3822a1aceafa792ccd379e5a6e
# Returns: snowball-1571123 (worker ID)

# Blob appears in both test files
grep "^d5c009f6" /tmp/pilot-batch-100.txt /tmp/pilot-batch-1000.txt
# /tmp/pilot-batch-100.txt:d5c009f684...
# /tmp/pilot-batch-1000.txt:d5c009f684...
```

### Error Log

```
12:42:59 | ERROR    | Extraction failed: duplicate key value violates unique constraint "inode_86bdf2e99302b5b6_pkey"
DETAIL:  Key (medium_hash, ino)=(86bdf2e99302b5b6, -568714427711742158) already exists.
CONTEXT:  COPY inode, line 1
```

The error "line 1" indicates the FIRST row in the COPY batch had a duplicate, confirming inodes already existed from previous extraction.

## Root Cause Analysis

### Bug 1: State Mismatch Between Redis and PostgreSQL

**Location:** `bin/ntt-extractor.py:98-100`

**Problem:**
```python
if reset:
    logger.warning("Clearing existing queue data")
    queue.clear_all()  # Clears Redis PROCESSED set
    # But PostgreSQL blobs.extraction_status remains 'completed'!
```

The `--reset` flag creates state inconsistency:
- Redis thinks: "No blobs processed yet" (PROCESSED set empty)
- PostgreSQL says: "These blobs are already completed" (extraction_status = 'completed')

**Why it matters:**
- `queue.pop()` checks Redis PROCESSED set for deduplication (lines 127, 144 in ntt_extractor_queue.py)
- It does NOT check PostgreSQL blob status or medium table
- Already-extracted blobs get re-queued and re-processed

**Impact:** Already-extracted blobs are re-processed, leading to duplicate key errors

### Bug 2: Missing Transaction Rollback Before Error Handling

**Location:** `bin/ntt-extractor.py:281-291`

**Problem:**
```python
except Exception as e:
    import traceback
    logger.error(...)

    # ERROR: Transaction is aborted, can't execute SQL!
    medium_manager.mark_extraction_failed(blobid, str(e))
    queue.mark_failed(blobid, str(e))
```

When COPY fails with duplicate key error, PostgreSQL automatically aborts the transaction. Any subsequent SQL commands fail with:
```
InFailedSqlTransaction: current transaction is aborted,
commands ignored until end of transaction block
```

The code attempts to call `mark_extraction_failed()` without rolling back the aborted transaction first, causing a secondary error that crashes the worker.

**Impact:** Worker crashes instead of gracefully handling extraction errors

### Bug 3: ON CONFLICT Masks Re-extraction Attempts

**Location:** `bin/ntt_extractor_medium.py:75-78`

**Problem:**
```python
INSERT INTO medium (...)
VALUES (%s, %s, 'extracted', %s, %s, %s)
ON CONFLICT (source_blobid)
WHERE medium_type = 'extracted'
DO UPDATE SET
    extracted_at = EXCLUDED.extracted_at  -- Silently updates timestamp
RETURNING medium_hash
```

The ON CONFLICT clause allows re-extraction to proceed silently:
1. Worker calls `create_extracted_medium()` → succeeds (updates timestamp)
2. Worker tries to insert inodes → fails (duplicates exist)
3. Medium record shows latest attempt time (20:42:59), not original extraction time

**Why it's problematic:**
- Masks duplicate extraction attempts (no early detection)
- Original extraction timestamp lost
- Worker proceeds to inode insertion before detecting the duplicate

**Impact:** Late failure during COPY instead of early detection at medium creation

## Proposed Fixes

### Fix 1: Skip Already-Extracted Blobs in Queue Initialization

**Location:** `bin/ntt-extractor.py` - `initialize_from_db()` method

**Change:** Modify database query to exclude blobs with existing extracted medium

**Before:**
```python
query = """
    SELECT DISTINCT b.blobid, i.mime_type, MIN(i.size) as size
    FROM blobs b
    JOIN inode i ON i.blobid = b.blobid
    WHERE b.extraction_status = 'pending'
      AND i.mime_type = ANY(%s)
    ...
"""
```

**After:**
```python
query = """
    SELECT DISTINCT b.blobid, i.mime_type, MIN(i.size) as size
    FROM blobs b
    JOIN inode i ON i.blobid = b.blobid
    WHERE b.extraction_status = 'pending'
      AND i.mime_type = ANY(%s)
      AND NOT EXISTS (
          SELECT 1 FROM medium m
          WHERE m.source_blobid = b.blobid
            AND m.medium_type = 'extracted'
      )
    ...
"""
```

**Rationale:** Queue only contains truly pending extractions, even after Redis reset. Prevents duplicates from entering queue in the first place.

### Fix 2: Add Pre-Extraction Duplicate Check

**Location:** `bin/ntt-extractor.py` - worker loop (after line 208)

**Change:** Check database for existing extraction BEFORE calling handler

```python
# Get next blob from queue
item = queue.pop()
if not item:
    logger.info("Queue empty, exiting")
    break

blobid, mime_type = item

logger.info("Processing blob", blobid=blobid, mime_type=mime_type)

# NEW: Check if already extracted (defense in depth)
cursor = db.cursor()
cursor.execute("""
    SELECT medium_hash, extracted_at
    FROM medium
    WHERE source_blobid = %s AND medium_type = 'extracted'
""", [blobid])

existing = cursor.fetchone()
if existing:
    logger.info(
        f"Blob {blobid[:8]}... already extracted to {existing['medium_hash']} "
        f"at {existing['extracted_at']}, skipping"
    )
    queue.mark_complete(blobid)
    jobs_processed += 1
    continue

# Proceed with extraction...
try:
    logger.debug(f"Starting extraction for {blobid[:8]}...")
    ...
```

**Rationale:** Defense in depth - catches any blobs that slip through queue initialization (e.g., from file-based init, nested archives, manual queue operations)

### Fix 3: Add Transaction Rollback in Exception Handler

**Location:** `bin/ntt-extractor.py:281-291`

**Change:** Roll back aborted transaction BEFORE attempting error handling

**Before:**
```python
except Exception as e:
    import traceback
    logger.error(
        f"Extraction failed: {e}",
        blobid=blobid,
        error=str(e),
        error_type=type(e).__name__,
        traceback=traceback.format_exc()
    )
    medium_manager.mark_extraction_failed(blobid, str(e))
    queue.mark_failed(blobid, str(e))
```

**After:**
```python
except Exception as e:
    import traceback
    logger.error(
        f"Extraction failed: {e}",
        blobid=blobid,
        error=str(e),
        error_type=type(e).__name__,
        traceback=traceback.format_exc()
    )

    # CRITICAL: Rollback aborted transaction FIRST
    try:
        db.rollback()
        logger.debug("Rolled back failed transaction")
    except Exception as rollback_error:
        logger.error(f"Rollback failed: {rollback_error}")

    # NOW we can mark as failed (in new transaction)
    try:
        medium_manager.mark_extraction_failed(blobid, str(e))
        queue.mark_failed(blobid, str(e))
    except Exception as cleanup_error:
        logger.error(f"Failed to mark extraction as failed: {cleanup_error}")
```

**Rationale:** Allows worker to gracefully handle errors and continue processing instead of crashing

## Testing Strategy

### Test 1: Re-extraction Detection (Primary Bug Fix)

**Purpose:** Verify that attempting to extract an already-extracted blob is handled gracefully

**Setup:**
```bash
# Extract the problematic blob that caused the crash
echo "d5c009f684531003e6307cd67983d5015697fa3822a1aceafa792ccd379e5a6e|application/zip|13837" > /tmp/test-reextract.txt
./bin/ntt-extractor.py init --from-file /tmp/test-reextract.txt
```

**Execute:**
```bash
./bin/ntt-extractor.py run --max-jobs 1
```

**Expected Result:**
- Worker logs: "Blob d5c009f6... already extracted to 86bdf2e99302b5b6 at 2025-11-06 20:42:59, skipping"
- Worker marks blob complete and continues
- No crash, no duplicate key error

### Test 2: Complete 1000-Archive Test

**Purpose:** Verify worker can complete the interrupted test

**Setup:**
```bash
# Clean up stuck blob
redis-cli HDEL ntt:extraction:in_progress d5c009f684531003e6307cd67983d5015697fa3822a1aceafa792ccd379e5a6e
```

**Execute:**
```bash
# Resume processing (273 remaining archives)
./bin/ntt-extractor.py run
```

**Expected Result:**
- Processes remaining 273 archives
- Skips d5c009f6... (already extracted)
- No crashes
- All archives processed or failed gracefully

### Test 3: Queue Init Filtering

**Purpose:** Verify queue initialization excludes already-extracted blobs

**Execute:**
```bash
# Reset queue with blobs that overlap with 100-archive test
./bin/ntt-extractor.py init --from-file /tmp/pilot-batch-100.txt --reset=True
./bin/ntt-extractor.py status
```

**Expected Result (Before Fix):**
- Queue size: 100 items (all blobs queued)

**Expected Result (After Fix):**
- Queue size: < 100 items (only pending blobs)
- Already-extracted blobs excluded from queue

### Test 4: Transaction Rollback on Error

**Purpose:** Verify worker handles extraction errors gracefully

**Execute:** Artificially trigger an error (e.g., corrupt archive, permission denied)

**Expected Result:**
- Error logged with full traceback
- Transaction rolled back
- Blob marked failed in both PostgreSQL and Redis
- Worker continues to next blob (no crash)

---

## Resolution

**Status:** TO BE COMPLETED

This section will be filled after implementing and testing the fixes.

### Commits

(To be added)

### Changes Made

(To be added)

### Testing Results

(To be added)

### Verification Commands

(To be added)

---

## Cleanup Required

After implementing fixes, manual cleanup needed for the stuck blob:

```bash
# Remove from Redis in_progress
redis-cli HDEL ntt:extraction:in_progress d5c009f684531003e6307cd67983d5015697fa3822a1aceafa792ccd379e5a6e

# Add to Redis PROCESSED (optional - will happen naturally on re-run)
redis-cli SADD ntt:extraction:processed d5c009f684531003e6307cd67983d5015697fa3822a1aceafa792ccd379e5a6e

# Decision on medium 86bdf2e99302b5b6:
# - KEEP: Medium is valid, contains correct 6 inodes
# - No action needed, extraction was successful
```

## Lessons Learned

1. **State Consistency:** Redis and PostgreSQL must stay synchronized. Queue resets should consider database state.

2. **Transaction Management:** Always rollback aborted transactions before attempting cleanup operations.

3. **Defense in Depth:** Multiple layers of duplicate detection needed:
   - Queue initialization (filter at source)
   - Queue pop (Redis PROCESSED set)
   - Pre-extraction check (database lookup)

4. **ON CONFLICT Tradeoffs:** `ON CONFLICT DO UPDATE` provides idempotency but masks duplicate operations. Consider whether early failure is preferable.

5. **Testing at Scale:** Small tests (10-100 archives) didn't reveal this bug. Larger tests (1000+) with overlapping data exposed the state mismatch.

## Related Issues

- Phase 5 Pilot Report: `docs/phase5-pilot-report.md`
- Redis Queue Implementation: `bin/ntt_extractor_queue.py`
- Medium Management: `bin/ntt_extractor_medium.py`
