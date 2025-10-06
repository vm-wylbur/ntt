<!--
Author: PB and Claude
Date: Sun 05 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/loader-optimization-investigation-2025-10-05.md
-->

# NTT Loader Performance Investigation - 2025-10-05

## Problem Statement

The `ntt-loader` was taking 120+ minutes (stuck before completion) to load bb22 medium with 11.2M paths. The loader appeared to hang in the deduplication phase indefinitely.

**Target performance:** Load 11.2M paths in a reasonable time (goal: <20 minutes)

---

## Investigation Process

### Step 1: Identify the Bottleneck

**Hypothesis:** GROUP BY operations in the deduplication phase are the bottleneck.

**Method:** Analyzed existing staging table `tmp_path_2528743` with 11.2M rows from bb22:

```sql
SELECT
  COUNT(*) as staging_rows,
  COUNT(DISTINCT ino) as unique_inodes,
  COUNT(DISTINCT (ino, path)) as unique_ino_path_pairs,
  COUNT(*) FILTER (WHERE nlink > 1) as rows_with_hardlinks
FROM tmp_path_2528743;
```

**Results:**
- 11,267,245 staging rows
- 10,509,611 unique inodes (757K duplicate inode rows from hardlinks)
- 11,267,245 unique (ino, path) pairs - **ZERO duplicates!**
- 20.55% of rows have hardlinks (nlink > 1)

**Key Finding:** The path INSERT uses `GROUP BY ino,path` which creates 11.2M groups from 11.2M rows - achieves zero deduplication, pure overhead.

### Step 2: Profile the Actual Queries

Used `EXPLAIN (ANALYZE, BUFFERS, TIMING)` on the staging table to measure actual performance:

#### Current Loader Queries (Baseline)

**Inode INSERT:**
```sql
SELECT '$MEDIUM_HASH',MAX(dev),ino,MAX(nlink),MAX(size),MAX(mtime)
FROM   tmp_path_$$
GROUP  BY ino
```
**Time:** 3.98 seconds

**Path INSERT:**
```sql
SELECT '$MEDIUM_HASH',MAX(dev),ino,convert_to(path, 'LATIN1')
FROM   tmp_path_$$
GROUP  BY ino,path
```
**Time:** 6.91 seconds

**Total SELECT time:** 10.89 seconds

#### Optimized Queries

**Inode INSERT (DISTINCT ON):**
```sql
SELECT DISTINCT ON (medium_hash, ino)
       '$MEDIUM_HASH' as medium_hash, dev, ino, nlink, size, mtime
FROM   tmp_path_$$
ORDER BY medium_hash, ino
```
**Time:** 3.69 seconds (1.08x faster)

**Path INSERT (Direct SELECT):**
```sql
SELECT '$MEDIUM_HASH' as medium_hash, dev, ino, convert_to(path, 'LATIN1')
FROM   tmp_path_$$
```
**Time:** 3.15 seconds (2.19x faster)

**Total optimized SELECT time:** 6.84 seconds (1.59x faster)

### Step 3: Apply Optimizations

**Changes to `bin/ntt-loader` lines 134-162:**

1. **Fixed jq logging bug** (line 110) - was crashing when EXPECTED_RECORDS="unknown"
2. **Added session tuning:**
   - `SET work_mem = '256MB'`
   - `SET maintenance_work_mem = '1GB'`
   - `SET synchronous_commit = OFF`
3. **Changed inode INSERT** to use `DISTINCT ON` instead of `GROUP BY`
4. **Changed path INSERT** to use direct `SELECT` (removed wasteful `GROUP BY ino,path`)

---

## Critical Realization: Profiling vs Reality

**Initial expectation based on profiling:**
- SELECT queries: 6.84 seconds (vs 10.89s baseline)
- Expected total load time with overhead: ~15-20 minutes

**What we learned from actual production run:**

### Timeline Breakdown (bb22 - 11.2M rows, 2.1GB raw file)

**Previous attempt (baseline loader):**
- 11:23:51 - Load start (COPY phase begins)
- 11:28:54 - Dedupe start (COPY complete: **5m 3s**)
- Dedupe hung for 90+ minutes before we killed it

**Current attempt (optimized loader):**
- 13:23:34 - Load start (COPY phase begins)
- 13:28:47 - Dedupe start (COPY complete: **5m 13s**)
- 13:31:33 - Still in inode INSERT (**2m 46s and counting**)
- Only 1,000 inodes inserted so far (out of 10.5M expected)

### The Gap Between Profiling and Reality

