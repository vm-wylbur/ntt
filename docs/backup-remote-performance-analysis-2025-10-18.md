<!--
Author: PB and Claude
Maintainer: PB
Date: Fri 18 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/backup-remote-performance-analysis-2025-10-18.md
-->

# Remote Backup Performance Analysis

**Date:** 2025-10-18
**Purpose:** Systematic performance testing of remote backup transfer methods
**Context:** Current backup running at 5-10 MB/s vs expected 50+ MB/s on chll-direct link

## Executive Summary

Performance testing shows **tar streaming with parallel workers achieves 5.2x speedup** over current rsync implementation:

- **Current (rsync):** 9.2 MB/s, 21 days for 42M files
- **Optimized (parallel tar):** 47.7 MB/s, 4 days for 42M files
- **Recommendation:** Implement tar streaming with 4 workers

## Test Environment

### Infrastructure
- **Source:** `/data/cold/by-hash` on snowball
- **Destination:** `pball@chll-direct:/storage/pball/by-hash`
- **Connection:** SSH to direct public IP (209.121.245.6:1222)
- **SSH Baseline:** 66.6 MB/s throughput ceiling

### Workload Characteristics

**Dataset:** 42M files pending backup, 17TB total

| Size Range | File Count | % of Total | Total Size |
|------------|------------|------------|------------|
| < 1KB | 11.7M | 27.79% | 3.5 GB |
| 1-10KB | 19.8M | 47.17% | 70 GB |
| 10-100KB | 6.6M | 15.73% | 204 GB |
| 100KB-1MB | 2.6M | 6.23% | 835 GB |
| 1-10MB | 1.0M | 2.39% | 3.2 TB |
| 10-100MB | 280K | 0.67% | 6.0 TB |
| > 100MB | 14K | 0.03% | 7.1 TB |

**Key Insight:** 75% of files are under 10KB (median: 3KB). Per-file overhead dominates.

### Test Methodology

Six tests conducted with production database samples:
- **100-file samples:** Test protocol overhead
- **1000-file samples:** Test batch size scaling
- **Parallel test:** 4 workers × 100 files each

All tests measured:
- Wall-clock time
- Throughput (MB/s)
- Files per second
- Return codes and errors

## Test Results

### Full Results Table

| Test | Files | Size | Time | Speed | Files/sec | Speedup |
|------|-------|------|------|-------|-----------|---------|
| 1. SSH Baseline | - | 1000 MB | 15.0s | 66.6 MB/s | - | - |
| 2. Rsync (current) | 100 | 39.5 MB | 4.3s | 9.2 MB/s | 23.2 | 1.0× |
| 3. Tar streaming | 100 | 39.5 MB | 2.6s | 15.1 MB/s | 38.3 | 1.6× |
| 4. Tar + gzip | 100 | 39.5 MB | 2.6s | 15.3 MB/s | 38.8 | 1.7× |
| 5. Large batch tar | 1000 | 302.6 MB | 25.6s | 11.8 MB/s | 39.1 | 1.3× |
| 6. Parallel tar (4×) | 400 | 158.1 MB | 3.3s | 47.7 MB/s | 120.6 | **5.2×** |

### Detailed Analysis

#### Test 1: SSH Baseline (66.6 MB/s)

```bash
dd if=/dev/zero bs=1M count=1000 | ssh -C chll-direct 'cat > /dev/null'
```

- Theoretical maximum for this connection
- 72% of baseline achieved with parallel tar (excellent)

#### Test 2: Rsync Current Method (9.2 MB/s, baseline)

```bash
rsync -a --no-perms --no-owner --no-group --size-only \
  --itemize-changes --files-from=<list> \
  -e 'ssh -o RemoteCommand=none -o RequestTTY=no' \
  /data/cold/by-hash/ chll-direct:/storage/pball/by-hash/
```

**Performance:**
- 9.2 MB/s, 23.2 files/sec
- Matches observed production rate (5-10 MB/s)
- Batch timing from logs: 20-180 seconds per 100 files (high variance)

**Bottleneck:** Per-file protocol handshake overhead
- Each file: stat, checksum negotiation, transfer decision
- For 3KB median file: ~0.04s overhead = 43ms/file
- At this rate: **21 days** to complete 42M files

#### Test 3: Tar Streaming (15.1 MB/s, 1.6× faster)

```bash
cd /data/cold/by-hash && tar cf - -T <list> | \
  ssh -C chll-direct 'cd /storage/pball/by-hash && tar xf -'
```

**Performance:**
- 15.1 MB/s, 38.3 files/sec
- 65% faster than rsync for same 100 files

**Why faster:**
- No per-file protocol negotiation
- Streaming pipeline: tar reads while SSH transmits
- Single continuous stream vs discrete file operations

#### Test 4: Tar + Gzip (15.3 MB/s, marginal improvement)

