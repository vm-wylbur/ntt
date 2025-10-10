<!-- completed: Priority 3.1 implemented with alternative schema (commit 6c963c7); actual implementation uses error_files array not diagnostic_events as proposed -->

<!--
Author: PB and Claude
Date: Tue 08 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/priorities-2-4-implementation-plan.md
-->

# Priorities 2-4 Implementation Plan

## Overview

This document details implementation approach for:
- **Priority 2**: Mount architecture (locking deferred, stale cleanup ✅ done)
- **Priority 3**: Problem recording system
- **Priority 4**: Health column management (deferred pending P3)

**Context:** After processing 1-2 img files through full pipeline (see img-processing-workflow-2025-10-08.md)

---

## Priority 2: Mount Architecture

### Task 2.1: Stale Loop Cleanup ✅ COMPLETE

**Status:** Implemented in ntt-mount-helper (2025-10-08)

**What was done:**
- Added `cleanup_stale_loops()` function at line 38
- Called before creating new loop device (line 91)
- Detects loops pointing to deleted inodes
- Automatically unmounts and detaches

**Testing:** Will be validated during img file processing

---

### Task 2.2: Per-Medium Mount Locking ⏸️ DEFERRED

**Status:** Designed but not implemented

**Decision:** Wait until we see mount races in production, OR until we start running parallel copiers

**Rationale:**
- Current workload is mostly serial (one medium at a time)
- Adding complexity before need increases risk
- Complete design exists in mount-arch-cleanups.md (lines 160-326)
- Can implement in 2-3 hours when needed

**Trigger conditions for implementation:**
- Start running >2 copier workers simultaneously
- Observe overmounts in `findmnt` output
- See multiple loop devices for same medium
- Kernel errors about mount races

**When we implement:**
1. Create `/var/lock/ntt/` directory
2. Add flock to `ensure_medium_mounted()` in copier.py
3. Implement double-check pattern (cache → lock → check → mount)
4. Add overmount detection helper
5. Add health check helper
6. Test with 10 parallel workers on same medium

---

## Priority 3: Problem Recording System

### Overview

Populate `medium.problems` JSONB column with diagnostic findings from copier.

**Schema status:** Column exists, all values currently NULL

**Goal:** Enable analytics on copy failures across all media

---

### Task 3.1: Implement Diagnostic Event Recording (Phase 4)

**Effort:** 2-3 hours
**Files:** `bin/ntt_copier_diagnostics.py`, `bin/ntt-copier.py`
**Priority:** HIGH (foundational for analytics)

**Implementation:**

#### Step 1: Add record_diagnostic_event() to DiagnosticService

**File:** `bin/ntt_copier_diagnostics.py`
**Add after line 206** (`_check_mount_status` method):

```python
def record_diagnostic_event(self, medium_hash: str, ino: int,
                            findings: dict, action_taken: str):
    """
    Record diagnostic event in medium.problems JSONB column.

    Args:
        medium_hash: Medium being processed
        ino: Inode that failed
        findings: dict from diagnose_at_checkpoint()
        action_taken: 'skipped', 'remounted', 'continuing', 'max_retries'
    """
    from datetime import datetime
    import json

    entry = {
        'ino': ino,
        'retry_count': findings['retry_count'],
        'checks': findings['checks_performed'],
        'action': action_taken,
        'timestamp': datetime.now().isoformat(),
        'worker_id': self.worker_id,
        'exception_type': findings.get('exception_type'),
        'exception_msg': findings.get('exception_msg', '')[:100]  # Truncate
    }

    try:
        with self.conn.cursor() as cur:
            # Append to diagnostic_events array in problems JSONB
            cur.execute("""
                UPDATE medium
                SET problems = COALESCE(problems, '{}'::jsonb) ||
                              jsonb_build_object(
                                  'diagnostic_events',
                                  COALESCE(problems->'diagnostic_events', '[]'::jsonb) || %s::jsonb
                              )
                WHERE medium_hash = %s
            """, (json.dumps(entry), medium_hash))
        self.conn.commit()

        logger.debug(f"Recorded diagnostic event: {action_taken} for ino={ino}")

    except Exception as e:
        logger.error(f"Failed to record diagnostic event: {e}")
        # Don't raise - diagnostic recording is best-effort
```

#### Step 2: Call record_diagnostic_event() from copier

**File:** `bin/ntt-copier.py`
**Location:** After diagnostic checkpoint decision (around line 660-683)

