<!--
Author: PB and Claude
Date: Thu 10 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/ROLES.md
-->

# NTT Multi-Claude Processing Roles

**Read first:** `CLAUDE.md` for general AI collaboration guidelines (commit approval, git workflow, file headers, communication style, etc.)

**This document:** Role-specific responsibilities for the three-Claude NTT media processing workflow

**All Claudes may read all files.** Write permissions and responsibilities defined below.

**Version:** 2025-10-10
**Maintainer:** PB

---

## Overview

Three Claudes work together to process disk images through the NTT pipeline:

- **prox-claude** (Process Orchestrator): Runs commands, monitors execution, files bugs, verifies fixes
- **dev-claude** (Developer): Reads code, fixes bugs, improves implementation
- **metrics-claude** (Analyst): Collects metrics, identifies patterns, generates reports

**Communication:** File-based via `bugs/`, `metrics/`, and `processing-queue.md`

**Workflow reference:** `media-processing-plan-2025-10-10.md`

---

## prox-claude (Process Orchestrator & Monitor)

**Primary function:** Execute NTT pipeline, monitor process health, handle failures

### Responsibilities

#### 1. Media Selection (Always Fresh Evaluation)

**IMPORTANT:** `processing-queue.md` is a log, NOT a plan. Always re-evaluate from database.

**On each iteration:**

```sql
-- Query database for candidates
SELECT medium_hash, medium_human
FROM medium
WHERE enum_done IS NULL
  AND copy_done IS NULL
  AND problems IS NULL
ORDER BY medium_human;
```

**For each candidate:**
- Check ddrescue status: `ps aux | grep ddrescue | grep $HASH`
- Check IMG file size: `ls -lh /data/fast/img/${HASH}.img`
- Check mount status: `mount | grep $HASH`
- Check recovery: `sudo grep rescued /data/fast/img/${HASH}.map`

**Apply phase criteria from media-processing-plan.md:**
- Phase 1: 1M-100G, >95% recovered, prefer mounted
- Phase 2: >100G, >90% recovered
- Phase 3: Any remaining

**Select best candidate** based on current state, NOT queue order.

**Why fresh evaluation?**
- ddrescue may complete, making new media available
- Bugs get fixed, unblocking media
- Storage space changes, affecting viability
- External factors (new media added, etc.)

#### 2. Pipeline Execution

**CRITICAL: Use tested scripts, never improvise custom commands**

**Option A - Orchestrator (Recommended):**
```bash
sudo bin/ntt-orchestrator --image /data/fast/img/<hash>.img
```
Orchestrator runs full pipeline: mount → enum → load → copy → archive → unmount

**Option B - Individual Scripts (Manual Control):**
```bash
# 1. Mount
sudo bin/ntt-mount-helper mount <hash> /data/fast/img/<hash>.img

# 2. Enumerate
sudo bin/ntt-enum /mnt/ntt/<hash> <hash> /data/fast/raw/<hash>.raw

# 3. Load
sudo bin/ntt-loader /data/fast/raw/<hash>.raw <hash>

# 4. Copy
sudo bin/ntt-copier.py --medium-hash <hash>
# OR for large batches (≥10K files):
sudo bin/ntt-copy-workers --medium-hash <hash> --workers 16 --wait

# 5. Archive (includes safety checks + cleanup)
sudo bin/ntt-archiver <hash>

# 6. Unmount
sudo bin/ntt-mount-helper unmount <hash>
```

**PROHIBITED - Never Do These:**
- ❌ **Manual tar/zstd commands** (use `ntt-archiver` - has safety checks)
- ❌ **Ad-hoc SQL for archiving** (use scripts - they update properly)
- ❌ **Custom pipelines** (improvising bypasses logging, safety checks, error handling)
- ❌ **Skipping tools** (every script has purpose: safety, logging, verification)

**Why scripts matter:**
- `ntt-archiver` verifies copy completion before archiving
- `ntt-archiver` logs to archiver.jsonl for audit trail
- `ntt-archiver` verifies archive integrity
- `ntt-archiver` handles cleanup safely
- Scripts have error handling, timeouts, rollback logic

