<!--
Author: PB and Claude
Date: Thu 17 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/bugs/BUG-020-udf-corruption-enum-hangs-9c5156cf.md
-->

# BUG-020: UDF filesystem corruption causes system-wide hangs

**Filed:** 2025-10-17 14:28
**Filed by:** prox-claude
**Status:** open
**Affected media:** 9c5156cf (9c5156cf916e98a63a4a34e5a8c928b8)
**Phase:** enumeration

---

## Observed Behavior

UDF filesystem with directory CRC corruption causes enumeration to hang at 0 files/s indefinitely. Any process attempting to read the filesystem hangs (ls, ntt-enum, lsof). Filesystem cannot be unmounted normally - requires lazy unmount.

**Commands run:**
```bash
# Already mounted from previous session:
mount | grep 9c5156cf
# /dev/loop7 on /mnt/ntt/9c5156cf916e98a63a4a34e5a8c928b8 type udf (...)

# Attempted processing:
sudo bin/ntt-orchestrator --image /data/fast/img/9c5156cf916e98a63a4a34e5a8c928b8.img --force

# Attempted to check filesystem:
sudo ls -R /mnt/ntt/9c5156cf916e98a63a4a34e5a8c928b8/
# [command hung, never returned]

# Attempted to find hung processes:
sudo lsof +D /mnt/ntt/9c5156cf916e98a63a4a34e5a8c928b8
# [command hung, never returned]

# Attempted unmount:
sudo bin/ntt-mount-helper unmount 9c5156cf916e98a63a4a34e5a8c928b8
# Warning: Failed to unmount /mnt/ntt/9c5156cf916e98a63a4a34e5a8c928b8

sudo umount -f /mnt/ntt/9c5156cf916e98a63a4a34e5a8c928b8
# umount: /mnt/ntt/9c5156cf916e98a63a4a34e5a8c928b8: target is busy.

# Only lazy unmount worked:
sudo umount -l /mnt/ntt/9c5156cf916e98a63a4a34e5a8c928b8
# Succeeded
```

**Output/Error:**
```
# From ntt-orchestrator output:
[2025-10-17T14:29:03-07:00] STAGE: Enumeration
[2025-10-17T14:29:03-07:00] Running ntt-enum: /mnt/ntt/9c5156cf916e98a63a4a34e5a8c928b8 -> /data/fast/raw/9c5156cf916e98a63a4a34e5a8c928b8.raw
0.00  0:00:01 [0.00 /s] [<=>  ]
0.00  0:00:02 [0.00 /s] [<=>  ]
0.00  0:00:03 [0.00 /s] [<=>  ]
[... continues at 0.00 files/s indefinitely ...]
0.00  0:00:31 [0.00 /s] [<=>  ]
[killed by user interrupt]
```

**Database state:**
```sql
-- Before attempt:
SELECT medium_hash, enum_done, copy_done, problems
FROM medium
WHERE medium_hash = '9c5156cf916e98a63a4a34e5a8c928b8';
# 9c5156cf916e98a63a4a34e5a8c928b8 | NULL | NULL | NULL

-- After marking with problems:
SELECT jsonb_pretty(problems)
FROM medium
WHERE medium_hash = '9c5156cf916e98a63a4a34e5a8c928b8';
# {
#   "udf_corruption": true,
#   "crc_errors": true,
#   "error_type": "UDF directory CRC mismatch",
#   "ino": 1622
# }
```

**Filesystem state:**
```bash
ls -lh /data/fast/img/9c5156cf916e98a63a4a34e5a8c928b8.img
# -rw-r----- 1 root root 41M Oct 17 10:50 9c5156cf916e98a63a4a34e5a8c928b8.img

# Raw file created but empty:
ls -lh /data/fast/raw/9c5156cf916e98a63a4a34e5a8c928b8.raw
# -rw-r----- 1 root root 0 Oct 17 10:51 9c5156cf916e98a63a4a34e5a8c928b8.raw
```

**System logs:**
```bash
sudo dmesg | tail -50 | grep -E 'UDF|loop7|9c5156cf'

# Result: Hundreds of UDF CRC errors:
[70848.932022] UDF-fs: error (device loop7): udf_verify_fi: directory (ino 1622) has entry where CRC length (0) does not match entry length (48)
[70848.932023] UDF-fs: error (device loop7): udf_verify_fi: directory (ino 1622) has entry where CRC length (0) does not match entry length (48)
[... repeated hundreds of times ...]
```

---

