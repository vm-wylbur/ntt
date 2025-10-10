<!--
Author: PB and Claude
Date: Fri 03 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/performance-investigation-2025-10-03.md
-->

<!-- completed: Early performance work; various optimizations implemented -->

# NTT Performance Investigation - Query Optimization

**Date**: 2025-10-03
**Issue**: Workers achieving only 85-111 i/s instead of target 1800+ i/s
**Root Cause**: TBD (investigation ongoing)

## Summary

Investigated slow claim query performance in ntt-copier workers. Target is 1800+ inodes/sec (based on previous partition2 processing), but seeing only 85-111 i/s with claim queries taking 100-130ms each.

## Key Findings

### 1. Index Usage Verification

**Test**: Compare query with/without `enable_seqscan`

```sql
-- Default settings (seqscan enabled)
EXPLAIN ANALYZE
WITH locked_row AS (
    SELECT medium_hash, ino FROM inode
    WHERE copied = false AND claimed_by IS NULL
      AND medium_hash = 'd9549175fb3638efbc919bdc01cb3310'
    LIMIT 1 FOR UPDATE SKIP LOCKED
) SELECT * FROM locked_row;
```

**Result**: 567ms with Seq Scan

```sql
-- With seqscan disabled
SET enable_seqscan = off;
-- (same query)
```

**Result**: 1ms with Index Scan on `idx_inode_unclaimed_medium`

**Conclusion**: Forcing index usage gives 567x speedup in psql tests.

### 2. Full Query Timing

**Test**: Complete worker query (with UPDATE and path array aggregation)

```sql
SET enable_seqscan = off;
EXPLAIN ANALYZE
WITH locked_row AS (
    SELECT medium_hash, ino FROM inode
    WHERE copied = false AND claimed_by IS NULL
      AND medium_hash = 'd9549175fb3638efbc919bdc01cb3310'
    LIMIT 1 FOR UPDATE SKIP LOCKED
),
claimed AS (
    UPDATE inode i
    SET claimed_by = 'test', claimed_at = NOW()
    FROM locked_row lr
    WHERE (i.medium_hash, i.ino) = (lr.medium_hash, lr.ino)
    RETURNING i.*
)
SELECT c.*,
       (SELECT array_agg(p.path) FROM path p
        WHERE (p.medium_hash, p.ino) = (c.medium_hash, c.ino)) as paths
FROM claimed c;
```

**Result**: 1.5ms execution time in psql

**Conclusion**: Full query CAN be fast (~1.5ms) when index is used.

### 3. Worker Session Configuration

**Investigation**: Check if `SET enable_seqscan = off` persists in worker sessions

Added to `ntt-copier.py __init__`:
```python
with self.conn.cursor() as cur:
    cur.execute("SET enable_seqscan = off;")
self.conn.commit()

# Verify
with self.conn.cursor() as cur:
    cur.execute("SHOW enable_seqscan;")
    result = cur.fetchone()
    logger.info(f"Worker {self.worker_id} enable_seqscan setting: {result}")
```

**Result**: Setting correctly shows `{'enable_seqscan': 'off'}` in worker logs

**Conclusion**: Session-level SET is being applied correctly.

### 4. Actual Query Plan in Workers

**Investigation**: Capture EXPLAIN output from live workers

Added instrumentation to log first 3 query plans:
```python
explain_query = "EXPLAIN " + claim_query
cur.execute(explain_query, params)
plan = '\n'.join([list(row.values())[0] for row in cur.fetchall()])
logger.info(f"Query plan:\n{plan}")
```

**Result from worker logs**:
```
->  Index Scan using idx_inode_unclaimed_medium on inode
      Index Cond: (medium_hash = ANY ('{d9549175...}'::text[]))
      Filter: ((NOT copied) AND (claimed_by IS NULL))
```

**Conclusion**: Workers ARE using the index (not seq scan).

### 5. Worker Contention Hypothesis - DISPROVED

**Hypothesis**: 16 workers competing on same index causes slowdown

**Test**: Run single worker and measure claim timing

**Result**: Single worker ALSO sees 105-127ms claim times

**Conclusion**: Worker contention is NOT the cause. Problem exists even with 1 worker.

### 6. Detailed Timing Breakdown

**Investigation**: Instrument claim query to isolate bottleneck

```python
t0 = time.time()
# ... cursor setup
t1 = time.time()
cur.execute(claim_query, params)
t2 = time.time()
row = cur.fetchone()
t3 = time.time()
self.conn.commit()
t4 = time.time()

logger.warning(f"Slow claim: total={((t4-t0)*1000):.1f}ms "
               f"execute={((t2-t1)*1000):.1f}ms "
               f"fetch={((t3-t2)*1000):.1f}ms "
               f"commit={((t4-t3)*1000):.1f}ms")
```

**Results** (from worker logs):
- `execute`: 105-132ms (the query itself)
- `fetch`: 0-0.1ms (negligible)
- `commit`: 0.5-1ms (negligible)

**Conclusion**: Entire delay is in `cur.execute()` - the query execution.

### 7. Cache Warming Effect - NEW FINDING

**Observation**: First few claims after worker starts are FAST

