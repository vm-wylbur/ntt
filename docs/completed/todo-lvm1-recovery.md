<!--
Author: PB and Claude
Date: Sat 19 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/todo-lvm1-recovery.md
-->

# TODO: LVM1 Volume Recovery

**Status**: Research complete, awaiting execution
**Priority**: Medium (historical data, not urgent)
**Estimated effort**: 3-5 hours

## Background

During processing of 2006-2007 era disk images, we discovered two LVM1 volume groups that cannot be read by modern LVM2 tools (2.03.31). LVM1 format support was completely removed from LVM2 in version 2.02.178 (June 2018).

## Affected Disk Images

### 473edca972a2ac424b90e6a2d374e7bb (WDC_WD2500JB-00GVA0)
**Location**: `/data/cold/img-unprocessed/473edca972a2ac424b90e6a2d374e7bb.img` (233GB)
**Status**: Archived (non-LVM partitions only)

**LVM Partitions**:
- **p1**: VGslow (PV UUID: h2626A-qEKz-BD7U-3xIL-CaTD-83sX-61NMYc)
  - LVs: guate, hrdag
- **p2**: VGfast (PV UUID: QCDA5y-ZT9F-TJLC-cTG7-kzDT-445K-4TQXd4)
  - LVs: apache, apachevar, apachewww, chad-images, chroot, home, imapd, imapdvar, qmail, rafe, syslog, usrlocal

### 4474de006851b27729e7b6c2f198885f (ST3300831A_3NF02YDZ)
**Location**: `/data/cold/img-unprocessed/4474de006851b27729e7b6c2f198885f.img` (280GB)
**Status**: Processed (0 files - only LVM partition)

**LVM Partitions**:
- **p1**: VGfast (PV UUID: QCDA5y-ZT9F-TJLC-cTG7-kzDT-445K-4TQXd4) [MATCHES 473edca9 p2]
  - Part of multi-disk VGfast volume group
- p2, p3: Truncated/corrupted

## Recovery Plan

**Recommended approach**: Legacy Linux VM with Ubuntu 12.04 LTS

**Key steps**:
1. Download Ubuntu 12.04 LTS ISO (has LVM2 2.02.66-2.02.95 with LVM1 support)
2. Create VirtualBox VM
3. Attach disk images via read-only loop devices + VMDK descriptors
4. Boot Ubuntu 12.04, activate VGfast/VGslow with `vgchange -ay --readonly`
5. Mount all logical volumes read-only
6. Extract data using dd/tar/rsync
7. Verify with checksums

**Timeline**: 3-5 hours
**Success probability**: High (8/10) - metadata intact, both PVs accessible

## Reference Documentation

**Comprehensive guide**: `docs/reference/lvm1-recovery-on-modern-linux.md`
- Details why modern LVM2 fails (format1 library removed)
- Step-by-step VM setup and recovery procedure
- Alternative approaches and risk assessment
- ISO download locations and VM configuration

**Metadata extraction tool**: `bin/ntt-mount-helper` (lines 410-594)
- Automatically detects and extracts LVM metadata during mount
- Stores PV UUID, VG name, LV list in database `medium.diagnostics`
- Works for both LVM1 and LVM2 detection (though cannot mount LVM1)

## For Future Disk Processing

**Detection**: Our mount-helper automatically detects LVM partitions (any version) and extracts metadata. When you see:
```
Skipping partition pN (status: lvm_detected)
Found N LVM partition(s), extracting metadata...
```

This indicates LVM volumes that need special recovery. Check `medium.diagnostics` for:
- Volume group names (look for matching VG names across disks)
- Physical volume UUIDs (matching UUIDs = multi-disk volume groups)
- Logical volume names (indicates what data to expect)

If metadata shows `LVM1_member` (via blkid), recovery requires the legacy VM approach documented in the reference guide.

## Action Items

- [ ] Download Ubuntu 12.04 LTS ISO (~700MB)
- [ ] Install VirtualBox if not present
- [ ] Create test VM and verify boot
- [ ] Attach disk images read-only (loop + VMDK)
- [ ] Activate VGfast and VGslow volumes
- [ ] Mount and verify all 14 logical volumes (12 VGfast + 2 VGslow)
- [ ] Extract data with checksums
- [ ] Document findings and data recovered
- [ ] Update this TODO with results

## Notes

- Both disk images remain in `img-unprocessed/` - not deleted
- VGfast spans two physical drives (RAID-0 or concat?)
- VGslow is single-disk only (473edca9 p1)
- All metadata successfully extracted and stored in database
- No data corruption detected - metadata is intact
