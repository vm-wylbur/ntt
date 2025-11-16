<!--
Author: PB and Claude
Date: Sat 16 Nov 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/partition-drop-solutions-comparison.md
-->

# PostgreSQL Partition Drop Solutions: Comprehensive Comparison

## Problem Statement

Need to drop 488,362 partitioned tables (244,181 path partitions + 244,181 inode partitions) as part of migration to unpartitioned schema. Standard `DROP TABLE CASCADE` takes 1-2 hours due to serial catalog processing.

**Context:**
- New schema ready: paths_provisional (231,628,765 rows, 146 GB)
- Goal: Minimize downtime during cutover
- Constraint: FK relationships between path/inode partition pairs

---

## Solution Approaches Analyzed

### 1. Original Approach (Claude - Initial)
**Strategy:** TRUNCATE before DROP to speed up operation

**Implementation:**
```sql
TRUNCATE TABLE path CASCADE;
TRUNCATE TABLE inode CASCADE;
DROP TABLE path CASCADE;
DROP TABLE inode CASCADE;
```

**Theory:** TRUNCATE removes data quickly, then DROP on empty tables is faster.

**Reality:** ❌ **FAILED**
- TRUNCATE CASCADE on partitioned tables also iterates partition-by-partition
- No performance improvement over direct DROP
- Both operations are O(n) where n = partition count

**Verdict:** Based on incorrect assumption that TRUNCATE would be faster. It's not.

---

### 2. Kimi's Approach
**Strategy:** Parallel DROP using Python ThreadPoolExecutor

**Implementation:**
```python
from concurrent.futures import ThreadPoolExecutor
import psycopg2

def drop_partition(partition_name):
    conn = psycopg2.connect("dbname=copyjob")
    cur = conn.cursor()
    cur.execute(f"DROP TABLE {partition_name};")
    conn.commit()
    cur.close()
    conn.close()

# Get partition list
partition_names = [...]  # from pg_tables query

# Drop in parallel
with ThreadPoolExecutor(max_workers=10) as executor:
    executor.map(drop_partition, partition_names)
```

**Strengths:**
- ✅ Addresses core problem: parallelism can reduce wall-clock time
- ✅ Uses multiple connections to avoid client-side serialization
- ✅ Simple, straightforward Python code

**Weaknesses:**
- ❌ Doesn't handle FK constraint ordering (path must be dropped before inode)
- ❌ Uses f-string interpolation (SQL injection risk, though safe here)
- ❌ Missing CASCADE in DROP statement
- ❌ No error aggregation/reporting
- ⚠️ Unclear if parallelism helps or creates catalog lock contention

**Fixes Needed:**
1. Drop all path partitions first, then all inode partitions
2. Add CASCADE to DROP statements
3. Use proper identifier quoting
4. Add error handling and reporting

**Estimated Time Savings:** Unknown - could be 2-8x faster IF catalog locks don't serialize operations

**Downtime Impact:** Still requires all drops to complete during cutover (30-60 minutes best case)

**Risk Level:** Medium - FK violations if not ordered correctly

---

### 3. Gemini's Approach
**Strategy:** Generate individual DROP commands, execute in parallel shell processes

**Implementation:**
```sql
-- Generate DROP commands from system catalogs
SELECT 'DROP TABLE IF EXISTS ' || quote_ident(nmsp_child.nspname) || '.' ||
       quote_ident(child.relname) || ' CASCADE;'
FROM pg_inherits
JOIN pg_class child ON pg_inherits.inhrelid = child.oid
JOIN pg_namespace nmsp_child ON child.relnamespace = nmsp_child.oid
JOIN pg_class parent ON pg_inherits.inhparent = parent.oid
WHERE parent.relname = 'path';
```

```bash
# Split into chunks and run in parallel
split -l 10000 drop_commands.sql chunk_
for chunk in chunk_*; do
    psql -d copyjob -f $chunk &
done
wait
```

