<!--
Author: PB and Claude (prox-claude)
Date: Sun 20 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/unrecoverable-drives.md
-->

# Unrecoverable Drives Log

Drives that could not be recovered due to hardware failure, corruption, or other issues. This log tracks attempts and failure modes for future reference.

---

## Mechanical Failures (Never Imaged)

### Hitachi 2TB (S/N F31H63XR) - 2025-10-20

**Status:** Mechanical failure - never detected by kernel

**Hardware Details:**
- **Model:** Hitachi 2TB
- **Part Number:** H3D20003254S
- **Serial Number:** F31H63XR
- **Manufactured:** July 2011
- **Interface:** SATA

**Failure Symptoms:**
- Buzzes 5-7 times on power-on
- Never spins up
- Not detected by kernel (no /dev/sdX device created)
- Sabrent USB bridge enumerates correctly but no drive appears

**Diagnostic Evidence:**
```bash
# USB bridge detected:
[Mon Oct 20 19:53:43] usb 10-2: New USB device found, idVendor=174c, idProduct=55aa
[Mon Oct 20 19:53:43] scsi host18: uas

# But NO "Attached SCSI disk" message
# No /dev/sd* device created
```

**Probable Cause:**
- Stuck read/write heads (failed to unpark)
- OR Spindle motor failure (cannot spin up)
- Drive PCB may be functional but mechanical assembly is dead

**Recovery Options:**
- Professional data recovery only (clean room, head replacement)
- Not economically viable for this project

**Action Taken:** Drive set aside, not imaged

**Database Record:** None (never hashed, never imaged)

---

## Severe Read Errors (Partially Imaged)

### Hitachi 465GB (d6c63baf) - 2025-10-20

**Status:** Severe read errors - unreadable at ~2% recovery

**Hardware Details:**
- **Model:** Hitachi HTS545050B9A300
- **Serial:** 090713PB4400Q7HB7ASG
- **Size:** 465GB
- **Medium Hash:** d6c63baf2ab797fbb7cc8a744d01e861

**Imaging Attempt:**
- **Tool:** ddrescue (ntt-imager)
- **Date:** 2025-10-18
- **Recovery Rate:** ~2% (ddrescue errors at 2%)
- **IMG Size:** 6.7GB (out of 465GB)
- **Map File:** 719 bytes

**Failure Symptoms:**
- Extreme read errors
- ddrescue unable to progress beyond 2%
- Severe sector corruption

**Archive Status:**
- Partial IMG archived: `/data/cold/img-read/d6c63baf2ab797fbb7cc8a744d01e861.tar.zst` (2.0GB compressed)
- Database marked as unreadable

**Database Record:**
```sql
-- medium_hash: d6c63baf2ab797fbb7cc8a744d01e861
-- problems: {"unreadable": true, "reason": "Drive unreadable - ddrescue errors at ~2%"}
```

**Action Taken:** Partial IMG archived for record-keeping, drive abandoned

---

## Wiped/Erased Media

### Maxtor 6H400F0 373GB (031a3ceb) - 2025-10-20

**Status:** Partition deliberately wiped - no data to recover

**Hardware Details:**
- **Model:** Maxtor 6H400F0
- **Serial:** H80P2CWH
- **Size:** 373GB
- **Medium Hash:** 031a3ceb158fb23993c16de83fca6833

**Imaging Results:**
- **Tool:** ddrescue (ntt-imager)
- **Date:** 2025-10-20
- **Recovery:** 99.99% (excellent)
- **Bad sectors:** 1 sector (512 bytes at offset 133.7GB)
- **IMG Size:** 373GB

**Mount Failure:**
- Partition 2 (7.5GB Linux type 83) filled with 0x55 bytes
- 0x55 (01010101 binary) is deliberate wipe pattern
- No filesystem signature, superblock destroyed
- Mount fails: "wrong fs type, bad option, bad superblock"

**Partition Analysis:**
```
p1: 94MB RAID (fd) - cannot mount standalone
p2: 7.5GB Linux (83) - WIPED (0x55 pattern)
p3: 973MB swap - not data partition
p5-p7: RAID members (fd) - cannot mount standalone
```

**Archive Status:**
- IMG archived: `/data/cold/img-read/031a3ceb158fb23993c16de83fca6833.tar.zst` (pending)
- Imaging successful but no mountable data found

**Database Record:**
```sql
-- medium_hash: 031a3ceb158fb23993c16de83fca6833
-- health: incomplete (99.99% recovery)
-- problems: {"mount_failed": true, "reason": "Partition 2 wiped (0x55 pattern), no filesystem"}
```

**Probable Cause:**
- Drive was deliberately wiped/sanitized before disposal
- 0x55 pattern suggests intentional data destruction
- RAID partitions likely contained actual data (now unavailable without full array)

**Action Taken:** IMG archived for record-keeping, marked as mount_failed

**Related:** BUG-021 resolved during analysis (health calculation bug fixed)

---

## Blank/Corrupted Media

### Iomega Zip 250 (24f9ecb5) - 2025-10-20

**Status:** No recognizable filesystem - blank or severely corrupted

**Hardware Details:**
- **Media Type:** Iomega Zip 250 disk
- **Size:** 96MB
- **Medium Hash:** 24f9ecb51fec228c60a3cc53f9000f50

**Imaging Results:**
- **Tool:** ddrescue
- **Date:** 2025-10-19
- **Recovery:** Partial with errors
- **IMG Size:** 96MB

**Failure Symptoms:**
- No recognizable filesystem signature
- Mount failed (tried Zip offset 16384, standard mount)
- `file` reports: "data" (no filesystem signature)
- `blkid` found no filesystem
- `fdisk` shows no partition table

**Archive Status:**
- IMG archived: `/data/cold/img-read/24f9ecb51fec228c60a3cc53f9000f50.tar.zst` (74MB compressed)
- Includes .map file for recovery details

**Database Record:**
```sql
-- medium_hash: 24f9ecb51fec228c60a3cc53f9000f50
-- problems: {"mount_failed": true, "reason": "No recognizable filesystem"}
```

**Probable Cause:**
- Never formatted (blank disk)
- OR Severe magnetic degradation
- OR Disk was bulk-erased/degaussed

**Action Taken:** IMG archived for record-keeping, marked as failed

---

## Summary Statistics

**Total Unrecoverable:** 4 drives
- **Mechanical failures:** 1 (never imaged)
- **Severe read errors:** 1 (2% recovery)
- **Wiped/erased media:** 1 (99.99% imaged but wiped)
- **Blank/corrupted media:** 1 (imaged but no data)

**Date Range:** 2025-10-18 to 2025-10-20

**Storage Impact:**
- Archived IMG data: ~375GB (031a3ceb 373GB + d6c63baf 2.0GB + 24f9ecb5 74MB compressed)
- Represents ~838GB of attempted recovery (465GB unreadable + 373GB wiped)

---

## Notes

- All unrecoverable drives are physically removed from imaging queue
- Partial IMG files preserved for record-keeping and potential future forensics
- Database records updated with `problems` JSONB documenting failure modes
- No further recovery attempts planned without professional data recovery services

---

## Related Documents

- `docs/disk-read-checklist.md` - Diagnostic procedures for problematic disks
- `processing-queue.md` - Current processing status
- `bugs/BUG-021-*.md` - Related issues with drive health calculation
