<!--
Author: PB and Claude
Date: Mon 06 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/integrated-analysis-and-plan-2025-10-06.md
-->

# Integrated Analysis: PostgreSQL Partition Performance Solution

## Executive Summary

**Problem:** DELETE on partitioned tables hangs for 6+ minutes on 11.2M row loads due to FK constraints scanning all 17 partitions instead of just the target partition.

**Root Cause:** FK constraint from `path` partitions references **parent** `inode` table, not partition-to-partition. PostgreSQL cannot prune partitions during FK validation - a known architectural limitation.

**Unanimous AI Consensus:** All 3 external AIs (Gemini, Web-Claude, ChatGPT) + test results confirm the same root cause and recommend similar solutions with different emphasis.

**Test Results:** DETACH/ATTACH pattern works correctly on 100K paths, but dataset too small to measure timing differences. Need production-scale test on bb22 (11.2M paths).

---

## Comparison Matrix: AI Recommendations vs Test Results

| Aspect | Gemini | Web-Claude | ChatGPT | Test Results |
|--------|--------|------------|---------|--------------|
| **Root Cause** | FK scans all partitions | FK scans all partitions | FK scans all partitions | ✅ Confirmed by errors |
| **Primary Solution** | DETACH/ATTACH | DETACH/ATTACH | P2P FK | DETACH works on 100K |
| **CHECK Constraint** | Required (1-2s vs 3-5min) | **CRITICAL** (100-1000x) | Not emphasized | Cannot confirm (too small) |
| **FK Indexes** | Mentioned | **PRIORITY #1** | Required for P2P | Not tested |
| **Trigger Optimization** | Not mentioned | Statement-level (10-100x) | Not mentioned | Not tested |
| **TRUNCATE vs DELETE** | Use TRUNCATE | Use TRUNCATE | **#2 priority** | ✅ Instant (<1s) |
| **P2P FK as permanent fix** | Not emphasized | #2 solution | **#1 priority** | Not tested |

---

## Critical New Information from Web-Claude

### 1. FK Index Priority (Not Previously Emphasized)

Web-Claude uniquely emphasized this as **PRIORITY #1**:

> "PostgreSQL does NOT automatically create indexes on foreign key referencing columns, only on referenced columns."

**Impact:** Case study showed 99.99% of DELETE time (53,410ms out of 53,414ms) spent in FK constraint triggers due to missing indexes. Another case: "a bunch of hours" → "a few seconds" (100-1000x speedup).

**Current Status:** Our partitions have partial indexes with WHERE clauses. Web-Claude warns:
> "Partial indexes may not be used for all FK checks"

**Action Required:** Verify if we have **full (non-partial) indexes** on `(medium_hash, ino)` in ALL path partitions:

```sql
-- Check current indexes
SELECT tablename, indexname, indexdef
FROM pg_indexes
WHERE tablename LIKE 'path_p_%'
  AND indexdef LIKE '%(medium_hash, ino)%'
ORDER BY tablename;

-- If partial (WHERE clause), need full index:
CREATE INDEX CONCURRENTLY idx_path_p_bb226d2a_fk
  ON path_p_bb226d2a (medium_hash, ino);  -- No WHERE clause
```

### 2. Trigger Optimization (New Insight)

Web-Claude identified our `update_queue_stats()` row-level trigger as significant overhead:

> "Row-level triggers can slow bulk operations by 13x. For 1,000 deleted rows, trigger executes 1,000 times."

**Solution:** Convert to statement-level trigger with transition tables:

```sql
CREATE TRIGGER maintain_queue_stats
AFTER DELETE ON inode_p_bb226d2a
REFERENCING OLD TABLE AS deleted_rows
FOR EACH STATEMENT
EXECUTE FUNCTION update_queue_stats_batch();
```

**Expected benefit:** 10-100x faster for bulk operations.

### 3. CHECK Constraint Automation (Operational Gold)

