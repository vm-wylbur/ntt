<!--
Author: PB and Claude
Date: 2025-11-20
License: (c) HRDAG, 2025, GPL-2 or newer

---
ntt/docs/bug-reports/null-blobid-copied-files-2025-11-20.md
-->

# Critical Bug: Null blobid for copied files

**Date Discovered**: 2025-11-20
**Date Updated**: 2025-11-21
**Severity**: CRITICAL - Data loss / integrity issue
**Status**: In remediation - 40 of 57 media recovered

## Executive Summary

**Initial discovery (2025-11-20):** 2,015,453 files across 57 media marked as `copied=true` but with `NULL blobid`, representing 483 GB of lost file references.

**Current status (2025-11-21):**
- ✅ **40 media re-processed successfully** - blobids restored
- 🔧 **5 media queued for re-processing** - archives available (11,840 files, ~4 GB)
- ⚠️ **12 media unrecoverable** - archives missing (1,649,388 files, ~355 GB)
  - 1.3M files in `mac-backups-2025` alone (79% of remaining loss)

**Remaining work:** Re-process 5 available images, investigate mac-backups-2025 recovery options.

## How the Bug Was Found

During investigation of blob uniqueness statistics for the top 100 media (to analyze deduplication rates), we noticed that 42M paths had null blobids. Initial assumption was these were non-files (directories, symlinks, etc.), but deeper investigation revealed:

1. Queried `paths` table statistics:
   - 233M total rows
   - 8M distinct blobids
   - **42M null blobids** (18%)

2. Broke down null blobids by `fs_type`:
   - 23.6M directories (`d`) - **EXPECTED** ✓
   - 1.8M symlinks (`l`) - **EXPECTED** ✓
   - 83K special files (block/char devices, sockets, pipes) - **EXPECTED** ✓
   - **2.2M regular files (`f`)** - **NOT EXPECTED** ❌
   - **14.6M with null fs_type** - **NEEDS INVESTIGATION** ⚠️

3. Checked status of null blobid regular files:
   - **14.8M with `copied=true`** - files marked as successfully copied
   - 99.6% are **non-empty** (size > 0)
   - These should have blobids but don't

4. Verified this affects 57 distinct media, mostly processed in October 2025

## Impact Assessment

### Summary Statistics

| Metric | Count |
|--------|-------|
| Affected media | 57 |
| Total lost file references | 2,015,453 |
| Lost non-empty files | 1,972,108 |
| Lost empty files | 43,345 |
| Total lost bytes | 518,994,625,143 (483 GB) |

### Top Affected Media

| medium_hash (8 chars) | medium_human | copy_done | lost_nonempty_files | lost_empty_files | total_lost_bytes |
|---|---|---|---|---|---|
| 36937238 | mac-backups-2025 | 2025-10-10 | 1,290,156 | 22,175 | 317 GB |
| 594d2e75 | ST3000DM001-1CH166_Z1F1N3R8 | 2025-10-13 | 237,284 | 8,064 | 33 GB |
| 97239906 | ST3300831A-3NF01XEE-dd | 2025-10-18 | 92,013 | 451 | 1.5 GB |
| 4b871132 | 4b871132e06f8337 | 2025-10-18 | 76,182 | 234 | 13 GB |
| 8e61cad2 | Hitachi_HUA723030ALA640_MK0331YHGE9U0A | 2025-10-13 | 55,531 | 75 | 56 GB |
| 60f3f319 | ST3400633AS_3PM0JA3Y | 2025-10-10 | 40,253 | 118 | 33 GB |
| 6bb11732 | 5cb0dafa977e17bf7e5f8f54a32690cd | (null) | 32,243 | 1 | 2.1 GB |
| 897c9f0b | vxa-tape2 | (null) | 28,295 | 264 | 7.7 GB |
| 3eef17c9 | vxa-tape4 | (null) | 26,185 | 48 | 6.7 GB |
| bb226d2a | sdc1-snowball-raid | 2025-10-10 | 25,321 | 7,488 | 1.7 GB |

(See full table in appendix below)

### Timeline of Affected Processing

| Date | Media Count | Lost Files |
|---|---|---|
| (no copy_done) | 14 | 111,626 |
| 2025-10-04 | 2 | 2 |
| 2025-10-08 | 3 | 9 |
| 2025-10-09 | 3 | 10,923 |
| **2025-10-10** | **15** | **1,386,840** |
| 2025-10-11 | 2 | 783 |
| 2025-10-12 | 3 | 20,719 |
| **2025-10-13** | **4** | **300,961** |
| **2025-10-18** | **4** | **173,121** |
| 2025-10-20 | 1 | 5 |
| 2025-10-21 | 3 | 3 |
| 2025-10-25 | 1 | 2,203 |
| 2025-10-26 | 1 | 8,238 |
| 2025-10-31 | 1 | 20 |

