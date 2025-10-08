<!--
Author: PB and Claude
Date: 2025-10-08
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/disk-read-checklist.md
-->

# Disk Read Diagnostic Checklist

This is a living document of diagnostic techniques, error patterns, and workarounds discovered while processing disk images through the NTT pipeline.

## 1. Initial Assessment

**Before mounting, always check:**

```bash
# Check ddrescue mapfile for bad sectors
cat /data/fast/img/${HASH}.map
# Look for:
# - Lines with status '-' = bad sectors
# - Position of bad sectors (offset 0x00000000 = boot sector critical)
# - Total readable vs unreadable

# Check first bytes with hexdump
sudo hexdump -C /data/fast/img/${HASH}.img | head -30
# Look for:
# - 0xf6 repeated = erased/unformatted disk (FAT erase marker)
# - All zeros = likely corrupted/blank
# - Boot sector signature at offset 0x1FE (0x55 0xAA for FAT)
```

**Common bad sector patterns:**
- **Boot sector corruption**: `0x00000000  0x00000200  -` means first 512 bytes bad → cannot mount
- **FAT table corruption**: Bad sectors at 0x00000200+ → may mount but have I/O errors
- **Clean read**: All `+` status, no `-` entries

---

## 2. Mount Attempt Diagnostics

```bash
# Try mounting with ntt-mount-helper
sudo /path/to/ntt-mount-helper mount ${HASH} /data/fast/img/${HASH}.img

# If mount fails, check dmesg immediately
sudo dmesg | tail -30
# Look for:
# - "Cannot read medium - unknown format" = boot sector bad
# - "FAT-fs: request beyond EOF" = FAT corruption
# - "wrong fs type" = filesystem detection issue
```

**Filesystem type detection:**
```bash
# Check what filesystem was detected
sudo file -s /data/fast/img/${HASH}.img

# Check loop device
sudo blkid /dev/loop38

# Manual mount attempts
sudo mount -t vfat -o ro /dev/loop38 /mnt/ntt/${HASH}
sudo mount -t ufs -o ro /dev/loop38 /mnt/ntt/${HASH}
```

---

## 3. Post-Mount Validation

```bash
# Try listing files
sudo ls -la /mnt/ntt/${HASH}/ | head -20

# Count files
sudo ls /mnt/ntt/${HASH}/ | wc -l
```

**Watch for:**
- **I/O errors during ls**: Mounted but filesystem metadata corrupted
- **Empty directory**: May be valid (empty floppy) or mount failed silently
- **Permission denied**: Check mount options and ownership

---

## 4. Enumeration Phase Issues

```bash
# Run enumeration
sudo ./ntt/bin/ntt-enum /mnt/ntt/${HASH} ${HASH} /tmp/${HASH_SHORT}.raw

# Check for duplicate paths (loader will fail on these)
sudo cat /tmp/${HASH_SHORT}.raw | tr '\034' '\n' | sort | uniq -d
```

**Duplicate path causes:**
- Hardlinks (same inode, multiple paths) - **expected and OK**
- Filesystem corruption showing same path multiple times - **problematic**

---

## 5. Copy Phase Error Patterns

**Watch copier output for:**
- **Infinite retry loops**: File being retried 100+ times with same error
- **FAT-fs errors in dmesg**: `dmesg | tail -100 | grep FAT`
- **I/O errors**: Check if specific files or entire disk

**Kill stuck copier:**
```bash
# Find copier process hammering filesystem
ps aux | grep ntt-copier

# Kill it
sudo kill -9 <PID>

# Check what loop device is active
mount | grep ntt

# Check dmesg for errors
sudo dmesg | tail -50 | grep -E '(FAT|I/O error|loop)'
```

**Mark problem files in database:**
```sql
UPDATE inode
SET copied = true, claimed_by = 'IO_ERROR_SKIP'
WHERE medium_hash = '${HASH}'
  AND ino IN (xxx, yyy, zzz);

UPDATE inode
SET copied = true, claimed_by = 'FAT_ERROR_SKIP'
WHERE medium_hash = '${HASH}'
  AND ino IN (aaa, bbb, ccc);
```

---

## 6. Problem Classification & Database Recording

**Add to medium.problems JSONB column:**

```sql
-- Boot sector corruption
UPDATE medium
SET problems = jsonb_build_object(
  'boot_sector_corruption', 1,
  'details', 'First 512 bytes (boot sector) are bad sectors, cannot mount filesystem'
)
WHERE medium_hash = '${HASH}';

-- Erased/unformatted disk
UPDATE medium
SET problems = jsonb_build_object(
  'erased_disk', 1,
  'details', 'Entire disk filled with 0xf6 bytes (FAT erase marker), disk was erased or never formatted'
)
WHERE medium_hash = '${HASH}';

-- I/O errors on mount
UPDATE medium
SET problems = jsonb_build_object(
  'io_error', 1,
  'details', 'Mounted as ${FS_TYPE} but I/O errors when listing files, filesystem corruption'
)
WHERE medium_hash = '${HASH}';

-- Duplicate paths
UPDATE medium
SET problems = jsonb_build_object(
  'duplicate_paths', <count>,
  'details', 'Enumeration found duplicate paths (file1, file2, ...), cannot load into database'
)
WHERE medium_hash = '${HASH}';

-- FAT corruption with file errors
UPDATE medium
SET problems = jsonb_build_object(
  'fat_errors', <count>,
  'io_errors', <count>,
  'error_files', jsonb_build_array(...)
)
WHERE medium_hash = '${HASH}';
```

