<!--
Author: PB and Claude
Date: Thu 17 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/bugs/FEATURE-001-mount-helper-hybrid-iso-apm-support.md
-->

# FEATURE-001: Support Apple Partition Map (APM) hybrid ISO/HFS+ discs

**Filed:** 2025-10-17 16:45
**Filed by:** prox-claude
**Type:** Feature Request
**Priority:** Medium
**Affected media:** 9bfbfb9e, d43eb00e, 647bf9a8 (3 optical discs, likely more)

---

## Problem

ntt-mount-helper cannot mount hybrid ISO9660/HFS+ optical discs created with Apple DiscRecording. These discs have:
1. **Apple Partition Map (APM)** partition table
2. **Partition 1:** APM metadata (unmountable)
3. **Partition 2:** HFS+ filesystem (for Mac OS)
4. **Whole disk:** ISO9660 filesystem overlay (for Windows/Linux)

**Current behavior:**
- Mount helper detects as multi-partition disk
- Tries to mount p1 (APM metadata) → fails
- Tries to mount p2 (HFS+) → could work but skipped
- Ignores whole-disk ISO9660 filesystem
- Exits with "No partitions could be mounted"

**Expected behavior:**
Mount the ISO9660 filesystem at whole-disk level, which contains all the data.

---

## Investigation

### Media Analyzed:

**9bfbfb9e** (353M ISO):
```
Partition table: Mac APM
p1: Apple Partition Map metadata (unmountable)
p2: HFS+ "Chad_DDS_doc_images" (UUID=0f476ed8...)
Whole disk: ISO9660 "CHAD_DDS_DOC_IMAGES" (UUID=2005-04-07-00-05-33-00)
Created: 2005-04-06 with DiscRecording 2.1.17f1
```

**d43eb00e** (341M ISO):
```
Partition table: Mac APM
p1: Apple Partition Map metadata (unmountable)
p2: HFS+ "Chad_DDS_doc_images" (UUID=40b1d3fe...)
Whole disk: ISO9660 "CHAD_DDS_DOC_IMAGES" (UUID=2005-04-07-18-22-17-00)
Created: 2005-04-07 with DiscRecording 2.1.17f1
```

**647bf9a8** (900K ISO):
```
Partition table: Mac APM
p1: Apple Partition Map metadata (unmountable)
p2: HFS+ "Memoria del Silencio" (UUID=fff17acf...)
Whole disk: ISO9660 "MEMORIADELSILENCIO" (UUID=2004-09-20-22-35-54-00)
Created: 2004-09-20 with DiscRecording 2.1.6f3
```

### Manual Mount Test:

**Successful whole-disk ISO9660 mount:**
```bash
$ sudo losetup -f --show -r -P /data/fast/img/9bfbfb9e7b86a330b4c45c1332e749e2.img
/dev/loop6

$ sudo mount -t iso9660 -o ro,noatime /dev/loop6 /mnt/test
# SUCCESS - filesystem is accessible

$ ls /mnt/test | head -5
aoffa891017-00-th.png
aoffa891017-00.png
aoffa891017-01-th.png
aoffa891017-01.png
as01xxxxxx-00-th.png
```

---

## Proposed Solution

**Enhancement to ntt-mount-helper:**

When multi-partition disk detected with APM partition table:
1. Check if whole-disk has ISO9660 filesystem: `blkid -o value -s TYPE "$loop_device"`
2. If TYPE="iso9660", mount whole disk instead of partitions
3. Fall back to partition mounting if whole-disk mount fails
4. Also try whole-disk mount for other hybrid formats (UDF/ISO9660 bridge)

**Detection logic:**
```bash
# After partition detection, before trying partition mounts
if [[ "$has_partitions" == "true" ]]; then
  # Check partition table type
  pttype=$(blkid -o value -s PTTYPE "$loop_device" 2>/dev/null || echo "")

  # Check for whole-disk filesystem
  fs_type=$(blkid -o value -s TYPE "$loop_device" 2>/dev/null || echo "")

  # For APM disks with whole-disk ISO9660/UDF, prefer whole-disk mount
  if [[ "$pttype" == "mac" ]] && [[ "$fs_type" =~ ^(iso9660|udf)$ ]]; then
    echo "  Hybrid APM/$fs_type disc detected - mounting whole disk" >&2
    # Try whole-disk mount
    if mount -t "$fs_type" -o ro,noatime,nodev,nosuid "$loop_device" "$mount_point"; then
      echo "Mounted $loop_device as $fs_type (APM hybrid)" >&2
      exit 0
    fi
    # Fall through to partition mounting if whole-disk fails
  fi

  # ... continue with existing partition mount logic
fi
```

---

## Benefits

1. **Enables processing of Mac hybrid discs** - currently all APM hybrid ISOs fail to mount
2. **Cross-platform compatibility** - ISO9660 layer is designed for Windows/Linux access
3. **Matches historical Mac disc burning practice** - DiscRecording created many such discs
4. **Simple detection** - `PTTYPE="mac"` + `TYPE="iso9660"` is reliable signature

---

## Alternative: HFS+ Partition Mounting

Could also mount the HFS+ partition (p2) instead of whole-disk ISO. However:
- **Cons:** HFS+ mounting in Linux requires kernel support (hfsplus module)
- **Cons:** HFS+ may have Mac-specific resource forks not in ISO layer
- **Pros:** ISO9660 is more universally supported and was intended for cross-platform access

**Recommendation:** Prefer ISO9660 whole-disk mount for APM hybrids.

---

## Testing Plan

1. Implement APM hybrid detection in mount-helper
2. Test on 3 affected media (9bfbfb9e, d43eb00e, 647bf9a8)
3. Verify whole-disk ISO9660 mounts successfully
4. Verify ntt-enum can enumerate files
5. Run full pipeline on one medium to confirm processing works

---

## Priority Justification

**Medium priority:**
- Affects at least 3 media (possibly more unprocessed)
- These are readable optical discs (not corrupt data)
- Fix is straightforward and low-risk
- Workaround exists (manual mount), but automation is blocked

**Not high priority because:**
- Doesn't affect majority of media types
- Media is not in danger of data loss
- Can be deferred without critical impact

---

## Implementation Notes

**Implemented by:** dev-claude
**Date:** 2025-10-17 17:10

**Changes made:**

Modified `bin/ntt-mount-helper` lines 227-247 to detect and handle APM hybrid discs:

1. After detecting multi-partition disk, check partition table type: `PTTYPE`
2. Check for whole-disk filesystem type: `TYPE`
3. If `PTTYPE="mac"` AND `TYPE` matches `iso9660` or `udf`:
   - Log "APM hybrid" detection
   - Attempt whole-disk mount with appropriate mount options
   - Return success with `"hybrid":"apm"` in JSON output
   - Fall through to partition mounting if whole-disk mount fails

**Benefits:**
- Enables mounting of Mac hybrid optical discs (DiscRecording format)
- Preserves fallback to partition mounting if needed
- Adds `hybrid` field to JSON output for orchestrator visibility

**Ready for testing:** 2025-10-17 17:10

**Test on:** 9bfbfb9e, d43eb00e, 647bf9a8