**Strengths:**
- ✅ Uses `quote_ident()` for SQL injection safety
- ✅ Queries system catalogs (more robust than pattern matching)
- ✅ Shell-based parallelism (no Python dependencies)
- ✅ Excellent explanation of WHY operations are slow

**Weaknesses:**
- ❌ Incomplete implementation (no actual shell script provided)
- ❌ Doesn't specify FK constraint ordering
- ❌ No guidance on optimal parallelism level
- ⚠️ Splitting file by line count doesn't guarantee balanced workload

**Comparison to Kimi:**
- More robust partition discovery (system catalogs vs pattern match)
- Less complete implementation (conceptual vs working code)
- Same fundamental approach (parallel drops)

**Estimated Time Savings:** Similar to Kimi - 2-8x IF parallelism helps

**Downtime Impact:** Still requires all drops during cutover (30-60 minutes best case)

**Risk Level:** Medium - incomplete implementation, FK ordering unclear

---

### 4. ChatGPT's Approach ⭐
**Strategy:** Fast rename cutover, then background cleanup

**Implementation:**
```sql
-- Phase 1: Fast cutover (seconds)
BEGIN;
ALTER TABLE path RENAME TO path_old;
ALTER TABLE inode RENAME TO inode_old;
ALTER TABLE paths_provisional RENAME TO path;
ALTER TABLE blobs_provisional RENAME TO blobs;
COMMIT;

-- Phase 2: Background cleanup (hours, no user impact)
-- Run this separately after cutover
DROP TABLE path_old CASCADE;
DROP TABLE inode_old CASCADE;
```

**Strengths:**
- ✅ **Solves the actual problem**: Minimizes user-visible downtime
- ✅ Cutover takes seconds (just renames)
- ✅ Drop happens in background after app is already using new schema
- ✅ Low risk, well-tested pattern
- ✅ No complex parallelism needed
- ✅ Clear separation of concerns (cutover ≠ cleanup)

**Weaknesses:**
- None significant - this is the pragmatic solution

**Why This Wins:**
1. **Business problem vs technical problem**: Users don't care when old tables drop, only that new tables are live
2. **Minimal downtime**: Seconds instead of 30-60+ minutes
3. **Flexibility**: Can choose cleanup strategy afterward based on system load
4. **Risk reduction**: Cleanup failures don't affect production app

**Estimated Time Savings:** Infinite - cutover downtime goes from 30-120 minutes to ~5 seconds

**Downtime Impact:** ~5 seconds (time to execute 4 renames in single transaction)

**Risk Level:** Very Low - standard pattern, minimal complexity

**Optional Optimizations for Background Cleanup:**
1. Drop FK constraints between partitions first
2. Use parallel drops (Kimi/Gemini approach) for faster cleanup
3. Move to new database and DROP DATABASE old one

---

### 5. Web-Claude's Approaches

Web-Claude proposed 4 options:

#### **Option 1: Parallel DETACH PARTITION CONCURRENTLY**

**Implementation:**
```bash
# Generate DETACH commands
psql -At -c "SELECT 'ALTER TABLE path DETACH PARTITION ' || tablename || ' CONCURRENTLY;'
             FROM pg_tables WHERE tablename LIKE 'path_%'" > detach_commands.sql

# Run in parallel
parallel -j 16 psql -d copyjob -c {} :::: detach_commands.sql

# Drop parent, then drop detached partitions in parallel
psql -c "DROP TABLE path, inode;"
parallel -j 32 psql -c "DROP TABLE {}" :::: partition_list.txt
```

**Critical Problems:**
- ❌ **Misunderstands CONCURRENTLY**: It means "don't block reads," not "parallel execution"
- ❌ DETACH is still O(n) catalog operations, not faster than DROP
- ❌ GNU parallel syntax won't work correctly for SQL commands
- ❌ Still requires all detaches to complete during cutover

**Verdict:** Based on misconception. DETACH PARTITION CONCURRENTLY doesn't solve the speed problem.

#### **Option 2: Rename and Background Drop** ✅

**This is identical to ChatGPT's approach.** Correct solution.

#### **Option 3: Direct Catalog Manipulation** 🚫

