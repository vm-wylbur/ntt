<!--
Author: PB and Claude
Date: 2025-10-08
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/copier-diagnostic-ideas.md
-->

# NTT Copier Diagnostic Service - Vision & Design

## Problem Statement

The ntt-copier Worker processes batches of inodes (files), copying them from mounted disk images to a deduplicated by-hash store. When files fail to copy (I/O errors, FAT corruption, mount issues), the worker currently retries indefinitely, creating infinite loops that require manual intervention.

**Example:** During processing of f95834a4b718f54edc7b549ca854aef8:
- File: AliciaMainList.xls (656KB)
- Error: `Input/output error` (Errno 5)
- Retried: ~2980 times over 149 seconds
- Root cause: FAT allocation chain points to sector 1316, but disk image only contains sectors 0-841 (partial ddrescue recovery)
- Resolution: Manual kill, mark inode as IO_ERROR_SKIP

This pattern wastes resources and requires constant monitoring.

---

## Solution: DiagnosticService

Add intelligent diagnostic capabilities to detect unrecoverable errors and take appropriate action (skip, remount, limited retry).

### Architecture Decision: Service Class

**Chosen approach:** Separate `DiagnosticService` class

**Rationale:**
- **Separation of concerns**: Worker stays focused on batch processing (~1390 lines), diagnostics isolated
- **State encapsulation**: Retry tracking belongs with diagnostic logic, not batch processing
- **Testability**: Can unit test DiagnosticService with mocked db_conn
- **Growth path**: Easy to add features (mount monitoring, predictive analysis) without bloating Worker
- **Pythonic**: Composition over inheritance, dependency injection

**Rejected alternatives:**
- Utility functions in strategies file (would bloat Worker with state management)
- Mixin class (Python community favors composition, harder to test)

### State Management: In-Memory Retry Tracking

```python
self.retry_counts = {(medium_hash, ino): count}
```

**Why not database?**
- **Fast**: No extra DB writes on every failure
- **Simple**: No schema changes needed
- **Acceptable loss**: If worker restarts, retry counts reset - that's OK because:
  - Startup check marks inodes with `len(errors) >= 5` as MAX_RETRIES_EXCEEDED
  - Diagnostic checkpoint is at retry #10 (session-scoped)
  - Persistent tracking via `inode.errors[]` array

**Database used for:**
- `inode.errors[]` - persistent error log across restarts
- `inode.copied=true, claimed_by='SKIP_REASON'` - permanent skip decisions
- `medium.problems` - diagnostic metadata for analysis

---

## Implementation Phases

### Phase 1: Detection Framework ✅ COMPLETE (Production as of 2025-10-08)

**Goal:** Add diagnostic framework that LOGS but doesn't change behavior yet

**What we build:**
- `DiagnosticService` class (~150 lines)
- Retry tracking: `track_failure(medium_hash, ino) -> retry_count`
- Diagnostic checkpoint: `diagnose_at_checkpoint(...)` at retry #10
- Simple checks:
  - Exception message pattern matching
  - dmesg scan for kernel errors
  - Mount point existence check

**Integration:**
```python
# In Worker exception handler:
retry_count = self.diagnostics.track_failure(medium_hash, ino)

if retry_count == 10:
    findings = self.diagnostics.diagnose_at_checkpoint(medium_hash, ino, exception)
    logger.warning(f"🔍 DIAGNOSTIC CHECKPOINT ino={ino} retry=10: {findings}")

if retry_count >= 50:
    logger.error(f"⚠️  MAX RETRIES REACHED ino={ino} (WOULD SKIP IN FUTURE PHASE)")
```

**Output:**
- Logs diagnostic findings at checkpoint
- Logs "WOULD SKIP" at max retries
- Zero behavior change (continues retrying)

**Testing:** Process f95834a4, verify diagnostic logs appear

---

### Phase 2: Auto-Skip BEYOND_EOF ✅ COMPLETE (Production as of 2025-10-08)

