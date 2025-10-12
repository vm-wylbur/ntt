<!--
Author: PB and Claude
Date: Fri 11 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/bugs/BUG-014-mount-path-mismatch-copier.md
-->

# BUG-014: Mount path mismatch between mount-helper and copier

**Filed:** 2025-10-11 18:08
**Filed by:** prox-claude
**Status:** open
**Affected media:** 43fda374c788bdf3a007fc8bf8aa10d8 (Hitachi 750GB RAID1), likely all multi-partition disks
**Phase:** copying

---

## Observed Behavior

Copier fails to detect existing mount and attempts remount, which fails. Copy workers exit immediately without processing any files despite 2M files in queue.

**Commands run:**
```bash
sudo bin/ntt-copy-workers -m 43fda374c788bdf3a007fc8bf8aa10d8 -w 8 --wait
```

**Error output:**
```
[18:02:58] Starting 8 workers for medium 43fda374c788bdf3a007fc8bf8aa10d8...
[18:02:58] Launched 8 workers with PIDs: 2214100 2214120 2214140 2214160 2214181 2214203 2214225 2214251
[18:02:58] Workers launched successfully
[18:02:58] PIDs saved to: /tmp/ntt-workers.pids
[18:02:58] Waiting for workers to complete...

[18:02:58] Progress: Pager usage is off.
2048542 files remaining
[18:03:28] All workers completed

[18:03:28] Received interrupt signal, stopping workers...
```

**Copier diagnostic output:**
```
2025-10-11 18:06:04.622 | INFO     | Medium 43fda374c788bdf3a007fc8bf8aa10d8 not mounted, attempting to mount...
2025-10-11 18:06:04.904 | ERROR    | Failed to mount 43fda374c788bdf3a007fc8bf8aa10d8: Multi-partition disk detected
Scanning for RAID arrays...
  Skipping /dev/loop37p1 (RAID member, will mount assembled array)
  Failed to mount /dev/md5
  Stopping RAID array: /dev/md5
  Warning: Could not stop /dev/md5 (may still be in use)
Error: No partitions could be mounted
```

---

## Root Cause Analysis

**Issue:** Mount-helper and copier use inconsistent mount point paths for multi-partition disks.

**Mount-helper behavior (multi-partition):**
```bash
# Mounts to partition-specific path:
/mnt/ntt/43fda374c788bdf3a007fc8bf8aa10d8/p1/
```

**Copier expectation:**
```python
# bin/ntt-copier.py line 397
mount_point = f'/mnt/ntt/{medium_hash}'

# Checks for mount at base path:
result = subprocess.run(['findmnt', mount_point], ...)
```

**What happens:**
1. Mount-helper successfully mounts filesystem at `/mnt/ntt/43fda374.../p1`
2. Copier checks for mount at `/mnt/ntt/43fda374...` (base path, no `/p1`)
3. `findmnt` returns exit code 1 (not found)
4. Copier assumes medium not mounted, attempts remount via mount-helper
5. Mount-helper fails (RAID array still in use from first mount)
6. Copier raises exception and exits

**Evidence:**
```bash
# Actual mount location:
$ findmnt /mnt/ntt/43fda374c788bdf3a007fc8bf8aa10d8/p1
TARGET                                       SOURCE   FSTYPE OPTIONS
/mnt/ntt/43fda374c788bdf3a007fc8bf8aa10d8/p1 /dev/md5 ext4   ro,nosuid,nodev,noatime,norecovery

# Copier checks here (wrong):
$ findmnt /mnt/ntt/43fda374c788bdf3a007fc8bf8aa10d8
# Returns exit 1 - not found
```

---

## Expected Behavior

**Option A: Mount-helper creates base-level mount**
For single-partition disks (most common case), mount directly at base path:
```bash
# Single partition RAID1 disk → mount at base
/mnt/ntt/43fda374c788bdf3a007fc8bf8aa10d8/  (mounted filesystem root)
```