Web-Claude provided **automated CHECK constraint generation** from partition bounds:

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
) as add_constraint_sql
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
JOIN pg_class parent ON parent.oid = i.inhparent
WHERE parent.relname IN ('path', 'inode')
AND c.relispartition;
```

This eliminates manual error-prone CHECK constraint creation before ATTACH.

### 4. ATTACH Validation Monitoring

Web-Claude showed how to verify CHECK constraints are working:

```sql
SET client_min_messages = 'debug4';
ALTER TABLE path ATTACH PARTITION path_p_bb226d2a FOR VALUES IN ('bb226d2a');

-- Should see:
-- DEBUG: partition constraint for table "path_p_bb226d2a" is implied by existing constraints

-- If silent → full table scan happening!
```

---

## Critical New Information from ChatGPT

### 1. Partition-to-Partition FK as Permanent Solution

ChatGPT uniquely prioritized P2P FK as **#1 long-term solution**:

> "If you need online RI enforcement during normal ingest and predictable DML latency, make the partition-to-partition FK permanent."

**Decision framework:**

**Choose P2P FK (permanent) when:**
- Inserts/updates/deletes happen continuously ← **This is us**
- Want immediate RI errors at write time
- Want stable latency and no surprise global scans

**Choose DETACH pattern when:**
- Loads are episodic and large
- Comfortable with post-load validation
- Want minimal DML overhead during bulk load

**ChatGPT's verdict for our use case:**
> "In your case (high-volume steady ingest and prior FK scans across 36M rows), permanent partition-to-partition FKs are worth it. Keep DETACH/TRUNCATE workflow as operational fast-path for rare rebuilds."

### 2. Idempotent Partition Provisioning Recipe

ChatGPT provided **operational procedure** for adding new media partitions with P2P FK:

```sql
-- 1) Create inode partition FIRST (PK must exist before FK references it)
CREATE TABLE IF NOT EXISTS inode_p_new (LIKE inode INCLUDING ALL);
ALTER TABLE inode ATTACH PARTITION inode_p_new FOR VALUES IN ('new_hash');

-- 2) Create path partition with required FK index
CREATE TABLE IF NOT EXISTS path_p_new (LIKE path INCLUDING ALL);
CREATE INDEX CONCURRENTLY idx_path_p_new_fk ON path_p_new (medium_hash, ino);

-- 3) Add P2P FK (NOT VALID to defer validation)
ALTER TABLE path_p_new
  ADD CONSTRAINT path_p_new_mh_ino_fkey
  FOREIGN KEY (medium_hash, ino)
  REFERENCES inode_p_new (medium_hash, ino)
  ON DELETE CASCADE NOT VALID;

-- 4) Attach path partition
ALTER TABLE path ATTACH PARTITION path_p_new FOR VALUES IN ('new_hash');

-- 5) Load data...

