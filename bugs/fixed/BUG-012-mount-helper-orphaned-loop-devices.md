<!--
Author: PB and Claude
Date: Fri 11 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/bugs/BUG-012-mount-helper-orphaned-loop-devices.md
-->

# BUG-012: Orphaned loop devices accumulate after pipeline completion

**Filed:** 2025-10-11 12:35
**Filed by:** prox-claude
**Status:** open
**Affected media:** All media (observed: 536a933b, 031a3ceb, plus ~30 total)
**Phase:** mount/unmount

---

## Observed Behavior

After processing media through NTT pipeline, orphaned loop devices accumulate and remain attached even after archiving completes and IMG files are deleted. Multiple loop devices are created for the same medium hash, but only one is detached during unmount.

**Commands run:**
```bash
# After 536a933b completion:
losetup -l | grep 536a933b | wc -l
# Output: 17 loop devices

# Check for deleted files:
losetup -l | grep deleted | wc -l
# Output: ~30+ total orphaned devices

# Sample output from losetup -l:
/dev/loop17  0 0  1 0 /data/fast/img/536a933b4481f605fcd44615740a9025.img (deleted)  0 512
/dev/loop18  0 0  1 0 /data/fast/img/536a933b4481f605fcd44615740a9025.img (deleted)  0 512
/dev/loop19  0 0  1 0 /data/fast/img/536a933b4481f605fcd44615740a9025.img (deleted)  0 512
... (14 more)
```

**Timeline for 536a933b:**
1. First orchestrator run failed at mount (BUG-011)
2. Second orchestrator run succeeded and completed full pipeline
3. Archive created and IMG file deleted
4. Unmount ran but only detached ONE loop device
5. Result: 17 loop devices remain attached to "(deleted)" file

---

## Root Cause

**Primary issue:** ntt-mount-helper:do_unmount() only detaches ONE loop device per medium

Current unmount logic (bin/ntt-mount-helper:488):
```bash
LOOP_DEV=$(findmnt -n -o SOURCE "$MOUNT_POINT/$PARTITION" 2>/dev/null)
if [[ -n "$LOOP_DEV" ]]; then
  losetup -d "$LOOP_DEV"
fi
```

This extracts the loop device from the current mount point and detaches it. However:

1. **Multiple runs create multiple loop devices:** Each orchestrator run calls `losetup -f --show -r -P "$IMG_FILE"` which creates a NEW loop device, even if one already exists for that IMG file

2. **Only mounted device gets detached:** findmnt only returns the loop device currently mounted at the mount point. Previous loop devices from failed runs or retries are not cleaned up.

3. **Archiver deletes IMG while loops attached:** ntt-archiver removes source IMG files while loop devices still reference them, creating "(deleted)" entries

4. **cleanup_stale_loops() not called during unmount:** The existing cleanup function (lines 130-164) only runs in do_mount(), not in do_unmount()

**Evidence of duplicate loop device creation:**
- 536a933b: 17 loop devices (1 successful run + 1 failed run = multiple losetup calls)
- 031a3ceb: Multiple devices from retry attempts
- System total: ~30+ orphaned loop devices

---

## Expected Behavior

**Unmount should clean up ALL loop devices associated with the medium:**

1. Find all loop devices pointing to the IMG file (not just the mounted one)
2. Detach all loop devices for that IMG file
3. Verify no orphaned devices remain before completing

**Additionally, periodic cleanup should handle any orphans:**
- ntt-cleanup-mounts should detect and clean orphaned loop devices during periodic runs
- Detect loop devices pointing to "(deleted)" files
- Safely detach if not mounted

---

## Impact

**Severity:** Medium (system resource leak, not blocking processing)

**Current state:**
- ~30+ orphaned loop devices across multiple media
- Each loop device consumes kernel resources (minor memory overhead)
- Risk of loop device exhaustion (default limit typically 8-255 devices)
- Confusing diagnostic output with "(deleted)" entries

**Workaround available:**
```bash
# Manual cleanup of all orphaned loop devices:
for dev in $(losetup -l | grep deleted | awk '{print $1}'); do
  sudo losetup -d "$dev" 2>/dev/null || true
done
```

**Not blocking:** Processing continues normally, but cleanup required periodically

---

## Recommended Fix

**Defense-in-depth approach combining two solutions:**

### Solution 1: Enhance do_unmount() - Find ALL loop devices (Targeted Fix)