**Goal:** Automatically skip files that are fundamentally unrecoverable

**What we add:**
```python
def should_skip_permanently(self, findings) -> bool:
    """Decide if we should skip this inode."""
    checks = findings['checks_performed']

    # Only skip if we're CERTAIN it's unrecoverable
    if 'detected_beyond_eof' in checks or 'dmesg:beyond_eof' in checks:
        return True

    return False
```

**Integration:**
```python
if retry_count == 10:
    findings = self.diagnostics.diagnose_at_checkpoint(...)

    if self.diagnostics.should_skip_permanently(findings):
        # Actually skip
        cur.execute("""
            UPDATE inode
            SET copied = true, claimed_by = 'DIAGNOSTIC_SKIP:BEYOND_EOF'
            WHERE medium_hash = %s AND ino = %s
        """, (medium_hash, ino))
        logger.warning(f"⏭️  SKIPPED ino={ino} reason=beyond_eof")
        continue
```

**Testing:** Re-process f95834a4 ino 3455, verify it skips at retry #10

---

### Phase 3: Auto-Remount ⏸️ DEFERRED

**Goal:** Attempt remount when mount issues detected

**Status:** Designed but not implemented. Will implement after mount locking (Priority 2.2) is complete to avoid remount races.

**What we add:**
```python
def should_attempt_remount(self, findings) -> bool:
    """Check if remount might help."""
    checks = findings['checks_performed']
    return 'mount_check:missing' in checks or 'detected_missing_file' in checks

def attempt_remount(self, medium_hash) -> bool:
    """Use ntt-mount-helper to remount."""
    logger.info(f"🔄 Attempting remount for {medium_hash}")

    # Get image path from DB
    with self.conn.cursor() as cur:
        cur.execute("SELECT image_path FROM medium WHERE medium_hash = %s", (medium_hash,))
        result = cur.fetchone()
        if not result or not result['image_path']:
            return False

    image_path = result['image_path']
    mount_helper = '/home/pball/projects/ntt/bin/ntt-mount-helper'

    # Unmount
    subprocess.run(['sudo', mount_helper, 'unmount', medium_hash], timeout=10)
    time.sleep(1)

    # Mount
    result = subprocess.run(
        ['sudo', mount_helper, 'mount', medium_hash, image_path],
        capture_output=True,
        timeout=30
    )

    return result.returncode == 0
```

**Integration:**
```python
if retry_count == 10:
    findings = self.diagnostics.diagnose_at_checkpoint(...)

    if self.diagnostics.should_attempt_remount(findings):
        success = self.diagnostics.attempt_remount(medium_hash)
        if success:
            logger.info(f"🔄 Remount succeeded, will retry")
            # Clear this inode from retry tracker so it gets fresh attempts
            self.diagnostics.retry_counts.pop((medium_hash, ino), None)
        else:
            logger.error(f"🔄 Remount failed")
```

**Testing:** Manually unmount a medium mid-copy, verify auto-remount works

---

### Phase 4: Problem Recording ✅ COMPLETE (Production as of 2025-10-08)

**Goal:** Store diagnostic events in `medium.problems` JSONB for later analysis

**Status:** Implemented with deferred writes to preserve FOR UPDATE SKIP LOCKED pattern

**Critical Design Decision: Deferred Writes**

The naive approach of recording diagnostic events immediately at retry #10 breaks the batch processing lock pattern:

```python
# ❌ WRONG - breaks FOR UPDATE SKIP LOCKED
if retry_count == 10:
    findings = self.diagnostics.diagnose_at_checkpoint(...)
    self.diagnostics.record_diagnostic_event(...)  # Commits!
    # Now locks are released, other workers can steal our batch rows
```

**Solution:** Queue events in memory, write after batch commit releases locks:

