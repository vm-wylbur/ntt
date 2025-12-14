<!--
Author: PB and Claude
Date: 2025-11-22
License: (c) HRDAG, 2025, GPL-2 or newer

---
ntt/docs/lessons/dd4918-graid-recovery-analysis-2025-11-22.md
-->

# DD4918 GRAID Recovery Analysis - Progress Report

## Executive Summary

**Medium**: dd4918 (GRAID 5-disk configuration, failed during imaging)
**Status**: Chunk-based similarity analysis complete for 35,333 file pairs
**Next Step**: Analyze remaining 314,949 unmatched blobs (46.7% of total)

### Recovery Status Overview

| Category | Blob Count | % of Total | Status |
|----------|------------|------------|--------|
| Binary-identical (perfect recovery) | 331,877 | 49.2% | ✓ Recovered |
| Found via similarity (corrupted) | 27,081 | 4.0% | ⚠ Partially recovered |
| False positives (not real matches) | 1,045 | 0.2% | ✗ Not recoverable |
| **Not yet analyzed** | **314,949** | **46.7%** | 🔍 **Needs analysis** |
| **Total unique blobs** | **674,952** | **100%** | |

## Background

**Original Device**: G-Technology G-RAID Thunderbolt 2 enclosure (Kit PN: 0G04093)
- **Configuration**: 2×6TB drives, marketed as RAID 1 but actually proprietary striping
- **Data**: 6TB of critical HRDAG data on HFS+ filesystem
- **Failure**: Enclosure/controller died September 2025, drives physically intact
- **DIY Recovery**: Impossible - proprietary hardware controller metadata required

**Professional Recovery** (SecureDataRecovery.com, October 2025):
- **Cost**: $2,350 (quoted $400-800 initially, 2.9x-5.9x overrun)
- **Recovery Method**: Likely file-carving (PhotoRec-style) despite having specialized G-RAID hardware
- **Metadata Loss**: All filenames, directory structure, timestamps destroyed (suspicious given HFS+ redundancy)
- **Delivery Issues**: Corrupted HFS+ filesystem on delivery drive, required weekend of additional recovery work with DiskWarrior
- **Actual Recovery Rate**: ~50% of files recovered cleanly (discovered weeks after delivery, 22 Nov 2025)

**Database Label**: Medium appears as `floppy_20251025_144803_dd4918ed` (mislabeled)

**Current Analysis Goal**: Determine recovery status of carved files by comparing with other media:
1. **Binary-identical files**: Already exist elsewhere (perfect recovery)
2. **Similar files**: Exist elsewhere but dd4918 version is corrupted
3. **Unique files**: Only exist on dd4918, need chunk-based similarity matching

**Reference Documentation**: See `~/docs/securedatarecovery-experience.md` and `~/docs/securedatarecovery-detailed-timeline.md` for complete story of the recovery process and issues encountered.

## Detailed Findings

### 1. File Inventory (within dd4918)

```
Total file paths:     2,338,330
Unique blobs:           674,952
Duplicate paths:      1,663,378 (71.1%)
```

**Note**: 71% of file paths are duplicates (same content at multiple paths within dd4918). This is expected for carved filesystems.

### 2. Binary-Identical Matches

```
Total unique blobs:              674,952 (100%)
Binary-identical on other media: 331,877 (49.2%)
Not found elsewhere:             343,075 (50.8%)
```

**Interpretation**: Nearly half the files (49.2%) have perfect binary-identical matches on other media. These are fully recovered.

### 3. Chunk-Based Similarity Analysis

Of the 343,075 blobs not found elsewhere, we performed chunk-based similarity matching and found **35,333 candidate pairs** (blobs that share content chunks with files on other media).

#### Corruption Analysis Results

| Match Type | Pair Count | % | Unusable | Description |
|------------|------------|---|----------|-------------|
| False positives | 4,578 | 13.0% | Yes | Size mismatch indicates chunk overlap artifacts |
| Truncated | 8,859 | 25.1% | No | DD file shorter, overlapping bytes match (USABLE) |
| Extra padding | 14,896 | 42.2% | No | DD file has extra bytes, overlapping bytes match (USABLE) |
| Byte corruption | 7,000 | 19.8% | Yes | Actual corruption throughout file (UNUSABLE) |

