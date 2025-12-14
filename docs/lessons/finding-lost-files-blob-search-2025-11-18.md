<!--
Author: PB and Claude
Date: 2025-11-18
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/lessons/finding-lost-files-blob-search-2025-11-18.md
-->

# Finding "Lost" Files Across Media - Investigation Guide

## The Problem

When processing damaged media (disk 4ec45e93 had 29 bad sectors), we encountered 4 unreadable files:
- Ku 990406-44.tif
- Ku 990406-45.tif
- Ku 990406-46.tif
- Ku 990406-47.tif

**Initial worry**: Are these files permanently lost?

## Investigation Strategy

### Step 1: Get the blob IDs from known-good copies

First, find ANY copy of the file you can read (from path_parts search, backup locations, etc):

```sql
SELECT
    convert_from(path, 'UTF8') as filename,
    blobid,
    size
FROM paths
WHERE medium_hash = '1d7c9dc81a26c871ccafc71ab284b4aa'  -- Known good medium
  AND (convert_from(path, 'UTF8') LIKE '%Ku-990406-44.tif'
   OR convert_from(path, 'UTF8') LIKE '%Ku-990406-45.tif'
   OR convert_from(path, 'UTF8') LIKE '%Ku-990406-46.tif'
   OR convert_from(path, 'UTF8') LIKE '%Ku-990406-47.tif')
ORDER BY filename;
```

Result: Found blob IDs for all 4 files from dump-2019 backup.

### Step 2: Count ALL instances of those blobs across entire database

```sql
WITH target_blobs AS (
  SELECT DISTINCT blobid, size
  FROM paths
  WHERE blobid IN (
    'e78265aca29a557f4db5a9612b7615cc07bb612ee8cd5607f91ede6d468239ad',
    'ccd7876d9ba1a8336b9bf94771fc4f3a0397a50ec2ac37e8ac9a7d074067c8fd',
    '1fe9958c7888538942c7f03dfac988a56e001758360890990580c04fede1a8f2',
    '832fc86202bc06693aa96aede1cb43d9d493f43f217f0fced28c1beb9df11f83'
  )
)
SELECT
  tb.blobid,
  tb.size,
  COUNT(*) as total_copies,
  COUNT(DISTINCT p.medium_hash) as distinct_media,
  array_agg(DISTINCT m.medium_human ORDER BY m.medium_human) as media_list
FROM target_blobs tb
JOIN paths p ON p.blobid = tb.blobid
JOIN medium m ON m.medium_hash = p.medium_hash
GROUP BY tb.blobid, tb.size
ORDER BY tb.blobid;
```

**Result**: ~580 copies of each file across 32 different media!

### Step 3: Check for filename variations

Files may appear with different naming conventions:

```sql
SELECT
  blobid,
  medium_hash,
  convert_from(path, 'UTF8') as path,
  size
FROM paths
WHERE blobid IN ('e78265aca...', ...)
AND convert_from(path, 'UTF8') NOT SIMILAR TO '%Ku.?990406-(44|45|46|47).tif'
LIMIT 50;
```

**Found variations**:
- `Ku-990406-47.tif` (dash)
- `Ku_990406-47.tif` (underscore)
- `Ku 990406-47.tif` (space)

### Step 4: Check carved/extracted media

Carved and extracted media often recover files with altered or generated names:

```sql
SELECT
  m.medium_human,
  m.medium_type,
  COUNT(*) as file_count
FROM paths p
JOIN medium m ON m.medium_hash = p.medium_hash
WHERE p.blobid IN (...)
AND m.medium_type IN ('carved', 'extracted')
GROUP BY m.medium_human, m.medium_type
ORDER BY m.medium_human;
```

**Result**: Files recovered from:
- 4 different bzip2 extracted archives
- vxa-tape6 (all 4 files)
- vxa-tape7 (16 instances)

## Key Lessons

### 1. Use blob IDs, not filenames
- Filenames vary across media (dashes, underscores, spaces)
- Paths vary (different directory structures)
- Blob ID is the ONLY reliable identifier for "same file"

### 2. Check everywhere
- Backup snapshots (multiple time points)
- Hard drives (various models/manufacturers)
- Tapes (VXA, LTO, etc.)
- Carved media (file carving from damaged filesystems)
- Extracted media (from archives, compressed files)

### 3. The path_parts index limitation
- Only populated for data that existed during migration
- New data being loaded won't have path_parts until next migration
- Fall back to blob ID search when path_parts is NULL

### 4. Bad sectors don't mean data loss
- Disk 4ec45e93 had 29 bad sectors, 4 files unreadable
- ALL 4 files existed in ~580 copies elsewhere
- Deduplication means we only need ONE good copy

### 5. Pattern for "is this file lost?"

```bash
# 1. Try to find ANY instance of the file (by name)
# 2. Get blob ID from that instance
# 3. Count all instances of that blob ID
# 4. Check carved/extracted media
# 5. Check for filename variations
```

## SQL Snippets for Future Use

### Quick blob lookup by filename pattern
```sql
SELECT DISTINCT blobid, size, COUNT(*) OVER (PARTITION BY blobid) as copies
FROM paths
WHERE convert_from(path, 'UTF8') LIKE '%filename%'
LIMIT 5;
```

### Find all media containing a specific blob
```sql
SELECT DISTINCT
  m.medium_human,
  m.medium_type,
  COUNT(*) as occurrences
FROM paths p
JOIN medium m ON m.medium_hash = p.medium_hash
WHERE p.blobid = 'blob-id-here'
GROUP BY m.medium_human, m.medium_type
ORDER BY occurrences DESC;
```

### Check if blob exists in by-hash storage
```sql
SELECT EXISTS(
  SELECT 1 FROM paths WHERE blobid = 'blob-id' AND copied = true
) as blob_saved;
```

## Case Study: Ku 990406 files

- **Problem**: 4 .tif files unreadable from ZIP disk (bad sectors)
- **Investigation time**: ~5 minutes
- **Result**: 580 copies across 32 media, including carved/extracted archives
- **Data loss**: 0 bytes (all files fully backed up)
- **Action**: Marked files as bad_sectors, archived remaining 704 files successfully

## Conclusion

In a well-backed-up archive with deduplication:
1. "Lost" files are rarely actually lost
2. Blob ID search finds files regardless of naming variations
3. Carved/extracted media provides additional redundancy
4. One good copy is all we need (deduplication ensures preservation)

When encountering unreadable files, DON'T PANIC - search by blob ID first!