**Implementation:**
```sql
SET session_replication_role = 'replica';
BEGIN;
DELETE FROM pg_inherits WHERE inhparent IN (...);
DROP TABLE path;
DROP TABLE inode;
-- Delete directly from pg_class
DELETE FROM pg_class WHERE relname IN (...);
COMMIT;
```

**THIS IS CATASTROPHICALLY DANGEROUS:**
- 🚫 **Will corrupt the database**
- 🚫 Bypasses dependency checking
- 🚫 Leaves orphaned files on disk
- 🚫 Breaks catalog referential integrity
- 🚫 Missing cleanup of pg_attribute, pg_constraint, pg_index, pg_depend, pg_statistic
- 🚫 `session_replication_role = 'replica'` doesn't make this safe

**Verdict:** **NEVER DO THIS.** This is the "filesystem manipulation" approach that everyone warns against, just one level up.

#### **Option 4: pg_repack**

**Implementation:**
```bash
pg_repack -d copyjob -t paths_provisional -t blobs_provisional
```

**Problems:**
- ❌ Misunderstands pg_repack purpose (it's for reclaiming bloat, not schema migration)
- ❌ Targets wrong tables (paths_provisional is already the destination)
- ❌ Doesn't help with partition drop problem

**Verdict:** Irrelevant to the problem.

**Web-Claude's Recommendation:** Option 2 (correct), but presenting Option 3 as viable is dangerous.

---

## Comprehensive Comparison Matrix

| Approach | Cutover Time | Cleanup Time | Complexity | Risk | Solves Problem? |
|----------|--------------|--------------|------------|------|-----------------|
| **Original (TRUNCATE first)** | 1-2 hours | N/A | Low | Low | ❌ No - not faster |
| **Kimi (Python parallel)** | 30-120 min | N/A | Medium | Medium | ⚠️ Partial - still blocks cutover |
| **Gemini (Shell parallel)** | 30-120 min | N/A | Medium | Medium | ⚠️ Partial - still blocks cutover |
| **ChatGPT (Rename)** | **5 seconds** | 1-2 hours (bg) | Low | Very Low | ✅ **YES** |
| **Web-Claude #1 (DETACH)** | 1-2 hours | N/A | Medium | Medium | ❌ No - misconception |
| **Web-Claude #2 (Rename)** | **5 seconds** | 1-2 hours (bg) | Low | Very Low | ✅ **YES** |
| **Web-Claude #3 (Catalog)** | Unknown | N/A | High | **EXTREME** | 🚫 **Corrupts DB** |
| **Web-Claude #4 (pg_repack)** | N/A | N/A | Low | Low | ❌ Irrelevant |

---

## Technical Deep Dive: Why Most Solutions Don't Work

### The Fundamental Problem

PostgreSQL partitioned tables create:
- 244,181 entries in pg_class (one per partition)
- 244,181 entries in pg_inherits (parent-child relationships)
- 244,181 sets of entries in pg_attribute (columns per partition)
- Hundreds of thousands of FK constraint entries in pg_constraint
- Hundreds of thousands of dependency entries in pg_depend
- Each partition has its own indexes, toast tables, statistics

**When you DROP TABLE CASCADE:**
1. Acquires exclusive lock on parent table
2. Walks pg_inherits to find all children
3. For EACH partition:
   - Acquires lock
   - Walks pg_depend to find dependencies
   - Updates pg_class, pg_attribute, pg_constraint, pg_index, etc.
   - Deletes filesystem files
   - Releases lock
4. Finally drops parent

**This is serial, O(n) catalog work.** ~78 partitions/minute observed.

### Why TRUNCATE Doesn't Help

TRUNCATE on partitioned tables also walks each partition:
1. Acquires locks on all partitions
2. For EACH partition:
   - Truncates data
   - Resets sequences
   - Updates statistics
3. Serial catalog updates

**Same O(n) problem, different operations.**

### Why Parallel Drops *Might* Help

**Theory:**
- Multiple psql/Python processes
- Each process drops subset of partitions
- Wall-clock time = (total time) / (parallelism factor)

**Reality Check:**
- System catalog tables (pg_class, etc.) are shared resources
- Heavy lock contention on catalog tables
- May serialize operations anyway
- Unclear if 2-8x speedup is achievable or if locks dominate

**Testing needed** to determine if parallelism helps or just moves bottleneck.

### Why Rename Wins

**Key insight:** Cutover ≠ Cleanup

Rename operations:
- Update 4 rows in pg_class (just the parent tables)
- No partition walking
- Seconds, not hours
- Atomic transaction

Users immediately get new schema. Old partitions can die slowly in background.

---

## Recommended Implementation Plan

### Phase 1: Pre-Cutover Verification
```sql
-- Verify new tables ready
SELECT 'paths_provisional', COUNT(*) FROM paths_provisional;
-- Expected: 231,628,765

SELECT 'blobs_provisional', COUNT(*) FROM blobs_provisional;

-- Verify FK exists
SELECT conname, conrelid::regclass, confrelid::regclass
FROM pg_constraint
WHERE conname LIKE '%paths_provisional%';

-- Verify indexes
\d paths_provisional
-- Should have PRIMARY KEY
```

### Phase 2: Fast Cutover (Seconds)
```sql
-- Stop all workers first!
-- ntt-copier, ntt-orchestrator, ntt-loader must be stopped

BEGIN;

-- Rename old partitioned tables out of the way
ALTER TABLE path RENAME TO path_old_to_drop;
ALTER TABLE inode RENAME TO inode_old_to_drop;

-- Rename new tables into production names
ALTER TABLE paths_provisional RENAME TO path;
ALTER TABLE blobs_provisional RENAME TO blobs;

COMMIT;

-- Restart workers pointing at new schema
```

**Expected downtime:** 5-10 seconds

### Phase 3: Background Cleanup (Choose One)

#### **Option A: Simple (Recommended)**
```bash
# Run in screen/tmux during low-traffic window
psql -d copyjob -c "DROP TABLE path_old_to_drop CASCADE;"
psql -d copyjob -c "DROP TABLE inode_old_to_drop CASCADE;"
```
**Time:** 1-2 hours, no user impact

#### **Option B: Pre-drop FK Constraints**
```sql
-- Generate FK drop commands
SELECT 'ALTER TABLE ' || conrelid::regclass || ' DROP CONSTRAINT ' || conname || ';'
FROM pg_constraint
WHERE contype = 'f'
  AND conrelid::regclass::text LIKE 'path_%'
  AND confrelid::regclass::text LIKE 'inode_%'
\gexec

-- Then drop tables (possibly slightly faster)
DROP TABLE path_old_to_drop CASCADE;
DROP TABLE inode_old_to_drop CASCADE;
```
**Time:** 1-2 hours, possibly 10-20% faster

#### **Option C: Parallel Cleanup (Experimental)**
```python
# Only if you want to test parallel approach
# Must drop all path partitions before any inode partitions

import psycopg2
from concurrent.futures import ThreadPoolExecutor

def drop_partition(partition_name):
    conn = psycopg2.connect("dbname=copyjob")
    conn.autocommit = True
    cur = conn.cursor()
    try:
        cur.execute(f"DROP TABLE IF EXISTS {partition_name} CASCADE;")
        return (partition_name, "ok")
    except Exception as e:
        return (partition_name, str(e))
    finally:
        cur.close()
        conn.close()

# Get partitions from system catalogs
conn = psycopg2.connect("dbname=copyjob")
cur = conn.cursor()

cur.execute("""
    SELECT child.relname
    FROM pg_inherits
    JOIN pg_class parent ON pg_inherits.inhparent = parent.oid
    JOIN pg_class child ON pg_inherits.inhrelid = child.oid
    WHERE parent.relname = 'path_old_to_drop'
    ORDER BY child.relname;
""")
path_partitions = [row[0] for row in cur.fetchall()]

cur.execute("""
    SELECT child.relname
    FROM pg_inherits
    JOIN pg_class parent ON pg_inherits.inhparent = parent.oid
    JOIN pg_class child ON pg_inherits.inhrelid = child.oid
    WHERE parent.relname = 'inode_old_to_drop'
    ORDER BY child.relname;
""")
inode_partitions = [row[0] for row in cur.fetchall()]

cur.close()
conn.close()

# Drop path partitions first (parallel)
print(f"Dropping {len(path_partitions)} path partitions...")
with ThreadPoolExecutor(max_workers=8) as executor:
    results = list(executor.map(drop_partition, path_partitions))
    failures = [r for r in results if r[1] != "ok"]
    print(f"Failures: {len(failures)}")

# Drop parent path table
conn = psycopg2.connect("dbname=copyjob")
conn.cursor().execute("DROP TABLE path_old_to_drop CASCADE;")
conn.commit()
conn.close()

# Drop inode partitions (parallel)
print(f"Dropping {len(inode_partitions)} inode partitions...")
with ThreadPoolExecutor(max_workers=8) as executor:
    results = list(executor.map(drop_partition, inode_partitions))
    failures = [r for r in results if r[1] != "ok"]
    print(f"Failures: {len(failures)}")

# Drop parent inode table
conn = psycopg2.connect("dbname=copyjob")
conn.cursor().execute("DROP TABLE inode_old_to_drop CASCADE;")
conn.commit()
conn.close()
```

**Time:** Unknown - test needed. Possibly 15-30 minutes if parallelism helps.

**Risk:** Medium - more moving parts, unclear if catalog locks serialize anyway.

---

## Final Recommendation

**Use ChatGPT's rename approach (Phase 1-2 above):**

1. ✅ **Minimal downtime**: 5 seconds instead of 30-120 minutes
2. ✅ **Low risk**: Standard pattern, simple transaction
3. ✅ **Solves business problem**: Users immediately get new schema
4. ✅ **Flexible cleanup**: Choose strategy afterward based on system load
5. ✅ **Battle-tested**: This pattern is used for large-scale migrations

**For background cleanup:**
- Start with Option A (simple DROP CASCADE)
- Only explore Option C (parallel) if testing shows real benefit
- Never use direct catalog manipulation (Web-Claude Option 3)

---

## Lessons Learned

### What Didn't Work:
1. **TRUNCATE before DROP**: Partitioned tables iterate partition-by-partition anyway
2. **DETACH PARTITION CONCURRENTLY**: Doesn't mean "parallel," still O(n)
3. **Direct catalog manipulation**: Will corrupt database

### What We Learned:
1. **244K partitions is way beyond recommended limits** (~1000 partitions is more typical)
2. **Catalog operations are serial** - no bulk primitive exists
3. **Decouple cutover from cleanup** - they're separate concerns
4. **Parallelism might help cleanup** - but testing needed to confirm

### Key Insight:
**The right solution often isn't "make the slow thing fast" but "make the slow thing irrelevant to users."**

---

## References

- PostgreSQL Partitioning: https://www.postgresql.org/docs/current/ddl-partitioning.html
- DROP TABLE: https://www.postgresql.org/docs/current/sql-droptable.html
- ALTER TABLE: https://www.postgresql.org/docs/current/sql-altertable.html
- Stack Overflow discussion on partition limits: (referenced by ChatGPT/Gemini)

---

## Appendix: System Information Needed

Before implementing, gather:
```sql
-- PostgreSQL version
SELECT version();

-- Current connection limits
SHOW max_connections;

-- Current active connections
SELECT COUNT(*) FROM pg_stat_activity;

-- Table sizes
SELECT
    schemaname || '.' || tablename as table,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as total_size
FROM pg_tables
WHERE tablename IN ('path', 'inode', 'paths_provisional', 'blobs_provisional')
ORDER BY tablename;

-- Partition counts
SELECT COUNT(*) as path_partitions FROM pg_tables WHERE tablename LIKE 'path_%';
SELECT COUNT(*) as inode_partitions FROM pg_tables WHERE tablename LIKE 'inode_%';
```
