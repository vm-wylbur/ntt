<!--
Author: PB and Claude
Date: Sun 13 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/carved-ingestion-workflow.md
-->

# PhotoRec Carved Files Ingestion Workflow

**Purpose**: Ingest PhotoRec-carved files into NTT with synthetic metadata

**Status**: Draft - ready for testing after PhotoRec completes

## Overview

PhotoRec recovers files from damaged/corrupted disks but loses all filesystem metadata (paths, timestamps, inodes). This workflow creates synthetic metadata to allow carved files to flow through the normal NTT pipeline.

## Physical Organization

**Problem**: PhotoRec outputs `carved.1/`, `carved.2/`, ..., `carved.N/` directories at arbitrary locations. Next week we'll have 10M+ more carved files from different sources. We need paths that distinguish multiple carved sources.

**Solution**: Symlink-based path mapping

### This Week's Files (Movable - 10K files)

```bash
# 1. Organize under carved-sources/
mkdir -p /data/cold/carved-sources/sda-20251013
mv /data/cold/carved.* /data/cold/carved-sources/sda-20251013/

# 2. Create symlink for copier access
mkdir -p /mnt/ntt
ln -s /data/cold/carved-sources/sda-20251013 /mnt/ntt/carved-sda-20251013
```

**Result**:
- Physical path: `/data/cold/carved-sources/sda-20251013/carved.1/file`
- Database path: `carved-sda-20251013/carved.1/file`
- Copier resolves: `/mnt/ntt/carved-sda-20251013/carved.1/file` → physical location

### Future Files (Immovable - 10M+ files)

```bash
# Create symlink to immovable PhotoRec output
mkdir -p /mnt/ntt
ln -s /immovable/photorec/output /mnt/ntt/carved-hdd2-20251020
```

**Result**:
- Physical path: `/immovable/photorec/output/carved.1/file`
- Database path: `carved-hdd2-20251020/carved.1/file`
- Copier resolves: `/mnt/ntt/carved-hdd2-20251020/carved.1/file` → physical location

**Benefits**:
- Paths are self-documenting (can query without medium_hash context)
- Single symlink per source (not per carved.N subdirectory)
- Consistent copier interface: always `--src-root /mnt/ntt`
- Works for both movable and immovable sources

## Source Data

**Location**: `/data/cold/carved.{1..N}` directories

**Characteristics**:
- No original paths - PhotoRec generates synthetic filenames (f0000073.dovecot)
- No original timestamps - files have recovery timestamp
- No inode numbers - sequential recovery order
- No filesystem structure - flat directories organized by recovery session

**Example**: `/data/cold/carved.1/f0000073.dovecot`, `/data/cold/carved.21/f11966536.dovecot`

## Pipeline Stages

### 1. Synthetic Enumeration

**Script**: `bin/ntt-enum-carved`

**Synthetic metadata strategy**:
- `medium_hash`: Fixed synthetic value (e.g., "carved-sda-20251013")
- `dev`: PhotoRec directory number (1, 2, ..., 21)
- `ino`: Sequential per directory (1, 2, 3, ...)
- `nlink`: Always 1 (no hardlinks in carved files)
- `size`: Actual file size
- `mtime`: File's current mtime (recovery timestamp)
- `path`: **Includes source identifier** (e.g., "carved-sda-20251013/carved.1/f0000073.dovecot")

**Output format**: Standard .raw format (034-delimited, null-terminated)

**Example usage**:
```bash
# Wait for PhotoRec to complete
# Check final count
sudo find /data/cold/carved-sources/sda-20251013/carved.* -type f | wc -l

# Run enumeration
sudo bin/ntt-enum-carved \
  /data/cold/carved-sources/sda-20251013 \
  carved-sda-20251013 \
  /data/fast/raw/carved-sda.raw

# Verify output (paths include source identifier)
od -c /data/fast/raw/carved-sda.raw | head -20
```

### 2. Database Loading

**Script**: `bin/ntt-loader`

**Process**:
- Creates partition for synthetic medium_hash
- Loads .raw data into path/inode tables
- Applies exclusion patterns (if configured)
- Deduplicates by (medium_hash, ino)