```bash
cd /data/cold/by-hash && tar czf - -T <list> | \
  ssh chll-direct 'cd /storage/pball/by-hash && tar xzf -'
```

**Performance:**
- 15.3 MB/s, 38.8 files/sec
- Only 1% faster than tar + SSH compression

**Conclusion:** Compression choice doesn't matter significantly
- SSH `-C` compression ≈ gzip compression
- Network bandwidth not the bottleneck
- Use SSH compression (simpler, one less process)

#### Test 5: Large Batch Tar (11.8 MB/s, slower!)

```bash
# Same as Test 3 but 1000 files instead of 100
```

**Performance:**
- 11.8 MB/s, 39.1 files/sec
- **Slower throughput** but same files/sec

**Analysis:**
- Files/sec remained constant (39 files/sec)
- Throughput dropped because this sample had smaller average file size
- 1000-file batch: 303 MB / 1000 = 303 KB/file avg
- 100-file batch: 39.5 MB / 100 = 395 KB/file avg
- **Batch size doesn't improve performance**

#### Test 6: Parallel Tar - 4 Workers (47.7 MB/s, 5.2× faster!)

```bash
# 4 concurrent tar streams, each handling 100 files
```

**Performance:**
- 47.7 MB/s, 120.6 files/sec
- **5.2× faster than current rsync**
- **72% of theoretical SSH ceiling** (47.7 / 66.6)

**Parallelism scaling:**
- Near-linear scaling: 4 workers = 4× throughput
- Each worker: ~12 MB/s (similar to single tar test)
- Excellent CPU utilization (system was 95% idle during tests)

**Projected completion time:**
- 42M files at 120.6 files/sec = **97 hours = 4.0 days**
- vs current 21 days = **5.2× faster**

## Root Cause Analysis

### Why Rsync is Slow

For small files (median 3KB), rsync overhead dominates:

1. **Per-file protocol handshake** (~40ms each):
   - Open file on both ends
   - Exchange metadata
   - Calculate checksums
   - Negotiate delta transfer
   - Close file

2. **Database round-trips:**
   - Fetch batch → transfer → update DB → repeat
   - Network idle during DB operations
   - DB idle during transfers

3. **Filesystem stat overhead:**
   - Python `Path.exists()` and `.stat()` for each file
   - 1000 syscalls per batch before transfer

### Why Tar Streaming Wins

1. **Single continuous stream:**
   - No per-file negotiation
   - Header + data in one pass
   - Receiver extracts as stream arrives

2. **Better pipelining:**
   - Tar reads next file while SSH compresses/transmits previous
   - Overlapped I/O operations
   - CPU and network utilized simultaneously

3. **Lower overhead:**
   - Simpler protocol (tar format vs rsync delta protocol)
   - Less CPU per file
   - No checksum calculations

4. **Parallel scaling:**
   - Independent workers share network bandwidth
   - Near-linear scaling observed (4× workers ≈ 4× throughput)

## Current Production Performance

From `/var/log/ntt/backup-remote.jsonl` (2025-10-18):

```
16:28:35  copied=48,800  16.15GB  speed=9.2MB/s  eta=111.0h
16:29:35  copied=50,400  16.82GB  speed=9.3MB/s  eta=110.1h
16:30:35  copied=52,300  17.69GB  speed=9.4MB/s  eta=108.1h
16:31:35  copied=53,800  18.33GB  speed=9.5MB/s  eta=107.6h
```

- Stable 9.2-9.5 MB/s (matches Test 2 results)
- 16 workers running (likely contention)
- High batch duration variance: 1.66s - 192s for 100 files

**Batch timing examples:**
```
worker=9  batch=100  success=100  bytes=100MB  duration=192.91s  (0.5 MB/s)
worker=14 batch=100  success=100  bytes=4MB    duration=1.66s    (2.4 MB/s)
worker=13 batch=100  success=100  bytes=70MB   duration=49.73s   (1.4 MB/s)
```

**Variance analysis:** Likely due to:
- File size distribution differences per batch
- Disk seek patterns (random access to by-hash tree)
- Worker contention on ControlMaster sockets

## Recommendations

### Primary Recommendation: Parallel Tar Streaming

**Implementation:**
1. Replace rsync with tar streaming in `ntt-backup-remote`
2. Keep multi-worker architecture (already exists)
3. Use 4 workers initially (proven scaling)
4. Add SSH compression flag (`-C`)

**Expected improvement:**
- 9.2 MB/s → 47.7 MB/s (5.2× speedup)
- 21 days → 4 days completion time

**Code changes required:**
- Replace `run_rsync_batch()` with `run_tar_batch()`
- Use `tar cf - -T <filelist>` pipe to SSH
- Keep existing batch tracking and DB updates
- No changes to worker coordination logic