-- 6) Validate FK after load
ALTER TABLE path_p_new VALIDATE CONSTRAINT path_p_new_mh_ino_fkey;
```

**Key insight:** Use `NOT VALID` to avoid long validation during FK creation, then `VALIDATE CONSTRAINT` after load completes.

### 3. Guardrails and Order Dependencies

ChatGPT emphasized critical ordering:

1. **Inode partition MUST exist/attach before path partition FK**
2. Keep `(medium_hash, ino)` index on every path partition (non-partial)
3. For bulk loads: disable autovacuum, drop non-essential indexes, COPY directly, recreate indexes CONCURRENTLY

---

## Gemini's Original Analysis (Reconfirmed)

### 1. ATTACH Timing Breakdown

**Without CHECK constraint (baseline):**
- PostgreSQL scans all rows to verify partition bound predicate
- For bb22 (11.2M paths): 3-5 minutes full table scan
- Holds ACCESS EXCLUSIVE lock during scan

**With CHECK constraint (optimized):**
- PostgreSQL uses constraint inference: "partition constraint is implied by existing constraints"
- No table scan needed
- Expected: 1-2 seconds for bb22

**Formula:** `ATTACH_time = scan_time(row_count) + validation_time(fk_checks)`

### 2. DETACH CONCURRENTLY Safety

Gemini confirmed DETACH CONCURRENTLY is safe:
- Takes 1-2 seconds (just metadata change)
- Requires SHARE UPDATE EXCLUSIVE lock (allows reads/writes on other partitions)
- Safe to run during live operations (PostgreSQL 14+)

**Risk:** Only fails if concurrent DDL on same partition. Retry if fails.

### 3. Expected Total Time for bb22

Gemini's estimate (9-14 minutes):
```
DETACH:                    1-2s
TRUNCATE:                  <1s
COPY (from .raw):          5-6 min
Transform/Load:            2-3 min
CHECK constraint add:      <1s
ATTACH (with CHECK):       1-2s
CHECK constraint drop:     <1s
ANALYZE:                   30-60s
-----------------------------------
TOTAL:                     9-14 min
```

vs. current: **Hours (hung indefinitely)**

---

## Test Results Analysis

### What We Validated

✅ **DETACH/ATTACH pattern works correctly**
- All operations completed successfully
- FK integrity verified after ATTACH
- No data loss or corruption

✅ **TRUNCATE is instant**
- <1 second for 100K rows
- ChatGPT's emphasis confirmed

✅ **FK problem confirmed**
- Errors show exactly what all AIs diagnosed:
  ```
  ERROR: removing partition "inode_p_test_100k" violates foreign key constraint
  NOTICE: truncate cascades to table "path_p_1d7c9dc8"
  ... (cascades to ALL 17 partitions)
  ```

### What We Could NOT Validate

⚠️ **CHECK constraint requirement**
- 100K dataset too small: both with/without CHECK completed in <1s
- Cannot confirm Gemini's "3-5 min vs 1-2s" claim
- Cannot confirm Web-Claude's "100-1000x speedup" claim

⚠️ **FK index impact**
- Did not test missing vs present FK indexes
- Cannot confirm Web-Claude's "99.99% of time in FK triggers" claim

⚠️ **Production-scale performance**
- Need bb22 (11.2M paths) test to validate:
  - ATTACH timing with/without CHECK
  - Total workflow time (9-14 min estimate)
  - FK index impact on load performance

---

## Risk Assessment: Two Competing Strategies

### Strategy A: DETACH/ATTACH Pattern (Gemini #1, Web-Claude #1)

**Implementation:**
1. Add automated CHECK constraint generation (Web-Claude's script)
2. Integrate DETACH/ATTACH into ntt-loader
3. Keep current parent-level FK (no P2P FK changes)

**Pros:**
- ✅ Simpler implementation (loader changes only, no schema changes)
- ✅ Works with current FK architecture
- ✅ Validated on 100K dataset
- ✅ Faster for batch "wipe-and-reload" scenarios

**Cons:**
- ⚠️ More complex loader logic (DETACH/ATTACH on every load)
- ⚠️ FK validation only happens during ATTACH (not continuous)
- ⚠️ Must handle DETACH failures gracefully
- ❌ Doesn't fix underlying FK architecture problem
- ❌ Still requires CHECK constraints for performance (unvalidated on our data)

**Risk Level:** Medium
- Test showed it works, but unclear if CHECK requirement is real
- Adds operational complexity to loader
- Still vulnerable to cross-partition FK scans if DETACH pattern not used

### Strategy B: Partition-to-Partition FK (ChatGPT #1, Web-Claude #2)

**Implementation:**
1. Drop parent-level FK constraints
2. Add FK from each path partition to matching inode partition (17 pairs)
3. Create full (non-partial) FK indexes on all path partitions
4. Update partition provisioning to add P2P FK for new media

**Pros:**
- ✅ Permanent architectural fix
- ✅ FK checks only against matching partition (O(1) vs O(partitions))
- ✅ Continuous RI enforcement (catches errors at write time)
- ✅ Simpler loader (no DETACH/ATTACH complexity)
- ✅ Predictable latency for normal DML operations

**Cons:**
- ⚠️ Must define FK for all 17 existing partition pairs
- ⚠️ Must update FKs when adding new media
- ⚠️ More complex schema management
- ⚠️ One-time migration effort to restructure FKs

**Risk Level:** Low-Medium
- More upfront work, but cleaner long-term
- Proven pattern (ChatGPT confirmed PostgreSQL 16+ supports well)
- Aligns with our use case ("continuous ingest", not "episodic batch")

---

## Synthesis: Hybrid Approach (Recommended)

After analyzing all inputs, I propose a **phased hybrid approach** that takes the best of both strategies:

### Phase 1: Immediate Fixes (This Week)

**Priority 1: Add Full FK Indexes** (Web-Claude's #1, ChatGPT requirement)

```sql
-- Generate index creation for all 17 path partitions
SELECT format(
    'CREATE INDEX CONCURRENTLY IF NOT EXISTS %I ON %I (medium_hash, ino);',
    tablename || '_fk_full_idx',
    tablename
)
FROM pg_tables
WHERE tablename LIKE 'path_p_%'
AND schemaname = 'public'
\gexec
```

**Expected impact:** 100-1000x speedup for FK checks (Web-Claude's claim)
**Risk:** None (CONCURRENTLY doesn't block)
**Time:** 10-20 minutes per partition (can run in parallel)

**Priority 2: Optimize Trigger** (Web-Claude's finding)

Convert `update_queue_stats()` to statement-level trigger with transition tables.

**Expected impact:** 10-100x faster for bulk operations
**Risk:** Low (only affects trigger logic)
**Time:** 1 hour to implement and test

**Priority 3: Test DETACH/ATTACH on bb22** (Validate all AI claims)

Use test script to load actual bb22 (11.2M paths) with DETACH/ATTACH pattern.

**Critical validation:**
- Does CHECK constraint requirement matter at 11.2M scale?
- Is ATTACH really 1-2s with CHECK vs 3-5min without?
- Does full workflow complete in 9-14 minutes?

**Risk:** None (test only, not production)
**Time:** 1 hour to prep .raw file + run test

### Phase 2: Choose Architecture (Next Week)

**Decision point after Phase 1 testing:**

**If bb22 test shows:**
- ATTACH with CHECK = 1-2s, without CHECK = 3-5min → **DETACH pattern works, proceed with Strategy A**
- ATTACH with CHECK = 1-2s, without CHECK = 1-2s → **CHECK not needed, reconsider Strategy B**
- FK indexes provide 100x+ speedup → **Strategy B becomes more attractive**

**Strategy A (DETACH pattern):** Implement if CHECK requirement validated
- Integrate automated CHECK constraint generation into loader
- Add DETACH/ATTACH workflow to ntt-loader
- Keep current FK architecture

**Strategy B (P2P FK):** Implement if we want permanent fix
- One-time migration: drop parent FK, add 17 partition-pair FKs
- Update partition provisioning procedure (ChatGPT's recipe)
- Simpler loader logic (no DETACH/ATTACH)

### Phase 3: Long-Term Optimization (Optional)

**If using Strategy A:**
- Consider migrating to P2P FK anyway for cleaner architecture
- Keep DETACH pattern as operational fast-path for rebuilds

**If using Strategy B:**
- Keep DETACH pattern script for rare full partition rebuilds
- Monitor FK constraint overhead with new indexes

---

## Proposed Immediate Action Plan (Do NOT Execute - Review First)

### Step 1: Verify Current Index Status

```sql
-- Check if we have full (non-partial) FK indexes
SELECT
    tablename,
    indexname,
    CASE
        WHEN indexdef LIKE '%WHERE%' THEN 'PARTIAL (may not be used for FK)'
        ELSE 'FULL (good for FK)'
    END as index_type,
    indexdef