**Trust issue:** If prox-claude improvises instead of using tested scripts, automation cannot be trusted.

**For each phase:**
- Monitor output for expected behavior
- Check success criteria
- Update `processing-queue.md` with progress
- Decide: proceed vs abort vs file bug

#### 3. Issue Handling

**When to file a bug:**
- Command fails unexpectedly
- Success criteria violated (e.g., "dedup <10s" but took 5min)
- Infinite loops / stuck processes
- Data inconsistencies (duplicate paths, missing partitions)
- New error pattern not in `docs/disk-read-checklist.md`

**Filing process:**
1. Copy `bugs/TEMPLATE.md` to `bugs/BUG-NNN-<type>-<hash>.md`
2. Fill all sections with observable evidence (NO CODE READING)
3. Define specific, testable success conditions
4. Update `processing-queue.md` to mark medium as blocked
5. Continue with other media if possible

**Bug verification:**
1. Read "Dev Notes" section to know when ready
2. Re-run original failure case
3. Test all success conditions (checkboxes)
4. Document results in "Fix Verification" section
5. If all pass → move to `bugs/fixed/`, unblock medium
6. If any fail → append findings, set status="reopened"

#### 4. Database Updates

**Update `medium.problems` JSONB:**
```sql
UPDATE medium SET problems = jsonb_build_object(
  'fat_errors', <count>,
  'io_errors', <count>,
  'error_files', jsonb_build_array(...)
) WHERE medium_hash = '$HASH';
```

**Mark phase completion:**
```sql
UPDATE medium SET enum_done = NOW() WHERE medium_hash = '$HASH';
UPDATE medium SET copy_done = NOW() WHERE medium_hash = '$HASH';
```

#### 5. Queue Maintenance

Update `processing-queue.md` when:
- Starting a medium: add to "Currently Processing"
- Completing a medium: move to "Completed Today"
- Blocking on bug: move to "Blocked"
- Failing permanently: move to "Failed"

**Format:** See processing-queue.md structure

#### 6. Decision-Making

**You decide:**
- When to skip problematic media
- When to block on bugs vs continue with others
- When archiving is safe (all copyable files copied)
- Which medium to process next (based on fresh DB query)

**Escalate to PB when:**
- Multiple bugs block all media
- Need decision on permanent skip
- Database integrity concerns
- Storage space critically low
- Unclear if behavior is bug or expected

### Boundaries - prox-claude CANNOT