#### Usability Summary

| Category | File Count | % of Analyzed |
|----------|------------|---------------|
| USABLE (truncated/padded) | 23,755 | 67.2% |
| UNUSABLE (corrupted/wrong) | 11,578 | 32.8% |

**Key Finding**: Of the 35,333 pairs analyzed, **23,755 (67.2%)** are usable despite corruption. The corruption is mostly truncation or extra padding, which can be handled by using the uncorrupted version from other media.

### 4. Current State Summary

| Status | Blob Count | % of Total | Action Required |
|--------|------------|------------|-----------------|
| Binary-identical (recovered) | 331,877 | 49.2% | ✓ Use version from other media |
| Found via similarity (corrupted) | 27,081 | 4.0% | ⚠ Use uncorrupted version from other media |
| False positives (not real matches) | 1,045 | 0.2% | ✗ Cannot recover |
| **Not yet analyzed** | **314,949** | **46.7%** | 🔍 **Perform chunk matching** |

**Math check**:
- Binary-identical: 331,877 (49.2%)
- Of remaining 343,075 unique blobs:
  - Analyzed: 28,126 (27,081 + 1,045) ≈ 8.2% of unique blobs
  - Not analyzed: 314,949 ≈ 91.8% of unique blobs

## Technical Implementation

### Database Schema

**Table**: `dd4918_corruption_analysis` (35,333 rows)

```sql
CREATE TABLE dd4918_corruption_analysis (
    dd_blobid text NOT NULL,              -- DD4918 carved file
    other_blobid text NOT NULL,           -- Matching file on other media
    status text NOT NULL,                 -- truncated|extra_padding|byte_corruption|wrong_match
    dd_size bigint NOT NULL,              -- DD file size
    other_size bigint NOT NULL,           -- Other file size
    diff_count bigint NOT NULL,           -- Number of differing bytes
    first_diff_byte bigint,               -- Position of first difference
    -- Extra bytes analysis (for extra_padding status)
    extra_bytes bigint,
    extra_all_zeros boolean,
    extra_pct_zeros numeric(5,2),
    extra_pct_printable numeric(5,2),
    extra_entropy numeric(5,3),
    unusable boolean NOT NULL,            -- Whether file is unusable
    PRIMARY KEY (dd_blobid, other_blobid)
);
```

### Analysis Tool

**Script**: `bin/analyze-carved-corruption-db.py`

Usage:
```bash
bin/analyze-carved-corruption-db.py /tmp/dd4918_pairs_clean.tsv [limit]
```

The script:
- Reads pairs of (dd4918_blobid, other_blobid) from TSV
- Runs `cmp -l` to get byte-level differences
- Classifies corruption type based on file sizes and diff patterns
- Writes results directly to PostgreSQL
- Supports resume by skipping already-analyzed pairs

Corruption classification logic (bin/analyze-carved-corruption-db.py:67-79):
```python
if diff_count == 0 and dd_size < other_size:
    status = 'truncated'              # DD shorter, overlapping bytes match
elif diff_count == 0 and dd_size > other_size:
    status = 'extra_padding'          # DD larger, overlapping bytes match
elif diff_count > 0 and dd_size < other_size * 0.05:
    status = 'wrong_match'            # DD tiny compared to other (false positive)
else:
    status = 'byte_corruption'        # Actual corruption throughout
```

## Step 1 Results: Chunking Status Verification

**Query Date**: 2025-11-22 (current session)

### DD4918 Unique Blobs Chunking Status

```
Total unique dd4918 blobs (no binary match elsewhere): 343,075
Blobs with chunks:                                     332,045 (96.8%)
Blobs without chunks:                                   11,030 (3.2%)
```

### Overall System Chunking Status

```
Total blobs in system:     9,462,088
Blobs chunked:             8,368,334 (88.4%)
Blobs not chunked:         1,093,754 (11.6%)
```

**Analysis**:
- 96.8% of dd4918 unique blobs are already chunked
- Only 11,030 blobs (3.2%) need chunking before we can proceed
- Overall system is 88.4% chunked

