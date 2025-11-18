<!--
Author: PB and Claude
Date: 2025-11-17
License: (c) HRDAG, 2025, GPL-2 or newer

---
ntt/docs/tape-processing-workflow.md
-->

# Tape Processing Workflow

Complete workflow for processing VXA tape dumps through the NTT pipeline.

## Directory Structure

```
/data/fast/tapes/vxa/
├── tapeN/                    # Original tape image + metadata
│   ├── tape_dump.img         # Raw tape image (e.g., 20GB)
│   ├── notes.md              # Documentation
│   └── metadata.json         # Hash + type + path metadata
│
├── for-ingestion/tapeN/      # Symlinks to selected dirs (selection guide)
│   ├── root -> ../tapeN/extracted/root
│   ├── rsync -> ../tapeN/extracted/rsync
│   └── home/...              # Nested symlinks to specific subdirs
│
└── ready-for-ntt/tapeN/      # Filtered extracted files (working directory)
    ├── root/                 # Real files (dereferenced)
    ├── rsync/                # Real files (dereferenced)
    └── home/...              # Only selected subdirs
```

## Overview

The tape processing workflow handles VXA tape dumps differently from physical disk images because:
1. Tape dumps contain full filesystem trees that need extraction
2. Not all data on tapes is ours (requires filtering)
3. Our tools are NOT symlink-friendly (require dereferencing)

The workflow uses `for-ingestion/tapeN/` as a selection guide with symlinks pointing to wanted directories, then creates real (dereferenced) copies in `ready-for-ntt/tapeN/` for processing.

## Processing Steps

### Step 1: Create metadata.json

Create metadata file in `tapeN/` directory:

```json
{
  "medium_hash": "<computed_blake3_hash>",
  "medium_human": "vxa-tapeN",
  "medium_type": "extracted",
  "image_path": "/data/fast/tapes/vxa/tapeN"
}
```

**Fields:**
- `medium_hash`: BLAKE3 hash computed from SIZE|MODEL|SERIAL| + first 1MB + last 1MB
  - See `docs/hash-format.md` for hash computation details
- `medium_human`: Human-readable identifier (e.g., "vxa-tape3")
- `medium_type`: "extracted" (not "physical" - this is extracted tape content)
- `image_path`: Path to tapeN/ directory containing original tape_dump.img

### Step 2: Extract and Filter Content

This is the critical step that differentiates tape processing from disk image processing.

#### 2a. Extract ALL content from tape

Mount or extract complete filesystem from `tape_dump.img` to temporary location:

```bash
# Example for tar-based tape dumps
mkdir -p /data/fast/tapes/vxa/tapeN/extracted
tar -xf /data/fast/tapes/vxa/tapeN/tape_dump.img \
  -C /data/fast/tapes/vxa/tapeN/extracted/
```

Result: Full tape filesystem in `tapeN/extracted/`

#### 2b. Identify wanted directories

The `for-ingestion/tapeN/` directory contains symlinks pointing to directories we want to process:

```bash
ls -la /data/fast/tapes/vxa/for-ingestion/vxa-tape3/
# lrwxrwxrwx root -> /data/fast/tapes/vxa/tape3/extracted/root
# lrwxrwxrwx rsync -> /data/fast/tapes/vxa/tape3/extracted/rsync
# drwxr-x--- home/
#   lrwxrwxrwx pball/pball -> ../../tape3/extracted/home/pball/pball
```

These symlinks define the selection - everything else is unwanted.

#### 2c. Copy symlink-referenced directories to ready-for-ntt

For each symlink in `for-ingestion/tapeN/`:
1. Follow the symlink to find the target directory
2. Copy the target directory (dereferencing symlinks → real files)
3. **FLATTEN nested directory structure** - copy directly to `ready-for-ntt/tapeN/`
4. Destination: `/data/fast/tapes/vxa/ready-for-ntt/tapeN/`

**CRITICAL:** Our tools (ntt-enum, ntt-copier) do NOT handle symlinks correctly. All symlinks must be dereferenced to real files.

**IMPORTANT:** Flatten the directory structure when copying. If for-ingestion has nested symlinks like `home/pball/project1`, copy the target directory directly to `ready-for-ntt/tapeN/project1/` (not `ready-for-ntt/tapeN/home/pball/project1/`).

```bash
# Example for tape4 with flattened structure
mkdir -p /data/fast/tapes/vxa/ready-for-ntt/vxa-tape4

# Find all symlinks in for-ingestion and copy their targets (dereferenced) with flattening
find /data/fast/tapes/vxa/for-ingestion/vxa-tape4/ -type l -print0 | \
while IFS= read -r -d '' symlink; do
  target=$(readlink -f "$symlink")
  dirname=$(basename "$target")
  cp -rL "$target" "/data/fast/tapes/vxa/ready-for-ntt/vxa-tape4/$dirname"
done
```

**Important:** Use `cp -rL` (or equivalent) to dereference symlinks.

#### 2d. Keep extracted directory (don't delete yet)

**DO NOT delete `tapeN/extracted/` yet.** Keep it until after successful archival.