**Current code** (lines ~646-683):
```python
# DIAGNOSTIC SERVICE: Track failure and run diagnostics
retry_count = self.diagnostics.track_failure(
    inode_row['medium_hash'],
    inode_row['ino']
)

# At checkpoint (retry #10), run full diagnostic analysis
if retry_count == 10:
    findings = self.diagnostics.diagnose_at_checkpoint(
        inode_row['medium_hash'],
        inode_row['ino'],
        e
    )
    logger.warning(
        f"🔍 DIAGNOSTIC CHECKPOINT "
        f"ino={inode_row['ino']} "
        f"retry={retry_count} "
        f"findings={findings}"
    )

    # PHASE 2: Auto-skip if unrecoverable error detected
    if self.diagnostics.should_skip_permanently(findings):
        logger.warning(
            f"⏭️  SKIPPED ino={inode_row['ino']} "
            f"reason=DIAGNOSTIC_SKIP:BEYOND_EOF (unrecoverable)"
        )
        # Mark as skipped (similar to NON_FILE success pattern)
        results_by_inode[key] = None
        action_counts['diagnostic_skip'] = action_counts.get('diagnostic_skip', 0) + 1
        continue  # Skip to next inode
```

**Add after auto-skip block** (around line 669):
```python
    # PHASE 2: Auto-skip if unrecoverable error detected
    if self.diagnostics.should_skip_permanently(findings):
        action_taken = 'skipped'
        logger.warning(
            f"⏭️  SKIPPED ino={inode_row['ino']} "
            f"reason=DIAGNOSTIC_SKIP:BEYOND_EOF (unrecoverable)"
        )
        results_by_inode[key] = None
        action_counts['diagnostic_skip'] = action_counts.get('diagnostic_skip', 0) + 1

        # NEW: Record diagnostic event
        self.diagnostics.record_diagnostic_event(
            inode_row['medium_hash'],
            inode_row['ino'],
            findings,
            action_taken
        )

        continue  # Skip to next inode

    # NEW: If not skipped, record that we're continuing despite errors
    self.diagnostics.record_diagnostic_event(
        inode_row['medium_hash'],
        inode_row['ino'],
        findings,
        'continuing'
    )
```

**Add after max retries log** (around line 677):
```python
# Log when max retries approached (safety net)
if retry_count >= 50:
    logger.error(
        f"⚠️  MAX RETRIES REACHED "
        f"ino={inode_row['ino']} "
        f"retry={retry_count} "
        f"(marking as failed)"
    )

    # NEW: Record max retries event
    findings = {
        'retry_count': retry_count,
        'exception_type': error_type,
        'exception_msg': error_msg,
        'checks_performed': ['max_retries_exceeded']
    }
    self.diagnostics.record_diagnostic_event(
        inode_row['medium_hash'],
        inode_row['ino'],
        findings,
        'max_retries'
    )
```

#### Step 3: Query Interface

**Add to documentation** (copier-diagnostic-ideas.md or new queries.md):

```sql
-- See diagnostic events for a medium
SELECT
    medium_hash,
    medium_human,
    jsonb_array_length(problems->'diagnostic_events') as event_count,
    problems->'diagnostic_events'
FROM medium
WHERE problems->'diagnostic_events' IS NOT NULL;

-- Count events by action type
SELECT
    event->>'action' as action,
    COUNT(*) as count
FROM medium,
     jsonb_array_elements(problems->'diagnostic_events') as event
GROUP BY 1
ORDER BY 2 DESC;

-- Find media with BEYOND_EOF errors
SELECT
    medium_hash,
    medium_human,
    COUNT(*) as beyond_eof_count
FROM medium,
     jsonb_array_elements(problems->'diagnostic_events') as event
WHERE event->'checks' ? 'detected_beyond_eof'
   OR event->'checks' ? 'dmesg:beyond_eof'
GROUP BY 1, 2;

-- Show details of skipped inodes
SELECT
    medium_hash,
    event->>'ino' as ino,
    event->>'action' as action,
    event->>'retry_count' as retries,
    event->'checks' as checks,
    event->>'timestamp' as when
FROM medium,
     jsonb_array_elements(problems->'diagnostic_events') as event
WHERE event->>'action' = 'skipped'
ORDER BY medium_hash, (event->>'ino')::int;
```

**Testing:**
```bash
# After processing img file with errors, check:
psql -d copyjob -c "
  SELECT problems->'diagnostic_events'
  FROM medium
  WHERE medium_hash = '<hash_with_errors>'
"

# Should show array of events with ino, retry_count, checks, action
```

