<!--
Author: PB and Claude
Date: Fri 11 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/bugs/BUG-011-mount-helper-ext4-noload-536a933b.md
-->

# BUG-011: Mount fails on ext4 filesystem with dirty journal

**Filed:** 2025-10-11 12:06
**Filed by:** prox-claude
**Status:** fixed (verified 2025-10-11 12:12)
**Fixed by:** prox-claude
**Affected media:** 536a933b (536a933b4481f605fcd44615740a9025)
**Phase:** mount

---

## Observed Behavior

Orchestrator fails to mount ext4 filesystem that requires journal recovery. Mount-helper attempts readonly mount but ext4 requires `noload` option to skip journal recovery.

**Commands run:**
```bash
sudo bin/ntt-orchestrator --image /data/fast/img/536a933b4481f605fcd44615740a9025.img
```

**Output/Error:**
```
[2025-10-11T12:05:14-07:00] Using hash from filename: 536a933b4481f605fcd44615740a9025
[2025-10-11T12:05:14-07:00] Found existing medium: ST3000DM001-1CH166_Z1F256LR
[2025-10-11T12:05:14-07:00] Identified as: ST3000DM001-1CH166_Z1F256LR (hash: 536a933b4481f605fcd44615740a9025)
[2025-10-11T12:05:14-07:00] Inserting medium record to database...
[2025-10-11T12:05:14-07:00] === STATE-BASED PIPELINE START ===
[2025-10-11T12:05:14-07:00] STAGE: Mount
[2025-10-11T12:05:14-07:00] Mounting /data/fast/img/536a933b4481f605fcd44615740a9025.img
[2025-10-11T12:05:15-07:00] ERROR: Mount failed
[2025-10-11T12:05:15-07:00] Mount stage: FAILED (cannot continue)
```

**Filesystem state:**
```bash
# File signature:
$ sudo file -s /data/fast/img/536a933b4481f605fcd44615740a9025.img
/data/fast/img/536a933b4481f605fcd44615740a9025.img: DOS/MBR boot sector; partition 1 : ID=0xee, start-CHS (0x0,0,1), end-CHS (0x3ff,254,63), startsector 1, 4294967295 sectors, extended partition table (last)

# Partition structure (GPT):
$ sudo fdisk -l /dev/loop17
Disk /dev/loop17: 2.73 TiB, 3000592982016 bytes, 5860533168 sectors
Disklabel type: gpt

Device        Start        End    Sectors  Size Type
/dev/loop17p1  2048 5860532223 5860530176  2.7T Linux filesystem

# Filesystem detection:
$ sudo blkid /dev/loop17p1
/dev/loop17p1: UUID="979afd1f-1740-4a43-a876-9e7679155cf8" BLOCK_SIZE="4096" TYPE="ext4" PARTUUID="ecf6f1ca-bfd6-4abe-a808-113be2478b6c"

# Manual mount attempt (fails):
$ sudo mount -t ext4 -o ro,noatime,nodev,nosuid /dev/loop17p1 /mnt/test-536a
mount: /mnt/test-536a: cannot mount /dev/loop17p1 read-only.

# Kernel error:
$ sudo dmesg | tail -3
[12475.687219] EXT4-fs (loop17p1): INFO: recovery required on readonly filesystem
[12475.687483] EXT4-fs (loop17p1): write access unavailable, cannot proceed (try mounting with noload)
```

**Root Cause:**
ext4 filesystem wasn't cleanly unmounted and has a dirty journal. When mounting readonly, ext4 normally replays the journal to recover, but this requires write access. Without the `noload` mount option, readonly mount fails.

**Workaround:**
```bash
# Mount with noload option (skips journal recovery):
$ sudo mount -t ext4 -o ro,noload,noatime,nodev,nosuid /dev/loop17p1 /mnt/test-536a
Mount successful!

$ ls /mnt/test-536a
gather-2013  lost+found
```

---

## Expected Behavior

Mount-helper should automatically add `noload` option for ext4 filesystems when mounting readonly. This is safe because:
1. We're only reading data (not modifying)
2. Skipping journal replay is acceptable for archival purposes
3. Any inconsistencies from incomplete writes are already present in the image

According to `man mount`, the `noload` option is specifically designed for this case: "Don't load the journal on mounting. Note that if the filesystem was not unmounted cleanly, skipping the journal replay will lead to the filesystem containing inconsistencies that can lead to any number of problems."

For archival purposes (readonly access only), this is acceptable.

---

## Success Condition

**How to verify fix (must be observable, reproducible, specific):**

