<!--
Author: PB and Claude
Date: Mon 06 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/session-context-2025-10-06.md
-->

# Session Context - PostgreSQL Partition Performance Fix

## Current Status: PHASE 1 COMPLETE, READY FOR PHASE 2

---

## Problem Summary

**Original Issue:** ntt-loader hung indefinitely (6+ minutes) on DELETE when loading bb22 medium (11.2M paths).

**Root Cause (confirmed by 3 AIs + testing):**
- FK constraint from `path` partitions references **parent** `inode` table (not partition-to-partition)
- PostgreSQL cannot prune partitions during FK validation - known limitation
- DELETE triggers FK validation across all 17 inode partitions (not just target partition)

---

## What We've Accomplished (Phase 1)

### 1. Created Full FK Indexes ✅
**Problem:** All indexes were PARTIAL (with WHERE clauses) - not used for FK checks

**Solution:** Created full `(medium_hash, ino)` indexes on all 18 path partitions:
```bash
# Created these indexes:
path_p_1d7c9dc8_fk_idx
path_p_236d5e0d_fk_idx
... (18 total)
```

**Result:** FK checks now use indexes, but still scan across partitions

### 2. Optimized Triggers ✅
**Problem:** Row-level AFTER triggers slow (fires once per row)

**Solution:** Converted to statement-level triggers with transition tables:
- File: `/home/pball/projects/ntt/sql/optimize-queue-stats-trigger.sql`
- Created 3 triggers per partition: INSERT, UPDATE, DELETE
- Use `REFERENCING NEW TABLE AS new_rows` pattern
- Expected 10-100x speedup for bulk operations

### 3. Tested bb22 Load ✅
**Test:** Loaded bb22 (11.2M paths) with current DELETE-based loader

**Results:**
- COPY phase: 4min 50s ✅ (expected, reasonable)
- Index working table: 19s ✅
- **DELETE + INSERT: 4min 41s** ⚠️ (still slow!)
- **Total: ~10 minutes**

**Previous:** HUNG indefinitely (6+ min on DELETE, never completed)
**After Phase 1:** Completes in 10 min (improvement, but still slow)

### Key Finding: FK Indexes Are Necessary But Not Sufficient

✅ **What FK indexes did:**
- Loads now complete (vs hanging indefinitely)
- ~2x improvement in DELETE phase

❌ **What FK indexes did NOT fix:**
- Cross-partition FK scan problem remains
- DELETE still takes 4min 41s (should be <1s with DETACH pattern)
- Partition-to-parent FK architecture is the bottleneck

**Detailed analysis:** `/home/pball/projects/ntt/docs/phase1-results-2025-10-06.md`

---

## What's Next (Phase 2)

### Objective: Test DETACH/ATTACH Pattern

**Goal:** Eliminate the 4min 41s DELETE overhead by avoiding DELETE entirely.

**Expected improvement:**
- Current DELETE: **4min 41s**
- DETACH + TRUNCATE + ATTACH: **~3 seconds**
- **Total load time: 10 min → ~5.5 min (45% faster)**

### Implementation Plan

**Step 1: Create DETACH/ATTACH version of ntt-loader**

Modify `/home/pball/projects/ntt/bin/ntt-loader` to use this workflow:

```bash
# 1. DETACH partitions (removes FK temporarily)
ALTER TABLE path DETACH PARTITION path_p_${SUFFIX} CONCURRENTLY;
ALTER TABLE inode DETACH PARTITION inode_p_${SUFFIX} CONCURRENTLY;

# 2. TRUNCATE (instant, no FK checks needed)
TRUNCATE path_p_${SUFFIX}, inode_p_${SUFFIX} CASCADE;

# 3. Load data (existing COPY + transform logic - no changes)
COPY ... FROM ...
INSERT INTO inode_p_${SUFFIX} ...
INSERT INTO path_p_${SUFFIX} ...

# 4. Add CHECK constraints (CRITICAL for fast ATTACH)
ALTER TABLE inode_p_${SUFFIX}
  ADD CONSTRAINT check_inode_p_${SUFFIX}
  CHECK (medium_hash = '${MEDIUM_HASH}');

ALTER TABLE path_p_${SUFFIX}
  ADD CONSTRAINT check_path_p_${SUFFIX}
  CHECK (medium_hash = '${MEDIUM_HASH}');

# 5. ATTACH partitions (should be 1-2s with CHECK constraints)
ALTER TABLE inode ATTACH PARTITION inode_p_${SUFFIX}
  FOR VALUES IN ('${MEDIUM_HASH}');

ALTER TABLE path ATTACH PARTITION path_p_${SUFFIX}
  FOR VALUES IN ('${MEDIUM_HASH}');

# 6. Drop CHECK constraints (no longer needed)
ALTER TABLE inode_p_${SUFFIX} DROP CONSTRAINT check_inode_p_${SUFFIX};
ALTER TABLE path_p_${SUFFIX} DROP CONSTRAINT check_path_p_${SUFFIX};

# 7. ANALYZE
ANALYZE inode_p_${SUFFIX};
ANALYZE path_p_${SUFFIX};
```