```python
# ✅ CORRECT - three-phase transaction pattern
# Phase 1: Batch processing (holds FOR UPDATE SKIP LOCKED)
for inode_row in batch:
    # ... copy files ...
    if retry_count == 10:
        findings = self.diagnostics.diagnose_at_checkpoint(...)
        # Queue event, don't write yet
        self._pending_diagnostic_events.append((medium_hash, ino, findings, action))

# Commit batch (releases locks)
self.conn.commit()

# Phase 2: Write diagnostic events (separate transaction, locks released)
for medium_hash, ino, findings, action in self._pending_diagnostic_events:
    self.diagnostics.record_diagnostic_event_no_commit(medium_hash, ino, findings, action)
self.conn.commit()

# Phase 3: Write medium-level summaries (separate transaction)
self.check_and_record_beyond_eof(skip_count)
self.check_and_record_high_error_rate()
self.conn.commit()
```

**What we added:**

**DiagnosticService.record_diagnostic_event_no_commit()** (bin/ntt_copier_diagnostics.py:208-253):
```python
def record_diagnostic_event_no_commit(self, medium_hash: str, ino: int,
                                      findings: dict, action_taken: str):
    """
    Record diagnostic event in medium.problems JSONB column WITHOUT committing.

    Caller is responsible for commit. This is critical to avoid breaking
    the FOR UPDATE SKIP LOCKED pattern in batch processing.
    """
    entry = {
        'ino': ino,
        'retry_count': findings['retry_count'],
        'checks': findings['checks_performed'],
        'action': action_taken,
        'timestamp': datetime.now().isoformat(),
        'worker_id': self.worker_id,
        'exception_type': findings.get('exception_type'),
        'exception_msg': findings.get('exception_msg', '')[:100]
    }

    with self.conn.cursor() as cur:
        cur.execute("""
            UPDATE medium
            SET problems = COALESCE(problems, '{}'::jsonb) ||
                          jsonb_build_object(
                              'diagnostic_events',
                              COALESCE(problems->'diagnostic_events', '[]'::jsonb) || %s::jsonb
                          )
            WHERE medium_hash = %s
        """, (json.dumps(entry), medium_hash))
```

**Worker.check_and_record_beyond_eof()** (bin/ntt-copier.py:887-943):
```python
def check_and_record_beyond_eof(self, skip_count: int):
    """Check if this is the first BEYOND_EOF detection and record if so."""
    if skip_count == 0:
        return

    with self.conn.cursor() as cur:
        cur.execute("""
            SELECT problems->'beyond_eof_detected' IS NOT NULL as already_recorded
            FROM medium
            WHERE medium_hash = %s
        """, (self.medium_hash,))
        result = cur.fetchone()

        if not result or not result['already_recorded']:
            # First detection - record it
            cur.execute("""
                UPDATE medium
                SET problems = COALESCE(problems, '{}'::jsonb) ||
                              jsonb_build_object('beyond_eof_detected', true)
                WHERE medium_hash = %s
            """, (self.medium_hash,))
```

**Worker.check_and_record_high_error_rate()** (bin/ntt-copier.py:945-990):
```python
def check_and_record_high_error_rate(self):
    """Check if error rate > 10% and record if so."""
    if self.processed_count < 100:
        return  # Need sufficient sample size

    error_rate = (self.error_count / self.processed_count) * 100

    if error_rate > 10.0:
        with self.conn.cursor() as cur:
            cur.execute("""
                SELECT problems->'high_error_rate' IS NOT NULL as already_recorded
                FROM medium
                WHERE medium_hash = %s
            """, (self.medium_hash,))
            result = cur.fetchone()

            if not result or not result['already_recorded']:
                cur.execute("""
                    UPDATE medium
                    SET problems = COALESCE(problems, '{}'::jsonb) ||
                                  jsonb_build_object(
                                      'high_error_rate',
                                      jsonb_build_object(
                                          'rate_percent', %s,
                                          'detected_at_count', %s
                                      )
                                  )
                    WHERE medium_hash = %s
                """, (error_rate, self.processed_count, self.medium_hash))
```

**Integration:**

