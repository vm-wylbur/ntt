<!--
Author: PB and Claude
Date: Sat 12 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/bugs/BUG-017-mount-helper-raid-concurrency.md
-->

# BUG-017: Mount-helper cannot handle multiple RAID-based media concurrently

**Filed:** 2025-10-12 14:25
**Filed by:** dev-claude
**Status:** FIXED (duplicate of BUG-019, committed 2025-10-17)
**Severity:** HIGH (blocks mounting when RAID arrays active)
**Affected media:** 594d2e75c6d629e0c7df7758bf5d7b8d (ST3000DM001 3TB), potentially all RAID1 media
**Phase:** Mounting

---

## Observed Behavior

When attempting to mount 594d2e75c6d629e0c7df7758bf5d7b8d while 43fda374c788bdf3a007fc8bf8aa10d8 was still mounted using a RAID array, ntt-mount-helper hung indefinitely at "Scanning for RAID arrays..."

**Commands run:**
```bash
# 43fda374 was mounted using /dev/md5
findmnt | grep 43fda374
# /mnt/ntt/43fda374c788bdf3a007fc8bf8aa10d8 /dev/md5 ext4 ro,relatime,norecovery

# Attempt to mount 594d
sudo bin/ntt-mount-helper mount 594d2e75c6d629e0c7df7758bf5d7b8d \
  /data/fast/img/594d2e75c6d629e0c7df7758bf5d7b8d.img
# Output: Multi-partition disk detected
#         Scanning for RAID arrays...
# [hangs indefinitely]
```

**Orchestrator log:**
```
2025-10-12T14:17:46-07:00 imager_success
2025-10-12T14:17:46-07:00 health_update
2025-10-12T14:17:46-07:00 pipeline_start
2025-10-12T14:17:47-07:00 mount_error
2025-10-12T14:17:47-07:00 pipeline_abort
```

---

## Root Cause Analysis

**Issue:** ntt-mount-helper runs `mdadm --assemble --scan` unconditionally, which blocks/hangs when other RAID arrays are already active.

**Code location:** `bin/ntt-mount-helper` around line 350-400 (RAID detection section)

```bash
# Current implementation (problematic):
echo "Scanning for RAID arrays..."
mdadm --assemble --scan 2>&1 | grep -v "mdadm: No arrays found"

# This command:
# 1. Scans ALL potential RAID devices
# 2. Attempts to assemble ANY inactive arrays it finds
# 3. Blocks/hangs when arrays are already active
# 4. Has no timeout mechanism
# 5. Cannot run concurrently with other mdadm operations
```

**Why this happens:**
- `mdadm --assemble --scan` is a global operation
- It examines ALL devices with RAID metadata
- When md5 is already active (from 43fda374), mdadm gets confused
- The scan operation hangs waiting for exclusive access
- No timeout or concurrent-safe mechanism

**Evidence:**
```bash
# Before mount attempt - 43fda374 using md5:
cat /proc/mdstat
# md5 : active (read-only) raid1 loop86p1[0]
#       732418223 blocks super 1.2 [4/1] [U___]

# During mount attempt - mdadm creates another md5:
cat /proc/mdstat
# md5 : inactive loop35p1[5](S)
#       2930134471 blocks super 1.2

# mdadm tries to assemble but conflicts with existing md5
# → infinite hang
```

---

## Impact

**Severity:** HIGH - Blocks mounting when any RAID array is active

**Current limitations:**
- Cannot mount multiple RAID-based media concurrently
- Cannot mount RAID media while archiver is running (keeps array active)
- Manual intervention required for every RAID mount
- Orchestrator cannot process RAID media in parallel

