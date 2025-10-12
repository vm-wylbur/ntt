<!--
Author: PB and Claude
Date: Thu 10 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/metrics/2025-10-10-529bfda4-lvm-recovery.md
-->

# LVM Recovery Investigation: 529bfda4 (A1_20250315)

**Purpose:** Document LVM activation process for p1 recovery
**Goal:** Inform ntt-mount-helper improvements for automatic LVM handling

---

## Discovery

Mount-helper output showed:
```json
{"num":1,"device":"/dev/loop84p1","mount":"","fstype":"LVM1_member","status":"failed"}
```

**fstype="LVM1_member"** indicates p1 is a physical volume in an LVM configuration, not a mountable filesystem.

---

## Current State

- p2 (ext3): 314,311 files enumerated ✓
- p3 (ext3): 2 files enumerated ✓
- **p1 (LVM): NOT ACCESSED - potential data loss**

---

## LVM Activation Steps

### Step 1: Scan for Volume Groups

```bash
$ sudo vgscan
(no output - no VGs found)

$ sudo pvscan
No matching physical volumes found
```

**Result:** Modern LVM2 tools don't detect the volume.

---

### Step 2: Check Physical Volume Details

```bash
$ sudo blkid /dev/loop84p1
/dev/loop84p1: UUID="QCDA5y-ZT9F-TJLC-cTG7-kzDT-445K-4TQXd4" TYPE="LVM1_member"

$ sudo file -s /dev/loop84p1
/dev/loop84p1: LVM1 (Linux Logical Volume Manager), version 1, System ID: hrvd1067914238
```

**Discovery:** This is **LVM1 format** (pre-2004), not LVM2.

---

### Step 3: Attempt LVM2 Tools

```bash
$ sudo pvdisplay /dev/loop84p1
Cannot use /dev/loop84p1: device has a signature

$ sudo pvck /dev/loop84p1
Cannot use /dev/loop84p1: device has a signature
```

**Problem:** LVM2 (version 2.03.31) refuses to work with LVM1 format.

---

## LVM1 Compatibility Issue

**Root cause:** LVM1 was deprecated in 2004. Modern LVM2 tools cannot read LVM1 metadata.

**System details:**
- LVM version: 2.03.31(2) (2025-02-27)
- Partition: `/dev/loop84p1`
- UUID: QCDA5y-ZT9F-TJLC-cTG7-kzDT-445K-4TQXd4
- System ID: hrvd1067914238

**Available tools:**
- No `lvm1` command in PATH
- No LVM1 packages in apt repositories
- Modern LVM2 explicitly refuses LVM1 devices

---

## Recovery Options

### Option 1: LVM1 Conversion Tools (if they exist)
- Search for historical LVM1 → LVM2 conversion tools
- May require old documentation from 2004-2006 era

### Option 2: Old Linux Environment
- Boot old Linux distribution (pre-2010) with LVM1 support
- Mount in VM or live CD with kernel 2.4/2.6 early versions
- Copy files out, then re-enumerate

### Option 3: Low-Level Recovery
- Hex dump LVM1 metadata structures
- Manually parse logical volume layout
- Direct block-level extraction

### Option 4: Document as Unrecoverable
- Mark in `medium.problems` as `lvm1_incompatible`
- Document data loss estimate
- Continue with p2+p3 data (already recovered)

---

## Questions for PB

1. **How critical is p1 data?** We recovered 314,313 files from p2+p3. Is p1 worth special effort?
2. **Do you have access to old Linux systems** (CentOS 4/5, Debian Etch, etc.) with LVM1 support?
3. **Should we document this pattern** for ntt-mount-helper to detect and warn about LVM1?
4. **Should we mark this in medium.problems** now, or wait for recovery attempt?

---

## Current Status

- ✓ p2: 314,311 files recovered
- ✓ p3: 2 files recovered
- ✗ p1: LVM1 format - modern tools incompatible
- **Total recovered: 314,313 files** (p1 data unknown)