**Most affected dates**: Oct 10 (1.4M files), Oct 13 (301K files), Oct 18 (173K files)

## Root Cause Analysis

### Possible Causes

1. **Copier bug**: The copier set `copied=true` without setting `blobid`
   - Could be from old copier version (pre-November 2025 claim-analyze-execute pattern)
   - Could be race condition or error handling bug

2. **Migration bug**: Database migration from v1.5 (partitioned) to v2.0 (unpartitioned) lost blobids
   - Timing matches (migrations in Oct 2025)
   - But why would only some media be affected?

3. **Interrupted processing**: Copier was killed/crashed mid-processing
   - Set `copied=true` but transaction didn't commit blobid
   - But this should have rolled back the entire transaction

4. **Null fs_type issue**: 14.6M paths with null fs_type also have null blobid
   - These could be from enumeration bug where fs_type wasn't captured
   - Copier may have skipped files without fs_type

### Sample Affected Path

```
medium_hash: 4b871132e06f83375c42fd7f8e5cd437
medium_human: 4b871132e06f8337
copy_done: 2025-10-18 17:45:48
size: 2043 bytes (non-empty)
fs_type: f (regular file)
copied: true
blobid: NULL  ← PROBLEM
```

## SQL Queries Used

### Find affected media and file counts
```sql
SELECT
  m.medium_hash,
  m.medium_human,
  m.copy_done,
  COUNT(*) FILTER (WHERE p.fs_type = 'f' AND p.size > 0) as lost_nonempty_files,
  COUNT(*) FILTER (WHERE p.fs_type = 'f' AND p.size = 0) as lost_empty_files,
  COUNT(*) FILTER (WHERE p.fs_type = 'f') as total_lost_files,
  SUM(p.size) FILTER (WHERE p.fs_type = 'f') as total_lost_bytes
FROM paths p
JOIN medium m ON m.medium_hash = p.medium_hash
WHERE p.blobid IS NULL
  AND p.copied = true
  AND p.fs_type = 'f'
GROUP BY m.medium_hash, m.medium_human, m.copy_done
ORDER BY lost_nonempty_files DESC;
```

### Summary statistics
```sql
SELECT
  COUNT(DISTINCT medium_hash) as affected_media,
  COUNT(*) as total_lost_files,
  COUNT(*) FILTER (WHERE size > 0) as lost_nonempty_files,
  COUNT(*) FILTER (WHERE size = 0) as lost_empty_files,
  SUM(size) as total_lost_bytes,
  pg_size_pretty(SUM(size)) as total_lost_size
FROM paths
WHERE blobid IS NULL
  AND copied = true
  AND fs_type = 'f';
```

## Image Availability Check (2025-11-20)

Checked `/data/cold/img-read` for all 57 affected media:

**FOUND: 45 images** (371,071 files, ~126 GB recoverable)
**MISSING: 12 images** (1,644,382 files, ~357 GB unrecoverable without images)

### Missing Images Breakdown

| Hash (8 chars) | Name | Files Lost | Size Lost |
|---|---|---|---|
| **36937238** | **mac-backups-2025** | **1,312,331** | **318 GB** |
| 594d2e75 | ST3000DM001-1CH166_Z1F1N3R8 | 245,348 | 33 GB |
| 6bb11732 | 5cb0dafa977e17bf7e5f8f54a32690cd | 32,244 | 2.1 GB |
| bb226d2a | sdc1-snowball-raid | 32,809 | 1.7 GB |
| fb1bb1c0 | (unnamed) | 13,650 | 172 MB |
| b32efb96 | 4474de_p1_LVM1_extracted | 7,992 | 679 MB |
| 411aefac | 411aefacd137a818 | 5 | 3.8 GB |
| 1ca645ce | 1ca645cee4c6ff1e | 1 | 2.1 GB |
| 4c2d175a | 2b48bdc70b5ff5f994832b3ef3505fb9 | 1 | 1.2 MB |
| 35351b35 | 35351b3544e5a8c6 | 1 | 277 KB |
| c2676ab2 | (unnamed) | 1 | 3 KB |
| cd3b7aec | (unnamed) | 1 | 40 bytes |

**Key finding**: `mac-backups-2025` alone accounts for 1.3M files (65% of total lost). The other 11 missing images total only 332,053 files (40.75 GB).

**Note**: `mac-backups-2025` may have alternative recovery options to investigate.

## Remediation Steps

### Recovery Strategy

**Phase 1: Re-process 45 available images** (371K files, 126 GB recoverable)
- Images exist in `/data/cold/img-read`
- Reset `copied=false` for these media
- Re-run copier to get correct blobids
- See `/tmp/image-availability.txt` for full list

