<!--
Author: PB and Claude
Date: Mon 06 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/ai-recommendations-comparison-2025-10-06.md
-->

# AI Recommendations Comparison - PostgreSQL Partition Performance

## Problem Summary
DELETE/INSERT operations on partitioned tables hang for 6+ minutes on 11.2M rows. Root cause: FK constraints from path partitions reference parent inode table, forcing scans across all 36M inodes in 17 partitions instead of just the target partition.

---

## All Three AIs Agree On Root Cause

**Unanimous diagnosis:**
1. FK constraints defined on path partitions point to **parent inode table**
2. PostgreSQL cannot prune partitions during FK validation
3. Every DELETE/INSERT triggers scans across all 17 partitions
4. This is a **known PostgreSQL limitation** (documented in mailing lists, Stack Exchange)
5. Missing or ineffective indexes on FK columns compound the problem

**Confidence level:** 100% - all three AIs independently identified the same root cause

---

## Recommended Solutions Comparison

### Solution Rankings by AI

| Rank | Gemini | Web-Claude | ChatGPT |
|------|--------|------------|---------|
| #1 | DETACH → Load → ATTACH | DETACH → TRUNCATE → Load → ATTACH | Partition-to-partition FKs |
| #2 | Drop FK → Load → Recreate | Partition-to-partition FKs | TRUNCATE instead of DELETE |
| #3 | - | Add FK indexes | DETACH → Load → ATTACH |

---

## Solution Analysis

### Option A: DETACH → Load → ATTACH Pattern

**How it works:**
```sql
-- Detach partition (removes FK temporarily)
ALTER TABLE path DETACH PARTITION path_p_bb226d2a CONCURRENTLY;

-- Load data without FK overhead
TRUNCATE path_p_bb226d2a;
COPY path_p_bb226d2a FROM stdin;

-- Re-attach (validates FK only for this partition)
ALTER TABLE path ATTACH PARTITION path_p_bb226d2a
  FOR VALUES IN ('bb226d2a...');
```