---

## LVM1 Metadata Analysis

Successfully extracted metadata from p1:

```
Volume Group: VGfast
System ID: hrvd1067914238
UUID: QCDA5y-ZT9F-TJLC-cTG7-kzDT-445K-4TQXd4
Format: LVM1 (pre-2004)
```

**The metadata is readable!** This means recovery is technically possible.

---

## Practical Recovery Options

### Option 1: Old LVM via Chroot (Most Practical)

**Approach:** Use debootstrap to create Ubuntu 8.04 (Hardy) or 10.04 (Lucid) chroot

```bash
# Create chroot with old Ubuntu that has LVM1 support
sudo debootstrap --arch=amd64 hardy /tmp/hardy-chroot http://old-releases.ubuntu.com/ubuntu/

# Chroot and install lvm2 (old version with LVM1 support)
sudo chroot /tmp/hardy-chroot
apt-get install lvm2

# Access loop device from inside chroot
# Run vgchange -ay VGfast
# Mount logical volumes
# Copy files out
```

**Pros:**
- Official LVM tools
- Safe (isolated environment)
- Can be automated for future LVM1 disks

**Cons:**
- Requires download (~200MB)
- Setup time (15-30 minutes)

---

### Option 2: Extract Old LVM .deb Package

**Approach:** Download lvm2 .deb from Debian/Ubuntu archives (2006-2009 era)

```bash
# Download old lvm2 package with LVM1 support
wget http://snapshot.debian.org/archive/debian/20080301/pool/main/l/lvm2/lvm2_2.02.33-1_amd64.deb

# Extract to temp location
dpkg-deb -x lvm2_2.02.33-1_amd64.deb /tmp/old-lvm

# Run old lvm tools directly
LD_LIBRARY_PATH=/tmp/old-lvm/lib /tmp/old-lvm/sbin/lvm vgchange -ay VGfast
```

**Pros:**
- Faster than full chroot
- Minimal download

**Cons:**
- Library compatibility issues possible
- May need multiple old dependencies

---

### Option 3: Manual LVM1 Metadata Parsing

**Approach:** Parse LVM1 structures directly, calculate LV offsets

LVM1 metadata contains:
- Physical extents map
- Logical volume definitions
- Extent size and layout

Could write Python script to:
1. Read LVM1 metadata sectors
2. Parse VG/LV/PV structures
3. Calculate block offsets for each LV
4. Use dd to extract LV data
5. Mount extracted LVs

**Pros:**
- No old software needed
- Educational/reusable

**Cons:**
- Complex (LVM1 format not well documented)
- Error-prone
- Time-consuming to implement

---

### Option 4: Live CD / VM Approach

**Approach:** Boot old Linux in VM (QEMU) or physical boot

Options:
- SystemRescueCD 2008-2010 vintage
- CentOS 5 Live CD
- Ubuntu 8.04 Live CD

**Pros:**
- Known working environment
- All tools included

**Cons:**
- Requires VM setup (no qemu currently installed)
- Slower workflow

---

## Recommendation: Option 1 (Chroot)

**Best balance of safety, speed, and reliability.**

Steps:
1. Use debootstrap to create Ubuntu 8.04 chroot
2. Install lvm2 (version with LVM1 support)
3. Bind mount /dev into chroot
4. Run vgchange, mount LVs
5. Copy files to /data/fast/recovered-529b-p1/
6. Re-run ntt-enum on recovered files
7. Import into main dataset

**Estimated time:** 1-2 hours (including setup)

**Estimated data recovery:** Unknown, but p1 is largest partition (typically / or /home)

---

## Questions for PB

1. **Should we attempt Option 1 (chroot recovery)?** Is the potential p1 data worth 1-2 hours?
2. **Do you have any old Linux VMs already available?** That would save setup time.
3. **Priority:** Should I continue with the other 8 media first, or focus on this LVM1 recovery?
4. **For ntt-mount-helper:** Should we add LVM1 detection and automatic chroot setup?