**Phase 2: Investigate mac-backups-2025 alternatives** (1.3M files, 318 GB)
- Check if backup source still exists
- Check if files exist in `/data/fast/by-hash` (can reconstruct blobids)
- Investigate whether this was a mounted filesystem that could be remounted

**Phase 3: Mark remaining 11 as lost** (332K files, 41 GB)
- Set `broken=true` and `exclude_reason='lost_image_and_blobid_20251120'`
- Document the loss
- Total unrecoverable: 332K files (if mac-backups-2025 is recovered separately)

### Prevention

1. **Add database constraint**
   ```sql
   ALTER TABLE paths ADD CONSTRAINT paths_copied_requires_blobid
   CHECK (copied = false OR blobid IS NOT NULL OR fs_type != 'f' OR fs_type IS NULL);
   ```

2. **Add monitoring**
   - Weekly check for null blobids with copied=true
   - Alert if count increases

3. **Verify copier version/code**
   - Which version of copier was running in Oct 2025?
   - Check git log for copier changes around that time
   - Look for bugs in blobid assignment logic

## Recovery Plan (2025-11-21)

### Status Update

**Re-processing progress:**
- ✅ 40 of 57 media successfully re-processed (70%)
- 17 media remaining with null blobids

### Phase 1: Re-process Available Images (IN PROGRESS)

**Media with archives in `/data/cold/img-read/` (5 total):**

| Hash (8) | Name | Files | Size | Status |
|----------|------|-------|------|--------|
| 4b871132 | 4b871132e06f8337 | 6,070 | 316 MB | Queued |
| 97239906 | ST3300831A-3NF01XEE-dd | 5,761 | 233 MB | Queued |
| bb98aeca | ZIP_250_003247DFAE95272D | 4 | 651 KB | Queued |
| af1349b9 | floppy_20251005_130331 | 3 | 655 KB | Queued |
| b74dff65 | floppy_20251005_191638 | 2 | 3.3 GB | Queued |

**Total recoverable:** 11,840 files (~4 GB)

**Recovery script:** `bin/reprocess-null-blobid-media.sh`
- Resets `copied=false` for null blobid files
- Extracts archives to temporary location
- Re-runs copier to regenerate blobids
- Verifies completion and cleans up

### Phase 2: Investigate mac-backups-2025 (DEFERRED)

**Issue:** Single medium with 1.3M files (296 GB) - 79% of remaining loss
- Archive missing from `/data/cold/img-read/`
- Needs investigation of alternative recovery options

### Phase 3: Mark Unrecoverable as Lost (PENDING)

**11 media with missing archives:**
- 336,057 files (~59 GB) - excluding mac-backups-2025
- Will be marked with `broken=true, exclude_reason='lost_image_and_blobid_20251121'`

## Next Steps

1. **Execute Phase 1 recovery script**
   ```bash
   cd ~/projects/ntt
   sudo bin/reprocess-null-blobid-media.sh
   ```

2. **Verify Phase 1 completion**
   ```sql
   SELECT COUNT(*) FROM paths
   WHERE blobid IS NULL AND copied = true AND fs_type = 'f';
   -- Should show ~1.64M (down from 1.66M)
   ```

3. **Investigate mac-backups-2025** (separate effort)
   - Check if source still exists
   - Check by-hash storage for orphaned files
   - Evaluate cost/benefit of recovery efforts

2. **Add database constraint**
   ```sql
   ALTER TABLE paths ADD CONSTRAINT paths_copied_requires_blobid
   CHECK (copied = false OR blobid IS NOT NULL OR fs_type != 'f' OR fs_type IS NULL);
   ```

3. **Document copier version history**
   - Identify when this bug was introduced
   - Verify it's fixed in current copier version

4. **Add monitoring**
   - Weekly check for null blobids with copied=true
   - Alert if count increases

## Appendix: Full Media List

See `/tmp/null-blobid-bug-report.txt` for complete table of all 57 affected media with detailed counts.

## Investigation Context

This bug was discovered during a request to analyze blob uniqueness across media. The investigation required:

1. Creating an index on `paths(blobid)` (which didn't exist)
2. Counting distinct blobids (found 8M out of 233M paths)
3. Noticing 42M null blobids seemed high
4. Breaking down by fs_type to separate expected nulls from unexpected
5. Finding 2M+ files with null blobid despite being marked copied

The bug has likely existed since October 2025 but went unnoticed because:
- Normal copier operations work medium-by-medium (don't need blobid index)
- No cross-medium analysis was done that required grouping by blobid
- The `copied=true` flag gave false confidence that files were processed

## Files Created During Investigation

- `/tmp/null-blobid-bug-report.txt` - Full table of affected media
- `/tmp/affected-medium-hashes.txt` - List of 57 affected medium hashes
- `/tmp/image-availability.txt` - Image availability check results (FOUND/MISSING)
- `docs/bug-reports/null-blobid-copied-files-2025-11-20.md` - This report