From worker logs (worker-01):
```
17:22:09.108 - Processing work unit ino=22809   (first claim)
17:22:09.110 - Completed work unit
17:22:09.110 - Processing work unit ino=22810   (<1ms gap!)
17:22:09.111 - Completed work unit
17:22:09.111 - Processing work unit ino=22810   (<1ms gap!)
... (items 1-9 processed in 21ms total = ~2ms per claim)
17:22:09.256 - Slow claim: total=125.0ms       (claim #10)
17:22:09.363 - Slow claim: total=105.9ms       (claim #11)
... (all subsequent claims are 105-125ms)
```

**Pattern**:
- Claims 1-9: <2ms each (FAST - matching psql tests)
- Claims 10+: 105-125ms each (SLOW)

**Hypothesis**: Index pages are cached for first few queries, then evicted or scan strategy changes.

### 8. EXPLAIN ANALYZE Bug - CRITICAL FINDING

**Investigation**: Instrumented worker to log EXPLAIN (ANALYZE, BUFFERS) for first 20 queries

**Result**: First 7 queries showed fast execution (0.1-0.7ms) with 100% cache hits

**Critical Discovery**: EXPLAIN (ANALYZE, BUFFERS) **actually executes the query** (because of ANALYZE), so:
1. Line 309: EXPLAIN executes query → claims a row (fast!)
2. Line 316: Same query executes again → claims different row (slow!)

The "fast" EXPLAIN results were measuring different rows than the "slow" actual claims.

**Resolution**: Removed EXPLAIN instrumentation to test actual query performance without interference.

### 9. ROOT CAUSE IDENTIFIED

**Investigation**: Reproduced exact worker pattern in standalone Python script

**Result**: IDENTICAL behavior - first ~10 claims fast (<2ms), then all subsequent claims slow (105-135ms)

**Key Discovery - Sequential Depletion**:
- Claims 1-10 return sequential inodes: 22867, 22868, 22869, ..., 22876
- Claim 11 jumps to distant inode: 1263777
- After claiming first 10 contiguous rows, index scan must traverse many pages to find next unclaimed row
- Each subsequent claim scans farther through partially-depleted index (105ms per scan)

**ROOT CAUSE**: Worker code claims to use "TABLESAMPLE for large queues" (line 243) but **actually uses simple `LIMIT 1 FOR UPDATE SKIP LOCKED` for ALL queue sizes**. Both code branches (lines 244-266 and 269-291) are IDENTICAL.

**Impact**:
- 3.2M unclaimed rows (>50k threshold) should trigger TABLESAMPLE strategy
- Instead, uses linear index scan that becomes progressively slower as early inodes are claimed
- After first ~10 sequential inodes claimed, must scan through increasingly sparse index
- 105ms per claim = **70x slower than optimal**

**Solution**: Implement TABLESAMPLE hybrid approach per `/reference/postgres-random-selection.md`:
- Expected performance: 6-10ms warm queries (vs current 105ms)
- Prevents sequential depletion by true random sampling
- Reference doc shows 10-50ms with `TABLESAMPLE SYSTEM_ROWS(1000) ... ORDER BY RANDOM()`

## Attempted Fixes

1. ✅ **Set `enable_seqscan = off` at session level** - Applied correctly but doesn't fix slow queries
2. ✅ **Check query plan in workers** - Confirmed index usage
3. ❌ **Reduce worker count** - No improvement with 1 worker vs 16
4. ✅ **Reduce queue depth check frequency** - Changed from every 100 to every 1000 inodes (reduces COUNT overhead)

## Current Status

**Known**:
- Query CAN run in 1.5ms (proven in psql)
- Workers ARE using the correct index
- `enable_seqscan = off` IS applied
- Bottleneck is in query execution itself (not fetch/commit)
- First ~9 claims are fast (<2ms), then all subsequent claims are slow (105ms+)

**Unknown**:
- Why query execution is 70x slower in workers than in psql
- Why performance degrades after first few claims (cache eviction?)
- What causes the transition from fast→slow after ~9 claims

## Next Steps

**Hypothesis to test**: Index cache eviction or PostgreSQL buffer management

Possible investigations:
1. Check PostgreSQL `shared_buffers` and `work_mem` settings
2. Monitor buffer cache hits vs misses during worker execution
3. Test with `EXPLAIN (ANALYZE, BUFFERS)` to see actual buffer reads
4. Check if there's lock contention on index pages (even with SKIP LOCKED)
5. Investigate why cache "warms" for first 9 claims then "cools"
6. Test alternative query formulations (ORDER BY random(), OFFSET, etc.)

## Reference Data

**Index definition**:
```
idx_inode_unclaimed_medium btree (medium_hash, ino)
  WHERE copied = false AND claimed_by IS NULL
```

**Table stats**:
- Total rows: 33.7M
- Unclaimed for medium d954917...: 3.3M
- Index is correctly used in WHERE clause

**Environment**:
- PostgreSQL (version TBD)
- 16 workers (but problem exists with 1 worker too)
- Workers run as root via sudo (connecting as pball user)
- Medium: HFS+ disk image mounted read-only

By PB & Claude