**Implementation:**
```bash
# In do_unmount(), replace single-device detach with multi-device cleanup:

# Find ALL loop devices for this IMG file
LOOP_DEVS=$(losetup -l | grep "$IMG_FILE" | awk '{print $1}')

if [[ -n "$LOOP_DEVS" ]]; then
  log "Found $(echo "$LOOP_DEVS" | wc -l) loop device(s) for $IMG_FILE"
  while IFS= read -r LOOP_DEV; do
    log "Detaching $LOOP_DEV"
    losetup -d "$LOOP_DEV" 2>/dev/null || log "Warning: Could not detach $LOOP_DEV"
  done <<< "$LOOP_DEVS"
fi
```

**Pros:**
- ✅ Directly addresses root cause (detaches ALL devices, not just mounted one)
- ✅ Small code change (~10 lines)
- ✅ Works for both successful and failed runs
- ✅ Cleans up at the right time (during unmount)

**Cons:**
- ⚠️ Requires IMG file to still exist (grep on filename)
- ⚠️ Won't help if IMG already deleted (archiver runs before unmount in some cases)

### Solution 2: Add orphan cleanup to ntt-cleanup-mounts (Periodic Safety Net)

**Implementation:**
```bash
# Add to ntt-cleanup-mounts after filesystem unmount section:

cleanup_orphaned_loop_devices() {
  log "Checking for orphaned loop devices..."

  # Find loop devices pointing to deleted files
  ORPHANED=$(losetup -l | grep '(deleted)' | awk '{print $1}')

  if [[ -n "$ORPHANED" ]]; then
    local count=$(echo "$ORPHANED" | wc -l)
    log "Found $count orphaned loop device(s)"

    while IFS= read -r LOOP_DEV; do
      # Verify not mounted
      if ! mount | grep -q "$LOOP_DEV"; then
        log "Detaching orphaned $LOOP_DEV"
        losetup -d "$LOOP_DEV" 2>/dev/null || log "Warning: Could not detach $LOOP_DEV"
      else
        log "Skipping $LOOP_DEV (still mounted)"
      fi
    done <<< "$ORPHANED"
  fi
}

# Call in main loop after cleanup_mounts():
cleanup_orphaned_loop_devices
```

**Pros:**
- ✅ Catches orphans even if unmount fails
- ✅ Works after IMG files deleted (detects "(deleted)" marker)
- ✅ Non-invasive (periodic cleanup, low risk)
- ✅ Handles edge cases (manual interventions, crashes)

**Cons:**
- ⚠️ Delayed cleanup (runs periodically, not immediately)
- ⚠️ Doesn't prevent problem, only cleans up after

**Why both solutions:**
1. Solution 1 prevents most orphans (immediate cleanup during normal workflow)
2. Solution 2 catches edge cases (failed runs, crashes, manual interventions)
3. Together they provide defense-in-depth

---

## Success Condition

**How to verify fix:**

1. **Start with clean state:**
   ```bash
   # Manually clean all existing orphans:
   for dev in $(losetup -l | grep deleted | awk '{print $1}'); do
     sudo losetup -d "$dev" 2>/dev/null
   done

   # Verify clean:
   losetup -l | grep deleted
   # Should return nothing
   ```

2. **Process a test medium through full pipeline:**
   ```bash
   sudo bin/ntt-orchestrator --image /data/fast/img/TEST_HASH.img
   # Let it complete to archive stage
   ```

3. **Check for orphaned loop devices:**
   ```bash
   losetup -l | grep TEST_HASH
   # Should show 0 devices (all cleaned up)

   losetup -l | grep deleted
   # Should show 0 devices system-wide
   ```

4. **Test periodic cleanup (if implemented):**
   ```bash
   # Wait for next ntt-cleanup-mounts run (or trigger manually)
   sudo bin/ntt-cleanup-mounts

   # Verify all orphans cleaned:
   losetup -l | grep deleted
   # Should return nothing
   ```

**Fix is successful when:**
- [ ] Processing medium through pipeline leaves 0 orphaned loop devices
- [ ] After archive stage, `losetup -l | grep HASH` returns nothing
- [ ] System-wide: `losetup -l | grep deleted` returns nothing after cleanup-mounts run
- [ ] Multiple orchestrator runs (including failures) don't accumulate orphans
- [ ] Test case: Process 2-3 media in sequence, verify no orphans accumulate

---

## Alternative Options Considered

### Option 3: Orchestrator unmounts BEFORE archiving (Workflow Change)
**Rejected:** Would require significant orchestrator restructuring and breaks current separation of concerns (archiver handles both file archiving and cleanup)

### Option 4: Call cleanup_stale_loops() during unmount (Use Existing Function)
**Rejected:** cleanup_stale_loops() is designed for finding stale mounts from previous crashes, not for cleaning up current operation's loop devices. Would need significant modification.