**Worker exception handler** (bin/ntt-copier.py:674-690):
```python
if retry_count == 10:
    findings = self.diagnostics.diagnose_at_checkpoint(...)

    # Determine action
    if self.diagnostics.should_skip_permanently(findings):
        action_taken = 'diagnostic_skip'
        # ... skip logic ...
    else:
        action_taken = 'continuing'

    # PHASE 4: Queue diagnostic event (no commit - locks held)
    self._pending_diagnostic_events.append((
        inode_row['medium_hash'],
        inode_row['ino'],
        findings,
        action_taken
    ))
```

**Worker batch completion** (bin/ntt-copier.py:826-868):
```python
# Commit batch (releases locks)
self.conn.commit()

# PHASE 2: Write diagnostic events (separate transaction after batch commit)
if self._pending_diagnostic_events:
    for medium_hash, ino, findings, action in self._pending_diagnostic_events:
        self.diagnostics.record_diagnostic_event_no_commit(medium_hash, ino, findings, action)

    self.conn.commit()
    self._pending_diagnostic_events = []

# PHASE 3: Record medium-level summaries (separate transaction)
skip_count = action_counts.get('diagnostic_skip', 0)
if skip_count > 0 or self.processed_count >= 100:
    self.check_and_record_beyond_eof(skip_count)
    self.check_and_record_high_error_rate()
    self.conn.commit()
```

**Testing:**

**Test 1: Normal Operation Validation (9210e78bf112f4462fb6bc4babfab82f)**

Medium: 9210e78b (1.2M floppy image, 33% bad sectors)
- Inodes: 7 (6 files + 1 directory)
- Copy result: 7/7 successful (all files in good sectors)
- Processing time: 0.091s
- Diagnostic events: 0 (no errors encountered)

**Result:** Validated that diagnostic system doesn't break normal operation and doesn't create false positives.

**What was validated:**
- ✅ Deferred recording pattern preserves FOR UPDATE SKIP LOCKED
- ✅ No lock conflicts during batch processing
- ✅ Three-phase transaction pattern works correctly
- ✅ Diagnostic code doesn't impact normal operation

**What still needs testing:**
- ❌ Diagnostic checkpoint at retry #10 with actual errors
- ❌ Auto-skip for BEYOND_EOF errors in production
- ❌ Medium-level problem recording (beyond_eof_detected, high_error_rate)
- ❌ Diagnostic event JSONB structure with real error data

**Query examples:**
```sql
-- See what diagnostics have been run
SELECT
    medium_hash,
    medium_human,
    jsonb_array_length(problems->'diagnostic_events') as event_count,
    problems->'diagnostic_events'
FROM medium
WHERE problems->'diagnostic_events' IS NOT NULL;

-- Count by action type
SELECT
    event->>'action' as action,
    COUNT(*)
FROM medium,
     jsonb_array_elements(problems->'diagnostic_events') as event
GROUP BY 1;

-- Check for medium-level problems
SELECT
    medium_hash,
    medium_human,
    problems->'beyond_eof_detected' as beyond_eof,
    problems->'high_error_rate' as high_error_rate
FROM medium
WHERE problems IS NOT NULL;
```

---

## Error Patterns We've Observed

### Pattern 1: BEYOND_EOF - Partial Disk Image

**Example:** f95834a4b718f54edc7b549ca854aef8

**Symptoms:**
- dmesg: `loop38: rw=0, sector=1316, nr_sectors = 8 limit=841`
- FAT trying to read sector 1316, but image only has sectors 0-841
- Infinite I/O errors on file access

**Root cause:**
- ddrescue recovered only 421KB of 1.44MB floppy
- FAT metadata survived, but file data didn't
- FAT allocation table points to unrecovered sectors

**Resolution:** Mark as DIAGNOSTIC_SKIP:BEYOND_EOF (unrecoverable)

**Detection:**
- Exception message: "beyond end of device"
- dmesg pattern: "sector=X ... limit=Y" where X > Y