---

## 7. Decision Tree

```
Start → Check mapfile
  ↓
Boot sector bad? → YES → Record boot_sector_corruption → Archive → Done
  ↓ NO
Hexdump shows 0xf6 fill? → YES → Record erased_disk → Archive → Done
  ↓ NO
Mount succeeds?
  ↓ NO → Record mount_failure + dmesg errors → Archive → Done
  ↓ YES
ls works?
  ↓ NO → Record io_error → Archive → Done
  ↓ YES
Enum succeeds?
  ↓ NO → Investigate duplicates → Record duplicate_paths → Archive → Done
  ↓ YES
Load succeeds?
  ↓ NO → Check partition conflicts → Debug
  ↓ YES
Copy succeeds?
  ↓ NO → Kill if stuck → Mark problem files → Record errors → Archive → Done
  ↓ YES
Mark complete → Archive → Done
```

---

## 8. Known Byte Patterns

- **0xf6 repeated**: FAT erase marker (erased or unformatted disk)
- **0x00 repeated**: Zeroed disk (corruption or intentional wipe)
- **Boot sector signature**: Bytes at offset 0x1FE should be `0x55 0xAA` for valid FAT
- **FAT12/16 boot sector**: Starts with jump instruction (0xEB or 0xE9)

---

## 9. Always Archive Everything

Even corrupted/unreadable disks should be archived:
```bash
cd /data/fast/img
sudo tar -I 'zstd -T0' -cvf /data/cold/img-read/${HASH}.tar.zst ${HASH}*
sudo rm ${HASH}*
```

**Rationale**: Preservation of disk image even if unreadable now - may have recovery techniques later.

---

## 10. Summary Statistics

Track completion in database:
```sql
-- Check overall status
SELECT
  COUNT(*) FILTER (WHERE copy_done IS NOT NULL) as completed,
  COUNT(*) FILTER (WHERE problems IS NOT NULL) as with_problems,
  COUNT(*) as total
FROM medium
WHERE image_path IS NOT NULL;

-- Problem breakdown
SELECT
  problems->>'boot_sector_corruption' IS NOT NULL as boot_sector,
  problems->>'erased_disk' IS NOT NULL as erased,
  problems->>'io_error' IS NOT NULL as io_error,
  problems->>'duplicate_paths' IS NOT NULL as duplicates,
  problems->>'fat_errors' IS NOT NULL as fat_errors,
  COUNT(*)
FROM medium
WHERE problems IS NOT NULL
GROUP BY 1,2,3,4,5;
```

---

## 11. Diagnostic Service (ntt-copier)

The copier now includes intelligent retry logic via `DiagnosticService`:

**Retry tracking:**
- In-memory counter per inode (resets on worker restart - acceptable)
- Diagnostic checkpoint at retry #10 for analysis
- Max retry limit: 50 (safety net)

**Diagnostic checks at checkpoint:**
- Exception message pattern matching (`detected_beyond_eof`, `detected_io_error`, `detected_missing_file`)
- dmesg scan for kernel errors (`dmesg:beyond_eof`, `dmesg:fat_error`, `dmesg:io_error`)
- Mount health verification (`mount_check:ok`, `mount_check:missing`, `mount_check:inaccessible`)

**What to look for in logs:**

```bash
# Diagnostic checkpoint triggered (retry #10)
🔍 DIAGNOSTIC CHECKPOINT ino=3455 retry=10 findings={'checks_performed': ['detected_beyond_eof', 'dmesg:beyond_eof', 'mount_check:ok'], ...}

# Max retries warning (Phase 2 will auto-skip here)
⚠️  MAX RETRIES REACHED ino=3455 retry=50 (WOULD SKIP IN FUTURE PHASE)
```

**Implementation phases:**
- **Phase 1 (current):** Detection only - logs findings, continues retrying
- **Phase 2 (next .img):** Auto-skip BEYOND_EOF errors at checkpoint
- **Phase 3 (future):** Auto-remount on mount issues
- **Phase 4 (future):** Record diagnostics in `medium.problems` JSONB

**Files:**
- `ntt/bin/ntt_copier_diagnostics.py` - DiagnosticService class
- `ntt/docs/copier-diagnostic-ideas.md` - Full vision and design rationale

---

## Maintenance Note

**This is a living document.** Add new diagnostic techniques, error patterns, and workarounds as they are discovered during disk processing operations.
