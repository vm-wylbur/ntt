# Disk 031a3ceb Investigation Report

## Problem Summary

Disk image `031a3ceb158fb23993c16de83fca6833.img` (372.61 GiB) cannot be successfully mounted to extract data. The disk contains a RAID1 array that assembles correctly, but all partitions (including the assembled RAID device) appear to contain no valid filesystems.

## Disk Layout

```
Disk /dev/loop17: 372.61 GiB, 400088457216 bytes, 781422768 sectors
Sector size: 512 bytes (logical/physical)
Disklabel type: dos
Disk identifier: 0x55555555

Partition Table:
Device        Boot    Start       End   Sectors   Size Id Type
/dev/loop17p1 *          63    192779    192717  94.1M fd Linux raid autodetect
/dev/loop17p2        192780  15824024  15631245   7.5G 83 Linux
/dev/loop17p3      15824025  17816084   1992060 972.7M 82 Linux swap / Solaris
/dev/loop17p4      17816085 781417664 763601580 364.1G  5 Extended
/dev/loop17p5      17816148  37351124  19534977   9.3G fd Linux raid autodetect
/dev/loop17p6      37351188  56886164  19534977   9.3G fd Linux raid autodetect
/dev/loop17p7      56886228 781417664 724531437 345.5G fd Linux raid autodetect
```

## RAID Array Status

### p1 - Boot Partition RAID Array

Successfully assembles as `/dev/md127`:

```
/dev/md127:
           Version : 1.2
     Creation Time : Fri Nov 11 20:15:48 2011
        Raid Level : raid1
        Array Size : 96346 (94.09 MiB 98.66 MB)
     Used Dev Size : 96346 (94.09 MiB 98.66 MB)
      Raid Devices : 1
     Total Devices : 1
       Persistence : Superblock is persistent

       Update Time : Fri Nov 11 20:23:40 2011
             State : clean
    Active Devices : 1
   Working Devices : 1
    Failed Devices : 0
     Spare Devices : 0

              Name : Microknoppix:0
              UUID : 401fbcd1:59c7cf0a:6ee9607a:58af2b55
            Events : 2

    Number   Major   Minor   RaidDevice State
       0     259       44        0      active sync   /dev/loop17p1
```

**RAID Array Characteristics:**
- Array name: "Microknoppix:0" (suggests Knoppix Linux distribution)
- Creation date: November 11, 2011
- Last update: November 11, 2011 (same day)
- RAID1 with 1 device (degraded, missing mirror)
- State reported as "clean"
- Array assembled successfully with `mdadm --assemble --run`

### p5, p6, p7 - Other RAID Partitions

All three partitions are marked with partition type `fd` (Linux raid autodetect), but:

```bash
$ sudo mdadm --examine /dev/loop17p5
mdadm: No md superblock detected on /dev/loop17p5.

$ sudo mdadm --examine /dev/loop17p6
mdadm: No md superblock detected on /dev/loop17p6.

$ sudo mdadm --examine /dev/loop17p7
mdadm: No md superblock detected on /dev/loop17p7.
```

**RAID Metadata Status:**
- p5 (9.3G): Partition type `fd`, but NO RAID metadata found
- p6 (9.3G): Partition type `fd`, but NO RAID metadata found
- p7 (345.5G): Partition type `fd`, but NO RAID metadata found

These partitions have the RAID partition type set but contain no mdadm superblock.

## Filesystem Detection Attempts

### blkid Results

```bash
$ sudo blkid /dev/loop17p* /dev/md127

/dev/loop17p1: UUID="401fbcd1-59c7-cf0a-6ee9-607a58af2b55"
               UUID_SUB="23c09e4f-4db6-67e1-a976-c660279753a0"
               LABEL="Microknoppix:0"
               TYPE="linux_raid_member"
               PARTUUID="55555555-01"

/dev/loop17p2: PARTUUID="55555555-02"
/dev/loop17p3: PARTUUID="55555555-03"
/dev/loop17p4: PTUUID="55555555" PTTYPE="dos" PARTUUID="55555555-04"
/dev/loop17p5: PARTUUID="55555555-05"
/dev/loop17p6: PARTUUID="55555555-06"
/dev/loop17p7: PARTUUID="55555555-07"
(no output for /dev/md127)
```

**Key Observations:**
- p1: Correctly identified as `linux_raid_member`
- p2-p7: No TYPE field (no filesystem signature detected)
- md127: No output from blkid (no recognized filesystem)

### file Command Results

```bash
$ sudo file -s /dev/md127
/dev/md127: SIMH tape data

$ sudo file -s /dev/loop17p2
/dev/loop17p2: SIMH tape data

$ sudo file -s /dev/loop17p3
/dev/loop17p3: SIMH tape data
```

The "SIMH tape data" identification is `file`'s interpretation of the repeating 0x55 byte pattern.

### Raw Data Inspection

All partitions and the assembled RAID device contain the same pattern:

