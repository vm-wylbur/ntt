<!--
Author: PB and Claude
Date: Thu 10 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/bugs/BUG-006-orchestrator-continues-after-optical-timeout.md
-->

# BUG-006: Orchestrator continues execution after optical drive timeout

**Filed:** 2025-10-10 14:59
**Filed by:** dev-claude
**Status:** fixed
**Fixed:** 2025-10-10
**Fixed by:** dev-claude
**Affected media:** Optical drives that fail readiness check
**Phase:** imaging (device identification)

---

## Observed Behavior

When optical drive fails readiness check (30s timeout), orchestrator reports error but continues execution anyway.

**Command run:**
```bash
sudo bin/ntt-orchestrator --message "Chad Data from HRW" /dev/sr0
```

**Output:**
```
[2025-10-10T14:59:05-07:00] Identifying device /dev/sr0...
[2025-10-10T14:59:05-07:00] Optical drive detected, waiting for media to be ready...
Error: Optical drive timeout: media not ready after 30s
[2025-10-10T14:59:35-07:00] Inserting medium record to database...
[2025-10-10T14:59:35-07:00] Starting imaging: /dev/sr0 -> /data/fast/img/.img
[2025-10-10T14:59:35-07:00] ======================================
[2025-10-10T14:59:35-07:00] NTT Progressive Imager Starting
[2025-10-10T14:59:35-07:00] ======================================
[2025-10-10T14:59:35-07:00] Device: /dev/sr0
[2025-10-10T14:59:35-07:00] Output: /data/fast/img/.img
```

**Problems:**
1. Script continues after "Error: Optical drive timeout" message
2. Output path is broken: `/data/fast/img/.img` (missing medium_hash)
3. Attempts to insert database record with incomplete/invalid data
4. Attempts to start imaging on device that failed readiness check

---

## Expected Behavior

When optical drive fails readiness check, orchestrator should:
1. Report the timeout error
2. **Exit immediately** with non-zero exit code
3. NOT continue to database insertion
4. NOT attempt to start imaging

**Expected output:**
```
[2025-10-10T14:59:05-07:00] Identifying device /dev/sr0...
[2025-10-10T14:59:05-07:00] Optical drive detected, waiting for media to be ready...
Error: Optical drive timeout: media not ready after 30s
[Script exits with code 1]
```

---

## Success Condition

**How to verify fix:**

1. Test with optical drive that fails readiness check
2. Run: `sudo bin/ntt-orchestrator --message "test" /dev/sr0`
3. Verify script exits after timeout error
4. Check exit code: `echo $?` should be non-zero (1)
5. Verify no database record inserted
6. Verify no imaging attempt

**Fix is successful when:**
- [ ] Script exits immediately after optical drive timeout
- [ ] Exit code is non-zero (1)
- [ ] No database insertion after timeout
- [ ] No imaging attempt after timeout
- [ ] No broken file paths in output
- [ ] Test case: Simulate timeout, verify clean exit

---

## Impact

**Initial impact:** Creates invalid database records and broken file paths
**Workaround available:** Manual cleanup of invalid records
**Severity:** MEDIUM

**Why MEDIUM:**
- Does not corrupt valid data
- Creates invalid/incomplete database records
- Wastes time attempting imaging on failed devices
- Broken paths could cause downstream issues
- User must manually clean up invalid records

**Data risk:**
- No data loss (device not readable anyway)
- Invalid records pollute database
- Broken paths in database require cleanup
- Could cause confusion in processing pipeline

---

## Root Cause Analysis

**The Problem: Command Substitution Subshell**

At line 1018 in `handle_device_mode()`:
```bash
local identify_result=$(identify_device "$dev" "$user_message")
```

When `identify_device()` calls `fail()` at line 189 (optical timeout), the `fail()` function correctly calls `exit 1` (line 95). However, because `identify_device()` is running inside a command substitution `$(...)`, the exit only terminates the **subshell**, not the main script.

**Flow:**
1. Line 1018: `identify_device` runs in subshell due to `$(...)`
2. Line 189: Optical timeout detected, calls `fail()`
3. Line 95: `fail()` calls `exit 1`
4. **Exit kills subshell only** - main script continues
5. Line 1019: `identify_result` is empty string
6. Lines 1020-1022: Parse empty string → `medium_hash=""`, `medium_human=""`
7. Line 1028: Image path becomes `/data/fast/img/.img` (missing hash)
8. Script continues with broken data

**Same issue at:**
- Line 1207: `identify_image()` in image mode
- Line 1175: `identify_path()` in directory mode

**Fix:** Check exit status after command substitution and exit if failed

---

## Dev Notes

### Fix Applied (2025-10-10 by dev-claude)

**Change:** Added exit status checks after all `identify_*` command substitutions

**Locations modified:**
1. **Line 1019** - `handle_device_mode()`:
```bash
local identify_result=$(identify_device "$dev" "$user_message")
[[ -n "$identify_result" ]] || exit 1  # identify_device already logged error
```

2. **Line 1177** - `handle_directory_mode()`:
```bash
local identify_result=$(identify_path "$path")
[[ -n "$identify_result" ]] || exit 1  # identify_path already logged error
```

3. **Line 1210** - `handle_image_mode()`:
```bash
local identify_result=$(identify_image "$image_path" "$user_message")
[[ -n "$identify_result" ]] || exit 1  # identify_image already logged error
```

**How it works:**
- When `fail()` is called inside command substitution `$(...)`, it only exits the subshell
- The result variable becomes empty string
- New check: `[[ -n "$identify_result" ]] || exit 1` exits main script if result is empty
- Error already logged by `fail()` function, so no additional logging needed

**Testing:**
Run with optical drive timeout to verify script exits cleanly:
```bash
sudo bin/ntt-orchestrator --message "test" /dev/sr0
# Should exit after timeout without attempting database insertion or imaging
```