1. Run orchestrator on 536a933b: `sudo bin/ntt-orchestrator --image /data/fast/img/536a933b4481f605fcd44615740a9025.img`
2. Check if mount succeeds and creates mountpoint at `/mnt/ntt/536a933b4481f605fcd44615740a9025/`
3. Verify enumeration can access mounted filesystem

**Fix is successful when:**
- [ ] Orchestrator completes mount stage without error
- [ ] `/mnt/ntt/536a933b*/` exists and is mounted with ext4 filesystem
- [ ] Mount options include `noload` (check with `mount | grep 536a933b`)
- [ ] Test case: `sudo bin/ntt-orchestrator --image /data/fast/img/536a933b4481f605fcd44615740a9025.img` proceeds past mount stage to enumeration

---

## Impact

**Severity:** TBD (metrics-claude to assess)
**Initial impact:** Blocks 1 media (536a933b 3TB disk) - potentially more if other ext4 disks have dirty journals
**Workaround available:** yes - manual mount with noload option, then run enum/load/copy manually

**Technical notes:**
- This is a 3TB ext4 filesystem on GPT partition
- Common scenario: disk images from systems that weren't cleanly shutdown
- The `noload` option is specifically designed for readonly mount of dirty ext4 filesystems
- Should apply to both single-partition and multi-partition disks

---

## Dev Notes

**Fixed by:** prox-claude
**Date:** 2025-10-11 12:12
**Commit:** (pending)

### Implementation

Added `get_mount_options()` helper function to ntt-mount-helper that automatically adds `noload` option for ext2/ext3/ext4 filesystems:

```bash
get_mount_options() {
  local fs_type="$1"
  local base_opts="ro,noatime,nodev,nosuid"

  if [[ "$fs_type" == "ext4" || "$fs_type" == "ext3" || "$fs_type" == "ext2" ]]; then
    echo "${base_opts},noload"
  else
    echo "$base_opts"
  fi
}
```

Updated all mount locations in ntt-mount-helper to use this helper:
- Multi-partition partition mounts (line 259)
- Multi-partition RAID device mounts (line 319)
- Single-partition mounts (line 363)
- ISO9660/UDF fallback mounts (lines 383, 392)
- Zip disk offset mounts (line 421)

### Technical Notes

The `noload` mount option tells ext4 to skip journal replay on readonly mounts. The kernel internally converts this to `norecovery` (visible in /proc/mounts). This is safe for archival purposes because:
1. We only read data (never write)
2. Any inconsistencies from incomplete writes were already present in the original disk
3. Journal replay requires write access, which we don't need

### Files Modified

- `bin/ntt-mount-helper` - Added helper function and updated 7 mount locations

---

## Fix Verification

**Verified by:** prox-claude
**Date:** 2025-10-11 12:12

### Verification Results

**Test:** `sudo bin/ntt-orchestrator --image /data/fast/img/536a933b4481f605fcd44615740a9025.img`

✅ **Mount stage: SUCCESS**
- Mount point created: `/mnt/ntt/536a933b4481f605fcd44615740a9025/p1`
- Mount options verified: `mount | grep 536a933b` shows `norecovery` (kernel's internal name for `noload`)
- Full mount line: `/dev/loop17p1 on /mnt/ntt/536a933b4481f605fcd44615740a9025/p1 type ext4 (ro,nosuid,nodev,noatime,norecovery,stripe=8191)`

✅ **Enumeration stage: SUCCESS**
- Records enumerated: 292,289 inodes
- Raw file created: `/data/fast/raw/536a933b4481f605fcd44615740a9025.raw`

✅ **Load stage: SUCCESS**
- PostgreSQL import: 292,289 records
- Partitions created: `inode_p_536a933b`, `path_p_536a933b`
- Deduplication completed in 4s
- Excluded inodes: 462 (all paths excluded), 11,627 (directories/symlinks)

✅ **Copy stage: IN PROGRESS**
- Workers launched: 16 workers
- Files to process: ~280,200 files
- Worker PID file: `/tmp/ntt-workers.pids`

### Success Criteria Met

- ✅ Orchestrator completed mount stage without error
- ✅ `/mnt/ntt/536a933b*/` exists and is mounted with ext4 filesystem
- ✅ Mount options include `noload`/`norecovery` (verified with `mount | grep 536a933b`)
- ✅ Pipeline proceeds past mount stage to enumeration, load, and copy

### Status

**BUG-011: FIXED and VERIFIED**

The noload option successfully allows mounting ext4 filesystems with dirty journals. Pipeline is now processing 536a933b through full workflow.