For multi-partition disks, mount primary partition at base AND create p1/p2/etc subdirs:
```bash
# Multi-partition disk with p1, p2
/mnt/ntt/43fda374c788bdf3a007fc8bf8aa10d8/     (p1 filesystem mounted here)
/mnt/ntt/43fda374c788bdf3a007fc8bf8aa10d8/.p2/ (p2 filesystem if needed)
```

**Option B: Copier checks partition-specific paths**
Update copier to check for `/p1`, `/p2`, etc. when base path not found:
```python
# Check base path first
if not mounted(f'/mnt/ntt/{medium_hash}'):
    # Try partition paths
    for part in ['p1', 'p2', 'p3']:
        if mounted(f'/mnt/ntt/{medium_hash}/{part}'):
            mount_point = f'/mnt/ntt/{medium_hash}/{part}'
            break
```

**Recommended: Option A** - Mount-helper should handle the complexity, copier should always find base path.

---

## Impact

**Severity:** Medium-High (blocks copying phase for multi-partition disks)

**Current state:**
- 43fda374: Loaded 3M files successfully, copying blocked
- Workaround: Manual bind mount required before copier works
- All multi-partition disks likely affected

**Affected operations:**
- Copying: Blocked until manual intervention
- Pipeline: Cannot complete automatically for multi-partition disks
- Orchestrator: Mount stage succeeds, copy stage fails

**Not blocking:**
- Loading: Works correctly (mount-helper used directly, paths correct)
- Single-partition disks: Likely unaffected (need to verify)

---

## Workaround

**Temporary bind mount:**
```bash
# After mount-helper completes, create bind mount at expected base path:
sudo mount --bind /mnt/ntt/43fda374c788bdf3a007fc8bf8aa10d8/p1 \
                  /mnt/ntt/43fda374c788bdf3a007fc8bf8aa10d8

# Verify copier can find it:
sudo bin/ntt-copier.py --medium-hash 43fda374c788bdf3a007fc8bf8aa10d8 --limit 1
# Should now work

# Start copy workers:
sudo bin/ntt-copy-workers -m 43fda374c788bdf3a007fc8bf8aa10d8 -w 8 --wait
```

**Result:** Copy workers now successfully process files (705 files in 90 seconds, ~8 files/sec)

---

## Recommended Fix

**Primary: Enhance ntt-mount-helper for single-partition cases**

Detect when multi-partition disk has only ONE mountable partition and mount at base path:

```bash
# In ntt-mount-helper, after scanning partitions:
MOUNTABLE_COUNT=$(count mountable partitions)

if [[ $MOUNTABLE_COUNT -eq 1 ]]; then
  # Only one partition - mount at base path for copier compatibility
  MOUNT_POINT="/mnt/ntt/${MEDIUM_HASH}"
  mount $PART_DEVICE $MOUNT_POINT
else
  # Multiple partitions - use subdirectories
  MOUNT_POINT="/mnt/ntt/${MEDIUM_HASH}/p${N}"
  mount $PART_DEVICE $MOUNT_POINT
fi
```

**Why this works:**
- 43fda374 is RAID1 with one filesystem → treated as single-partition
- Copier finds mount at expected base path
- Multi-partition disks (rare) still get subdirectories
- Backward compatible: existing single-partition code unchanged

**Alternative: Add auto-bind-mount for primary partition**
```bash
# After mounting partitions, create convenience bind mount:
if [[ -d "/mnt/ntt/${MEDIUM_HASH}/p1" ]]; then
  mount --bind "/mnt/ntt/${MEDIUM_HASH}/p1" "/mnt/ntt/${MEDIUM_HASH}"
fi
```

---

## Success Condition

**How to verify fix:**

1. **Unmount 43fda374 completely:**
   ```bash
   sudo umount /mnt/ntt/43fda374c788bdf3a007fc8bf8aa10d8
   sudo umount /mnt/ntt/43fda374c788bdf3a007fc8bf8aa10d8/p1
   sudo mdadm --stop /dev/md5
   ```

