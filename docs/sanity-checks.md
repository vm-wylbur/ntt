<!--
Author: PB and Claude
Date: Sat 05 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/sanity-checks.md
-->

# NTT Sanity Checks

Database integrity checks for the NTT deduplication system.

## 1. Blob ID Size Consistency

**Purpose:** Verify that each unique `blobid` (BLAKE3 hash) corresponds to exactly one file size.

**Rationale:** If the same hash maps to different sizes, it indicates either:
- Hash collision (extremely unlikely with BLAKE3)
- Hashing bugs
- Files modified after hashing
- Database corruption

**Query:**
```sql
SELECT
    blobid,
    COUNT(DISTINCT size) as distinct_sizes,
    COUNT(*) as inode_count
FROM inode
WHERE blobid IS NOT NULL
GROUP BY blobid
HAVING COUNT(DISTINCT size) > 1
ORDER BY inode_count DESC
LIMIT 20;
```

**Expected result:** 0 rows

**Last verified:** 2025-10-05 ✅ PASS (0 violations)

---
