# Extracting Data from LVM1 Volumes with ReiserFS

Guide for recovering data from LVM1 logical volumes containing ReiserFS filesystems using a vintage Ubuntu 6.06 VM.

## The Challenge

Modern Linux systems (kernel 6.6+) removed support for:
- **LVM1 format** (removed in LVM2 version 2.02.178, May 2018)
- **ReiserFS** (removed from kernel in version 6.6, October 2023)

Recovery requires using a vintage Linux distribution that supports both technologies natively.

## Prerequisites

- Completed LVM1 volume extraction (see LVM1-Recovery-Guide.md)
- Ubuntu 6.06 LTS (Dapper Drake) VM already set up
- Extracted LVM volume images in output-disk.img
- Sufficient disk space for tarballs (estimate ~50-70% of original volume size for compressed tarballs)

## Overview

The extraction happens in two stages:
1. Extract LVM1 logical volumes to raw image files (already completed)
2. Mount ReiserFS volumes in vintage VM and create tarballs

## Step 1: Identify ReiserFS Volumes

Before starting, identify which volumes use ReiserFS:

```bash
sudo mount -o loop output-disk.img output-mount
for img in output-mount/*.img; do
  echo "=== $img ==="
  sudo debugreiserfs $img 2>/dev/null | grep "Filesystem state" || echo "Not ReiserFS"
done
sudo umount output-mount
```

Or from inside the VM after mounting volumes, use:

```bash
file -s /mnt/output/*.img | grep -i reiser
```

## Step 2: Boot VM with Output Disk

```bash
cd ~/vms/dapper-lvm1
qemu-system-i386 \
  -m 1024 \
  -hda dapper-vm.qcow2 \
  -hdc output-disk.img \
  -nographic \
  -serial mon:stdio \
  -accel kvm
```

**Important:** Do NOT use `-snapshot` flag. You need writes to persist to output-disk.img.

## Step 3: Extract ReiserFS Data to Tarballs

Inside the VM, run as root:

```bash
sudo su
```

```bash
mount /dev/hdc /mnt/output
mkdir -p /root/tmp-mount
```

For each ReiserFS volume, create a tarball:

```bash
for vol in chad-images qmail rafe; do
  echo "Processing $vol..."
  mount -t reiserfs -o loop,ro /mnt/output/${vol}.img /root/tmp-mount
  cd /root/tmp-mount
  tar czf /mnt/output/${vol}-data.tar.gz .
  sync
  ls -lh /mnt/output/${vol}-data.tar.gz
  cd /root
  umount /root/tmp-mount
done
```

Verify tarballs exist:

```bash
ls -lh /mnt/output/*.tar.gz
```

Flush all writes:

```bash
sync
sync
sync
umount /mnt/output
shutdown -h now
```

## Step 4: Access Extracted Data on Host

Wait for VM to fully shut down, then unmount any stale mounts:

```bash
sudo umount ~/vms/dapper-lvm1/output-mount 2>/dev/null
```

Clear kernel caches to ensure fresh data:

```bash
sudo sync
echo 3 | sudo tee /proc/sys/vm/drop_caches
```

Mount the output disk:

```bash
sudo mount -o loop ~/vms/dapper-lvm1/output-disk.img ~/vms/dapper-lvm1/output-mount
ls -lh ~/vms/dapper-lvm1/output-mount/*.tar.gz
```

## Step 5: Extract Tarballs

```bash
mkdir -p ~/extracted-data
cd ~/extracted-data
```

Extract each tarball:

```bash
mkdir qmail-data
tar xzf ~/vms/dapper-lvm1/output-mount/qmail-data.tar.gz -C qmail-data/
```

```bash
mkdir rafe-data
tar xzf ~/vms/dapper-lvm1/output-mount/rafe-data.tar.gz -C rafe-data/
```

```bash
mkdir chad-images-data
tar xzf ~/vms/dapper-lvm1/output-mount/chad-images-data.tar.gz -C chad-images-data/
```

## Handling Non-ReiserFS Volumes

For ext2/ext3 volumes, mount directly on modern host:

```bash
mkdir -p ~/vms/dapper-lvm1/home-mount
sudo mount -o loop,ro ~/vms/dapper-lvm1/output-mount/home.img ~/vms/dapper-lvm1/home-mount
ls -la ~/vms/dapper-lvm1/home-mount/
```

