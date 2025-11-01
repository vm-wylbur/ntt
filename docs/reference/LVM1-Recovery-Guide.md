# LVM1 Data Recovery Guide

Guide for accessing and extracting data from LVM1 volumes (circa 2006) using a vintage Ubuntu VM.

## Background

LVM1 format support was removed from LVM2 in May 2018 (version 2.02.178). Modern Linux systems cannot read LVM1 metadata. The solution is to use a vintage Linux distribution from the LVM1 era (2004-2007) in a virtual machine.

## Prerequisites

- QEMU installed: `sudo apt install qemu-system-x86 qemu-utils`
- KVM access: `sudo usermod -aG kvm $USER` then `newgrp kvm`
- Ubuntu 6.06 LTS (Dapper Drake) Server ISO from http://old-releases.ubuntu.com/releases/6.06/
- Your LVM1 disk as an image file
- Sufficient disk space for extracted volumes

## Step 1: Prepare Workspace
```bash
mkdir -p ~/vms/dapper-lvm1
cd ~/vms/dapper-lvm1
```

## Step 2: Extract Kernel and Initrd from ISO
```bash
mkdir -p iso-mount
sudo mount -o loop ~/path/to/ubuntu-6.06.2-server-i386.iso iso-mount
cp iso-mount/install/vmlinuz .
cp iso-mount/install/initrd.gz .
sudo umount iso-mount
```

## Step 3: Create Virtual Disks
```bash
qemu-img create -f qcow2 dapper-vm.qcow2 10G
qemu-img create -f raw output-disk.img 50G
```

Adjust output disk size based on your LVM volumes (use `df -h` equivalent).

## Step 4: Install Ubuntu in VM
```bash
qemu-system-i386 \
  -m 1024 \
  -hda dapper-vm.qcow2 \
  -cdrom ~/path/to/ubuntu-6.06.2-server-i386.iso \
  -kernel vmlinuz \
  -initrd initrd.gz \
  -append "console=ttyS0,9600n8 -- debian-installer/locale=en_US console-setup/ask_detect=false" \
  -nographic \
  -serial mon:stdio \
  -accel kvm
```

During installation:
- Install to /dev/hda (the 10GB virtual disk)
- Basic server install is sufficient
- Set a simple password you'll remember

To exit QEMU: Press Ctrl-A then X

## Step 5: Boot VM with All Disks Attached
```bash
qemu-system-i386 \
  -m 1024 \
  -hda dapper-vm.qcow2 \
  -hdb /path/to/your/lvm1-disk.img \
  -hdc output-disk.img \
  -nographic \
  -serial mon:stdio \
  -accel kvm
```

## Step 6: Extract LVM Volumes (Inside VM)
```bash
sudo mkfs.ext3 /dev/hdc
sudo mkdir -p /mnt/output
sudo mount /dev/hdc /mnt/output
sudo vgchange -ay VGfast
for lv in home usrlocal chroot syslog qmail rafe imapd imapdvar apache apachevar apachewww chad-images; do
  echo "Starting $lv at $(date)..."
  sudo dd if=/dev/VGfast/$lv of=/mnt/output/${lv}.img bs=1M
  echo "Finished $lv at $(date)"
done
ls -lh /mnt/output/
sudo sync
sudo umount /mnt/output
sudo shutdown -h now
```

Replace VGfast and volume names with your actual volume group and logical volume names.

To find your volume names, use:
```bash
sudo vgscan
sudo lvdisplay
```

## Step 7: Mount and Access Extracted Data (On Host)
```bash
mkdir -p ~/vms/dapper-lvm1/output-mount
sudo mount -o loop output-disk.img output-mount
ls -lh output-mount/
```

Mount individual volume images:
```bash
mkdir -p volume-mount
sudo mount -o loop,ro output-mount/home.img volume-mount
ls -la volume-mount/
```

Use `ro` (read-only) flag for safety when examining recovered data.

## Troubleshooting

### KVM Permission Denied
```bash
sudo usermod -aG kvm $USER
newgrp kvm
```

### Block Node is Read-Only
Check file permissions:
```bash
ls -l dapper-vm.qcow2 output-disk.img
chmod 644 dapper-vm.qcow2 output-disk.img
```

### Can't Find Volume Group
Inside VM, check what's detected:
```bash
sudo pvscan
sudo pvdisplay
sudo vgscan
sudo vgdisplay
```

## Notes

- The `-snapshot` flag protects disks but prevents saving changes. Don't use it when writing to output disk.
- Old Ubuntu 6.06 uses LVM version that natively supports LVM1 format
- dd is slow; large volumes (10GB+) may take several minutes
- Always work with copies of archival disks, never originals
- Extract to read-only mounted output to prevent accidental writes

## Cleanup

After extraction, you can delete:
- dapper-vm.qcow2 (the Ubuntu VM)
- vmlinuz and initrd.gz
- Keep output-disk.img (contains your extracted volumes)

## Alternative Distributions

If Ubuntu 6.06 doesn't work, try:
- Debian Etch (4.0) - released April 2007
- Debian Sarge (3.1) - released June 2005
- CentOS 4.x / RHEL 4 - circa 2005-2006

---

Date: October 2025
LVM1 Format: Deprecated ~2004, support removed 2018