---

### Task 3.2: Copier Records Medium-Level Summaries

**Effort:** 1-2 hours
**Files:** `bin/ntt-copier.py`
**Priority:** MEDIUM (nice-to-have analytics)

**Goal:** Record medium-level summaries in `medium.problems`

**When to record:**
1. First BEYOND_EOF error encountered
2. High error rate detected (>10% of inodes failing)
3. Mount issues detected

**Implementation:**

#### Add helper method to CopyWorker:

```python
def record_medium_problem(self, problem_type: str, details: dict):
    """
    Record medium-level problem in database.

    Args:
        problem_type: 'beyond_eof_detected', 'high_error_rate', 'mount_unstable'
        details: dict with problem-specific metadata
    """
    import json
    from datetime import datetime

    try:
        with self.conn.cursor() as cur:
            problem_entry = {
                problem_type: True,
                **details,
                'detected_at': datetime.now().isoformat(),
                'worker_id': self.worker_id
            }

            cur.execute("""
                UPDATE medium
                SET problems = COALESCE(problems, '{}'::jsonb) || %s::jsonb
                WHERE medium_hash = %s
            """, (json.dumps(problem_entry), self.medium_hash))

        self.conn.commit()
        logger.info(f"Recorded medium problem: {problem_type}")

    except Exception as e:
        logger.error(f"Failed to record medium problem: {e}")
```

#### Call from batch processing:

```python
# In process_batch(), after processing all inodes:

# Check if first BEYOND_EOF error
if 'diagnostic_skip' in action_counts and action_counts['diagnostic_skip'] > 0:
    # Check if this is first occurrence
    with self.conn.cursor() as cur:
        cur.execute("""
            SELECT problems->'beyond_eof_detected' IS NOT NULL as already_recorded
            FROM medium WHERE medium_hash = %s
        """, (self.medium_hash,))
        result = cur.fetchone()

        if not result or not result['already_recorded']:
            self.record_medium_problem('beyond_eof_detected', {
                'first_ino': '<ino from this batch>',
                'skip_count': action_counts['diagnostic_skip']
            })

# Check for high error rate
error_rate = self.stats['errors'] / max(self.processed_count, 1)
if error_rate > 0.10 and self.processed_count > 100:
    self.record_medium_problem('high_error_rate', {
        'error_rate': round(error_rate, 3),
        'errors': self.stats['errors'],
        'processed': self.processed_count
    })
```

---

## Priority 4: Health Column Management

### Task 4.1: Orchestrator Populates medium.health ⏸️ DEFERRED

**Status:** Deferred - `medium.problems` provides richer information

**Decision:** Use `medium.problems` JSONB for diagnostics, keep `health` for simple status if needed later

**Rationale:**
- `problems` can store detailed diagnostic events
- `health` would be redundant with `problems->>'beyond_eof_detected'`
- Orchestrator already logs ddrescue results to files
- Can derive health from problems if needed

**If we implement later:**
- Parse ddrescue log after completion
- Set health based on recovery %:
  - 100% → 'ok'
  - ≥95% → 'incomplete'
  - ≥50% → 'corrupt'
  - <50% → 'failed'

---

### Task 4.2: Copier Checks Health Before Mounting ⏸️ DEFERRED

**Status:** Depends on 4.1, which is deferred

**Alternative:** Check `medium.problems` before mounting:

```python
# In ensure_medium_mounted(), after acquiring lock:

# Check if medium has known problems
with self.conn.cursor() as cur:
    cur.execute("""
        SELECT problems
        FROM medium
        WHERE medium_hash = %s
    """, (medium_hash,))
    result = cur.fetchone()

    if result and result['problems']:
        problems = result['problems']

        # Refuse to mount if fundamentally broken
        if problems.get('beyond_eof_detected'):
            raise Exception(
                f"Medium {medium_hash} has BEYOND_EOF errors, refusing to mount. "
                f"Mark remaining inodes as EXCLUDED."
            )

        # Warn but allow if high error rate
        if problems.get('high_error_rate'):
            logger.warning(
                f"Medium {medium_hash} has high error rate: {problems['high_error_rate']}"
            )
```

---

## Implementation Order

### Week 1: Complete and Test Priority 1
- ✅ Stale loop cleanup in mount-helper (DONE)
- ✅ Update docs (DONE)
- [ ] Process 1-2 img files through pipeline
- [ ] Validate all improvements working