The archiver (ntt-archiver) will automatically exclude the `extracted/` subdirectory when archiving.

**Result:** `ready-for-ntt/tapeN/` contains ONLY selected directories as real files (no symlinks, flattened structure), ready for enumeration.

### Step 3: Enumerate

Enumerate all files in the ready-for-ntt directory:

```bash
bin/ntt-enum /data/fast/tapes/vxa/ready-for-ntt/tapeN \
  <medium_hash> \
  /data/fast/raw/<medium_hash>.enum
```

**Output:** `.enum` file containing inode metadata for all files in selected directories.

### Step 4: Load Enumeration

Load enumeration data into database:

```bash
bin/ntt-loader /data/fast/raw/<medium_hash>.enum <medium_hash>
```

This inserts records into the `paths` table with `copied = false`.

**IMPORTANT:** ntt-loader automatically creates a `medium` record. If the medium already exists in the database, you may get duplicate records. Check for and delete duplicates:

```sql
-- Check for duplicates
SELECT medium_hash, medium_type, image_path
FROM medium
WHERE medium_hash = '<medium_hash>';

-- If duplicates exist, keep the correct record and delete others
DELETE FROM medium
WHERE medium_hash = '<medium_hash>'
  AND medium_type = 'physical';  -- Delete wrong type, keep 'extracted'
```

### Step 5: Copy Files (Deduplication)

Run 4 parallel copier workers to deduplicate files to by-hash storage:

```bash
# Terminal 1
sudo -E bin/ntt-copier.py --medium-hash <medium_hash> --batch-size 50

# Terminal 2
sudo -E bin/ntt-copier.py --medium-hash <medium_hash> --batch-size 50

# Terminal 3
sudo -E bin/ntt-copier.py --medium-hash <medium_hash> --batch-size 50

# Terminal 4
sudo -E bin/ntt-copier.py --medium-hash <medium_hash> --batch-size 50
```

**How it works:**
- Each worker claims batches from per-medium Redis queue
- Files are hashed and copied to `/data/fast/ntt/by-hash/`
- Deduplication: if blobid already exists, creates hardlink instead
- Database updated: `copied = true`, `blobid` recorded

**Monitor progress:**
```bash
# Watch worker logs
tail -f /var/log/ntt/copier.jsonl

# Check database status
psql -d copyjob -c "
  SELECT
    COUNT(*) FILTER (WHERE copied = true) as copied,
    COUNT(*) FILTER (WHERE copied = false) as pending,
    COUNT(*) as total
  FROM paths
  WHERE medium_hash = '<medium_hash>';
"
```

### Step 6: Verify Copy Completion

Before archiving, verify ALL files are copied:

```sql
SELECT
  COUNT(*) FILTER (WHERE copied = true) as copied,
  COUNT(*) FILTER (WHERE copied = false) as pending,
  COUNT(*) as total
FROM paths
WHERE medium_hash = '<medium_hash>';
```

**Expected:** `pending = 0` (all files copied)

If pending > 0:
- Check copier logs for errors: `/var/log/ntt/copier.jsonl`
- Investigate failed paths: `SELECT * FROM paths WHERE medium_hash = '<hash>' AND copied = false`
- Resolve issues and re-run copier

### Step 7: Archive Original Tape Image

Once all files are copied to by-hash storage, archive the original tape image:

```bash
sudo bin/ntt-archiver <medium_hash> --verbose
```

**What gets archived:**
- Source: `/data/fast/tapes/vxa/tapeN/` directory
  - `tape_dump.img` (original raw tape image)
  - `notes.md` (documentation)
  - `metadata.json` (hash metadata)
- Destination: `/data/cold/img-read/<medium_hash>.1.dar`

**How it works:**
1. Queries database for `medium_type` and `image_path`
2. For `medium_type='extracted'`, uses `image_path` from database
3. Verifies copy completion (unless `--force`)
4. Creates dar archive with zstd:3 compression
5. Verifies archive size > 0
6. **Removes source directory after successful archive**

**CRITICAL:** ntt-archiver archives the ORIGINAL tape image (tapeN/), NOT the ready-for-ntt working directory.

### Step 8: Cleanup Working Directory

After successful archival, remove the ready-for-ntt working directory:

```bash
rm -rf /data/fast/tapes/vxa/ready-for-ntt/tapeN/
```

This directory is no longer needed - all files are in by-hash storage and the original tape is archived.

## End State

After completing the workflow:

- ✅ **Files deduplicated**: `/data/fast/ntt/by-hash/` contains unique files
- ✅ **Original tape archived**: `/data/cold/img-read/<medium_hash>.1.dar`
- ✅ **Database tracking**: `paths` table records all file metadata with blobids
- ✅ **Source removed**: Original tape_dump.img archived and removed from fast storage
- ✅ **Working directory cleaned**: ready-for-ntt/tapeN/ removed

## Key Differences from Physical Disk Processing

