<!--
Author: PB and Claude
Date: 2025-11-17
License: (c) HRDAG, 2025, GPL-2 or newer

---
ntt/docs/lessons/profiling-copier-performance-2025-11-17.md
-->

# NTT Copier Performance Profiling - 2025-11-17

## Context

After migrating from partitioned to unpartitioned schema (v2.0), copier performance degraded from 100+ files/sec to ~1.5 files/sec. Initial hypothesis blamed synchronous processing, but profiling revealed the real bottleneck.

**Git commit:** `642ec1a` - Add batched failure UPDATEs and cProfile instrumentation
**Test medium:** vxa-tape1 (`b82431235963a5b1a8c5ab27dee5413a`, 1,999 paths, 3.3GB data)
**Test size:** 100 files, batch_size=50

## Initial Hypothesis (WRONG)

TODO-20251117.md blamed "synchronous processing" - workers processing files one-by-one instead of in parallel. This was incorrect. A single thread should easily process 100+ files/sec.

**Actual problem:** Performance testing methodology and missing tmpfs ramdisk.

## Testing Methodology Issues

### Problem 1: Cache Warming Effects

Initial tests compared apples-to-oranges:
- First run: Cold PostgreSQL cache, cold filesystem cache, empty Redis
- Second run: Warm caches everywhere
- Result: 7.85s → 0.047s queue population (167x speedup from caching alone)

**Lesson:** Must clear ALL caches between test runs:
```bash
# Clear Redis
redis-cli FLUSHALL

# Clear PostgreSQL claims
psql -d copyjob -c "UPDATE paths SET claimed_by = NULL WHERE medium_hash = '...'"

# Clear PostgreSQL shared_buffers + OS page cache
sudo systemctl stop postgresql@17-main
echo 3 | sudo tee /proc/sys/vm/drop_caches
sudo systemctl start postgresql@17-main
```

### Problem 2: Database State Inconsistency

Can't compare runs with different database states:
- Test 1: Processed 631 items (includes hardlinks, non-files)
- Test 2: Processed 523 items (different subset)

**Solution:** DELETE + reload between tests for identical starting state:
```bash
psql -d copyjob -c "DELETE FROM paths WHERE medium_hash = '...'"
bin/ntt-loader /data/fast/raw/{hash}.raw {hash}
```

## Profiling Setup

Used cProfile for Python code and PostgreSQL query logging for database:

```python
# Run with profiling
python3 -m cProfile -o copier.prof bin/ntt-copier.py --limit 100 ...

# Analyze
python3 -m pstats copier.prof
```

PostgreSQL config for query timing:
```sql
ALTER SYSTEM SET log_min_duration_statement = 100;  -- Log queries >100ms
SELECT pg_reload_conf();
```

## Test Results

All tests: 100 files, 3341.5 MB, cold caches, identical database state.

### Test 1: Batched UPDATEs (ZFS /tmp/ram)
- Duration: 5.351 seconds
- Throughput: 18.7 files/sec, 625 MB/sec
- Failed paths UPDATE: Batched using `unnest()` arrays

### Test 2: Non-batched UPDATEs (ZFS /tmp/ram)
- Duration: 5.483 seconds
- Throughput: 18.2 files/sec, 610 MB/sec
- Failed paths UPDATE: Individual UPDATE per failure

**Batched vs non-batched:** Only 2.4% difference (0.132s). Batching provides no benefit when there are zero errors.

### Test 3: tmpfs ramdisk (Batched UPDATEs)
- Duration: 4.836 seconds
- Throughput: 20.7 files/sec, 691 MB/sec
- **Improvement:** 9.6% faster than batched ZFS, 11.8% faster than baseline

## Root Cause: Missing tmpfs Ramdisk

**Problem:** `/tmp/ram` was a regular directory on ZFS pool "fastpool", not a tmpfs ramdisk.

```bash
$ df -h /tmp/ram
Filesystem      Size  Used Avail Use% Mounted on
fastpool/tmp     64G   19G   46G  30% /tmp
```

**Impact:** Every file copy involved unnecessary disk I/O:
1. Read from source (ZFS)
2. Write to `/tmp/ram/{worker_id}/{ino}.tmp` **(DISK instead of RAM)**
3. Read temp file for BLAKE3 hashing
4. Copy to `/data/fast/ntt/by-hash/` (ZFS)