FROM pg_indexes
WHERE tablename LIKE 'path_p_%'
  AND indexdef LIKE '%(medium_hash, ino)%'
ORDER BY tablename;
```

**Expected finding:** Likely partial indexes with WHERE clauses
**Action if partial:** Need to create full indexes (Phase 1 Priority 1)

### Step 2: Create Full FK Indexes on All Path Partitions

**Why:** Web-Claude's #1 priority, may provide 100-1000x speedup

```bash
# Generate index creation SQL
psql postgres:///copyjob << 'EOF' > /tmp/create_fk_indexes.sql
SELECT format(
    'CREATE INDEX CONCURRENTLY IF NOT EXISTS %I ON %I (medium_hash, ino);',
    tablename || '_fk_full_idx',
    tablename
)
FROM pg_tables
WHERE tablename LIKE 'path_p_%'
AND schemaname = 'public';
EOF

# Review generated SQL before executing
cat /tmp/create_fk_indexes.sql

# Execute (takes 10-20 min per partition, can run in parallel)
psql postgres:///copyjob -f /tmp/create_fk_indexes.sql
```

**Risk:** None (CONCURRENTLY doesn't block writes)
**Time:** 3-5 hours total (17 partitions × ~15 min each, parallelizable)

### Step 3: Test bb22 Load with DETACH/ATTACH Pattern

**Prerequisites:**
- Full FK indexes created (Step 2)
- bb22 .raw file available at known path

```bash
# Modify test script to support loading from .raw file
# (Currently loads from inode_old/path_old)