2. **Remount with fixed mount-helper:**
   ```bash
   sudo bin/ntt-mount-helper mount 43fda374c788bdf3a007fc8bf8aa10d8 \
        /data/fast/img/43fda374c788bdf3a007fc8bf8aa10d8.img

   # Verify mount at base path:
   findmnt /mnt/ntt/43fda374c788bdf3a007fc8bf8aa10d8
   # Should succeed (exit 0)

   ls /mnt/ntt/43fda374c788bdf3a007fc8bf8aa10d8 | head
   # Should show filesystem root
   ```

3. **Test copier mount detection:**
   ```bash
   sudo bin/ntt-copier.py --medium-hash 43fda374c788bdf3a007fc8bf8aa10d8 --limit 1
   # Should NOT attempt remount
   # Should process 1 file successfully
   ```

4. **Test with genuine multi-partition disk (if available):**
   ```bash
   # Disk with 2+ filesystems should still get subdirectories:
   ls /mnt/ntt/<multi-part-hash>/
   # Expected: p1/ p2/ (not direct filesystem contents)
   ```

**Fix is successful when:**
- [ ] 43fda374 mounts at `/mnt/ntt/43fda374.../` (no `/p1`)
- [ ] Copier detects mount without attempting remount
- [ ] Copy workers start immediately without mount errors
- [ ] Genuine multi-partition disks still get `/p1`, `/p2` subdirs
- [ ] No manual bind mount workaround needed

---

## Technical Notes

**Mount-helper current logic:**
```bash
# bin/ntt-mount-helper around line 200-400
# Multi-partition detection:
if [[ "$PARTITION_COUNT" -gt 1 ]]; then
  LAYOUT="multi"
  # Always creates /p1, /p2, etc. subdirectories
fi
```

**RAID1 degraded array characteristics:**
- mdadm auto-assembles as "inactive" (1/4 members present)
- After `mdadm --run`, becomes "active" degraded array
- Appears as single /dev/md* device
- Contains one ext4 filesystem (no nested partitions)
- **Should be treated as single-partition for mount purposes**

**Why this wasn't caught earlier:**
- Loading phase uses mount-helper directly and accesses `/p1` path explicitly
- Copier is first component to expect base-level mount point
- 43fda374 is first RAID1 disk processed through full pipeline

---

## Related Issues

**Similar architectural issues:**
- BUG-012: Loop device cleanup (mount-helper lifecycle management)
- BUG-011: ext4 noload for dirty journals (mount-helper enhancement)

**Architectural consideration:**
- Long-term: Standardize mount point structure across all components
- All tools should query mount location from helper rather than assume path
- Or: Create mount point registry that tracks actual locations

---

## Files Requiring Modification

**Primary: bin/ntt-mount-helper**
- **Location:** Multi-partition mount logic (around line 200-300)
- **Change:** Detect single-mountable-partition case, mount at base path
- **Lines:** Where LAYOUT="multi" is set and partition loop begins

**Alternative: bin/ntt-copier.py**
- **Location:** `ensure_medium_mounted()` function (line 397)
- **Change:** Check for `/p1` fallback when base path not found
- **Risk:** Every consumer would need same change (copier, verifier, etc.)

**Preferred approach:** Fix in mount-helper (single source of truth)

---

## Dev Notes

**Analysis by:** prox-claude
**Date:** 2025-10-11 18:08

43fda374 exposed architectural assumption mismatch between mount-helper and copier. The RAID1 disk is technically "multi-partition" (disk has partition table) but functionally "single-partition" (only one filesystem).

Mount-helper treats it as multi-partition (creates /p1 subdir), copier treats it as single-partition (expects base path). Neither is wrong given their context, but they disagree.

