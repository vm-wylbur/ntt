<!--
Author: PB and Claude
Date: 2025-10-17
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/bugs/fixed/BUG-021-copier-workers-hang-on-truncated-partitions.md
-->

# BUG-021: Copier Workers Hang on Truncated Partitions

**Status:** FIXED
**Severity:** High (causes complete pipeline failure)
**Affected Component:** mount-helper, copier workers
**Fixed In:** bin/ntt-mount-helper:372
**Date Discovered:** 2025-10-17
**Date Fixed:** 2025-10-17

---

## Problem Description

When copier workers mount disk images independently (standalone mode without orchestrator), they hang in D-state when attempting to mount truncated ext3 partitions. This causes all 16 workers to die after 30 seconds, leaving most files uncopied.

### Affected Disk

**ST3300831A-3NF01XEE-dd.img (hash 97239906f88d6799e3b4f22127b6905c)**
- Partition 9 extends beyond device EOF
- Partition table claims 93GB, actual device is 39GB
- Kernel truncates p9 but mount still hangs

---

## Root Cause

### The Timing Issue

1. **Orchestrator run** (first attempt):
   - Creates loop55 at 18:39
   - Kernel logs truncation warning to dmesg
   - Enum/Load stages complete
   - Orchestrator unmounts and exits

2. **Orchestrator re-run with --force** (second attempt at 18:42):
   - Skips mount stage (already enumerated)
   - Launches workers directly

3. **Workers mount disk independently**:
   - Create NEW loop devices (loop39, loop40, etc.)
   - Kernel logs NEW truncation warnings
   - Mount-helper checks `dmesg | tail -100` for warnings
   - **BUG**: Original warnings from 18:39 have scrolled past last 100 lines
   - Workers miss the warning, try to mount p9
   - Mount enters D-state waiting for filesystem structures that don't exist

### Technical Details

**Original buggy code** (bin/ntt-mount-helper:372):
```bash
if dmesg 2>/dev/null | tail -100 | grep -q "$loop_name:.*p$part_num.*beyond EOD.*truncated"; then
```

**Problem:**
- `tail -100` only searches recent 100 dmesg lines
- Workers run 3+ minutes after orchestrator
- Truncation warnings have scrolled past the tail window
- Workers don't detect truncation, attempt mount, hang

---

## Symptoms

**Orchestrator Log** (`/tmp/orch-ST3300831A-complete.log`):
```
[18:42:16] STAGE: Copy (403274 files)
[18:42:16] Launching 16 workers...
[18:42:17] Launched 16 workers with PIDs: 881816 881836 ...
[18:42:17] Waiting for workers to complete...
[18:42:17] Progress: 349272 files remaining
[18:42:47] All workers completed
[18:42:47] Received interrupt signal, stopping workers...
[18:42:50] ERROR: Copy incomplete - 349272 files remain
```

**Worker Log** (`/tmp/ntt-worker-01.log`):
```
DEBUG: Starting mount loop for /dev/loop39p9...
DEBUG: part_type for /dev/loop39p9 = 'ext3'
DEBUG: Creating mount point for /dev/loop39p9...
DEBUG: Attempting mount...
[log ends - worker hung in D-state]
```

**Kernel Log** (dmesg):
```bash
$ sudo dmesg | grep loop55:
[15744.537622] loop55: p9 size 195318207 extends beyond EOD, truncated

$ sudo dmesg | tail -100 | grep loop39:
[no output - warnings scrolled past]

$ sudo dmesg | grep loop39:
[16037.157622] loop39: p9 size 195318207 extends beyond EOD, truncated
```

---

## Fix

**Modified code** (bin/ntt-mount-helper:372):
```bash
if sudo dmesg 2>/dev/null | grep "$loop_name:" | grep -q "p$part_num.*beyond EOD.*truncated"; then
```

**Changes:**
1. **Removed `tail -100`** - Now searches ALL dmesg messages
2. **Added `grep "$loop_name:"`** - Filters to specific loop device first
3. **Added `sudo`** - Ensures dmesg access even for non-root callers

**Why This Works:**
- Searches entire dmesg buffer for specific loop device
- Catches truncation warnings regardless of timing
- Each worker's loop device (loop39, loop40, etc.) has its own warning
- Workers correctly detect and skip truncated partitions

---

## Verification

**Test Run** (2025-10-17 19:11):
```
[19:11:32] STAGE: Copy (403274 files)
[19:11:32] Launching 16 workers...
[19:11:32] Workers launched successfully
[19:11:32] Progress: 349272 files remaining
[19:12:02] Progress: 203072 files remaining   (146K files copied)
[19:12:32] Progress: 75872 files remaining    (127K files copied)
[19:13:03] All workers completed
[19:13:05] Copy complete! All 403274 files copied.
```

**Results:**
- ✅ Workers successfully skipped p9
- ✅ No D-state hangs
- ✅ All 403,274 files copied in 91 seconds
- ✅ Pipeline completed successfully

**Kernel Log Verification:**
```bash
$ sudo dmesg | grep loop59:
[16383.589316] loop59: p9 size 195318207 extends beyond EOD, truncated
```

Mount-helper correctly detected this warning and skipped p9.

---

## Impact

**Before Fix:**
- All 16 workers hang when mounting disk
- Pipeline fails with 349,272 files uncopied (87% failure rate)
- Requires manual intervention to kill hung processes
- Affects any disk with truncated partitions when workers mount independently

**After Fix:**
- Workers successfully detect and skip truncated partitions
- Pipeline completes successfully
- All accessible files copied (403,274 files)
- No manual intervention required

---

## Related Issues

- **FEATURE-003**: Extended partition support (mount-helper improvements)
- Partition geometry validation added in same mount-helper section

---

## Lessons Learned

1. **Timing matters for dmesg checks**: Don't assume warnings are recent
2. **Worker independence is critical**: Workers must handle mounting correctly without orchestrator
3. **Test timing scenarios**: Verify fixes work when workers run long after orchestrator
4. **Search specificity**: Filter for exact loop device name to avoid false matches
5. **D-state hangs are serious**: Truncated ext3 filesystems create unkillable processes

---

## Prevention

**For New Mount Checks:**
- Always search full dmesg, not just tail
- Filter by specific device identifier
- Test with stale dmesg buffers
- Verify worker standalone operation

**For Truncated Partitions:**
- Consider adding partition size validation using `/sys/class/block/*/size`
- Could eliminate reliance on dmesg parsing entirely
- See `/sys/class/block/loop55p9/{start,size}` for partition geometry