# Option A: Load bb22 using modified test script
./test/test-detach-attach-pattern.sh bb226d2ae226b3e048f486e38c55b3bd \
  --raw-file /data/fast/raw/bb22.raw

# Option B: Load bb22 using modified ntt-loader with DETACH/ATTACH
# (Requires implementing DETACH/ATTACH in loader first)
```

**What to measure:**
1. ATTACH time WITHOUT CHECK constraint (baseline)
2. ATTACH time WITH CHECK constraint (optimized)
3. Total workflow time (target: 9-14 minutes)
4. Compare with current loader (hours)

**Success criteria:**
- Total time < 15 minutes
- ATTACH with CHECK < 5 seconds
- No hangs or timeouts
- FK integrity validated

### Step 4: Optimize Trigger (Parallel to Step 2-3)

**Current trigger (row-level):**
```sql
CREATE TRIGGER update_queue_stats_trigger
AFTER DELETE ON inode
FOR EACH ROW
EXECUTE FUNCTION update_queue_stats();
```

**New trigger (statement-level with transition tables):**
```sql
-- Drop old row-level trigger
DROP TRIGGER update_queue_stats_trigger ON inode;

-- Create statement-level trigger on each partition
CREATE TRIGGER update_queue_stats_trigger
AFTER DELETE ON inode_p_bb226d2a
REFERENCING OLD TABLE AS deleted_rows
FOR EACH STATEMENT
EXECUTE FUNCTION update_queue_stats_batch();

-- Update function to process OLD TABLE
CREATE OR REPLACE FUNCTION update_queue_stats_batch()
RETURNS TRIGGER AS $$
BEGIN
    -- Process all deleted rows at once
    -- (Need to see current update_queue_stats() implementation to adapt)
    UPDATE queue_stats qs
    SET count = count - d.cnt
    FROM (
        SELECT queue_id, COUNT(*) as cnt
        FROM deleted_rows
        GROUP BY queue_id
    ) d
    WHERE qs.queue_id = d.queue_id;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;