**Example usage**:
```bash
# Create synthetic medium record first
sudo -u pball psql postgresql:///copyjob -c "
INSERT INTO medium (medium_hash, medium_human, added_at)
VALUES ('carved-sda-20251013', 'PhotoRec sda.img carved files (2025-10-13)', now())
ON CONFLICT DO NOTHING;
"

# Load enumeration data
sudo bin/ntt-loader /data/fast/raw/carved-sda.raw carved-sda-20251013
```

### 3. File Copying

**Script**: `bin/ntt-copier.py`

**Process**:
- Reads files via symlinks in `/mnt/ntt/`
- Computes BLAKE3 hashes
- Deduplicates to `/data/cold/by-hash/`
- Creates hardlinks for duplicate files
- Updates inode.copied status

**Example usage**:
```bash
# Single worker for small datasets
sudo python3 bin/ntt-copier.py --medium carved-sda-20251013 --src-root /mnt/ntt

# Multiple workers for larger datasets (next week's 10M files)
sudo python3 bin/ntt-copier.py --medium carved-hdd2-20251020 --src-root /mnt/ntt --workers 8
```

**Note**: Always use `--src-root /mnt/ntt` for carved files. The symlinks handle both movable and immovable source locations transparently.

## Testing

### Small Subset Test

Test on carved.1 only (first ~500 files):

```bash
# Create test directory with carved.1
mkdir -p /tmp/test-carved-sources/test-001
sudo cp -r /data/cold/carved-sources/sda-20251013/carved.1 /tmp/test-carved-sources/test-001/

# Create symlink
mkdir -p /mnt/ntt
ln -s /tmp/test-carved-sources/test-001 /mnt/ntt/test-carved-001

# Run enumeration (paths will include test-carved-001)
sudo bin/ntt-enum-carved \
  /tmp/test-carved-sources/test-001 \
  test-carved-001 \
  /tmp/test-carved.raw

# Verify format (should see test-carved-001/carved.1/filename)
od -c /tmp/test-carved.raw | head -20

# Load to database
sudo bin/ntt-loader /tmp/test-carved.raw test-carved-001

# Query results
sudo -u pball psql postgresql:///copyjob -c "
SELECT COUNT(*) as files, SUM(size) as total_bytes
FROM inode
WHERE medium_hash = 'test-carved-001' AND fs_type = 'f';
"

# Copy files (uses /mnt/ntt symlink)
sudo python3 bin/ntt-copier.py --medium test-carved-001 --src-root /mnt/ntt --workers 1

# Clean up test
sudo -u pball psql postgresql:///copyjob -c "
DROP TABLE IF EXISTS inode_p_testcarv CASCADE;
DROP TABLE IF EXISTS path_p_testcarv CASCADE;
DELETE FROM medium WHERE medium_hash = 'test-carved-001';
"
rm /mnt/ntt/test-carved-001
rm -rf /tmp/test-carved-sources /tmp/test-carved.raw
```

## Post-Ingestion

### Verify Deduplication

Check which carved files deduplicated with existing media:

```sql
-- Count unique blobs vs total files
SELECT
  COUNT(*) as total_files,
  COUNT(DISTINCT blobid) as unique_blobs,
  COUNT(*) - COUNT(DISTINCT blobid) as duplicates
FROM inode
WHERE medium_hash = 'carved-sda-20251013' AND fs_type = 'f';

-- Find which media share blobs with carved files
SELECT
  m.medium_hash,
  m.medium_human,
  COUNT(*) as shared_blobs
FROM inode i1
JOIN inode i2 ON i1.blobid = i2.blobid
JOIN medium m ON i2.medium_hash = m.medium_hash
WHERE i1.medium_hash = 'carved-sda-20251013'
  AND i2.medium_hash != 'carved-sda-20251013'
GROUP BY m.medium_hash, m.medium_human
ORDER BY shared_blobs DESC;
```

### Cleanup Source Directories

After successful ingestion and verification:

```bash
# Verify files are in by-hash storage
sudo -u pball psql postgresql:///copyjob -c "
SELECT
  COUNT(*) FILTER (WHERE copied = true) as copied,
  COUNT(*) FILTER (WHERE copied = false) as pending
FROM inode
WHERE medium_hash = 'carved-sda-20251013' AND fs_type = 'f';
"

# If all copied=true, safe to clean up
# Remove symlink
rm /mnt/ntt/carved-sda-20251013

# Delete source directories
sudo rm -rf /data/cold/carved-sources/sda-20251013

# Optionally remove raw file
rm /data/fast/raw/carved-sda.raw
```