### Option 5: Prevent duplicates - reuse existing loop devices (Preventive)
**Rejected:** Complex logic to safely reuse loop devices, risks mount conflicts, minimal benefit over cleanup approach

---

## Files Requiring Modification

### Primary: bin/ntt-mount-helper
- **Function:** do_unmount() (lines 458-523)
- **Change:** Replace single-device detach with multi-device loop
- **Location:** Around line 488 where `losetup -d "$LOOP_DEV"` is called

### Secondary: bin/ntt-cleanup-mounts
- **Function:** Add cleanup_orphaned_loop_devices()
- **Change:** New function + call in main loop
- **Location:** After cleanup_mounts() around line 113

---

## Technical Notes

**Loop device behavior:**
- `losetup -f --show -r -P "$IMG"` always creates NEW device
- Loop devices persist until explicitly detached with `losetup -d`
- Multiple loop devices CAN point to same backing file
- Kernel maintains loop device list in /dev/loop*
- "(deleted)" appears when backing file removed while loop device attached

**System limits:**
- Default max loop devices: varies by kernel config (typically 8-255)
- Can be increased via `max_loop` kernel parameter
- Each device consumes minor kernel resources

**Safety considerations:**
- Never detach loop device while mounted (check with `mount | grep $LOOP_DEV`)
- Safe to detach devices pointing to "(deleted)" files (backing file gone anyway)
- Multiple retries/failures can create many orphans quickly

---

## Dev Notes

**Analysis by:** prox-claude
**Date:** 2025-10-11 12:35

Investigation revealed this is a widespread issue affecting all processed media. The combination of retry logic (multiple orchestrator runs) plus single-device unmount creates accumulating orphans.

Recommendation: Implement both Solution 1 and Solution 2 for defense-in-depth. Solution 1 handles normal workflow, Solution 2 catches edge cases.

Priority: Medium - not blocking processing but should be fixed to prevent resource exhaustion on long-running systems.

---

**Implementation by:** dev-claude
**Date:** 2025-10-17 17:00

**Changes made:**

**Solution 1: Enhanced do_unmount() in ntt-mount-helper (lines 617-652)**
- Find ALL loop devices pointing to the same image file (not just the mounted one)
- Extract image path from loop device using `losetup -l`
- Search for all loop devices with matching image path
- Detach all found devices, logging each one
- Handles both normal files and "(deleted)" files
- Fallback to single-device detach if image path can't be determined

**Solution 2: Added cleanup_orphaned_loop_devices() to ntt-cleanup-mounts (lines 63-101)**
- Scans for loop devices pointing to "(deleted)" files
- Verifies device is not mounted before detaching
- Logs detached count and failed count
- Called automatically after mount cleanup (line 159)
- Runs periodically via cron for defense-in-depth

**Defense-in-depth benefits:**
- Solution 1: Prevents orphans during normal unmount operations
- Solution 2: Catches orphans from crashes, manual interventions, or edge cases
- Together they ensure loop devices don't accumulate over time

**Ready for testing:** 2025-10-17 17:00

---

## Testing Results

**Tested by:** prox-claude
**Date:** 2025-10-17 18:45

### Test Scenario

Created controlled test environment with medium 9bfbfb9e7b86a330b4c45c1332e749e2.img:

```bash
# Setup: Created 4 loop devices total
sudo losetup -f --show -r -P /data/fast/img/9bfbfb9e7b86a330b4c45c1332e749e2.img  # /dev/loop0
sudo losetup -f --show -r -P /data/fast/img/9bfbfb9e7b86a330b4c45c1332e749e2.img  # /dev/loop1
sudo losetup -f --show -r -P /data/fast/img/9bfbfb9e7b86a330b4c45c1332e749e2.img  # /dev/loop2
# Mount-helper created /dev/loop3 during mount

# Action: Run unmount
sudo bin/ntt-mount-helper unmount 9bfbfb9e7b86a330b4c45c1332e749e2

# Verification:
losetup -l | grep 9bfbfb9e
```

**Expected:** 0 loop devices remaining (all 4 detached)
**Actual:** All 4 loop devices still attached

```
/dev/loop0  0 0  1 0 /data/fast/img/9bfbfb9e7b86a330b4c45c1332e749e2.img  0 512
/dev/loop1  0 0  1 0 /data/fast/img/9bfbfb9e7b86a330b4c45c1332e749e2.img  0 512
/dev/loop2  0 0  1 0 /data/fast/img/9bfbfb9e7b86a330b4c45c1332e749e2.img  0 512
/dev/loop3  0 0  1 0 /data/fast/img/9bfbfb9e7b86a330b4c45c1332e749e2.img  0 512
```