**Affected operations:**
- Mounting: Blocked if any RAID array exists
- Pipeline: Cannot run multiple RAID media through pipeline
- Archiver: Must complete before next RAID mount (archiver doesn't need mount!)

**Workaround required:**
1. Unmount previous RAID medium
2. Stop all md arrays: `sudo mdadm --stop /dev/md*`
3. Detach all loop devices: `sudo losetup -d /dev/loop*`
4. Manually create loop device: `sudo losetup -f --show --partscan *.img`
5. Manually run array: `sudo mdadm --run /dev/md5`
6. Manually mount: `sudo mount -o ro,noload /dev/md5 /mnt/ntt/...`

---

## Expected Behavior

Mount-helper should handle RAID arrays without blocking on concurrent operations.

**Option A: Skip scan if array already exists**
```bash
# Check if target RAID array already assembled
if mdadm --detail /dev/md5 2>/dev/null | grep -q "State.*active"; then
  echo "RAID array already active: /dev/md5"
else
  # Only assemble if not already active
  mdadm --assemble --scan 2>&1 | grep -v "mdadm: No arrays found"
fi
```

**Option B: Target-specific assembly (preferred)**
```bash
# Instead of --scan, assemble specific device
mdadm --assemble /dev/md5 "${loop_device}p1" 2>&1 || {
  # If that fails, try --run for degraded arrays
  mdadm --run /dev/md5 2>&1
}
```

**Option C: Use next available md device**
```bash
# Don't hardcode /dev/md5, find next available
next_md=$(mdadm --assemble --scan --auto=yes 2>&1 | grep -oP 'md\d+')
echo "Assembled to: $next_md"
```

**Option D: Add timeout and retry**
```bash
# Timeout mdadm scan to prevent infinite hang
timeout 30s mdadm --assemble --scan 2>&1 || {
  echo "WARNING: mdadm scan timed out, trying manual assembly"
  mdadm --run "${loop_device}" 2>&1
}
```

---

## Recommended Fix

**Priority 1: Implement targeted assembly (Option B)**

**File:** `bin/ntt-mount-helper`
**Location:** RAID detection section (~line 350-400)

**Current code:**
```bash
echo "Scanning for RAID arrays..."
mdadm --assemble --scan 2>&1 | grep -v "mdadm: No arrays found"

for part_dev in "${partition_devices[@]}"; do
  part_type=$(blkid -o value -s TYPE "$part_dev" 2>/dev/null || echo "")

  if [[ "$part_type" == "linux_raid_member" ]]; then
    echo "  Skipping $part_dev (RAID member, will mount assembled array)"
  fi
done
```

**Proposed fix:**
```bash
echo "Scanning for RAID arrays..."

# Collect RAID member partitions FIRST
raid_members=()
for part_dev in "${partition_devices[@]}"; do
  part_type=$(blkid -o value -s TYPE "$part_dev" 2>/dev/null || echo "")

  if [[ "$part_type" == "linux_raid_member" ]]; then
    raid_members+=("$part_dev")
    echo "  Found RAID member: $part_dev"
  fi
done

# If we have RAID members, assemble them specifically
if [[ ${#raid_members[@]} -gt 0 ]]; then
  # Try to find which md device this RAID uses
  raid_uuid=$(mdadm --examine "${raid_members[0]}" 2>/dev/null | grep "Array UUID" | awk '{print $4}')

  # Check if this RAID is already assembled
  if mdadm --detail --scan 2>/dev/null | grep -q "$raid_uuid"; then
    echo "  RAID already assembled (UUID: $raid_uuid)"
    # Find which md device
    md_device=$(mdadm --detail --scan 2>/dev/null | grep "$raid_uuid" | awk '{print $2}')
    echo "  Using existing device: $md_device"
  else
    # Assemble this specific RAID (not a global scan!)
    echo "  Assembling RAID members: ${raid_members[*]}"

    # Try assembly first (for complete arrays)
    if ! md_device=$(mdadm --assemble --run --uuid="$raid_uuid" 2>&1 | grep -oP '/dev/md\d+'); then
      # If that fails, try --run for degraded arrays
      echo "  Array incomplete, trying degraded mode..."
      mdadm --run "${raid_members[0]}" 2>&1
      md_device=$(mdadm --examine "${raid_members[0]}" | grep "MD_DEVICE" | awk '{print $2}')
    fi

    echo "  Assembled to: $md_device"
  fi

  # Add md device to mountable list
  partition_devices+=("$md_device")
fi
```

**Priority 2: Add timeout for safety**

Even with targeted assembly, add timeout as safety net:
```bash
# Wrap mdadm calls with timeout
timeout 30s mdadm --assemble --uuid="$raid_uuid" 2>&1 || {
  echo "WARNING: mdadm assembly timed out"
  return 1
}
```

---

## Testing Requirements

**Test 1: Sequential RAID mounts**
```bash
# Mount first RAID medium
sudo bin/ntt-mount-helper mount 43fda374c788bdf3a007fc8bf8aa10d8 \
  /data/fast/img/43fda374c788bdf3a007fc8bf8aa10d8.img
# Should succeed, use /dev/md5

# Mount second RAID medium WITHOUT unmounting first
sudo bin/ntt-mount-helper mount 594d2e75c6d629e0c7df7758bf5d7b8d \
  /data/fast/img/594d2e75c6d629e0c7df7758bf5d7b8d.img
# Should succeed, use next available md device (md6?)
# Should NOT hang
```

**Test 2: Remount existing RAID**
```bash
# Mount RAID medium
sudo bin/ntt-mount-helper mount 594d2e75c6d629e0c7df7758bf5d7b8d \
  /data/fast/img/594d2e75c6d629e0c7df7758bf5d7b8d.img

# Unmount but leave array active
sudo umount /mnt/ntt/594d2e75c6d629e0c7df7758bf5d7b8d

# Remount same medium
sudo bin/ntt-mount-helper mount 594d2e75c6d629e0c7df7758bf5d7b8d \
  /data/fast/img/594d2e75c6d629e0c7df7758bf5d7b8d.img
# Should detect existing array and reuse it
# Should NOT create duplicate md device
```

**Test 3: Concurrent orchestrator runs**
```bash
# Start processing first RAID medium
sudo bin/ntt-orchestrator --image /data/fast/img/43fda374*.img &

# While first is processing, start second
sudo bin/ntt-orchestrator --image /data/fast/img/594d*.img &

# Both should complete without hanging
```

---

## Success Criteria

**Fix is successful when:**

- [ ] Can mount multiple RAID-based media concurrently
- [ ] No hanging on `mdadm --assemble --scan`
- [ ] Each RAID medium gets its own md device (md5, md6, md7, etc.)
- [ ] Remounting existing RAID reuses existing md device
- [ ] Mount-helper completes within 30 seconds for RAID media
- [ ] Orchestrator can process multiple RAID media in parallel
- [ ] No manual intervention required for RAID mounts

---

## Related Issues

**Similar architectural issues:**
- BUG-012: Loop device cleanup (mount-helper lifecycle management)
- BUG-014: Mount path mismatch (single-mountable-partition detection)

**Architectural consideration:**
- Long-term: Stateful mount registry tracking active md devices
- Track which md device is associated with which medium_hash
- Proper cleanup on unmount (stop md array, detach loop devices)
- Resource pooling for md devices (md5-md15 available pool)

---

## Files Requiring Modification

**Primary: bin/ntt-mount-helper**
- **Location:** RAID detection section (~line 350-400)
- **Change:** Replace `mdadm --assemble --scan` with targeted assembly
- **Add:** UUID-based duplicate detection
- **Add:** Timeout wrapper for safety

---

## Dev Notes

**Analysis by:** dev-claude
**Date:** 2025-10-12 14:25

594d mount failure revealed fundamental concurrency limitation in mount-helper's RAID handling. The `mdadm --assemble --scan` global operation cannot run concurrently with active arrays.

This is a blocking issue for pipeline scalability - we cannot process multiple RAID-based media in parallel, which is critical for high-throughput operation.

The fix requires moving from global scanning to targeted assembly using RAID UUIDs. This makes each mount operation independent and concurrent-safe.

**Immediate workaround:** Manually mount RAID media (as done for 594d) until fix is deployed.

**Priority:** HIGH - Blocks parallel processing of RAID media (43fda374, 594d, and likely many more in collection).

---

## Resolution Notes

**Updated by:** dev-claude
**Date:** 2025-10-17 17:30

**Status:** FIXED as part of BUG-019

BUG-019 fixed the root cause identified in this bug:
- Removed system-wide `mdadm --assemble --scan` entirely
- Added pre-check for RAID members using `blkid TYPE="linux_raid_member"`
- Only run mdadm if RAID members actually detected on the specific disk
- Use targeted `mdadm --assemble --run <device>` per partition instead of global scan

**Changes:** `bin/ntt-mount-helper` lines 249-269 (committed 2025-10-17)

**Result:**
- No more system-wide scanning
- Each mount operation is independent
- Concurrent RAID media mounting is now safe
- Non-RAID disks skip mdadm entirely (faster)

**Recommendation:** Close as duplicate of BUG-019 after verification testing
