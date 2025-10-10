<!--
Author: PB and Claude
Date: Thu 10 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/lessons/performance-optimization-mime-backfill-2025-10-10.md
-->

<!-- lesson: Profile first, optimize iteratively; wrong optimizations can make things worse -->

# Performance Optimization: MIME Type Backfill - 2025-10-10

## Context

Need to backfill `mime_type` for 13.3M inodes (2.8M unique blobids) that have `blobid` but NULL `mime_type`. Initial implementation was too slow for production use.

**Task:** Detect MIME types from `/data/cold/by-hash` files and update database.

## The Iterative Optimization Process

### Baseline Performance (173 blobs/s)
- **Approach:** Batch size 1000, sequential MIME detection, individual UPDATE statements
- **Profile Results (10K blobids in 33.2s):**
  - Database queries: 5.9s (67%) - `SELECT DISTINCT` scanning partitioned table
  - MIME detection: 2.8s (32%) - `magic.from_file()` on full files
  - Path operations: 0.05s (0.5%)
- **Projected time:** 4.6 hours for 2.8M blobids

### Optimization Attempt 1: Server-Side Cursor ❌ FAILED

**Hypothesis:** Repeated `SELECT DISTINCT ... LIMIT` queries are slow, use streaming cursor instead.

**Implementation:**
```python
with conn.cursor(name='blobid_stream') as stream_cur:
    stream_cur.execute("SELECT DISTINCT blobid FROM inode WHERE ...")
    stream_cur.itersize = batch_size
    while True:
        batch = stream_cur.fetchmany(batch_size)
```

**Result:** **WORSE** - 70 blobs/s (2.4x slower!)
- Added 11.76s overhead for `fetchmany()` round-trips
- Server-side cursors only beneficial for millions of rows streamed continuously
- Not worth it for batched processing

**Lesson:** Not all "database optimization techniques" are universal - profile before assuming.

### Optimization Attempt 2: Larger Batch Size ✓ PARTIAL SUCCESS

**Approach:** Increase batch size from 1,000 to 10,000 to amortize query cost.

**Result:** Mixed
- Dry-run: 301 blobs/s (1.7x improvement)
- Real writes: 360 blobs/s
- Database queries still dominated (same 5.9s but for 10x data)
- MIME detection now the bottleneck: 30.2s (84% of time)

### Optimization Attempt 3: MIME Detection Improvements ✓ SUCCESS

**Two optimizations applied:**

1. **`from_buffer()` instead of `from_file()`**
   ```python
   with open(file_path, 'rb') as f:
       buffer = f.read(2048)  # Only first 2KB
   mime_type = magic_detector.from_buffer(buffer)
   ```
   - Avoids reading entire files (some are GB-sized)

2. **Multiprocessing (8 workers)**
   ```python
   with multiprocessing.Pool(8) as pool:
       results = pool.map(_detect_mime_worker, worker_args)
   ```
   - Parallel MIME detection across CPU cores
   - Each worker has its own `magic.Magic` instance

**Result:** 2,128 blobs/s dry-run (7.1x improvement over baseline!)
- MIME detection: < 0.1s (no longer bottleneck)
- Database queries: 6.4s (now 81% of time)

### Optimization Attempt 4: Batch Database Updates ✓ SUCCESS

**Problem:** With real writes, 10,000 individual UPDATE statements = 22s overhead per batch.

**Solution:** Single UPDATE using UNNEST
```sql
UPDATE inode
SET mime_type = data.mime_type
FROM (SELECT UNNEST(%s::text[]) AS blobid,
             UNNEST(%s::text[]) AS mime_type) AS data
WHERE inode.blobid = data.blobid
  AND inode.mime_type IS NULL
```

**Result:** 1,281 blobs/s with real database writes (7.4x improvement!)
- Batch 1: 7.8s (vs 26.3s before)
- Batch 2: 8.6s
- Batch 3: 9.2s

## Final Performance Comparison

| Version | Time (10K blobs) | Rate | Projected Total |
|---------|-----------------|------|-----------------|
| Baseline | 33.2s | 173 blobs/s | 4.6 hours |
| +Batch size | 33.2s | 301 blobs/s | 2.6 hours |
| +MIME opts (dry) | 4.7s | 2,128 blobs/s | 22 min |
| **+Batch UPDATE** | **7.8s** | **1,281 blobs/s** | **37 min** |

## What Went Wrong (Server-Side Cursor)

**Why it seemed like a good idea:**
- "Avoid repeated expensive queries"
- "Stream data efficiently"
- Common optimization pattern

**Why it failed:**
- Server-side cursors have round-trip overhead
- `fetchmany()` added 11.76s for 10K rows
- Only beneficial for continuous streaming of millions of rows
- Our use case: discrete batches with processing between

**Red flag missed:** Should have tested on 1K batch first before assuming it would help.

## Lessons Learned

### DO:
- **Profile before optimizing** - Measure, don't guess the bottleneck
- **Profile after each change** - Verify improvement, detect regressions
- **Use cProfile for Python** - Added `--profile` flag from the start
- **Test optimizations on small batches first** - Would have caught server-side cursor failure faster
- **Optimize iteratively** - Each profile reveals new bottleneck
- **Read only what you need** - 2KB buffer vs full file = huge win
- **Use appropriate tools** - Multiprocessing for CPU-bound, batch SQL for I/O-bound

### DON'T:
- **Don't assume "optimization X" always helps** - Server-side cursor made things worse
- **Don't over-engineer** - Simple batching worked better than fancy cursors
- **Don't optimize without metrics** - Profile-driven vs assumption-driven
- **Don't stop at first improvement** - Went from 173 → 301 → 2128 → 1281 b/s through iteration

## Prevention

For future performance work:

1. **Baseline first:** Measure current performance with profiling
2. **Identify bottleneck:** Use cProfile, not assumptions
3. **Single optimization:** Change ONE thing at a time
4. **Profile again:** Verify improvement and find next bottleneck
5. **Test on small data:** Catch failures early (1K batch before 10K)
6. **Document metrics:** Record before/after for each change

## Tools Used

- **cProfile:** Python deterministic profiler
- **pstats:** Profile analysis and reporting
- **PostgreSQL EXPLAIN ANALYZE:** Query performance
- **Multiprocessing Pool:** Parallel CPU work
- **UNNEST:** PostgreSQL batch operations

## References

- Script: `bin/ntt-backfill-mime.py`
- Profile data: `/tmp/mime-backfill.prof`
- Profiling methodology: Python cProfile → pstats sorted by cumulative time