**Step 2: Test on bb22**

Run modified loader and measure:
- DETACH time (expected: 1-2s)
- ATTACH time (critical: should be 1-2s with CHECK, 3-5min without)
- Total time (target: <6 min)

### Critical: CHECK Constraint Requirement

**Why CHECK constraints matter:**

**Without CHECK constraint:**
- ATTACH scans entire partition to verify partition bounds
- For bb22: 3-5 minutes to scan 11.2M rows
- Holds ACCESS EXCLUSIVE lock during scan

**With CHECK constraint matching partition bounds:**
- PostgreSQL infers: "constraint proves all rows match partition bounds"
- No table scan needed
- ATTACH completes in 1-2 seconds

**How to verify CHECK is working:**
```sql
SET client_min_messages = 'debug4';
ALTER TABLE path ATTACH PARTITION path_p_bb226d2a FOR VALUES IN ('bb226d2a');

-- Should see:
-- DEBUG: partition constraint for table "path_p_bb226d2a" is implied by existing constraints

-- If silent → full table scan happening!
```

### Automated CHECK Constraint Generation

Use Web-Claude's script to generate CHECK constraints from partition bounds:

```sql
SELECT format(
    'ALTER TABLE %I ADD CONSTRAINT check_%s CHECK (medium_hash = %L);',
    c.relname,
    c.relname,
    regexp_replace(
        pg_get_expr(c.relpartbound, c.oid),
        'FOR VALUES IN \(''(.+?)''\)',
        '\1'
    )
)
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
JOIN pg_class parent ON parent.oid = i.inhparent
WHERE parent.relname IN ('path', 'inode')
  AND c.relispartition
  AND c.relname LIKE '%_bb226d2a';
```

---

## Database Current State

### Partitions
- 18 partitions total (17 production + 1 test)
- bb22 partition: `inode_p_bb226d2a`, `path_p_bb226d2a`
- bb22 currently has 11.2M paths loaded (from Phase 1 test)

### Indexes
- All 18 path partitions have full FK indexes: `path_p_*_fk_idx (medium_hash, ino)`
- No WHERE clauses (previously all were partial)

### Triggers
- All 18 inode partitions have statement-level triggers
- 3 triggers each: `trigger_queue_stats_insert`, `trigger_queue_stats_update`, `trigger_queue_stats_delete`
- Use transition tables for batch processing

### Old Tables (for rollback)
- `inode_old`: 123.6M rows (original data)
- `path_old`: 123.6M rows (original data)
- Keep these for safety

---

## Key Files and Locations

### Documentation
- **Integrated analysis:** `/home/pball/projects/ntt/docs/integrated-analysis-and-plan-2025-10-06.md`
- **Phase 1 results:** `/home/pball/projects/ntt/docs/phase1-results-2025-10-06.md`
- **Test results:** `/home/pball/projects/ntt/docs/detach-attach-test-results-2025-10-06.md`
- **AI comparisons:** `/home/pball/projects/ntt/docs/ai-recommendations-comparison-2025-10-06.md`

### Scripts
- **Current loader:** `/home/pball/projects/ntt/bin/ntt-loader` (uses DELETE)
- **Test script:** `/home/pball/projects/ntt/test/test-detach-attach-pattern.sh` (DETACH/ATTACH)
- **Trigger optimization:** `/home/pball/projects/ntt/sql/optimize-queue-stats-trigger.sql`
- **FK index creation:** `/tmp/create_fk_indexes.sql`

### Data
- **bb22 raw file:** `/data/fast/raw/bb226d2ae226b3e048f486e38c55b3bd.raw`
- **Medium hash:** `bb226d2ae226b3e048f486e38c55b3bd`
- **Partition suffix:** `bb226d2a` (first 8 chars)

---

## TODO List (Current State)

- [x] Phase 1: Verify FK index status
- [x] Phase 1: Create full FK indexes on all partitions
- [x] Phase 1: Optimize triggers to statement-level
- [x] Phase 1: Test bb22 with DELETE approach
- [ ] **Phase 2: Create DETACH/ATTACH loader** ← NEXT STEP
- [ ] Phase 2: Test bb22 with DETACH/ATTACH pattern

---

## Immediate Next Actions

### 1. Create DETACH/ATTACH Loader

**Option A: Modify existing ntt-loader**
- Copy to `ntt-loader-detach` for testing
- Replace DELETE section with DETACH/ATTACH logic
- Add CHECK constraint generation

**Option B: Use existing test script**
- `/home/pball/projects/ntt/test/test-detach-attach-pattern.sh` already has DETACH/ATTACH logic
- Modify to support loading from .raw file (currently loads from _old tables)

**Recommendation:** Start with Option A - create `ntt-loader-detach` based on current loader.

### 2. Key Changes Needed

**Current loader (lines 172-173):**
```bash
DELETE FROM path_p_bb226d2a;     # Takes 4min 41s!
DELETE FROM inode_p_bb226d2a;
```