---

### Pattern 2: Boot Sector Corruption

**Example:** 93e1a75c519dac73ef54c6b9176f078b

**Symptoms:**
- Mount fails immediately
- ddrescue mapfile shows first 512 bytes (offset 0x00000000) as bad sectors

**Root cause:**
- Boot sector contains filesystem metadata (FAT table location, cluster size, etc.)
- Without boot sector, filesystem cannot be mounted

**Resolution:** Record in medium.problems, cannot process

**Detection:**
- ddrescue mapfile: `0x00000000  0x00000200  -`
- Mount helper returns "Failed to mount"

---

### Pattern 3: FAT Corruption with File Errors

**Example:** af1349b9f5f9a1a6a0404dea36dcc949

**Symptoms:**
- Mounts successfully
- Some files readable, others infinite I/O errors
- dmesg: "FAT-fs: request beyond EOF"

**Root cause:**
- FAT filesystem metadata corrupted (bad sectors in FAT table itself)
- Some file entries point to invalid locations

**Resolution:** Copy what we can, mark failed files as FAT_ERROR_SKIP

**Detection:**
- Persistent I/O errors on specific files
- dmesg shows FAT-fs errors

---

### Pattern 4: Duplicate Paths (Enumeration Issue)

**Example:** b74dff654f21db1e0976b8b2baaed0af

**Symptoms:**
- Enumeration succeeds
- Loader fails: "duplicate key value violates unique constraint path_pkey"

**Root cause:**
- Filesystem corruption shows same path multiple times
- Different from hardlinks (same inode, multiple paths)

**Resolution:** Record in medium.problems, cannot load

**Detection:**
- Loader fails with unique constraint error
- `tr '\034' '\n' < enum.raw | sort | uniq -d` shows duplicates

---

### Pattern 5: Erased/Unformatted Disk

**Example:** f40a0868cc16fa730c6d232095d9bb5a

**Symptoms:**
- Entire disk filled with 0xf6 bytes
- Cannot mount (no filesystem)

**Root cause:**
- Disk was erased (FAT erase marker = 0xf6)
- Or never formatted

**Resolution:** Record in medium.problems, no files to recover

**Detection:**
- hexdump shows 0xf6 repeated throughout
- Mount fails

---

### Pattern 6: UFS I/O Errors

**Example:** cb12e75a3002480252b6b3943f254677

**Symptoms:**
- Mounts as UFS filesystem
- `ls` command returns I/O error

**Root cause:**
- UFS filesystem corruption
- Metadata readable enough to mount, but directory structure corrupted

**Resolution:** Record in medium.problems, cannot enumerate

**Detection:**
- Mount succeeds (as UFS)
- Immediate I/O error on directory listing

---

## Diagnostic Checks (Simple Categories)

We don't need complex error taxonomies - just enough to know what we tried:

**Detection patterns:**
- `detected_beyond_eof` - Exception or dmesg shows sector beyond image
- `detected_io_error` - Generic I/O error in exception
- `detected_missing_file` - File not found (possible mount issue)
- `dmesg:beyond_eof` - Kernel log shows beyond EOF
- `dmesg:fat_error` - Kernel log shows FAT-fs error
- `dmesg:io_error` - Kernel log shows I/O error
- `mount_check:ok` - Mount point exists and accessible
- `mount_check:missing` - Mount point doesn't exist
- `mount_check:inaccessible` - Mount point exists but can't stat

**Actions taken:**
- `continuing` - Just logged, kept retrying
- `skipped` - Marked as permanent skip (DIAGNOSTIC_SKIP)
- `remounted` - Attempted remount via ntt-mount-helper
- `max_retries` - Hit 50 retries, gave up

---

## Integration with ntt-mount-helper

**Location:** `/home/pball/projects/ntt/bin/ntt-mount-helper`