Fix should be in mount-helper: detect when only ONE partition is mountable and treat as single-partition case. This makes copier's assumption correct and avoids needing bind mount workaround.

**Priority:** Medium-High - blocks automatic pipeline progression for multi-partition disks, but manual workaround is straightforward.

**Recommendation:** Implement single-mountable-partition detection in mount-helper. Test with both 43fda374 (RAID1 single-fs) and genuine multi-partition disk to ensure no regression.

---

## Fix Verification

**Implemented:** 2025-10-12
**Verified by:** dev-claude
**Status:** VERIFIED - Fix working correctly

### Changes Made

Modified `bin/ntt-mount-helper` to count mountable partitions and decide mount structure:

```bash
# Count mountable partitions (skip extended containers, RAID members)
mountable_count=0
for part_dev in "${partition_devices[@]}"; do
  part_type=$(blkid -o value -s TYPE "$part_dev" 2>/dev/null || echo "")
  [[ -z "$part_type" ]] && continue              # Skip extended containers
  [[ "$part_type" == "linux_raid_member" ]] && continue  # Skip RAID members
  ((mountable_count++))
done

# Count assembled RAID arrays
for md_dev in /dev/md[0-9]* /dev/md/*; do
  [[ -b "$md_dev" ]] || continue
  md_fs_type=$(blkid -o value -s TYPE "$md_dev" 2>/dev/null || echo "")
  [[ -n "$md_fs_type" ]] && ((mountable_count++))
done

# Mount structure decision
if [[ $mountable_count -eq 1 ]]; then
  # Single mountable partition → mount at base path
  mount_point="$mount_point"  # /mnt/ntt/{hash}
else
  # Multiple partitions → use /p{N} subdirectories
  mount_point="$mount_point/p$part_num"
fi
```

### Test Results

**Medium 43fda374c788bdf3a007fc8bf8aa10d8 (RAID1, single filesystem):**

1. ✅ **Mount structure verified:**
   ```bash
   $ findmnt /mnt/ntt/43fda374c788bdf3a007fc8bf8aa10d8
   TARGET                                    SOURCE   FSTYPE OPTIONS
   /mnt/ntt/43fda374c788bdf3a007fc8bf8aa10d8 /dev/md5 ext4   ro,relatime,norecovery

   $ sudo test -d /mnt/ntt/43fda374c788bdf3a007fc8bf8aa10d8/p1
   # Exit 1 - /p1 subdirectory does NOT exist (correct!)
   ```

2. ✅ **Enumeration paths verified:**
   ```bash
   # NEW paths (correct):
   /mnt/ntt/43fda374.../imac/.emacs-places
   /mnt/ntt/43fda374.../hitachi-mp3/file.ogg

   # OLD paths (buggy) would have been:
   /mnt/ntt/43fda374.../p1/imac/.emacs-places
   /mnt/ntt/43fda374.../p1/hitachi-mp3/file.ogg
   ```

3. ✅ **Database reloaded successfully:**
   - 3,015,047 paths loaded
   - 2,347,847 inodes to copy
   - All paths stored WITHOUT `/p1/` prefix

4. ✅ **Copy test successful:**
   ```
   processed=100 (new=100, deduped=0) bytes=393.2MB errors=0
   ```
   **Zero errors** - files found and copied successfully with corrected paths!

### Success Criteria Met

- [x] 43fda374 mounts at `/mnt/ntt/43fda374.../` (no `/p1`)
- [x] Copier detects mount without attempting remount
- [x] Copy workers process files immediately without mount errors
- [x] No manual bind mount workaround needed
- [ ] Genuine multi-partition disks still get `/p1`, `/p2` subdirs (not tested - no multi-partition media available)

### Next Steps

1. Re-process 43fda374 through full pipeline with corrected paths
2. Test with genuine multi-partition disk when available
3. Commit mount-helper changes

**Fix Status:** Complete and verified for single-mountable-partition case (43fda374)