**Result:** ❌ **TEST FAILED** - No loop devices were detached

---

### Root Cause Analysis

**Bug location:** `bin/ntt-mount-helper` lines 656-662

**Problematic code:**
```bash
# Line 656: Extract image path from loop device
image_path=$(losetup -l | grep "^$base_loop_device" | awk '{for(i=6;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ *$//' | sed 's/ (deleted)$//')

# Line 662: Search for all loop devices with matching image path
all_loop_devices=$(losetup -l | grep -F "$image_path" | awk '{print $1}')
```

**Issue:** The awk command extracts fields 6 through end-of-line, but `losetup -l` output format is:

```
NAME SIZELIMIT OFFSET AUTOCLEAR RO BACK-FILE DIO LOG-SEC
```

- Field 6 = `BACK-FILE` (the actual image path) ✅
- Field 7 = `DIO` (direct I/O flag: 0 or 1)
- Field 8 = `LOG-SEC` (logical sector size: typically 512)

**Result:** `image_path` contains extra fields:
```bash
# Expected:
/data/fast/img/9bfbfb9e7b86a330b4c45c1332e749e2.img

# Actual:
/data/fast/img/9bfbfb9e7b86a330b4c45c1332e749e2.img 0 512
```

**Impact:** The `grep -F "$image_path"` at line 662 searches for the literal string:
```
/data/fast/img/9bfbfb9e7b86a330b4c45c1332e749e2.img 0 512
```

This string does NOT exist in the `losetup -l` output because the BACK-FILE column doesn't include the DIO and LOG-SEC values. The grep fails to match ANY loop devices, so nothing gets detached.

---

### Proposed Fix

**Change line 656** to extract only field 6 (BACK-FILE column):

```bash
# Current (BROKEN):
image_path=$(losetup -l | grep "^$base_loop_device" | awk '{for(i=6;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ *$//' | sed 's/ (deleted)$//')

# Fixed:
image_path=$(losetup -l | grep "^$base_loop_device" | awk '{print $6}' | sed 's/(deleted)$//')
```

**Why this works:**
- `awk '{print $6}'` extracts ONLY the BACK-FILE column
- `sed 's/(deleted)$//'` strips the "(deleted)" suffix if present
- The resulting `image_path` will match the BACK-FILE values in other rows
- `grep -F "$image_path"` will correctly find all loop devices pointing to that image

---

### Status

**Implementation status:** FAILED - fix does not work as implemented
**Action required:** dev-claude needs to correct line 656 in `bin/ntt-mount-helper`
**Priority:** Medium - loop devices still accumulating, but Solution 2 (ntt-cleanup-mounts) provides fallback cleanup

---

## Fix Applied and Re-tested

**Fixed by:** PB
**Date:** 2025-10-17 19:00

**Code change applied to `bin/ntt-mount-helper` line 656:**

```bash
# Before (BROKEN):
image_path=$(losetup -l | grep "^$base_loop_device" | awk '{for(i=6;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ *$//' | sed 's/ (deleted)$//')

# After (FIXED):
image_path=$(losetup -l | grep "^$base_loop_device" | awk '{print $6}' | sed 's/(deleted)$//')
```

**Re-test performed by:** prox-claude
**Date:** 2025-10-17 19:05

### Re-test Scenario

```bash
# Setup: Create 4 loop devices
sudo losetup -f --show -r -P /data/fast/img/9bfbfb9e...img  # /dev/loop0
sudo losetup -f --show -r -P /data/fast/img/9bfbfb9e...img  # /dev/loop1
sudo losetup -f --show -r -P /data/fast/img/9bfbfb9e...img  # /dev/loop2
sudo bin/ntt-mount-helper mount 9bfbfb9e... /data/fast/img/9bfbfb9e...img  # /dev/loop3

# Verify 4 loop devices exist
sudo losetup -l | grep 9bfbfb9e
# Output: 4 loop devices confirmed

# Run unmount
sudo bin/ntt-mount-helper unmount 9bfbfb9e7b86a330b4c45c1332e749e2
# Output:
# Unmounted /mnt/ntt/9bfbfb9e7b86a330b4c45c1332e749e2
# Found 4 loop device(s) for this image, detaching all...
#   Detached /dev/loop1
#   Detached /dev/loop2
#   Detached /dev/loop0
#   Detached /dev/loop3

# Verify cleanup
sudo losetup -l | grep 9bfbfb9e
# Output: No loop devices remaining
```

**Result:** ✅ **TEST PASSED**

- All 4 loop devices successfully detached
- 0 orphaned loop devices remaining
- Fix verified working as expected

**Status:** FIXED - Ready to move to bugs/fixed/

---