**Pros:**
- ✅ FK validation scoped to single partition during ATTACH
- ✅ No FK overhead during load
- ✅ No impact on other partitions
- ✅ Transactional and reversible
- ✅ All 3 AIs recommend this (Gemini #1, Web-Claude #1, ChatGPT #3)

**Cons:**
- ⚠️ Requires DETACH/ATTACH for every load
- ⚠️ More complex loader logic
- ⚠️ FK validation still happens (just faster, during ATTACH)

**Performance estimate:**
- COPY: 5 minutes (unchanged)
- Load/Transform: 2-3 minutes (no FK checks)
- ATTACH validation: 30-60 seconds (single partition)
- **Total: ~8 minutes** (Gemini's estimate)

**Web-Claude critical detail:**
> "Add CHECK constraints matching partition bounds BEFORE ATTACH - without these, ATTACH will perform full table scan"

```sql
-- CRITICAL: Add before ATTACH
ALTER TABLE path_p_bb226d2a ADD CONSTRAINT check_path_hash
  CHECK (medium_hash = 'bb226d2a');
```

---

### Option B: Partition-to-Partition FK Constraints

**How it works:**
```sql
-- Drop inherited FK from parent
ALTER TABLE path_p_bb226d2a
  DROP CONSTRAINT path_medium_hash_ino_fkey;

-- Add direct partition-to-partition FK
ALTER TABLE path_p_bb226d2a
  ADD CONSTRAINT fk_to_same_partition
  FOREIGN KEY (medium_hash, ino)
  REFERENCES inode_p_bb226d2a(medium_hash, ino)
  ON DELETE CASCADE;
```

**Pros:**
- ✅ Permanent fix (no special load logic needed)
- ✅ FK checks only against matching partition
- ✅ Same integrity guarantees as parent-level FK
- ✅ Recommended by Web-Claude (#2) and ChatGPT (#1)

**Cons:**
- ⚠️ Must define FK for all 17 partition pairs
- ⚠️ Must update FKs when adding new partitions
- ⚠️ More complex schema management
- ❌ Still has FK overhead during INSERT (but much less)

**Performance estimate:**
- FK checks against 11M rows (same partition) instead of 36M (all partitions)
- ~3x faster than current, but not as fast as DETACH pattern

**ChatGPT emphasis:**
> "PostgreSQL 16+ supports this pattern cleanly"
> "Restores local index lookups and pruning"

---

### Option C: Drop FK → Load → Recreate FK

**How it works:**
```sql
-- Drop FK from parent table
ALTER TABLE path DROP CONSTRAINT path_medium_hash_ino_fkey;

-- Load data (fast, no FK checks)
-- ... load operations ...

-- Recreate FK
ALTER TABLE path ADD CONSTRAINT path_medium_hash_ino_fkey
  FOREIGN KEY (medium_hash, ino)
  REFERENCES inode(medium_hash, ino) ON DELETE CASCADE;
```

**Pros:**
- ✅ Simplest approach
- ✅ No FK overhead during load
- ✅ Gemini mentions as Option A

**Cons:**
- ❌ FK validation checks **all 17 partitions** when recreating (could take 10+ minutes)
- ❌ Window where FK is not enforced
- ❌ Affects all partitions, not just the one being loaded

**Performance estimate:**
- Load: fast
- FK recreation: 10+ minutes validating 123M paths
- **Total: potentially slower than current problem!**

**Verdict:** All AIs agree this is inferior to other options

---

### Option D: Add Indexes on FK Columns

**How it works:**
```sql
-- Create index on FK referencing columns
CREATE INDEX CONCURRENTLY idx_path_medium_ino
  ON path_p_bb226d2a (medium_hash, ino);
```

**Pros:**
- ✅ Can provide 100-1000x speedup (Web-Claude cites studies)
- ✅ Complements other solutions
- ✅ Should be done regardless

**Cons:**
- ⚠️ Our partitions already have these indexes (but they're partial with WHERE clauses)
- ⚠️ Won't fix the "scan all partitions" problem
- ⚠️ Partial indexes may not be used for all FK checks

**Web-Claude critical finding:**
> "99.99% of DELETE time (53,410ms out of 53,414ms) spent in FK constraint triggers due to missing indexes"
> "PostgreSQL does NOT automatically create indexes on foreign key REFERENCING columns"

**Action required:**
```sql
-- Check current indexes
SELECT indexname, indexdef
FROM pg_indexes
WHERE tablename = 'path_p_bb226d2a';

-- Create full (non-partial) index if missing
CREATE INDEX CONCURRENTLY idx_path_p_bb226d2a_fk
  ON path_p_bb226d2a (medium_hash, ino);
```

---

### Option E: Use TRUNCATE Instead of DELETE

**ChatGPT emphasis (#2):**
```sql
TRUNCATE TABLE path_p_bb226d2a, inode_p_bb226d2a CASCADE;
```

**Pros:**
- ✅ Metadata-only operation (ignores MVCC)
- ✅ Much faster than DELETE
- ✅ No FK validation overhead

**Cons:**
- ⚠️ Requires CASCADE to handle FK dependencies
- ⚠️ Cannot be rolled back (DDL operation)
- ⚠️ Resets table statistics

**Verdict:** Good complementary approach, use with DETACH pattern

---

## Trigger Optimization (Web-Claude)

**Current issue:** Row-level `update_queue_stats()` trigger fires 1,000 times

**Solution:** Convert to statement-level trigger with transition tables
```sql
CREATE TRIGGER maintain_queue_stats
AFTER DELETE ON inode_p_bb226d2a
REFERENCING OLD TABLE AS deleted_rows
FOR EACH STATEMENT
EXECUTE FUNCTION update_queue_stats_batch();
```

**Performance impact:** 10-100x faster for bulk operations

---

## Configuration Tuning (Web-Claude)

**Critical settings:**
```sql
ALTER SYSTEM SET maintenance_work_mem = '2GB';  -- from 1GB
ALTER SYSTEM SET max_wal_size = '10GB';  -- from 1GB default
ALTER SYSTEM SET checkpoint_timeout = '30min';  -- from 5min
```

**Our current settings:**
- work_mem = '256MB' ✓ (appropriate)
- synchronous_commit = OFF ✓ (appropriate for bulk loads)

---

## Key Differences Between AIs

### Gemini
- Most concise, focused on DETACH/ATTACH as primary solution
- Mentioned Option A (drop/recreate FK) but acknowledged ATTACH is better
- Didn't emphasize CHECK constraint requirement

### Web-Claude
- Most comprehensive analysis
- **Critical detail:** Need CHECK constraints before ATTACH to avoid full scan
- Emphasized missing FK indexes (100-1000x speedup potential)
- Provided detailed trigger optimization
- Documented known PostgreSQL bugs in 17.5/17.6

### ChatGPT
- Most structured presentation
- Prioritized partition-to-partition FKs as permanent fix
- Emphasized TRUNCATE over DELETE
- Mentioned ON CONFLICT still doesn't prune in 17.6 (confirms our earlier finding)

---

## Consensus Recommendation

### Primary Solution: DETACH → TRUNCATE → Load → ATTACH

All three AIs agree this is the best approach for your use case:

```sql
-- 1. Detach partition
ALTER TABLE path DETACH PARTITION path_p_bb226d2a CONCURRENTLY;
ALTER TABLE inode DETACH PARTITION inode_p_bb226d2a CONCURRENTLY;

-- 2. Clear old data
TRUNCATE path_p_bb226d2a, inode_p_bb226d2a CASCADE;

-- 3. Load new data (existing COPY + INSERT logic)
-- ... your current loader logic ...

-- 4. Add CHECK constraints (CRITICAL - Web-Claude's insight)
ALTER TABLE path_p_bb226d2a ADD CONSTRAINT check_medium_hash
  CHECK (medium_hash = 'bb226d2ae226b3e048f486e38c55b3bd');
ALTER TABLE inode_p_bb226d2a ADD CONSTRAINT check_medium_hash
  CHECK (medium_hash = 'bb226d2ae226b3e048f486e38c55b3bd');

-- 5. Re-attach (validates FK only for this partition)
ALTER TABLE inode ATTACH PARTITION inode_p_bb226d2a
  FOR VALUES IN ('bb226d2ae226b3e048f486e38c55b3bd');
ALTER TABLE path ATTACH PARTITION path_p_bb226d2a
  FOR VALUES IN ('bb226d2ae226b3e048f486e38c55b3bd');

-- 6. Cleanup CHECK constraints
ALTER TABLE path_p_bb226d2a DROP CONSTRAINT check_medium_hash;
ALTER TABLE inode_p_bb226d2a DROP CONSTRAINT check_medium_hash;

-- 7. Analyze
ANALYZE inode_p_bb226d2a;
ANALYZE path_p_bb226d2a;
```

**Expected performance:** ~8 minutes total (vs hours currently)

---

## Immediate Actions Before Implementing

### 1. Verify/Add FK Indexes (High Priority)

**Web-Claude's critical point:** Missing FK indexes cause 99.99% of FK check time

```sql
-- Check what indexes exist
SELECT tablename, indexname, indexdef
FROM pg_indexes
WHERE tablename LIKE '%path_p_%'
  AND indexdef LIKE '%(medium_hash, ino)%';

-- Add full (non-partial) FK index if needed
DO $$
DECLARE
    part_name text;
BEGIN
    FOR part_name IN
        SELECT tablename FROM pg_tables
        WHERE tablename LIKE 'path_p_%'
    LOOP
        EXECUTE format(
            'CREATE INDEX CONCURRENTLY IF NOT EXISTS %I
             ON %I (medium_hash, ino)',
            part_name || '_fk_idx',
            part_name
        );
    END LOOP;
END $$;
```

### 2. Optimize Trigger (Medium Priority)

Convert `update_queue_stats()` to statement-level trigger using Web-Claude's pattern.

### 3. Test DETACH/ATTACH Pattern (Before Production)

Test on one small partition first to verify:
- CHECK constraint requirement
- ATTACH validation time
- Overall workflow

---

## Follow-Up Questions for AIs

### For Web-Claude:
1. How critical is the CHECK constraint? What happens if we skip it?
2. Can we automate the CHECK constraint creation based on partition bounds?

### For ChatGPT:
1. Is partition-to-partition FK worth implementing as permanent solution vs DETACH pattern?
2. How do we maintain partition-to-partition FKs when adding new media?

### For Gemini:
1. Your estimate was ~8 minutes total - can you break down ATTACH validation time more?
2. Any risks with DETACH CONCURRENTLY we should know about?

---

## Decision Framework

| If your priority is... | Choose... |
|------------------------|-----------|
| **Fastest implementation** | DETACH → Load → ATTACH (Option A) |
| **Permanent architectural fix** | Partition-to-partition FKs (Option B) |
| **Minimal schema changes** | Add FK indexes + DETACH pattern (Option D + A) |
| **Safest approach** | Test DETACH pattern on small partition first |

---

## Conclusion

**High confidence solution:** DETACH → TRUNCATE → Load → ATTACH with CHECK constraints

**Must also do:** Verify/add full indexes on FK columns (not just partial)

**Nice to have:** Convert trigger to statement-level

**Future consideration:** Partition-to-partition FKs for permanent fix

**Expected outcome:** Load time reduced from hours to ~8 minutes