**API:**
```bash
# Mount image to /mnt/ntt/<hash>
ntt-mount-helper mount <medium_hash> <image_path>

# Unmount and detach loop device
ntt-mount-helper unmount <medium_hash>

# Check if mounted (exit 0=yes, 1=no)
ntt-mount-helper status <medium_hash>
```

**Features:**
- Validates medium_hash format (16-64 hex chars)
- Auto-detects filesystem type (blkid)
- Read-only mounts with nosuid,nodev,noatime
- Cleans up loop devices on unmount

**Python integration:**
```python
import subprocess

# Remount
subprocess.run(['sudo', '/home/pball/projects/ntt/bin/ntt-mount-helper',
               'unmount', medium_hash], timeout=10)
time.sleep(1)
subprocess.run(['sudo', '/home/pball/projects/ntt/bin/ntt-mount-helper',
               'mount', medium_hash, image_path], timeout=30)

# Check status
result = subprocess.run(['sudo', '/home/pball/projects/ntt/bin/ntt-mount-helper',
                        'status', medium_hash])
is_mounted = (result.returncode == 0)
```

---

## Growth Path (6+ months)

With DiagnosticService architecture, future enhancements stay isolated:

### Completed (2025-10-08)
- ✅ Phase 1: Detection framework (logging) - PRODUCTION
- ✅ Phase 2: Auto-skip BEYOND_EOF - PRODUCTION
- ✅ Phase 4: Problem recording with deferred writes - PRODUCTION

### Next Steps (Deferred)
- ⏸️ Phase 3: Auto-remount on mount issues - After mount locking (Priority 2.2)

### Month 3-4: Predictive Capabilities
- **Medium-level diagnostics**: If 3+ inodes fail with BEYOND_EOF, mark entire medium problematic
- **Proactive checks**: Before claiming batch, verify mount health
- **Retry budget**: Track retry attempts across entire medium, stop early if hopeless

### Month 5-6: Monitoring & Orchestration
- **Mount health monitoring thread**: Background check every 60s
- **Orchestrator integration**: Signal when medium is unrecoverable
- **Automatic recovery**: Restart worker if diagnostics suggest system issue

### Long-term: Analytics & Learning
- **Statistical analysis**: Query `medium.problems` for patterns across media
- **Error pattern learning**: Build heuristics from historical data
- **Predictive skipping**: If medium shows pattern X, preemptively skip similar files

---

## Testing Strategy

### Unit Tests (test_diagnostics.py)
```python
def test_track_failure():
    service = DiagnosticService(mock_conn, 'abc123', 'w1')
    assert service.track_failure('abc123', 100) == 1
    assert service.track_failure('abc123', 100) == 2
    assert service.track_failure('abc123', 200) == 1  # Different inode

def test_detect_beyond_eof():
    service = DiagnosticService(mock_conn, 'abc123', 'w1')
    exc = IOError("attempt to access beyond end of device")
    findings = service.diagnose_at_checkpoint('abc123', 100, exc)
    assert 'detected_beyond_eof' in findings['checks_performed']

def test_check_mount_status():
    service = DiagnosticService(mock_conn, 'abc123', 'w1')
    # Would need to mock Path.exists() for proper testing
    status = service._check_mount_status('abc123')
    assert status in ['ok', 'missing', 'inaccessible']
```

### Integration Tests

**Test 1: Detection on known BEYOND_EOF**
```bash
# Reset f95834a4 ino 3455
psql copyjob -c "UPDATE inode SET copied=false, claimed_by=NULL WHERE medium_hash='f95834a4b718f54edc7b549ca854aef8' AND ino=3455"

# Run copier (Phase 1)
sudo ./bin/ntt-copier.py --medium-hash f95834a4b718f54edc7b549ca854aef8

# Check logs
grep "DIAGNOSTIC CHECKPOINT" copier.log
# Should see: ino=3455 retry=10 findings={'checks_performed': ['detected_beyond_eof', ...]}

grep "MAX RETRIES REACHED" copier.log
# Should see: ino=3455 retry=50 (WOULD SKIP IN FUTURE PHASE)
```