| Aspect | Physical Disks | Tapes |
|--------|---------------|-------|
| **Source data** | Mounted disk image | Extracted tar/filesystem |
| **Filtering** | Process entire disk | Select specific directories via for-ingestion symlinks |
| **Symlinks** | Not an issue | MUST dereference (tools not symlink-friendly) |
| **Working directory** | Mount point (read-only) | ready-for-ntt (extracted, filtered, dereferenced) |
| **Archive source** | Disk image file (.raw) | Tape dump + metadata directory |
| **medium_type** | "physical" | "extracted" |

## Common Issues

### Issue: Copier processes symlinks incorrectly

**Symptom:** Enumeration shows 22 symlink-only paths instead of thousands of files

**Cause:** Used for-ingestion symlinks directly instead of dereferencing to ready-for-ntt

**Solution:** Always enumerate `ready-for-ntt/tapeN/`, not `for-ingestion/tapeN/`

### Issue: ntt-archiver archives wrong directory

**Symptom:** Archive contains ready-for-ntt working files, not original tape image

**Cause:** Incorrect `image_path` in database or metadata.json

**Solution:** Ensure `image_path` points to `tapeN/` (original), not `ready-for-ntt/tapeN/`

**Example from tape4:**
```sql
-- WRONG: image_path pointing to working directory
UPDATE medium SET image_path = '/data/fast/tapes/vxa/ready-for-ntt/vxa-tape4'
WHERE medium_hash = '3eef17c9...';

-- CORRECT: image_path pointing to original tape directory
UPDATE medium SET image_path = '/data/fast/tapes/vxa/tape4'
WHERE medium_hash = '3eef17c9...';
```

### Issue: Duplicate medium records from ntt-loader

**Symptom:** Copier fails with "No image_path in database" even though medium exists

**Cause:** ntt-loader created duplicate medium record with `medium_type='physical'` and `image_path=NULL`

**Solution:** Delete the duplicate physical record, keep the extracted record with correct image_path

```sql
-- Check for duplicates
SELECT medium_hash, medium_type, image_path FROM medium WHERE medium_hash = '<hash>';

-- Delete wrong record
DELETE FROM medium WHERE medium_hash = '<hash>' AND medium_type = 'physical';
```

### Issue: Copy incomplete but workers stopped

**Symptom:** Database shows `copied = false` for many paths, but workers exited

**Cause:** Workers encountered errors (permissions, disk space, bad files)

**Solution:** Check worker logs for error details, resolve, re-run copier

## Related Documentation

- `docs/hash-format.md` - BLAKE3 hash computation for medium_hash
- `docs/schema-evolution.md` - Database schema (v2.0 unpartitioned)
- `docs/lessons/tape3-processing-errors-2025-11-17.md` - Common mistakes and recovery
- `ROLES.md` - Multi-Claude workflow for tape processing

## Example: Complete Tape3 Processing

```bash
# Step 1: Create metadata.json in /data/fast/tapes/vxa/tape3/
cat > /data/fast/tapes/vxa/tape3/metadata.json <<EOF
{
  "medium_hash": "6e4be148069be013f725f3cb95ed11ecc89c0803eb64a1aa1cf5f5be1ef6a288",
  "medium_human": "vxa-tape3",
  "medium_type": "extracted",
  "image_path": "/data/fast/tapes/vxa/tape3"
}
EOF

# Step 2: Extract and filter (already done for tape3)
# ready-for-ntt/vxa-tape3/ contains dereferenced content

# Step 3: Enumerate
bin/ntt-enum /data/fast/tapes/vxa/ready-for-ntt/vxa-tape3/extracted \
  6e4be148069be013f725f3cb95ed11ecc89c0803eb64a1aa1cf5f5be1ef6a288 \
  /data/fast/raw/6e4be148069be013f725f3cb95ed11ecc89c0803eb64a1aa1cf5f5be1ef6a288.enum

# Step 4: Load
bin/ntt-loader \
  /data/fast/raw/6e4be148069be013f725f3cb95ed11ecc89c0803eb64a1aa1cf5f5be1ef6a288.enum \
  6e4be148069be013f725f3cb95ed11ecc89c0803eb64a1aa1cf5f5be1ef6a288

# Step 5: Copy (4 workers)
sudo -E bin/ntt-copier.py \
  --medium-hash 6e4be148069be013f725f3cb95ed11ecc89c0803eb64a1aa1cf5f5be1ef6a288 \
  --batch-size 50

# Step 6: Verify
psql -d copyjob -c "
  SELECT
    COUNT(*) FILTER (WHERE copied = true) as copied,
    COUNT(*) FILTER (WHERE copied = false) as pending
  FROM paths
  WHERE medium_hash = '6e4be148069be013f725f3cb95ed11ecc89c0803eb64a1aa1cf5f5be1ef6a288';
"

# Step 7: Archive
sudo bin/ntt-archiver 6e4be148069be013f725f3cb95ed11ecc89c0803eb64a1aa1cf5f5be1ef6a288 --verbose

# Step 8: Cleanup
rm -rf /data/fast/tapes/vxa/ready-for-ntt/vxa-tape3/
```
