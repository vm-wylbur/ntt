<!--
Author: PB and Claude
Date: Sun 05 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/partition-migration-plan-2025-10-05.md
-->

<!-- completed: Original P2P FK plan; completed in commit 30153f1 -->

# NTT Partition Migration Plan - 2025-10-05

## Executive Summary

**Problem:** Loading bb22 medium (11.2M paths) takes hours in dedupe phase due to ON CONFLICT checking against 122M existing paths.

**Solution:** Convert `inode` and `path` tables to LIST partitioning by `medium_hash`. Each medium gets its own partition, making new medium inserts hit empty partitions (zero ON CONFLICT overhead).

**Expected improvement:** bb22 load time: Hours → ~6 minutes total (5min COPY + 30sec dedupe)

---

## Current Performance Bottleneck

### Symptom
From `docs/loader-optimization-investigation-2025-10-05.md`:
- COPY phase: 5m 13s (acceptable)
- Dedupe phase: Stuck for 90+ minutes, only 1K/10.5M inodes inserted

### Root Cause
```sql
INSERT INTO inode ... ON CONFLICT (medium_hash, ino) DO NOTHING;
INSERT INTO path ... ON CONFLICT (medium_hash, ino, path) DO NOTHING;
```

**ON CONFLICT checks require:**
1. Index probe for EVERY row to check uniqueness
2. `path` table has 122M existing rows across 16 media
3. Even with B-tree efficiency, 11.2M × log₂(122M) ≈ 300M index operations
4. This dominates execution time (hours vs seconds for actual inserts)

### Why GROUP BY Optimization Wasn't Enough

The investigation doc correctly identified wasteful GROUP BY operations, but:
- GROUP BY optimization saved ~4 seconds on SELECT queries
- ON CONFLICT overhead costs hours (missed in SELECT-only profiling)
- Need architectural change, not just query tuning

---

## Partition Strategy: LIST by medium_hash

### Architecture

**Parent tables** (empty routing tables):
```sql
CREATE TABLE inode PARTITION BY LIST (medium_hash);
CREATE TABLE path PARTITION BY LIST (medium_hash);
```

**Per-medium partitions** (auto-created on-demand):
```sql
-- For medium bb226d2ae226b3e048f486e38c55b3bd
CREATE TABLE inode_p_bb226d2a PARTITION OF inode
    FOR VALUES IN ('bb226d2ae226b3e048f486e38c55b3bd');

CREATE TABLE path_p_bb226d2a PARTITION OF path
    FOR VALUES IN ('bb226d2ae226b3e048f486e38c55b3bd');
```

### Why LIST Instead of HASH

**LIST partitioning (chosen):**
- Each medium = dedicated partition
- New medium → empty partition (zero conflicts)
- Perfect partition pruning for medium_hash queries
- Unlimited media (create partition on-demand)

**HASH partitioning (rejected):**
- Fixed number of partitions (e.g., 32)
- New medium still shares partition with other media (~3.8M paths)
- Only 18% improvement vs 100% with LIST
- Can't perfectly prune queries by medium

---

## Performance Analysis

### Current State (No Partitioning)

| Medium | Paths | Inode Insert | Path Insert | Total Dedupe |
|--------|-------|--------------|-------------|--------------|
| bb22 (new) | 11.2M | Hours* | Hours* | Hours* |

*Actual: 2m46s with only 1K/10.5M rows inserted before timeout

### Expected After Partitioning

| Medium | Paths | Inode Insert | Path Insert | Total Dedupe |
|--------|-------|--------------|-------------|--------------|
| bb22 (new) | 11.2M | ~15 sec | ~15 sec | ~30 sec |

**Math:**
- Sequential insert into empty partition (no ON CONFLICT lookups)
- Typical PostgreSQL bulk insert: 300-500K rows/sec
- 10.5M inodes / 400K rows/sec ≈ 26 seconds
- 11.2M paths / 400K rows/sec ≈ 28 seconds
- Index maintenance adds ~10-20% overhead

**Total load time:** 5m COPY + 30s dedupe = **~6 minutes** (vs hours currently)

---

## Migration Files

### Pre-Cutover (Safe to Run)