```

**Risk:** Medium (changes trigger logic, need to test)
**Action:** Need to see current `update_queue_stats()` implementation to adapt

### Step 5: Decision Point

**After Steps 1-4 complete, assess results:**

| Result | Action |
|--------|--------|
| FK indexes provided massive speedup | Consider Strategy B (P2P FK) more attractive |
| CHECK constraint critical (3-5 min vs 1-2s) | Proceed with Strategy A (DETACH pattern) |
| CHECK constraint not critical (both fast) | Reconsider - maybe FK indexes solved it |
| Total workflow < 15 min | Success! Choose strategy based on operational preference |
| Total workflow still slow | Re-analyze bottleneck |

---

## Open Questions for PB

### Architecture Decision

1. **Preferred long-term architecture:**
   - **Option A:** Keep current parent-level FK + DETACH/ATTACH pattern (simpler schema, more complex loader)
   - **Option B:** Migrate to partition-to-partition FK (more complex schema, simpler loader)
   - **Option C:** Hybrid - implement both, use DETACH for bulk loads, P2P FK for normal ops

2. **Risk tolerance:**
   - OK with one-time migration effort to restructure 17 partition-pair FKs?
   - OK with more complex loader logic (DETACH/ATTACH on every load)?

### Testing Approach

3. **bb22 test timing:**
   - OK to test bb22 load now (will take ~10-15 min if successful)?
   - Prefer to add full FK indexes first, then test bb22?
   - Want to test on smaller partition first (but we don't have complete 1M dataset)?

4. **Index creation timing:**
   - OK to create full FK indexes now (3-5 hours, non-blocking)?
   - Can run during business hours (CONCURRENTLY doesn't block)?

### Implementation Priority

5. **What to implement first:**
   - Full FK indexes (Web-Claude #1 priority, may solve everything)?
   - Trigger optimization (10-100x faster, smaller effort)?
   - DETACH/ATTACH test on bb22 (validate all AI claims)?

### Operational Constraints

6. **Current state acceptability:**
   - Can we leave bb22 in current state (1K inodes, 0 paths) during testing?
   - Need to load bb22 successfully soon, or can we test/optimize first?

---

## Recommendation Summary

**My recommendation:**

1. **Start with FK indexes** (Phase 1 Priority 1)
   - Lowest risk, potentially highest impact (100-1000x per Web-Claude)
   - Non-blocking (CONCURRENTLY)
   - Helps regardless of which strategy we choose

2. **Test bb22 with DETACH/ATTACH** after indexes complete (Phase 1 Priority 3)
   - Validates all AI claims on production-scale data
   - Answers the critical question: "Is CHECK constraint requirement real?"
   - Low risk (test only)

3. **Optimize trigger** in parallel (Phase 1 Priority 2)
   - Medium effort, clear benefit (10-100x)
   - Independent of architecture decision

4. **Choose architecture** based on test results (Phase 2)
   - If DETACH pattern works well → Strategy A (simpler schema)
   - If we want predictable latency for all DML → Strategy B (cleaner architecture)
   - If unsure → Hybrid (implement both, use appropriately)

**Expected outcome:** bb22 loads in 9-14 minutes instead of hours, with clear path to permanent solution.

---

## What NOT to Do

❌ **Don't implement partition-to-partition FK migration yet**
- Wait for test results
- Significant one-time effort (17 partition pairs)
- May not be needed if DETACH pattern + FK indexes solve it

❌ **Don't modify loader yet**
- Test first on bb22 to validate approach
- Confirm CHECK constraint requirement before adding complexity

❌ **Don't drop/recreate existing FK constraints**
- Current FKs work (just slow)
- Changing them is Phase 2 decision

✅ **Do create full FK indexes immediately**
- Safe, non-blocking, potentially solves everything
- Helps regardless of architecture choice

✅ **Do test DETACH/ATTACH on bb22 after indexes**
- Low risk, high information value
- Answers critical unknowns

✅ **Do optimize trigger**
- Clear benefit, independent of other decisions

---

**Status:** Analysis complete, awaiting PB decision on approach and priorities.

---

## PHASE 1 RESULTS (COMPLETED 2025-10-06)

### What We Did

1. ✅ Created full FK indexes on all 18 path partitions
2. ✅ Optimized triggers to statement-level with transition tables
3. ✅ Tested bb22 load (11.2M paths) with current DELETE-based loader

### Results

**bb22 Load Timing:**
- COPY phase: 4min 50s
- Index working table: 19s
- **DELETE + INSERT phase: 4min 41s** ← Still slow!
- **Total: ~10 minutes**

**Key Finding:**
- FK indexes helped (loads complete vs hanging)
- But DELETE still takes 4min 41s (should be <1s)
- **FK indexes did NOT eliminate cross-partition FK scans**

**Conclusion:** FK indexes are necessary but not sufficient. The partition-to-parent FK architecture still causes cross-partition scanning during DELETE validation.

**Detailed analysis:** `/home/pball/projects/ntt/docs/phase1-results-2025-10-06.md`

---

## PHASE 2: DETACH/ATTACH PATTERN (NEXT STEP)

### Objective

Test if DETACH/ATTACH pattern eliminates the 4min 41s DELETE overhead.

### Expected Results

**Current (Phase 1):**
- DELETE FROM partition: **4min 41s**
- Total load: **10 minutes**

**With DETACH/ATTACH:**
- DETACH: 1-2s
- TRUNCATE: <1s  
- ATTACH with CHECK: 1-2s
- Total overhead: **~3 seconds** (vs 4min 41s)
- **Total load: ~5.5 minutes**

### Implementation Plan

**Step 1: Create modified loader with DETACH/ATTACH**

Modify `ntt-loader` to use DETACH/ATTACH pattern:

```bash
# Before loading:
1. DETACH path_p_${PARTITION_SUFFIX} CONCURRENTLY
2. DETACH inode_p_${PARTITION_SUFFIX} CONCURRENTLY