## Next Steps

### Immediate Actions

1. **Finish chunking dd4918 unique blobs** (11,030 remaining)
   - Background orchestrators from previous session may still be running
   - Check status: `ps aux | grep ntt-chunk-orchestrator`
   - Monitor progress via database query

2. **Generate chunk-based candidate pairs** for the 314,949 unanalyzed blobs
   - Use existing chunk matching queries (similar to how we found the 35,333 pairs)
   - Create new TSV of (dd4918_blobid, other_blobid) pairs

3. **Run corruption analysis** on new pairs
   ```bash
   bin/analyze-carved-corruption-db.py /tmp/dd4918_pairs_new.tsv
   ```

4. **Final recovery report** after all analysis complete

### Long-term Questions

1. **Verify chunking on other media**: Are all media adequately chunked for similarity matching?
2. **Storage optimization**: After identifying all recoverable files, archive dd4918 images?
3. **Lessons learned**: Document PhotoRec carving results vs. filesystem mounting for future GRAID recoveries

## Supporting Documentation

### Reports Generated

- `/tmp/dd4918_report_corrected.txt` - Current analysis report (comprehensive)
- `/tmp/dd4918_report_optimized.txt` - Optimized version with same data
- This document - Ongoing progress and next steps

### SQL Queries

**Find dd4918 unique blobs not yet in corruption analysis**:
```sql
WITH dd4918_unique AS (
    SELECT DISTINCT p1.blobid
    FROM paths p1
    WHERE p1.medium_hash LIKE 'dd4918%' AND p1.blobid IS NOT NULL
    AND NOT EXISTS (
        SELECT 1 FROM paths p2
        WHERE p2.blobid = p1.blobid
        AND p2.medium_hash NOT LIKE 'dd4918%'
    )
)
SELECT COUNT(*) as unanalyzed_count
FROM dd4918_unique
WHERE blobid NOT IN (
    SELECT DISTINCT dd_blobid FROM dd4918_corruption_analysis
);
-- Result: 314,949 blobs
```

**Check chunking status for dd4918 unique blobs**:
```sql
WITH dd4918_unique_blobs AS (
    SELECT blobid
    FROM (
        SELECT DISTINCT blobid
        FROM paths
        WHERE medium_hash LIKE 'dd4918%' AND blobid IS NOT NULL
    ) dd
    WHERE NOT EXISTS (
        SELECT 1
        FROM paths other
        WHERE other.blobid = dd.blobid
          AND other.medium_hash NOT LIKE 'dd4918%'
    )
)
SELECT
    COUNT(*) as total_unique_dd4918_blobs,
    COUNT(*) FILTER (WHERE EXISTS (
        SELECT 1 FROM file_chunks fc
        WHERE fc.blobid = dub.blobid
    )) as blobs_with_chunks,
    COUNT(*) FILTER (WHERE NOT EXISTS (
        SELECT 1 FROM file_chunks fc
        WHERE fc.blobid = dub.blobid
    )) as blobs_without_chunks,
    ROUND(100.0 * COUNT(*) FILTER (WHERE EXISTS (
        SELECT 1 FROM file_chunks fc WHERE fc.blobid = dub.blobid
    )) / COUNT(*), 1) as pct_chunked
FROM dd4918_unique_blobs dub;
-- Result: 343,075 total, 332,045 chunked (96.8%), 11,030 not chunked (3.2%)
```

## Related Files

- `bin/analyze-carved-corruption-db.py` - Main analysis script
- `bin/load-corruption-analysis.py` - JSONL to PostgreSQL loader (deprecated, now writes directly)
- `sql/create-corruption-analysis-table.sql` - Table schema
- `/tmp/dd4918_pairs_clean.tsv` - Input pairs for corruption analysis (35,333 pairs)

## Session Notes

**Background Processes**: Several `ntt-chunk-orchestrator` processes were inherited from a previous session. These are NOT from the current work session but may still be processing blobs in the background.

**Ongoing Document**: This file (`docs/lessons/dd4918-graid-recovery-analysis-2025-11-22.md`) is the ongoing document for DD4918 GRAID recovery work.