## Source Disk Decision

**Source disk**: `/mnt/temp_sdc/sda.img` (2.7TB)

**Recovery stats** (as of 2025-10-13):
- Disk size: 2.7TB
- Files recovered: 10,248 files, 146MB
- Recovery rate: 0.005%
- File types: 98% dovecot cache fragments

**Recommendation**: Do not archive source disk
- Low recovery rate suggests disk was mostly empty/corrupted/encrypted
- Dovecot cache files are low-value (not actual mail messages)
- 2.7TB storage cost for 146MB of fragments is not justified
- Carved files will be preserved in by-hash storage

**Action**: Delete `/mnt/temp_sdc/sda.img` after successful ingestion

## Database Schema Integration

Carved files integrate normally with NTT schema:

- `medium` table: One row for synthetic medium
- `inode` table: Regular file inodes (via partition)
- `path` table: Synthetic paths (via partition)
- Deduplication: Normal blobid-based deduplication
- Queries: Standard SQL queries work

**Distinguishing carved files**:
- `medium_hash` pattern: "carved-*"
- `medium_human`: Includes "PhotoRec" and source disk info
- `path.path`: Starts with "carved-*/carved.{N}/" (e.g., "carved-sda-20251013/carved.1/")

## Troubleshooting

### Permission Issues

If enumeration fails with permission errors:

```bash
# Check directory ownership
ls -ld /data/cold/carved-sources/sda-20251013/carved.*

# Fix permissions if needed
sudo chmod -R 755 /data/cold/carved-sources/sda-20251013
sudo chown -R pball:pball /data/cold/carved-sources/sda-20251013
```

### Format Verification

Verify .raw format matches ntt-loader expectations:

```bash
# Check delimiter (should be \034 = octal 034)
od -c /data/fast/raw/carved-sda.raw | head -5

# Count records (null-terminated)
tr -cd '\0' < /data/fast/raw/carved-sda.raw | wc -c

# Verify paths include source identifier
grep -a "carved-sda" /data/fast/raw/carved-sda.raw | head -1
```

### Copier Source Path Issues

If copier can't find files, verify symlink and path construction:

```bash
# Check symlink exists and points to correct location
ls -l /mnt/ntt/carved-sda-20251013
readlink /mnt/ntt/carved-sda-20251013

# Copier constructs paths as: ${SRC_ROOT}/${DATABASE_PATH}
# Database path: carved-sda-20251013/carved.1/f0000073.dovecot
# Constructed: /mnt/ntt/carved-sda-20251013/carved.1/f0000073.dovecot
# Resolves to: /data/cold/carved-sources/sda-20251013/carved.1/f0000073.dovecot

# Test path construction
python3 -c "
import os
src_root = '/mnt/ntt'
medium = 'carved-sda-20251013'
dev = 1
filename = 'f0000073.dovecot'
# Database path includes medium identifier
db_path = f'{medium}/carved.{dev}/{filename}'
full_path = os.path.join(src_root, db_path)
print(f'Database path: {db_path}')
print(f'Constructed path: {full_path}')
print(f'Real path: {os.path.realpath(full_path)}')
print(f'Exists: {os.path.exists(full_path)}')
"
```

### Symlink Issues

If files aren't accessible through symlinks:

```bash
# Check symlink is valid
test -L /mnt/ntt/carved-sda-20251013 && echo "Symlink exists" || echo "Symlink missing"
test -d /mnt/ntt/carved-sda-20251013 && echo "Target accessible" || echo "Target missing/broken"

# Recreate symlink if needed
rm /mnt/ntt/carved-sda-20251013
ln -s /data/cold/carved-sources/sda-20251013 /mnt/ntt/carved-sda-20251013

# Test access through symlink
ls /mnt/ntt/carved-sda-20251013/carved.1/ | head -5
```

## References

- `bin/ntt-enum-carved` - Synthetic enumeration script
- `bin/ntt-enum` - Original enumeration (for comparison)
- `bin/ntt-loader` - Partition creation and data loading
- `bin/ntt-copier.py` - Hash-based deduplication and copying
- `docs/hash-format.md` - BLAKE3 hash specification
