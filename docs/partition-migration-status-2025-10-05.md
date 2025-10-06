<!--
Author: PB and Claude
Date: Sun 05 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/partition-migration-status-2025-10-05.md
-->

# Partition Migration Status - 2025-10-05

## Completed Steps

### ✓ Step 1: Create Partitioned Parent Tables
**Status:** Complete
**Runtime:** <1 minute
**Changes:**
- Created `inode_new` partitioned by LIST(medium_hash)
- Created `path_new` partitioned by LIST(medium_hash)
- **Key fix:** Changed `path_new` PK from `(medium_hash, ino, path)` to `(medium_hash, path)`
  - Verified: Zero duplicate (medium_hash, path) pairs in existing data
  - Rationale: Path is unique within medium, ino is redundant
- Created 12 indexes on parent tables (auto-inherited by partitions)
- Added FK: `inode_new.medium_hash` → `medium.medium_hash`

**Verification:**
```sql
SELECT tablename FROM pg_tables WHERE tablename IN ('inode_new', 'path_new');
-- Result: Both tables exist
```

### ✓ Step 2: Create Partitions for Existing Media
**Status:** Complete
**Runtime:** <1 minute
**Changes:**
- Created 16 inode partitions (one per medium)
- Created 16 path partitions (one per medium)
- Added FK: `path_new(medium_hash, ino)` → `inode_new(medium_hash, ino)`

**Partition naming:** `{table}_p_{medium_hash:0:8}`

**Verification:**
```sql
SELECT count(*) FROM pg_inherits WHERE inhparent = 'inode_new'::regclass;
-- Result: 16 partitions

SELECT count(*) FROM pg_inherits WHERE inhparent = 'path_new'::regclass;
-- Result: 16 partitions
```

---

## Pending Steps

### Step 3: Copy Data from Old Tables
**Status:** Ready to run
**File:** `sql/partition-migration-step3-copy-data-batched.sql`
**Estimated runtime:** 2-4 hours (122M paths)
**Prerequisites:** None (safe to run anytime)

**Recommended approach:** Use batched version for progress tracking

### Step 4: Add Triggers
**Status:** Ready to run
**File:** `sql/partition-migration-step4-add-trigger.sql`
**Estimated runtime:** <1 second

### Step 5: Cutover (REQUIRES PB APPROVAL)
**Status:** Designed, NOT executable without approval
**File:** `sql/partition-migration-step5-cutover.sql`
**Requirements:**
- All copier workers stopped
- All loader processes stopped
- Steps 1-4 completed and verified
- Database backup taken
- Explicit approval from PB

---

## Key Design Decisions

### 1. Simplified Path Primary Key
**Change:** PK `(medium_hash, ino, path)` → `(medium_hash, path)`

**Rationale:**
- Verified: Zero duplicate (medium_hash, path) pairs in 122M existing paths
- Path is globally unique within a medium (filesystem guarantees this)
- Including `ino` was redundant and caused unnecessary index bloat
- Simplifies ON CONFLICT checks during bulk load

**Impact:**
- Smaller primary key index
- Faster ON CONFLICT checks (one less column to compare)
- Still preserves full data integrity

### 2. LIST Partitioning vs HASH
**Choice:** LIST partitioning by `medium_hash`

**Rationale:**
- Each medium gets dedicated partition (perfect isolation)
- New medium inserts hit empty partition (zero ON CONFLICT overhead)
- Perfect partition pruning for medium_hash queries
- Scalable to unlimited media (auto-create partitions in loader)

**Alternative (rejected):** HASH partitioning with fixed partition count
- Would still have cross-medium collisions in partitions
- Only ~18% improvement vs ~100% with LIST

---

## Performance Expectations

### Current (No Partitioning)
- bb22 load: COPY 5min + dedupe **HOURS** (stuck)
- Bottleneck: ON CONFLICT against 122M paths

### After Migration
- bb22 load: COPY 5min + dedupe **~30 sec** = **~6 min total**
- Reason: Empty partition = zero ON CONFLICT lookups

### Math
- Sequential insert rate: ~400K rows/sec (typical bulk insert)
- 10.5M inodes / 400K ≈ 26 seconds
- 11.2M paths / 400K ≈ 28 seconds
- Index maintenance overhead: ~20%
- **Total dedupe: ~30-35 seconds**

---

## Files Modified