**Replace with:**
```bash
# DETACH (1-2s)
psql ... -c "ALTER TABLE path DETACH PARTITION path_p_bb226d2a CONCURRENTLY;"
psql ... -c "ALTER TABLE inode DETACH PARTITION inode_p_bb226d2a CONCURRENTLY;"

# TRUNCATE (<1s)
psql ... -c "TRUNCATE path_p_bb226d2a, inode_p_bb226d2a CASCADE;"

# ... existing load logic ...

# Add CHECK constraints
psql ... -c "ALTER TABLE inode_p_bb226d2a ADD CONSTRAINT check_inode_p_bb226d2a CHECK (medium_hash = '$MEDIUM_HASH');"
psql ... -c "ALTER TABLE path_p_bb226d2a ADD CONSTRAINT check_path_p_bb226d2a CHECK (medium_hash = '$MEDIUM_HASH');"

# ATTACH (1-2s with CHECK)
psql ... -c "ALTER TABLE inode ATTACH PARTITION inode_p_bb226d2a FOR VALUES IN ('$MEDIUM_HASH');"
psql ... -c "ALTER TABLE path ATTACH PARTITION path_p_bb226d2a FOR VALUES IN ('$MEDIUM_HASH');"

# Drop CHECK constraints
psql ... -c "ALTER TABLE inode_p_bb226d2a DROP CONSTRAINT check_inode_p_bb226d2a;"
psql ... -c "ALTER TABLE path_p_bb226d2a DROP CONSTRAINT check_path_p_bb226d2a;"

# ANALYZE
psql ... -c "ANALYZE inode_p_bb226d2a;"
psql ... -c "ANALYZE path_p_bb226d2a;"
```

### 3. Test Command

```bash
./bin/ntt-loader-detach /data/fast/raw/bb226d2ae226b3e048f486e38c55b3bd.raw bb226d2ae226b3e048f486e38c55b3bd
```

### 4. Success Criteria

- [ ] DETACH completes in <5 seconds
- [ ] TRUNCATE completes in <1 second
- [ ] ATTACH with CHECK completes in <5 seconds
- [ ] Total load time <6 minutes (vs 10 min in Phase 1)
- [ ] All 11.2M paths load correctly
- [ ] FK integrity validated

---

## Important Notes

### DO NOT Use `watch` Command
- User's terminal breaks with `watch`
- Use polling with sleep instead, or manual checks

### Partition Naming Convention
- Full hash: `bb226d2ae226b3e048f486e38c55b3bd`
- Partition suffix: `bb226d2a` (first 8 chars)
- Partition names: `inode_p_bb226d2a`, `path_p_bb226d2a`

### Database Connection
- URL: `postgres:///copyjob`
- User: pball
- Commands run via sudo -u pball

### Key Insights from Phase 1

1. **FK indexes are necessary** - without them, loads hang indefinitely
2. **FK indexes are not sufficient** - still have 4min DELETE overhead
3. **The architecture is the problem** - partition-to-parent FK causes cross-partition scans
4. **DETACH/ATTACH is the solution** - avoids DELETE and FK validation entirely

---

## External AI Recommendations (All Agree)

### Gemini
- #1 recommendation: DETACH/ATTACH pattern
- Estimated total time with DETACH: 9-14 minutes
- CHECK constraint critical: 1-2s vs 3-5min for ATTACH

### Web-Claude
- #1 recommendation: DETACH/ATTACH pattern
- Emphasized CHECK constraint requirement (100-1000x speedup claim)
- Provided automated CHECK constraint generation script
- #1 priority: FK indexes (done in Phase 1)

### ChatGPT
- #1 long-term: Partition-to-partition FK
- #2 operational: DETACH/ATTACH for bulk loads
- Provided idempotent provisioning recipe

### Consensus
All 3 AIs agree:
1. Root cause: FK from partition → parent table
2. Immediate fix: DETACH/ATTACH pattern
3. Long-term: Consider P2P FK for cleaner architecture

---

## Decision Framework (After Phase 2)

### If DETACH/ATTACH succeeds (<6 min total):

**Option A: Use DETACH/ATTACH for all loads**
- Proven to work
- 5.5 minute load time acceptable
- Keep current FK architecture (simpler)
- No migration effort

**Option B: Also migrate to P2P FK (future)**
- One-time effort (17 partition pairs)
- Permanent architectural fix
- Even simpler loader (no DETACH/ATTACH)
- Consider after validating DETACH/ATTACH works

**Recommendation:** Start with Option A, consider Option B later if needed.

---

## Quick Reference: Current Performance

| Metric | Before Phase 1 | After Phase 1 | Target Phase 2 |
|--------|----------------|---------------|----------------|
| DELETE phase | HUNG (6+ min) | 4min 41s | ~3 seconds |
| Total load | HUNG | 10 minutes | **~5.5 minutes** |
| Status | Broken | Slow | **Optimal** |

---

**Status:** Phase 1 complete, ready to implement Phase 2 (DETACH/ATTACH loader).

**Next session should:**
1. Create ntt-loader-detach with DETACH/ATTACH logic
2. Test on bb22 (11.2M paths)
3. Measure timings and validate CHECK constraint benefit
4. Compare with Phase 1 results
5. Decide on final architecture