### Alternative Options

#### Option A: Increase Worker Count
- Test 8 or 16 workers
- May approach theoretical ceiling (66.6 MB/s)
- Could reduce to 2-3 days
- Risk: Diminishing returns, possible contention

#### Option B: Hybrid Approach
- Tar for small files (< 1MB, 90% of files)
- Rsync for large files (> 1MB)
- More complex, marginal benefit
- Not recommended (complexity vs gain)

#### Option C: Larger Batches
- Test 5 showed no improvement
- Batch size 100-1000 doesn't affect files/sec
- Current 1000/batch is fine

## Implementation Notes

### Preserving Existing Functionality

Keep from current implementation:
- PID-based locking (`/tmp/ntt-backup-remote.lock`)
- Worker hex-range partitioning (0x00-0xff split)
- SSH ControlMaster per worker
- Database batch tracking
- Graceful shutdown on SIGINT/SIGTERM
- Progress reporting (console + JSON logs)

### Changes Required

Replace in `BackupWorker.run_rsync_batch()`:
```python
# OLD: rsync with --itemize-changes parsing
rsync_cmd = ['rsync', '-a', '--itemize-changes', ...]

# NEW: tar streaming
tar_cmd = f"cd {self.source_root} && tar cf - -T {temp_file} | " \
          f"ssh -C {ssh_opts} {self.remote_host} " \
          f"'cd {self.remote_path}/by-hash && tar xf -'"
```

**Trade-offs:**
- ✓ 5.2× faster
- ✓ Simpler protocol
- ✗ Lose per-file transfer visibility (tar exits 0 or non-zero for whole batch)
- ✗ Lose partial batch resume (need to retry entire batch on failure)

**Mitigation:**
- Current implementation already retries entire batches
- Batch size (1000 files) is small enough for atomic retry
- Failed batches marked in DB, can be re-queued

## Test Artifacts

**Scripts:**
- `/tmp/test-backup-performance.py` - Test harness
- `/tmp/sample-100-files.txt` - 100-file sample paths
- `/tmp/sample-1000-files.txt` - 1000-file sample paths

**Results:**
- `/tmp/backup-perf-results.json` - Machine-readable results

**Cleanup:**
```bash
# Remove test files from remote (transferred during tests)
ssh chll-direct 'cd /storage/pball/by-hash && find . -type f -mmin -60 | xargs rm'
```

## Next Steps

1. Review and approve this analysis
2. Implement tar streaming in `ntt-backup-remote`
3. Test with single worker in production
4. Deploy with 4 workers
5. Monitor performance and adjust worker count
6. Document final configuration

## Implementation Issues Discovered

### Issue 1: SSH Configuration Problems

**Problem:** Global SSH config had X11 forwarding enabled with incorrect path:
```
Host *
    ForwardX11 yes
    ForwardX11Trusted yes
    XAuthLocation /opt/X11/bin/xauth  # macOS path on Linux!
```

**Impact:** SSH hung on non-interactive commands waiting for X11 setup that never completed.

**Solution:** Added `-o ForwardX11=no` to all SSH commands in backup scripts.

**Test validation:**
```bash
# Before (hangs):
ssh chll-script 'echo test'  # Times out after 15s

# After (works):
ssh -o ForwardX11=no chll-script 'echo test'  # Returns immediately
```

### Issue 2: SSH Host Selection

**Problem:** Using `chll-direct` which had `RemoteCommand exec zsh` in SSH config.

**Impact:** Conflicted with scripted SSH commands even with `-o RemoteCommand=none` override.

**Solution:** Created `chll-script` host entry without RemoteCommand directive.

**SSH config:**
```
Host chll-script
    Hostname 209.121.245.6
    Port 1222
    User pball
    # No RemoteCommand or RequestTTY directives

Host chll-direct
    Hostname 209.121.245.6
    Port 1222
    User pball
    RequestTTY yes
    RemoteCommand exec zsh  # Interferes with scripting
```

### Issue 3: Inadequate Validation

**Original validation** (in `validate_remote_access()` function):
- Did not disable X11 forwarding
- Timed out without clear error message
- Only tested connectivity, not actual transfer capability

**Improved validation needed:**
- Disable all interactive features: `-o ForwardX11=no -o RemoteCommand=none -o RequestTTY=no`
- Test actual tar streaming, not just echo command
- Provide clear error messages on timeout

**Lesson:** Validation must replicate actual workload conditions.

## ROOT CAUSE: Flawed Baseline Test (RESOLVED)

### The Problem with Test 1

**Original "baseline" test:**
```bash
dd if=/dev/zero bs=1M count=1000 | ssh -C chll-direct 'cat > /dev/null'
```
**Result:** 66.6 MB/s