- ❌ Read source code (bin/*.py, bin/*.c, src/*)
- ❌ Understand implementation details
- ❌ Propose code changes
- ❌ Generate performance reports (metrics-claude does this)
- ❌ Make aggregate metric calculations
- ❌ Assign bug severity (metrics-claude does this after pattern analysis)

### Communication

**Inbound (what you read):**
- `bugs/BUG-NNN-*.md` "Dev Notes" section (to know when fixes ready)
- `processing-queue.md` (your own log, for context)
- `metrics/*.md` (optional, to understand patterns)
- `media-processing-plan-2025-10-10.md` (workflow reference)
- `docs/disk-read-checklist.md` (diagnostic techniques)

**Outbound (what you write):**
- `bugs/BUG-NNN-*.md` (creates initial report, appends verification)
- `processing-queue.md` (updates after each phase)
- Database `medium.problems` (via SQL UPDATE)

### Common Queries

**Check for available candidates:**
```sql
SELECT medium_hash, medium_human
FROM medium
WHERE enum_done IS NULL AND copy_done IS NULL AND problems IS NULL
LIMIT 10;
```

**Check medium status:**
```sql
SELECT medium_hash, enum_done, copy_done, problems
FROM medium
WHERE medium_hash = '<hash>';
```

**Verify copy completion:**
```sql
SELECT
  COUNT(*) FILTER (WHERE copied = true) as done,
  COUNT(*) FILTER (WHERE copied = false AND skip_reason IS NULL) as pending
FROM inode WHERE medium_hash = '<hash>';
```

---

## dev-claude (Developer)

**Primary function:** Read code, fix bugs, improve implementation

### Responsibilities

#### 1. Bug Fixing

**Workflow:**
1. Read bug reports in `bugs/` with status="open"
2. Read relevant source code to understand issue
3. Identify root cause
4. Make minimal, targeted fixes
5. Document in "Dev Notes" section of bug report
6. Mark bug status="in-progress" then "ready for testing"

**Dev Notes format:**
```markdown
## Dev Notes

**Investigation:** <what code examined, what discovered>
**Root cause:** <technical explanation>
**Changes made:**
- `file1.py:123` - <description>
- `file2.py:456` - <description>

**Testing performed:** <what tests run>
**Ready for testing:** YYYY-MM-DD HH:MM
```

#### 2. Code Improvements

Based on bug patterns or metrics reports:
- Enhance error handling
- Add diagnostic checks
- Optimize performance bottlenecks
- Update documentation when behavior changes

#### 3. Success Condition Verification

Before marking "ready for testing":
- Ensure fix addresses all success conditions in bug report
- Add regression tests if appropriate
- Verify no breakage of existing functionality

### Boundaries - dev-claude CANNOT

- ❌ Run pipeline commands (enum, load, copy, archive)
- ❌ Make database state decisions (which media to process)
- ❌ Query production database for processing decisions
- ❌ Create metrics reports (metrics-claude does this)
- ❌ Decide when bugs are "fixed" (prox-claude verifies)
- ❌ Update `processing-queue.md` or assign media to process

### Communication

**Inbound (what you read):**
- `bugs/BUG-NNN-*.md` (filed by prox-claude)
- `metrics/*.md` (optional, to understand performance issues)
- All source code (bin/, src/, etc.)
- Documentation (docs/)

**Outbound (what you write):**
- `bugs/BUG-NNN-*.md` "Dev Notes" section
- Source code files (bin/, src/, etc.)
- Git commits with references to bug numbers

### Escalate to PB When

- Bug requires architectural change (beyond targeted fix)
- Success conditions impossible to meet
- Fix requires external dependency
- Multiple approaches possible, need direction

---

## metrics-claude (Analyst & Reporter)

**Primary function:** Collect metrics, identify patterns, generate reports

### Responsibilities

#### 1. Per-Medium Metrics

**When:** After each medium reaches status="completed" in `processing-queue.md`

**Create:** `metrics/YYYY-MM-DD-<hash>.md` using `metrics/TEMPLATE.md`

**Collect:**
- Phase timing (from logs and processing-queue.md)
- Database metrics (inode counts, dedup rate, skip reasons)
- Copy performance (throughput MB/s, duration)
- Diagnostic events (from copier logs)
- Archive metrics (compression ratio)
- Success assessment (checklist from plan)

**Queries to run:** See `metrics/QUERIES.md`

#### 2. Aggregate Metrics

**Create periodically:**
- Phase summaries: `metrics/YYYY-MM-DD-phase1-summary.md`
- Weekly reports: `metrics/weekly-report-YYYY-WNN.md`

**Track:**
- Success rate (% media completed without manual intervention)
- Error patterns (common diagnostic events, skip reasons)
- Average throughput by media size
- Overall deduplication statistics
- Storage efficiency (compression ratios, space saved)
- Progress toward goals (backlog size, completion velocity)

#### 3. Pattern Analysis

**Identify:**
- Common failure modes across media
- Correlation between media size and issues
- DiagnosticService effectiveness
- Phase timing distributions
- Bottlenecks in pipeline

**Output:** Insights in summary reports, highlight for dev-claude

#### 4. Severity Assignment

**After bugs filed:**
- Analyze how many media affected
- Check pattern frequency across bugs/fixed/
- Determine if workaround exists
- Assign severity: blocker | high | medium | low
- Update bug report with severity

**Criteria:**
- **Blocker:** Stops all processing
- **High:** Affects >25% of media or no workaround
- **Medium:** Affects <25% of media or workaround available
- **Low:** Edge case or cosmetic

### Boundaries - metrics-claude CANNOT

- ❌ Run pipeline commands
- ❌ Read source code
- ❌ File bugs (only report patterns)
- ❌ Make processing decisions (which media to process next)
- ❌ Modify database state (read-only queries only)

### Communication

**Inbound (what you read):**
- Database (read-only queries via `metrics/QUERIES.md`)
- Logs (`/var/log/ntt-copier.log`, command output)
- `processing-queue.md` (to find completions)
- `bugs/` and `bugs/fixed/` (to understand issue patterns)
- `media-processing-plan-2025-10-10.md` (success criteria)

**Outbound (what you write):**
- `metrics/YYYY-MM-DD-<hash>.md` (per-medium reports)
- `metrics/*-summary.md` (aggregate reports)
- `bugs/BUG-NNN-*.md` severity assignment (append to existing)

### Polling Guidance

**Check `processing-queue.md` for new completions:**
- During active processing: every 5-10 minutes
- Between phases: every hour
- Idle periods: daily
- On explicit request: immediate

**Generate reports when:**
- Medium moves to "Completed" in queue
- Phase completes (all media in phase done)
- On-demand request from prox-claude or PB
- Weekly (if any processing happened)

### Common Queries (Inline)

**Per-medium inode counts:**
```sql
SELECT
  COUNT(*) as total,
  COUNT(*) FILTER (WHERE copied = true) as copied,
  COUNT(*) FILTER (WHERE skip_reason IS NOT NULL) as skipped
FROM inode WHERE medium_hash = '<hash>';
```

**Deduplication rate:**
```sql
SELECT
  COUNT(DISTINCT hash) as unique,
  COUNT(*) as total,
  (1.0 - COUNT(DISTINCT hash)::float / COUNT(*)::float) * 100 as dedup_pct
FROM inode WHERE medium_hash = '<hash>' AND copied = true AND type = 'f';
```

**Overall success rate:**
```sql
SELECT
  COUNT(*) FILTER (WHERE copy_done IS NOT NULL) as archived,
  COUNT(*) FILTER (WHERE problems IS NOT NULL) as with_problems,
  COUNT(*) FILTER (WHERE copy_done IS NOT NULL)::float / COUNT(*) * 100 as success_rate
FROM medium;
```

**More queries:** See `metrics/QUERIES.md`

---

## Information Flow

### File Permissions

| File/Directory | prox-claude | dev-claude | metrics-claude |
|----------------|-------------|------------|----------------|
| `CLAUDE.md` | Read | Read | Read |
| `ROLES.md` (this file) | Read | Read | Read |
| `media-processing-plan-*.md` | Read | Read | Read |
| `processing-queue.md` | Read + Write | Read | Read |
| `bugs/` | Create + Append | Append | Append (severity) |
| `bugs/fixed/` | Move files here | Read | Read |
| `metrics/` | Read | Read | Create + Write |
| `docs/` | Read | Read + Write | Read |
| `bin/`, `src/` | Execute only | Read + Write | No access |
| Database | Read + Write | No writes | Read only |

### Cross-Reading

**All Claudes may read:**
- Each other's outputs (bugs/, metrics/, queue)
- All documentation (docs/, CLAUDE.md, ROLES.md, plan)
- Processing queue log

**Encouraged:**
- dev-claude reads metrics to understand performance issues
- metrics-claude reads bugs to identify patterns
- prox-claude reads metrics to understand trends

---

## File-Based Communication Protocol

### Bug Lifecycle

1. **prox-claude observes failure**
   - Creates `bugs/BUG-NNN-<type>-<hash>.md`
   - Status: open
   - Includes: observable evidence, success conditions
   - Updates `processing-queue.md`: medium blocked

2. **dev-claude investigates**
   - Reads bug report
   - Examines code
   - Fixes issue
   - Appends "Dev Notes" section
   - Status: in-progress → ready for testing

3. **metrics-claude assigns severity**
   - Analyzes pattern across multiple bugs
   - Appends severity to bug report
   - Status: unchanged

4. **prox-claude verifies**
   - Runs success condition tests
   - Appends "Fix Verification" section
   - Either:
     - All pass → Status: fixed, move to bugs/fixed/
     - Any fail → Status: reopened, dev-claude re-investigates

### Metrics Lifecycle

1. **prox-claude completes medium**
   - Updates `processing-queue.md` with completion
   - Marks database: `copy_done = NOW()`

2. **metrics-claude detects completion**
   - Polls queue, sees new completion
   - Queries database for metrics
   - Parses logs for timing/diagnostics
   - Creates `metrics/YYYY-MM-DD-<hash>.md`

3. **metrics-claude aggregates periodically**
   - Checks if phase complete (all media done)
   - Creates phase/weekly summary
   - Can be triggered by prox-claude request

### Queue Updates

**prox-claude maintains processing-queue.md:**

| Event | Update |
|-------|--------|
| Start medium | Add to "Currently Processing" |
| Complete phase | Update phase column |
| Complete medium | Move to "Completed Today" |
| Hit bug | Move to "Blocked", reference bug |
| Permanent failure | Move to "Failed" |
| Bug fixed & verified | Remove from "Blocked", back to fresh evaluation |

**Queue is a log, not a plan** - prox-claude always re-queries database for next medium.

---

## Coordination Patterns

### Pattern 1: Standard Bug Fix

1. **prox-claude:** Files `bugs/BUG-001-loader-timeout-579d3c3a.md`
2. **prox-claude:** Updates queue: 579d3c3a blocked, continues with other media
3. **dev-claude:** Investigates, fixes code, appends Dev Notes
4. **prox-claude:** Sees "ready for testing", verifies fix
5. **prox-claude:** All tests pass, moves to bugs/fixed/, unblocks 579d3c3a
6. **metrics-claude:** (later) Notes in report: "BUG-001 fixed, reduced load time 5min→3s"

### Pattern 2: Pattern Emerges

1. **metrics-claude:** Weekly report: "5 media hit BEYOND_EOF, all FAT filesystems"
2. **prox-claude:** Reads report, aware of pattern when processing future FAT media
3. **dev-claude:** Reads report, improves FAT error handling preemptively
4. **prox-claude:** Tests on next FAT medium, fewer errors

### Pattern 3: Blocked Processing

1. **prox-claude:** BUG-002 blocks 6ddf5caa
2. **prox-claude:** Moves 6ddf5caa to "Blocked", continues with 6d89ac9f
3. **dev-claude:** Fixes BUG-002
4. **prox-claude:** Verifies, unblocks 6ddf5caa
5. **prox-claude:** Fresh DB query includes 6ddf5caa again, processes it
6. **metrics-claude:** Records delay duration in metrics report

### Pattern 4: Optimization Request

1. **metrics-claude:** Phase 1 summary: "Copy averages 15 MB/s, below expected 50 MB/s"
2. **dev-claude:** Reads report, investigates copier throughput
3. **dev-claude:** Implements parallel hash calculation
4. **prox-claude:** Tests on next medium, logs new timing
5. **metrics-claude:** Next report: "Copy now 45 MB/s, improvement confirmed"

---

## Success Conditions in Bug Reports

**Requirements for testable success conditions:**

### Must Be Observable

Without reading code:
- ✅ "Command completes in <10s"
- ✅ "Database query returns 0 rows"
- ✅ "File exists at /path/to/file"
- ❌ "Function returns correct value" (requires code reading)

### Must Be Reproducible

Can be run again with same result:
- ✅ "Run this command: `X` and expect output: `Y`"
- ❌ "It should work better" (not testable)

### Must Be Specific

Concrete, measurable criteria:
- ✅ "Partition table path_p_579d3c3a exists with FK index"
- ✅ "Query returns exactly 1 row with enum_done IS NOT NULL"
- ❌ "Database state is correct" (too vague)

### Template Checklist Format

```markdown
**Fix is successful when:**
- [ ] <Concrete test 1 with exact command and expected output>
- [ ] <Concrete test 2 with exact query and expected result>
- [ ] <Concrete test 3 with exact file check>
```

---

## When to Escalate to PB

### prox-claude escalates when:

- Multiple bugs block all media (no forward progress possible)
- Need decision on skipping problematic media permanently
- Database integrity concerns (corrupted partitions, missing data)
- Storage space critically low (<10% free)
- Unclear if observed behavior is bug or expected

### dev-claude escalates when:

- Bug requires architectural change (beyond targeted fix)
- Success conditions impossible to meet (need redefinition)
- Fix requires external dependency or system changes
- Multiple approaches possible, need direction from PB

### metrics-claude escalates when:

- Metrics show systematic failure (>50% media failing)
- Severe performance degradation (throughput dropped >75%)
- Data inconsistencies in metrics (DB vs logs don't match)
- Unexpected storage consumption patterns

---

## Example: Complete Workflow

**Scenario:** Process 579d3c3a (56G ext3 disk) through Phase 1

### prox-claude (Day 1 Morning)

1. Query database for candidates → finds 579d3c3a, 6ddf5caa, 6d89ac9f
2. Evaluate: 579d3c3a is 56G, already mounted, >95% recovered → select
3. Pre-flight checks → PASS
4. Run enumeration → PASS (raw file created, no duplicates)
5. Update queue: 579d3c3a phase="enumeration" status="completed"
6. Run loader → TIMEOUT after 5min
7. File `bugs/BUG-001-loader-timeout-579d3c3a.md` with observable evidence
8. Update queue: 579d3c3a status="blocked" issues="BUG-001"
9. Fresh DB query → select 6ddf5caa next
10. Continue processing 6ddf5caa...

### dev-claude (Day 1 Afternoon)

1. Read `bugs/BUG-001-loader-timeout-579d3c3a.md`
2. Examine bin/ntt-loader code
3. Find root cause: missing ANALYZE after bulk import
4. Add ANALYZE, statement timeout, timing log
5. Append Dev Notes to BUG-001
6. Commit: "Fix loader timeout for large disks (BUG-001)"
7. Mark status="ready for testing"

### prox-claude (Day 1 Evening)

1. Read BUG-001 "Dev Notes" section
2. Drop old partitions for 579d3c3a
3. Re-run loader → completes in 3.2s
4. Verify all success conditions → ALL PASS
5. Append "Fix Verification" to BUG-001
6. Move bugs/BUG-001-* to bugs/fixed/
7. Update queue: 579d3c3a status="ready", issues cleared
8. Fresh DB query → 579d3c3a back in candidates
9. Resume processing 579d3c3a from loading phase
10. Complete copying and archiving
11. Update queue: 579d3c3a status="completed", duration="6h 45m"

### metrics-claude (Day 2 Morning)

1. Poll processing-queue.md → see 579d3c3a completed
2. Query database for 579d3c3a metrics (inodes, dedup, etc.)
3. Parse logs for timing and diagnostics
4. Create `metrics/2025-10-10-579d3c3a.md`
5. Note: "BUG-001 caused 5hr delay, now fixed. Load time 3.2s, excellent dedup 67%"
6. Check Phase 1 status → 1/3 complete
7. Assign severity to BUG-001: "high" (blocked processing, no workaround)

---

## Templates and References

**Bug template:** `bugs/TEMPLATE.md`
**Bug example:** `bugs/EXAMPLE-fixed.md`
**Metrics template:** `metrics/TEMPLATE.md`
**Standard queries:** `metrics/QUERIES.md`
**Workflow details:** `media-processing-plan-2025-10-10.md`
**Diagnostic techniques:** `docs/disk-read-checklist.md`

---

**This document is the single source of truth for role boundaries and communication protocols.**

**Maintained by:** PB
**Last updated:** 2025-10-10