For 100 files × 33MB avg = ~6.6GB of unnecessary disk I/O (write + read).

### Why tmpfs Was Missing

The system was designed to use tmpfs, but only when launched through `ntt-copy-workers`:

```bash
# bin/ntt-copy-workers (lines 220-228)
WORKER_TMPFS="/tmp/ram/${WORKER_ID}"
sudo mount -t tmpfs -o size=128M,mode=1777 tmpfs "$WORKER_TMPFS"
```

**We ran `ntt-copier.py` directly for testing, bypassing the worker launcher.**

## cProfile Analysis

Time breakdown for batched ZFS run (5.351s total):

| Operation | Time (s) | % Total | Location |
|-----------|----------|---------|----------|
| File I/O (sendfile, read) | 4.23 | 79% | Copy to temp, hash temp file |
| PostgreSQL | 0.80 | 15% | Queries, connection management |
| Redis | 0.21 | 4% | Queue operations |
| MIME detection | 0.11 | 2% | magic.from_file() |

**Key insight:** Database batching is irrelevant when file I/O dominates.

## Fix: System-level tmpfs + Startup Cleanup

### 1. Added tmpfs to /etc/fstab
```bash
# /etc/fstab
tmpfs /tmp/ram tmpfs defaults,size=2G,mode=1777 0 0

# Mount it
sudo mkdir -p /tmp/ram
sudo mount /tmp/ram
```

**Size:** 2GB handles 16 workers × 128MB per worker, or ~100 files in flight.

### 2. Added Startup Cleanup to ntt-copier.py

```python
# Clean up any orphaned temp files from crashed workers
my_tmp_dir = self.RAMDISK / self.worker_id
my_tmp_dir.mkdir(parents=True, exist_ok=True)
orphaned_count = 0
for f in my_tmp_dir.glob("*.tmp"):
    f.unlink()
    orphaned_count += 1
if orphaned_count > 0:
    logger.info(f"Cleaned up {orphaned_count} orphaned temp files from {my_tmp_dir}")
```

**Cleanup strategy:**
- Worker startup: Cleans own directory (`/tmp/ram/{worker_id}/`)
- Reboot: Clears entire tmpfs automatically (tmpfs is RAM)
- Manual: `rm /tmp/ram/*/*.tmp` if needed

## Important Caveat

**All tests used pre-existing blobs** - every file was already in the blob store from previous runs. Tests only measured:
- Path claiming (PostgreSQL)
- File copy to temp (disk or RAM)
- BLAKE3 hashing
- Blob existence check (PostgreSQL)
- Deduplication (file already exists, no final write)

**NOT measured:** Writing new blobs to disk after hashing. This is likely the real bottleneck in production, where most files are new.

The 10-12% tmpfs improvement only applies to the temp copy + hash phase. Final blob write to ZFS will dominate when processing new media.

## Lessons Learned

1. **Cache warming is massive** - Always clear ALL caches (Redis, PostgreSQL, OS) between benchmark runs
2. **Database state matters** - Use DELETE + reload for identical starting conditions
3. **Measure the right thing** - Pre-existing blobs don't test the write path
4. **Infrastructure assumptions** - `/tmp/ram` looked like a ramdisk but wasn't
5. **Profiling beats intuition** - File I/O was 79% of time, not database queries
6. **Micro-optimizations are micro** - Batched UPDATEs saved 2.4% (only matter when there are errors)

## Recommendations

1. **Keep batched UPDATEs** - No cost when errors=0, significant benefit when media is degraded
2. **Keep tmpfs ramdisk** - 10% improvement for free, eliminates disk contention
3. **Test with new blobs** - Run full pipeline test with previously unseen media to measure real throughput
4. **Profile again at scale** - These tests were 100 files × 33MB. Production disks have 1M+ files.
5. **Consider parallel workers** - Single-threaded copier is fine for small batches, but large media should use `ntt-copy-workers` (16 workers)

## Next Steps

- [ ] Commit batched UPDATEs + tmpfs cleanup
- [ ] Test with new media (no pre-existing blobs) to measure write bottleneck
- [ ] Profile at scale (10K+ files) to find next bottleneck
- [ ] Document when to use single worker vs `ntt-copy-workers`