**This test was fundamentally flawed** because:
1. Used compression (`-C`) on zeros
2. Zeros compress from 1000MB down to nearly nothing
3. Measured compression speed, NOT network throughput
4. Created false expectation of 50+ MB/s transfers

### Actual Network Performance

**Corrected baseline tests (2025-10-18 evening):**

| Test | Compression | Data Type | Result | What it measures |
|------|-------------|-----------|--------|------------------|
| dd zeros + SSH -C | Yes | Zeros | 35 MB/s | Compression speed |
| dd zeros, no -C | No | Zeros | **12 MB/s** | **TRUE baseline** |
| dd urandom + SSH -C | Yes | Random | 5.6 MB/s | Wasted CPU on incompressible data |
| dd urandom, no -C | No | Random | 8.9 MB/s | Real data throughput |
| tar files, no -C | No | Real files | 10.7 MB/s | Our actual workload |
| tar files + SSH -C | Yes | Real files | 10.8 MB/s | Same (data doesn't compress) |

**Conclusion:** The actual SSH connection throughput is **~12 MB/s maximum** for uncompressed data.

### Why Production Matches Expectations

**Production performance:**
- rsync: 9.2 MB/s
- tar streaming: 8-10 MB/s
- These are **67-83% of the true 12 MB/s baseline**
- This efficiency is actually very good!

**The "47.7 MB/s with 4 workers" test result was also flawed:**
- Used compression on data that doesn't compress
- Test sample may have had different characteristics
- Production performance of 8-10 MB/s is correct

### Network Characteristics

**Connection details:**
- Host: 209.121.245.6:1222 (chll direct public IP)
- RTT: 28ms average
- Cipher: chacha20-poly1305@openssh.com
- Throughput: ~12 MB/s for real data

**TCP Window Size Limitation:**
- Current throughput: 12 MB/s
- RTT: 28ms
- Bandwidth-delay product: 12 MB/s × 0.028s = 336 KB
- For 50 MB/s would need: 50 MB/s × 0.028s = 1.4 MB window
- Likely limited by default TCP buffer sizes

**Diagnostic commands run:**
```bash
# True baseline (no compression, real data):
dd if=/dev/zero bs=1M count=500 | ssh [opts] chll-script 'cat > /dev/null'
# Result: 12 MB/s

# Test with different cipher (same result):
dd if=/dev/zero bs=1M count=500 | ssh -c aes128-gcm@openssh.com [opts] chll-script 'cat > /dev/null'
# Result: 12 MB/s

# Real file transfer:
tar cf - -T file-list.txt | ssh [opts] chll-script 'cat > /dev/null'
# Result: 10.7 MB/s (good efficiency!)
```

### Final Findings (After Exhaustive Testing)

**Network Ceiling:** Snowball → chll is hard-capped at **~12 MB/s** via:
- Public IP (209.121.245.6:1222): 12 MB/s
- Tailscale (100.92.166.69): 11 MB/s (uses same public IP for direct connection)
- Both routes hit identical bottleneck

**Tested optimizations (no improvement):**
- ✗ TCP buffer tuning (16MB buffers)
- ✗ Parallel connections (4 streams = 10.96 MB/s total)
- ✗ BBR congestion control
- ✗ Disabling slow start after idle
- ✗ Different SSH ciphers

**Network issues identified:**
- MTR shows 80-90% packet loss and 7-8 second latency at intermediate hops
- TCP retransmissions observed (6179 total)
- Asymmetric: upload 12 MB/s, download 7.8 MB/s
- Link negotiation issue: "Link partner advertised auto-negotiation: No"

### Final Recommendations

**Accept the 12 MB/s ceiling** - no further optimization possible from snowball.

**Implementation choice:**
- Rsync: 9.2 MB/s (77% of ceiling)
- Tar: 10.7 MB/s (89% of ceiling)
- **Use tar streaming** for 16% improvement

**Expected completion time:**
- 3.2TB actual data (deduplication working!) at 10 MB/s = **~4 days**
- 5.5M pending files at ~40 files/sec = **1.6 days**
- Bandwidth is the bottleneck, not file count

**Use ntt-backup-remote-scp-nocontrol** with current settings:
- Tar streaming via SSH (no compression - data doesn't compress)
- 4 workers (good for parallelizing file I/O)
- No ControlMaster (simpler, minimal performance difference)

## References

- Test harness: `/tmp/test-backup-performance.py`
- Current implementation: `/home/pball/projects/ntt/bin/ntt-backup-remote` (rsync)
- Alternative implementations:
  - `/home/pball/projects/ntt/bin/ntt-backup-remote-scp` (tar + ControlMaster)
  - `/home/pball/projects/ntt/bin/ntt-backup-remote-scp-nocontrol` (tar, no ControlMaster)
- Production logs: `/var/log/ntt/backup-remote.jsonl`
- SSH config: `~/.ssh/config`