1. **`sql/partition-migration-step1-create.sql`**
   - Creates `inode_new` and `path_new` as partitioned parent tables
   - Creates all indexes (auto-inherited by partitions)
   - Adds foreign key from `inode_new` to `medium`
   - Runtime: <1 minute
   - Safety: Creates new tables, doesn't touch production

2. **`sql/partition-migration-step2-partitions.sql`**
   - Creates 16 partitions (one per existing medium)
   - Names: `inode_p_{hash:0:8}`, `path_p_{hash:0:8}`
   - Adds foreign key from `path_new` to `inode_new`
   - Runtime: <1 minute
   - Safety: Creates empty partitions, doesn't touch production

3. **`sql/partition-migration-step3-copy-data.sql`**
   - Single-transaction copy from `inode`/`path` → `inode_new`/`path_new`
   - Includes extensive verification queries
   - Runtime: 2-4 hours (122M paths)
   - Safety: Copies data, doesn't modify production tables

4. **`sql/partition-migration-step3-copy-data-batched.sql`**
   - Alternative to step 3: processes one medium at a time
   - Better progress tracking and failure recovery
   - Runtime: 2-4 hours (same total, but visible progress)
   - Recommended for production

5. **`sql/partition-migration-step4-add-trigger.sql`**
   - Recreates `queue_stats` trigger on `inode_new`
   - Runtime: <1 second
   - Safety: Only adds trigger, doesn't modify data

### Cutover (Requires Approval)

6. **`sql/partition-migration-step5-cutover.sql`**
   - **DO NOT RUN WITHOUT PB APPROVAL**
   - Atomic rename: `inode` → `inode_old`, `inode_new` → `inode`
   - Renames all indexes and constraints for consistency
   - Requires: All copier/loader processes stopped
   - Downtime: ~5-10 seconds (DDL operation time)
   - Keeps `inode_old`/`path_old` for rollback safety

### Rollback

7. **`sql/partition-migration-rollback.sql`**
   - Before cutover: Simply drops `inode_new`/`path_new`
   - After cutover: Reverses rename operations (complex, emergency only)

### Updated Loader

8. **`bin/ntt-loader-partitioned`**
   - New loader with auto-partition creation
   - Uses `CREATE TABLE IF NOT EXISTS` for idempotency
   - Compatible with both partitioned and non-partitioned tables
   - After cutover: Replace `bin/ntt-loader` → `bin/ntt-loader-partitioned`

---

## Migration Timeline

### Phase 1: Preparation (30 minutes)
- [ ] Review all migration SQL files
- [ ] Backup database (pg_dump or snapshot)
- [ ] Run step 1: Create parent tables
- [ ] Run step 2: Create partitions
- [ ] Verify partitions exist (run verification queries)

### Phase 2: Data Migration (2-4 hours)
- [ ] Run step 3 (batched version recommended)
- [ ] Monitor progress per medium
- [ ] Run verification queries (compare row counts)
- [ ] Spot-check sample data integrity

### Phase 3: Trigger Setup (1 minute)
- [ ] Run step 4: Add triggers
- [ ] Verify trigger exists on `inode_new`

### Phase 4: Final Verification (15 minutes)
- [ ] Run all verification queries from each step
- [ ] Confirm row counts match exactly
- [ ] Check partition sizes (`pg_total_relation_size`)
- [ ] Verify foreign keys intact

### Phase 5: Cutover (REQUIRES APPROVAL)
- [ ] **STOP all ntt-copier workers**
- [ ] **STOP any running ntt-loader processes**
- [ ] Verify no active sessions (query `pg_stat_activity`)
- [ ] Get explicit approval from PB
- [ ] Run step 5: Cutover (atomic rename)
- [ ] Update loader symlink: `ln -sf ntt-loader-partitioned ntt-loader`
- [ ] Restart copier workers

### Phase 6: Post-Cutover Testing (30 minutes)
- [ ] Test bb22 load with new partitioned loader
- [ ] Measure actual dedupe time
- [ ] Verify auto-partition creation works for new media
- [ ] Monitor copier workers for any issues