## Expected Behavior

According to checklist, enumeration should:
1. Show progress with files/second rate
2. Complete within reasonable time (minutes for small media)
3. If filesystem has errors, should fail fast, not hang indefinitely

For comparison:
- HFS+ catalog corruption: slow but eventually completes (~50-100 files/s)
- UDF corruption: complete system hang, no progress, affects all processes

---

## Success Condition

**This bug is NOT fixable** - UDF corruption is at filesystem metadata level and there is no fsck tool for UDF.

**Success condition is to SKIP this medium:**
- [x] Medium marked with `problems` in database
- [x] Lazy unmount succeeded
- [ ] Document in lessons: UDF corruption pattern, how to detect early
- [ ] Add to checklist: Watch for 0.00 files/s in first 10 seconds → STOP immediately

**Prevention for future media:**
- [ ] If enum shows 0.00 files/s for >10 seconds → kill process immediately
- [ ] Check dmesg for UDF errors before attempting enum
- [ ] Consider pre-flight check: `sudo blkid` to detect filesystem type, warn on UDF

---

## Impact

**Severity:** HIGH (corrupted media is unrecoverable, but pattern is rare)
**Initial impact:** Blocks 1 medium (9c5156cf), causes system-wide hangs when accessed
**Workaround available:** no - media is permanently corrupt
**Pattern:** UDF directory CRC mismatch (ino 1622)

**Dangerous behavior:**
- Causes system-wide hangs (not just NTT tools)
- Required force-killing multiple processes
- Required lazy unmount to detach filesystem
- Any process attempting directory read will hang

**Mitigation for future:**
1. Watch enum rate in first 10 seconds
2. If 0.00 files/s → kill immediately, check dmesg
3. If UDF errors in dmesg → mark medium as corrupt, skip
4. Never attempt to re-mount UDF-corrupted media

---

## Recovery Investigation (2025-10-17)

**Attempted by:** prox-claude

### Tools Investigated:

**udfinfo analysis:**
```bash
sudo udfinfo /data/fast/img/9c5156cf916e98a63a4a34e5a8c928b8.img

Results:
- numfiles=0, numdirs=0 (metadata claims empty filesystem)
- integrity=closed (properly closed)
- udfrev=1.50 (valid UDF format)
- Warnings:
  * First and second Anchor Volume Descriptor Pointer differ
  * Partition Space overlaps with other blocks
  * VAT found at block 20981 (expected 20983)
```

**Analysis:** Metadata structures are readable but claim 0 files. However, kernel found directory ino 1622 with CRC errors - inconsistency suggests corruption.

**wrudf attempt:**
```bash
sudo wrudf /data/fast/img/9c5156cf916e98a63a4a34e5a8c928b8.img

Error:
No File Set Descriptor
No UDF VRS
Unexpected tag id 0, where File Set Desc(256) expected
```

**Analysis:** Cannot read File Set Descriptor - deeper structural corruption than just CRC mismatches.

### Available UDF Tools:

From udftools package (version 2.3):
- udfinfo - read metadata only (no repair)
- wrudf - file operations shell (requires valid FSD)
- mkudffs/mkfs.udf - create new filesystem (destructive)
- udflabel - change volume label
- cdrwtool - CD-RW operations

**Critical finding:** NO fsck or repair tool exists for UDF filesystems in Linux.

### Recovery Conclusion:

**UDF filesystem is UNRECOVERABLE:**

1. No fsck.udf or repair tool exists
2. File Set Descriptor is missing/corrupted (wrudf cannot access)
3. Directory metadata has CRC mismatches (kernel errors on ino 1622)
4. Metadata claims 0 files, but corrupted directory entries exist
5. Attempting filesystem access causes kernel-level hangs
6. Linux UDF driver is read-only, no repair capability

**Root cause:** Likely incomplete CD-R burn or optical media degradation.

**Decision:** Mark medium as permanently corrupt and skip. No further recovery possible.

---

## Dev Notes

<!-- dev-claude: No fix needed - this is a data quality issue, not a code bug -->

**Recommended action:**
- Update PROX-CLAUDE-CHECKLIST.md with UDF corruption detection
- Add to disk-read-checklist.md: Check dmesg for UDF errors
- Document in lessons/

---

## Fix Verification

**Not applicable** - this is data corruption, not a code bug. Medium 9c5156cf should be skipped permanently.

**Recovery attempted:** Yes (2025-10-17)
**Recovery successful:** No - filesystem is unrecoverable