```bash
$ sudo hexdump -C /dev/md127 | head -40
00000000  55 55 55 55 55 55 55 55  55 55 55 55 55 55 55 55  |UUUUUUUUUUUUUUUU|
*
05e16800

$ sudo hexdump -C /dev/loop17p2 | head -40
00000000  55 55 55 55 55 55 55 55  55 55 55 55 55 55 55 55  |UUUUUUUUUUUUUUUU|
*
1dd071a00

$ sudo hexdump -C /dev/loop17p5 | head -10
00000000  55 55 55 55 55 55 55 55  55 55 55 55 55 55 55 55  |UUUUUUUUUUUUUUUU|
*
254290200

$ sudo hexdump -C /dev/loop17p6 | head -10
00000000  55 55 55 55 55 55 55 55  55 55 55 55 55 55 55 55  |UUUUUUUUUUUUUUUU|
*
254290200
```

**Pattern Analysis:**
- Every partition contains repeating `0x55` bytes
- Pattern extends through entire partition (verified with `hexdump` until timeout)
- No variation in data pattern observed
- No filesystem magic numbers present

## Mount Attempts

### md127 (Assembled RAID Device)

**Attempt 1: ext4**
```bash
$ sudo mount -t ext4 -o ro /dev/md127 /tmp/test-mount-031a

mount: /tmp/test-mount-031a: wrong fs type, bad option, bad superblock on
/dev/md127, missing codepage or helper program, or other error.

$ dmesg | tail -1
EXT4-fs (md127): VFS: Can't find ext4 filesystem
```

**Attempt 2: ext3**
```bash
$ sudo mount -t ext3 -o ro /dev/md127 /tmp/test-mount-031a

mount: /tmp/test-mount-031a: wrong fs type, bad option, bad superblock on
/dev/md127, missing codepage or helper program, or other error.
```

**Attempt 3: ext2**
```bash
$ sudo mount -t ext2 -o ro /dev/md127 /tmp/test-mount-031a

mount: /tmp/test-mount-031a: wrong fs type, bad option, bad superblock on
/dev/md127, missing codepage or helper program, or other error.
```

**Attempt 4: ext2 superblock check**
```bash
$ sudo dumpe2fs /dev/md127
dumpe2fs 1.47.2 (1-Jan-2025)
dumpe2fs: Bad magic number in super-block while trying to open /dev/md127
Couldn't find valid filesystem superblock.
```

### Other Partitions

No mount attempts were made on p2-p7 because blkid reported no filesystem type. Based on the hexdump output showing solid 0x55 patterns, these would also fail to mount.

## What We Know

1. **RAID Assembly Works**: The RAID1 array on p1 assembles successfully into /dev/md127
2. **No Filesystem Present**: The assembled md127 device contains no ext2/ext3/ext4 filesystem
3. **Data Wiped Pattern**: All partitions contain repeating 0x55 bytes (no actual data)
4. **RAID Metadata Inconsistency**: p5/p6/p7 marked as RAID type but contain no RAID superblock
5. **Disk Identifier Suspicious**: Partition table has disk ID 0x55555555 (all same pattern)
6. **Date Context**: Array created/updated November 11, 2011 (13+ years ago)
7. **Microknoppix System**: Array name suggests this was a Knoppix-based system

## What Failed

1. **Filesystem detection with blkid**: No TYPE detected for any partition except p1 (raid member)
2. **Mount attempts**: All filesystem types (ext2, ext3, ext4) failed on md127
3. **Superblock inspection**: dumpe2fs found no valid ext filesystem magic number
4. **RAID assembly of p5/p6/p7**: No RAID metadata present despite partition type
5. **Data recovery**: Entire disk appears to be filled with 0x55 pattern

## Questions

1. **Was this disk securely wiped?** The 0x55 pattern across all partitions suggests deliberate data destruction, not random corruption.

2. **Why does the RAID metadata survive?** The mdadm superblock on p1 is intact and valid, but the filesystem within the array is wiped.

3. **Why mark p5/p6/p7 as RAID type?** These partitions have partition type `fd` but no RAID metadata - were they wiped more thoroughly?

4. **Is the disk image complete?** Could this be a partial or corrupted imaging of an already-wiped disk?

5. **Alternative filesystems?** Should we try other filesystem types (FAT, NTFS, ReiserFS, XFS, JFS)?

6. **Backup superblocks?** For ext filesystems, should we search for backup superblocks at known offsets?

7. **Data carving?** Is it worth attempting to carve file signatures from the 0x55 pattern, or is it truly uniform throughout?

## Technical Environment

- Kernel: Linux 6.17.0-5-generic
- mdadm version: Not explicitly checked, but supports RAID1 with v1.2 superblock
- Loop device: /dev/loop17 with partition scanning (-P flag)
- RAID module: raid1 loaded with `modprobe raid1`
- Mount attempts: All with `-o ro,noatime,nodev,nosuid` for safety