### Phase 7: Cleanup (After 48 Hours)
- [ ] Verify 48+ hours of stable operation
- [ ] Get approval from PB
- [ ] Drop old tables: `DROP TABLE inode_old CASCADE;`
- [ ] Remove rollback script (no longer valid)

---

## Verification Checklist

### After Step 3 (Data Copy)

```sql
-- Row count verification
SELECT
    'inode' as table_name,
    (SELECT count(*) FROM inode) as old_count,
    (SELECT count(*) FROM inode_new) as new_count,
    (SELECT count(*) FROM inode) = (SELECT count(*) FROM inode_new) as match;

SELECT
    'path' as table_name,
    (SELECT count(*) FROM path) as old_count,
    (SELECT count(*) FROM path_new) as new_count,
    (SELECT count(*) FROM path) = (SELECT count(*) FROM path_new) as match;

-- Per-medium verification
SELECT
    medium_hash,
    (SELECT count(*) FROM path WHERE path.medium_hash = m.medium_hash) as old_paths,
    (SELECT count(*) FROM path_new WHERE path_new.medium_hash = m.medium_hash) as new_paths
FROM medium m
ORDER BY medium_hash;
```

**Expected:** All counts match exactly

### After Cutover

```sql
-- Verify partitioning active
SELECT count(*) as partition_count
FROM pg_inherits
WHERE inhparent = 'inode'::regclass;

SELECT count(*) as partition_count
FROM pg_inherits
WHERE inhparent = 'path'::regclass;
```

**Expected:** 16 partitions each

### Performance Test

```bash
# Test bb22 load (should complete in ~6 minutes)
time ntt-loader /data/fast/raw/bb226d2a.raw bb226d2ae226b3e048f486e38c55b3bd
```

**Expected:**
- COPY phase: ~5 minutes
- Dedupe phase: ~30 seconds
- Total: ~6 minutes

---

## Risk Assessment

### Low Risk
- Steps 1-4 (all pre-cutover): Creates new tables, doesn't modify production
- Rollback: Simply drop `_new` tables
- No downtime during migration

### Medium Risk
- Step 5 (cutover): Requires stopping all workers (~5-10 second downtime)
- Mitigation: Run during low-activity window, verify no active sessions

### High Risk (Avoided)
- ❌ Modifying production tables in-place (not doing this)
- ❌ Dropping old tables immediately after cutover (keeping for 48 hours)

### Failure Scenarios

**If step 3 fails mid-migration:**
- No impact (production tables unchanged)
- Rollback: Drop `_new` tables, retry

**If step 5 cutover fails:**
- Emergency rollback: Rename tables back
- Maximum downtime: ~1 minute
- Data intact (rename is atomic)

**If post-cutover issues discovered:**
- Keep `_old` tables for 48 hours
- Can rollback by reversing renames
- Analyze issue before retry

---

## Success Criteria

### Immediate (Post-Cutover)
- [ ] All row counts match between old and new tables
- [ ] Foreign keys intact
- [ ] Triggers functioning
- [ ] Copier workers restart successfully

### Short-Term (24 Hours)
- [ ] bb22 load completes in <10 minutes
- [ ] No errors in loader logs
- [ ] Copier workers processing normally
- [ ] No performance regressions on queries

### Long-Term (48+ Hours)
- [ ] All operations stable
- [ ] Performance improvement sustained
- [ ] No unexpected issues
- [ ] Safe to drop `_old` tables

---

## Next Steps

1. **Review this plan with PB** - Confirm approach and timeline
2. **Execute steps 1-4** - Safe pre-cutover preparation
3. **Thorough verification** - Compare all counts, check data integrity
4. **Schedule cutover window** - Coordinate with PB for step 5 approval
5. **Post-cutover testing** - Measure actual performance improvement
6. **Document results** - Update `loader-optimization-investigation` with findings

---

## References

- Investigation: `docs/loader-optimization-investigation-2025-10-05.md`
- Migration SQL: `sql/partition-migration-step*.sql`
- New loader: `bin/ntt-loader-partitioned`
- PostgreSQL docs: [Table Partitioning](https://www.postgresql.org/docs/current/ddl-partitioning.html)