# Load data:
3. TRUNCATE both partitions
4. Existing COPY + transform logic

# Before re-attaching:
5. Add CHECK constraints (automated from partition bounds)
6. ATTACH inode partition
7. ATTACH path partition  
8. Drop CHECK constraints
9. ANALYZE
```

**Step 2: Test on bb22**

Run modified loader on bb22 and measure:
- DETACH time
- ATTACH time (critical: should be 1-2s with CHECK)
- Total time (target: <6 minutes)

**Step 3: Compare with Phase 1**

| Phase | DELETE/ATTACH overhead | Total time |
|-------|----------------------|------------|
| Phase 1 (DELETE) | 4min 41s | 10 min |
| Phase 2 (DETACH/ATTACH) | ~3s | **~5.5 min** |
| **Improvement** | **~4.5 min faster** | **45% faster** |

### Success Criteria

- [ ] DETACH completes in <5 seconds
- [ ] TRUNCATE completes in <1 second
- [ ] ATTACH with CHECK completes in <5 seconds
- [ ] Total load time <6 minutes
- [ ] All 11.2M paths load correctly
- [ ] FK integrity validated

### If Phase 2 Succeeds

**Decision point:** Choose final architecture:

**Option A: DETACH/ATTACH Pattern (Recommended for now)**
- Proven to work at production scale
- 5.5 minute load time acceptable
- Keep current FK architecture (simpler)
- Use DETACH/ATTACH for all loads

**Option B: Migrate to P2P FK (Future optimization)**
- One-time migration effort (17 partition pairs)
- Permanent fix to FK architecture
- Simpler loader (no DETACH/ATTACH needed)
- Consider after Phase 2 validates performance

### Ready to Implement

**Next action:** Create DETACH/ATTACH version of ntt-loader and test on bb22.

**File to modify:** `/home/pball/projects/ntt/bin/ntt-loader`

**Test command:**
```bash
./bin/ntt-loader-detach /data/fast/raw/bb226d2ae226b3e048f486e38c55b3bd.raw bb226d2ae226b3e048f486e38c55b3bd
```

---

**Status:** Phase 1 complete (FK indexes + triggers optimized). Ready for Phase 2 (DETACH/ATTACH test).
