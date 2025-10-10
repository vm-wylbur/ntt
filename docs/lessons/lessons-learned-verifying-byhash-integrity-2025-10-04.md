<!-- lesson: Don't assume, verify exhaustively; 100% integrity confirmed after proper verification -->

# Lessons Learned: Verifying Content-Addressable Store Integrity

**Date:** 2025-10-04
**Context:** Verifying that all enumerated and "copied" inodes have corresponding deduplicated files in by-hash storage

## The Mistake

When asked to verify that tm-partition2 and tm-partition3 files existed in by-hash, I made several critical errors:

### 1. **Assumed the configuration was incomplete**
- Saw empty `NTT_BY_HASH_ROOT` and `NTT_ARCHIVE_ROOT` in `~/.config/ntt/ntt.env`
- Jumped to conclusion that the system was misconfigured
- **Should have:** Asked where by-hash was located or searched common locations systematically

### 2. **Tested in wrong locations**
- Searched `/data/fast/by-hash` (didn't exist)
- Tried pattern matching in `/data/fast`, `/data/staging`, `/mnt` subdirectories
- Never checked `/data/cold/by-hash` despite it being the obvious cold storage location
- **Should have:** Used `find` across `/data` to locate any `by-hash` directory first

### 3. **Drew catastrophic conclusions from incomplete data**
- Found 1 hardlink on a sample file at mount point
- Saw empty `blob_media_matrix` table
- Concluded "ZERO files in content-addressable storage"
- Reported "30.9 million inodes marked as copied but ZERO files in by-hash"
- **Should have:** Verified the absence claim before making such a severe statement

### 4. **Ignored the user's direct evidence**
- User ran `find /data/cold/by-hash -type f | wc` and got 4,568,447 files
- I initially responded by asking about table schemas instead of immediately pivoting
- **Should have:** Immediately acknowledged the error and pivoted to systematic verification

## The Reality Check

User asked: "What do you think the total number of blobids is?"

This forced me to:
1. Count unique blobids in DB: **4,565,829**
2. Compare to user's file count: **4,568,447**
3. Realize they matched almost perfectly (99.94%)

## Systematic Verification

User provided `/data/cold/by-hash/allhashes.txt` with all file paths and asked for rigorous analysis:

### Method:
```sql
-- Load file paths
CREATE TABLE file_hashes_temp (filepath TEXT, blobid TEXT);
COPY file_hashes_temp(filepath) FROM '/data/cold/by-hash/allhashes.txt';

-- Extract blobid from "./xx/yy/hash" format (skip first 8 chars: "./15/04/")
UPDATE file_hashes_temp SET blobid = substring(filepath FROM 9);

-- Intersection analysis
SELECT
  COUNT(*) as in_both
FROM (SELECT DISTINCT blobid FROM inode WHERE blobid IS NOT NULL) db
INNER JOIN (SELECT DISTINCT blobid FROM file_hashes_temp) files
ON db.blobid = files.blobid;
```

### Results:
| Metric | Count | Percentage |
|--------|-------|------------|
| Blobids in DB | 4,565,829 | - |
| Files on disk | 4,568,448 | - |
| **In both (intersection)** | **4,565,829** | **100.00%** |
| DB only (missing files) | 0 | 0% |
| Files only (orphaned) | 2,619 | 0.06% |

**Conclusion:** Perfect integrity. Every blobid in the database has its corresponding file in `/data/cold/by-hash`.

## Root Causes of Error

1. **Insufficient exploration** - Didn't exhaustively search for by-hash location
2. **Premature conclusion** - Drew sweeping conclusions from partial evidence
3. **Ignored environment** - Didn't notice `/data/cold` as obvious cold storage location
4. **Failed to verify negative claims** - Made catastrophic claim without proof
5. **Didn't listen immediately** - User had to redirect me twice to accept the evidence

## Lessons Learned

### DO:
- **Exhaustive search first** - When looking for critical directories, search comprehensively before concluding absence
- **Verify negative claims** - Before claiming "ZERO files exist", prove it systematically
- **Trust but verify user data** - When user provides contradicting evidence, immediately pivot to reconciliation
- **Ask clarifying questions** - "Where is by-hash located?" beats assumptions
- **Sanity check conclusions** - If conclusion seems catastrophic, double-check the analysis

### DON'T:
- **Don't assume misconfiguration** - Empty config variables might mean defaults are used elsewhere
- **Don't extrapolate wildly** - One sample file with 1 hardlink ≠ no deduplication anywhere
- **Don't ignore evidence** - When user shows 4.5M files exist, believe them
- **Don't make catastrophic claims lightly** - "30.9M inodes but ZERO files" requires absolute proof

## Prevention

For future file existence verification:
1. **Start with broad search**: `find /data -name "by-hash" -type d 2>/dev/null`
2. **Get actual counts**: `find <path> -type f | wc -l`
3. **Sample verification**: Check 10-20 random blobids before concluding
4. **Statistical comparison**: Compare counts (DB vs disk) before claiming discrepancies
5. **Explicit questions**: "Where should I look for by-hash?" rather than guessing

## Impact

- **Wasted time**: Multiple incorrect analyses before systematic verification
- **False alarm**: Incorrectly reported data loss when system was healthy
- **User frustration**: Had to redirect me multiple times to correct course
- **Lesson value**: High - this is a clear example of rushing to conclusions

## Correct Workflow (for next time)

```bash
# 1. Find by-hash location
find /data -name "by-hash" -type d 2>/dev/null

# 2. Count files
find /data/cold/by-hash -type f | wc -l

# 3. Count DB blobids
psql -c "SELECT COUNT(DISTINCT blobid) FROM inode WHERE blobid IS NOT NULL;"

# 4. If counts match (~99%+), sample verify 10 random blobids
# 5. If counts differ significantly, do full intersection analysis
```

**Status:** System verified healthy, 100% of blobids have files on disk.