### Week 2: Priority 3 Core
- [ ] Task 3.1: Diagnostic event recording
- [ ] Test with img file that has errors
- [ ] Verify JSONB queries work
- [ ] Document query patterns

### Week 3: Priority 3 Enhancement
- [ ] Task 3.2: Medium-level summaries
- [ ] Add helper methods to copier
- [ ] Test on multiple media
- [ ] Analytics queries

### Future (As Needed):
- [ ] Priority 2.2: Mount locking (when parallel workers needed)
- [ ] Priority 4: Health column (if problems JSONB insufficient)

---

## Testing Strategy

### Test 3.1: Diagnostic Event Recording

**Setup:**
Find or create medium with BEYOND_EOF errors (partial ddrescue recovery)

**Test:**
```bash
# Run copier on problematic medium
sudo -E bin/ntt-copier.py --medium-hash <hash_with_errors> --limit 100

# Check events recorded
psql -d copyjob -c "
  SELECT jsonb_pretty(problems->'diagnostic_events')
  FROM medium
  WHERE medium_hash = '<hash_with_errors>'
"

# Should show array of events with:
# - ino numbers
# - retry_count = 10
# - checks = ['detected_beyond_eof', ...]
# - action = 'skipped' or 'continuing'
# - timestamps
```

**Success criteria:**
- Events appear in database
- One event per inode that hit checkpoint
- Action matches behavior (skipped inodes have action='skipped')
- Timestamps are recent

---

### Test 3.2: Medium-Level Summaries

**Test:**
```bash
# Process medium with mixed results
sudo -E bin/ntt-copier.py --medium-hash <hash> --limit 1000

# Check summary
psql -d copyjob -c "
  SELECT jsonb_pretty(problems)
  FROM medium
  WHERE medium_hash = '<hash>'
"

# Should show:
# - beyond_eof_detected: true (if any BEYOND_EOF errors)
# - first_ino: <inode number>
# - skip_count: <number skipped>
# - high_error_rate: true (if >10% failed)
# - error_rate: 0.15 (example)
```

**Success criteria:**
- Summary flags set correctly
- Metadata accurate (counts, rates)
- Only recorded once (not duplicate entries)

---

## Success Metrics

**By end of Week 2:**
- [ ] Diagnostic events recorded for all problem inodes
- [ ] Can query which media have BEYOND_EOF issues
- [ ] Can count events by action type
- [ ] Event timestamps useful for debugging

**By end of Week 3:**
- [ ] Medium-level summaries populated
- [ ] High error rate detection working
- [ ] Analytics queries provide insights
- [ ] Can identify problematic media quickly

---

## Rollback Plan

**If diagnostic recording breaks copier:**
- Remove `record_diagnostic_event()` calls
- Copier continues without recording (no data loss)
- Diagnostic service Phase 2 (auto-skip) still works

**If JSONB queries slow:**
- Add index: `CREATE INDEX ON medium USING gin (problems);`
- Or query specific paths: `problems->'diagnostic_events'`

**If problems column gets too large:**
- Limit events: Only record first N per medium
- Or archive old events: Move to separate table

---

## Open Questions

**Q1:** Should we limit diagnostic_events array size?
- **Concern:** JSONB column could grow unbounded
- **Options:**
  - A) No limit (trust that most media have <100 problem inodes)
  - B) Limit to first 50 events per medium
  - C) Rotate events (keep only recent 100)
- **Recommendation:** Start with no limit, monitor size, add limit if needed

**Q2:** Should Phase 3 auto-remount be before or after problem recording?
- **Current plan:** After problem recording (safer)
- **Alternative:** Before (could reduce problem count if remount fixes issues)
- **Recommendation:** Keep current plan, implement Phase 3 only after mount locking

**Q3:** Do we need health column at all?
- **Pros:** Simple enum for quick filtering
- **Cons:** Redundant with problems JSONB
- **Recommendation:** Keep column but don't populate yet, use problems for now

---

## References

- **Workplan**: `docs/workplan-2025-10-08.md`
- **Diagnostic design**: `docs/copier-diagnostic-ideas.md`
- **Mount cleanup**: `docs/mount-arch-cleanups.md`
- **Img processing**: `docs/img-processing-workflow-2025-10-08.md`

---

**Status:** Ready for implementation after img file processing complete
**Created:** 2025-10-08
**Next review:** After processing 1-2 img files