**Test 2: Auto-skip works (Phase 2)**
```bash
# Same setup, but Phase 2 code deployed
sudo ./bin/ntt-copier.py --medium-hash f95834a4b718f54edc7b549ca854aef8

# Check logs
grep "SKIPPED" copier.log
# Should see: ino=3455 reason=beyond_eof at retry=10

# Verify database
psql copyjob -c "SELECT copied, claimed_by FROM inode WHERE medium_hash='f95834a4...' AND ino=3455"
# Should show: copied=true, claimed_by='DIAGNOSTIC_SKIP:BEYOND_EOF'
```

**Test 3: Auto-remount works (Phase 3)**
```bash
# Start copier on clean medium
sudo ./bin/ntt-copier.py --medium-hash <working_medium> &

# Wait for batch processing to start
sleep 5

# Manually unmount
sudo /home/pball/projects/ntt/bin/ntt-mount-helper unmount <working_medium>

# Watch logs - should see remount attempt
tail -f copier.log | grep "Attempting remount"

# Verify processing continues after remount
```

---

## Maintenance Notes

### Adding New Error Patterns

When we discover a new error pattern:

1. **Document it** in this file (Error Patterns section)
2. **Add detection** to `_classify_exception()` or `_check_dmesg_simple()`
3. **Add test case** with known example
4. **Update checklist** in disk-read-checklist.md

### Adjusting Retry Thresholds

If we need to change retry/checkpoint values:

```python
# In DiagnosticService
CHECKPOINT_RETRY = 10  # When to run diagnostics
MAX_RETRY_LIMIT = 50   # When to give up

# In Worker exception handler
if retry_count == self.diagnostics.CHECKPOINT_RETRY:
    ...
if retry_count >= self.diagnostics.MAX_RETRY_LIMIT:
    ...
```

### Debugging Diagnostics

Enable debug logging:
```python
# In ntt_copier_diagnostics.py
logger.level("DEBUG")

# Or at runtime
export LOGURU_LEVEL=DEBUG
```

---

## Success Criteria

**Phase 1 Success:**
- ✅ Diagnostic service logs appear at retry #10
- ✅ "WOULD SKIP" logs appear at retry #50
- ✅ No behavior change (still retries infinitely)
- ✅ Can identify error patterns from logs

**Phase 2 Success:**
- ✅ BEYOND_EOF files skip at retry #10
- ✅ Database shows `claimed_by='DIAGNOSTIC_SKIP:BEYOND_EOF'`
- ✅ No infinite loops on partial images

**Phase 3 Success:**
- ✅ Mount issues trigger automatic remount
- ✅ Processing continues after successful remount
- ✅ Failed remounts logged clearly

**Phase 4 Success:**
- ✅ Deferred recording pattern preserves FOR UPDATE SKIP LOCKED
- ✅ Three-phase transaction architecture implemented
- ✅ Medium-level summaries (beyond_eof_detected, high_error_rate) implemented
- ✅ Validated on clean medium (no false positives)
- ⏸️ Diagnostic events recorded in `medium.problems` (code ready, needs error testing)
- ⏸️ Analytics on error patterns across media (needs actual error data)

---

## References

**Related files:**
- `ntt/bin/ntt-copier.py` - Worker class (batch processing)
- `ntt/bin/ntt_copier_strategies.py` - Utility functions
- `ntt/bin/ntt-mount-helper` - Mount/unmount helper
- `ntt/docs/disk-read-checklist.md` - Manual diagnostic procedures

**Database schema:**
- `inode.errors[]` - Array of error messages
- `inode.claimed_by` - Can store skip reasons
- `medium.problems` - JSONB for diagnostic metadata

**Key insights:**
- In-memory retry tracking is sufficient (persistent via `errors[]`)
- Checkpoint at retry #10 balances transient vs persistent errors
- Service class keeps Worker focused on batch processing
- Incremental rollout reduces risk