### Migration SQL
1. `sql/partition-migration-step1-create.sql` - Parent tables + indexes
2. `sql/partition-migration-step2-partitions.sql` - Create 16 partitions
3. `sql/partition-migration-step3-copy-data.sql` - Single-transaction copy
4. `sql/partition-migration-step3-copy-data-batched.sql` - Batched copy (recommended)
5. `sql/partition-migration-step4-add-trigger.sql` - Recreate triggers
6. `sql/partition-migration-step5-cutover.sql` - Atomic rename (not yet executed)
7. `sql/partition-migration-rollback.sql` - Rollback procedures

### Application Code
8. `bin/ntt-loader-partitioned` - New loader with auto-partition creation
   - Checks for existing partition, creates if needed
   - Uses `CREATE TABLE IF NOT EXISTS` for idempotency
   - Updated ON CONFLICT to match new PK: `(medium_hash, path)`

### Documentation
9. `docs/partition-migration-plan-2025-10-05.md` - Complete migration plan
10. `docs/partition-migration-status-2025-10-05.md` - This file

---

## Next Actions

### Option A: Continue Migration (Steps 3-4)
If ready to proceed with data copy:

```bash
# Step 3: Copy data (batched version for progress tracking)
psql postgres:///copyjob -f sql/partition-migration-step3-copy-data-batched.sql

# Expected output: Progress messages per medium, ~2-4 hours total
# Verify row counts match after completion

# Step 4: Add triggers
psql postgres:///copyjob -f sql/partition-migration-step4-add-trigger.sql
```

### Option B: Test on Subset First
Test partition performance before full migration:

```bash
# Create test partition for a new medium
psql postgres:///copyjob -c "
CREATE TABLE inode_p_test_new PARTITION OF inode_new FOR VALUES IN ('test_new_medium');
CREATE TABLE path_p_test_new PARTITION OF path_new FOR VALUES IN ('test_new_medium');
"

# Test load with new partitioned loader
ntt-loader-partitioned /data/fast/raw/test.raw test_new_medium

# Measure dedupe time (should be <30 seconds for 11M rows)
```

### Option C: Review and Plan Cutover
If steps 1-2 are sufficient for now:
- Review migration plan with PB
- Schedule cutover window (requires stopping workers)
- Prepare rollback plan
- Take database backup before cutover

---

## Rollback Procedures

### Before Cutover (Steps 1-4)
**Simple rollback:**
```sql
DROP TABLE inode_new CASCADE;
DROP TABLE path_new CASCADE;
```
Production tables (`inode`, `path`) remain untouched.

### After Cutover (Step 5)
**Complex rollback** - requires reversing all renames. See `sql/partition-migration-rollback.sql`.

**Recommendation:** Keep `inode_old` and `path_old` for 48+ hours after cutover for emergency rollback.

---

## Current Database State

**Production tables:**
- `inode`: 122M+ paths across 16 media (active)
- `path`: 122M+ paths across 16 media (active)

**New partitioned tables:**
- `inode_new`: 16 empty partitions (ready for data copy)
- `path_new`: 16 empty partitions (ready for data copy)

**Indexes:**
- All parent-level indexes created (auto-inherited by partitions)
- Each partition will have full set of indexes

**Constraints:**
- FK: `inode_new` → `medium` (enforced)
- FK: `path_new` → `inode_new` (enforced)
- PK: `inode_new(medium_hash, ino)` (enforced)
- PK: `path_new(medium_hash, path)` (enforced)

---

## Risk Assessment

**Current risk level:** LOW
- Steps 1-2 completed successfully
- No production data modified
- Can rollback instantly (drop new tables)

**Next step risk (Step 3):** LOW
- Copies data without modifying production
- Long-running but safe
- Can verify before proceeding

**Cutover risk (Step 5):** MEDIUM
- Requires stopping workers (~5-10 sec downtime)
- Atomic operation, but needs careful verification
- Mitigation: Keep old tables for 48 hours

---

## Questions for PB

1. **Proceed with Step 3 now?** Data copy is safe and takes 2-4 hours
2. **Preferred timing for cutover?** Need to coordinate worker shutdown
3. **Performance test first?** Load a test medium into new partitions to verify speed
4. **Backup strategy?** pg_dump before cutover, or rely on existing backups?

---

## Success Metrics (Post-Migration)

- [ ] bb22 load completes in <10 minutes total
- [ ] Dedupe phase completes in <60 seconds
- [ ] All 122M paths migrated successfully
- [ ] Row counts match exactly between old and new tables
- [ ] Copier workers function normally
- [ ] No query performance regressions
- [ ] Partition auto-creation works for new media

---

**Status:** Steps 1-2 complete, ready for Step 3 (data copy) pending PB decision.