Copy data as needed:

```bash
sudo rsync -av ~/vms/dapper-lvm1/home-mount/ ~/extracted-data/home-data/
```

Unmount when done:

```bash
sudo umount ~/vms/dapper-lvm1/home-mount
```

## Troubleshooting

### Tarballs Not Visible After VM Shutdown

**Symptom:** VM shows tarballs created, but they're not visible on host after remount.

**Cause:** Kernel page cache showing stale data.

**Solution:**

```bash
sudo umount ~/vms/dapper-lvm1/output-mount
sudo sync
echo 3 | sudo tee /proc/sys/vm/drop_caches
sudo mount -o loop ~/vms/dapper-lvm1/output-disk.img ~/vms/dapper-lvm1/output-mount
```

### Verify Tarballs Exist Without Mounting

Use debugfs to check filesystem contents directly:

```bash
sudo debugfs ~/vms/dapper-lvm1/output-disk.img
```

Inside debugfs:

```
ls
quit
```

This shows actual disk contents, bypassing any cache issues.

### Output Disk Won't Unmount (Device Busy)

Check what's holding it:

```bash
sudo lsof +D ~/vms/dapper-lvm1/output-mount
```

If you're in that directory:

```bash
cd ~
sudo umount ~/vms/dapper-lvm1/output-mount
```

Force unmount if needed:

```bash
sudo umount -l ~/vms/dapper-lvm1/output-mount
```

### Loop Devices Not Releasing

List all loop devices:

```bash
sudo losetup -a
```

Detach specific device:

```bash
sudo losetup -d /dev/loopX
```

Detach all unused loop devices:

```bash
sudo losetup -D
```

### Filesystem Corruption After Concurrent Access

If output disk was mounted on host while VM was writing:

```bash
sudo umount ~/vms/dapper-lvm1/output-mount
sudo fsck.ext3 ~/vms/dapper-lvm1/output-disk.img
```

Answer 'yes' to repair any errors found.

## Best Practices

1. **Never use `-snapshot` flag** when writing to output disk
2. **Always sync multiple times** before unmounting in VM
3. **Verify tarballs exist** with `ls -lh` before shutting down VM
4. **Clear kernel caches** after VM shutdown before remounting on host
5. **Work with copies** - never directly attach original archival disks
6. **Use read-only mounts** (`-o ro`) when examining recovered data

## Why Tarballs Instead of Direct Mount?

ReiserFS requires kernel support that modern systems lack. Options:

1. **Tarballs (recommended):** Universal format, portable, compresses well
2. **reiserfs-fuse:** Not available in modern repos, unmaintained
3. **VM access:** Slow, requires keeping vintage VM around
4. **Conversion tools:** Limited availability, risk of data loss

Tarballs provide the cleanest extraction path with maximum compatibility.

## File Integrity Verification

After extraction, verify tarball integrity:

```bash
tar tzf ~/vms/dapper-lvm1/output-mount/qmail-data.tar.gz > /dev/null
echo $?
```

Exit code 0 means tarball is valid.

Compare sizes for reasonableness:

```bash
ls -lh ~/vms/dapper-lvm1/output-mount/qmail.img
ls -lh ~/vms/dapper-lvm1/output-mount/qmail-data.tar.gz
```

Compressed tarballs typically 50-70% of original for text data, less for binary data.

## Cleanup

After successful extraction, you can:

1. Keep output-disk.img as a backup (contains both .img files and tarballs)
2. Delete individual .img files once tarballs are verified
3. Archive tarballs to long-term storage
4. Delete the Ubuntu VM (dapper-vm.qcow2) if no longer needed

```bash
tar czf lvm1-extracted-$(date +%Y%m%d).tar.gz -C ~/extracted-data .
```

## Summary

This process extracts data from obsolete storage formats (LVM1 + ReiserFS) using a vintage Linux VM:

1. Boot Ubuntu 6.06 VM with output disk attached
2. Mount ReiserFS volumes inside VM
3. Create compressed tarballs of all data
4. Transfer tarballs to host system
5. Extract data on modern system

The key insight: use tarballs as an intermediate format to bridge between incompatible filesystem technologies.

---

Created: October 2025  
Technologies: LVM1 (deprecated ~2004), ReiserFS (deprecated 2023)  
Recovery Method: Ubuntu 6.06 LTS (Dapper Drake) in QEMU VM