**Profiling measured:** Just the SELECT portion (~3.69s for inode query)

**Reality includes:**
- The SELECT query execution
- INSERT operation overhead
- **ON CONFLICT constraint checking** (checks uniqueness for every row)
- Index updates (multiple indexes on inode and path tables)
- Foreign key constraint validation
- Write-ahead log (WAL) overhead
- Buffer/cache management

**The ON CONFLICT overhead is massive** - checking uniqueness on 11.2M rows against existing data and indexes is expensive.

---

## What We're Actually Trying to Solve

### Core Problem
Loading 11+ million filesystem paths from enumerated media into PostgreSQL takes prohibitively long (hours vs minutes).

### Why This Matters
- **Workflow blocker:** Cannot efficiently ingest large drives (common case)
- **Resource waste:** Ties up database and system resources for hours
- **Scalability:** bb22 is just one medium; we have many to process

### The Real Bottleneck (Revised Understanding)

**Not just GROUP BY overhead**, but the combination of:

1. **Wasteful GROUP BY operations** (especially path GROUP BY that does nothing)
2. **ON CONFLICT constraint checking** on massive inserts
3. **Index maintenance overhead** during bulk inserts
4. **Multiple constraint validations** per row

### What GROUP BY Optimization Actually Achieved

**Before optimization:**
- Inode: GROUP BY + MAX aggregations + constraint checks
- Path: GROUP BY + convert_to() + constraint checks

**After optimization:**
- Inode: DISTINCT ON (simpler, less aggregation) + constraint checks
- Path: Direct SELECT + convert_to() + constraint checks

**Savings:** Eliminated redundant sorting/grouping, but ON CONFLICT overhead remains.

---

## Alternative Approaches to Consider

### 1. Disable Constraints During Load
```sql
ALTER TABLE path DISABLE TRIGGER ALL;
-- load data
ALTER TABLE path ENABLE TRIGGER ALL;
```
**Risk:** Potential data integrity issues if load fails mid-way

### 2. Use COPY for Final Tables
Skip staging table entirely, COPY directly into final tables with ON CONFLICT
**Challenge:** Need to pre-format data exactly right (bytea conversion, medium_hash)

### 3. Partition by Medium Hash
If path table is partitioned by medium_hash, new medium insertions hit empty partition (no conflicts)
**Benefit:** ON CONFLICT checks only against small partition, not entire table

### 4. Bulk Insert with Post-Processing
Insert everything with a temporary flag, then deduplicate in a second pass
**Benefit:** Avoids ON CONFLICT overhead during insert

### 5. Parallel Workers
Split staging table by ino ranges, parallel INSERT workers
**Benefit:** PostgreSQL can parallelize the work

---

## Current Status (As of 13:31)

**bb22 load in progress with optimized loader:**
- COPY phase: **5m 13s** ✓ (unchanged, as expected)
- Dedupe phase: **Still running** (inode INSERT at 2m 46s, only 1K of 10.5M rows inserted)

**What we're watching for:**
- How long does the optimized dedupe actually take end-to-end?
- Is the ON CONFLICT overhead the dominant factor?
- Does the optimization provide meaningful speedup despite ON CONFLICT costs?

---

## Lessons Learned

1. **Profiling SELECT queries alone is misleading** - must profile the full INSERT with constraints
2. **ON CONFLICT is expensive at scale** - checking uniqueness against large indexes is slow
3. **The Perl COPY preprocessing is not the bottleneck** - takes ~5 minutes consistently
4. **GROUP BY optimization helps, but may not be enough** - need to consider alternative loading strategies
5. **Diagnosis before optimization** - our analysis correctly identified waste, but underestimated constraint overhead

---

## Next Steps (Pending Current Run Completion)

1. **Measure actual end-to-end time** for optimized loader on bb22
2. **Calculate real speedup** vs baseline (if we can reconstruct baseline timing)
3. **Decide if optimization is sufficient** or if we need architectural changes
4. **Consider alternative approaches** listed above if speedup is inadequate
5. **Document findings** and update loader with best approach

---

## Files Modified

- `bin/ntt-loader` - Applied GROUP BY optimization and session tuning
- Created test infrastructure:
  - `/tmp/test_100k.raw` - 100K row test dataset from bb22
  - `/tmp/test_1m.raw` - 1M row test dataset from bb22
  - `/tmp/ntt-loader-v{1-5}-*` - Variant loaders with incremental optimizations
  - `/tmp/watch_bb22_load.sh` - Real-time monitoring script
  - `/tmp/analyze_bb22_timing.sh` - Timing analysis script
