<!--
Author: PB and Claude
Date: 2025-11-21
License: (c) HRDAG, 2025, GPL-2 or newer

---
ntt/docs/carved-file-matching-plan.md
-->

# Carved File Matching Plan - GRAID Recovery Analysis

## Problem Statement

We have **343,075 carved files** from GRAID array recovery (medium dd4918edc8a2cefaf6c3d0560cfc30d2) that do NOT have exact byte-for-byte matches elsewhere in our 60M+ file archive. These files were extracted by SecureDataRecovery.com and have generic filenames like `06A885C8.ps-eps`.

**Goals:**
1. Identify which carved files are partial/corrupted versions of original files in the archive
2. Restore proper filenames and directory structures for recovered files
3. Assess file corruption/truncation patterns from the RAID failure
4. Identify truly unique recovered files not found elsewhere (even partially)

## Data Available

### Tables (102M rows)
- `file_chunks`: Maps blobid → chunk_hash with offset and size
  - Indexes: PK(blobid, chunk_offset), idx_chunk_hash(chunk_hash), idx_file_chunks_blobid(blobid)
  - FastCDC chunking: min=4KB, avg=16KB, max=64KB
  - Chunk hashes: BLAKE3 hex (64 characters)

- `blobs`: File metadata with blobid as primary key (content-addressed hash)

- `paths`: File paths and metadata, links to blobid
  - 60M+ files total across all media
  - 2.3M paths on dd4918 → 674,952 unique blobs
  - 331,877 dd4918 blobs have exact matches elsewhere (already solved)
  - **343,075 dd4918 blobs are unique (our target)**

### Materialized Views
- `duplicate_chunks` (8.1M rows): Chunks appearing in 2+ files across entire archive
  - Indexes: idx_dup_chunks_hash(chunk_hash), idx_dup_chunks_file_count(file_count)

- `cross_medium_chunks` (2.9M rows): Chunks appearing in BOTH dd4918 AND other media
  - Columns: chunk_hash, file_count, dd4918_files, other_media_files, dd4918_blobids[], other_blobids[]
  - Indexes: idx_cross_medium_hash(chunk_hash), idx_cross_medium_dd4918_count, idx_cross_medium_other_count
  - **These 2.9M shared chunks are the foundation for finding partial matches**
  - Creation time: 3h 44m (one-time cost, already complete)

## Why Not Simple Jaccard Similarity?

**Problem:** Jaccard = |A ∩ B| / |A ∪ B| fails for truncated files.

**Example:**
- Carved file C: 1MB = 64 chunks
- Original file O: 10MB = 640 chunks
- If C is a perfect prefix of O: |C ∩ O| = 64
- Jaccard(C, O) = 64 / (64 + 640 - 64) = 64/640 = **10%**

Despite being 100% contained, Jaccard scores it as only 10% similar!

## Recommended Approach: Containment-Based Similarity

### Core Metrics

**Containment (directional):**
- `containment_dd = shared_chunks / dd4918_total_chunks`
  - "What fraction of the carved file is accounted for in this other file?"
- `containment_other = shared_chunks / other_total_chunks`
  - "What fraction of the other file is present in the carved file?"
- `containment_max = shared_chunks / min(dd4918_total_chunks, other_total_chunks)`
  - Maximum containment in either direction

**For the truncated file example:**
- containment_dd = 64/64 = **100%** ✓
- containment_other = 64/640 = 10%
- containment_max = 64/64 = **100%** ✓

This correctly identifies it as a truncated copy!

**Match criteria:**
- `containment_dd >= 0.8` (80% of carved file chunks match)
- `shared_chunks >= 10` (minimum absolute overlap for robustness)
- Optional: `containment_other >= 0.1` (ignore tiny overlaps into huge files)

## Implementation Plan: Multi-Phase Pipeline

### Phase 0: Understand Data Distribution

**Histogram analysis** to find where combinatorial explosion happens:

```sql
SELECT
    cardinality(dd4918_blobids) as dd_count,
    cardinality(other_blobids) as other_count,
    cardinality(dd4918_blobids) * cardinality(other_blobids) as pairs,
    COUNT(*) as chunks,
    SUM(cardinality(dd4918_blobids) * cardinality(other_blobids)) OVER () as total_pairs
FROM cross_medium_chunks
GROUP BY 1, 2
ORDER BY pairs DESC
LIMIT 20;
```

**Purpose:** Identify high-frequency "stopword" chunks that appear in thousands of files.

**Expected finding:** 1% of chunks generate 99% of candidate pairs.

### Phase 1: Build Candidate Pairs (Aggressive Filtering)

**Create `candidate_pairs` table** with multiple filters to prevent explosion:

```sql
CREATE TABLE candidate_pairs AS
WITH dd4918_unique_blobs AS (
    -- Only the 343K blobs without exact matches
    SELECT DISTINCT blobid
    FROM paths
    WHERE medium_hash LIKE 'dd4918%'
      AND blobid IS NOT NULL
      AND blobid NOT IN (
          SELECT DISTINCT blobid FROM paths WHERE medium_hash NOT LIKE 'dd4918%'
      )
),
cm_filtered AS (
    -- Filter out high-frequency "stopword" chunks
    SELECT *
    FROM cross_medium_chunks
    WHERE file_count <= 5000                                    -- Global frequency cap
      AND cardinality(dd4918_blobids) <= 10                     -- Per-chunk dd4918 cap
      AND cardinality(other_blobids) <= 10                      -- Per-chunk other cap
      AND cardinality(dd4918_blobids) * cardinality(other_blobids) < 100  -- Pair explosion cap
)
SELECT
    dd_blob,
    other_blob,
    COUNT(*) AS shared_chunks
FROM cm_filtered cm,
     unnest(cm.dd4918_blobids) AS dd_blob,
     unnest(cm.other_blobids) AS other_blob
WHERE dd_blob IN (SELECT blobid FROM dd4918_unique_blobs)
GROUP BY dd_blob, other_blob
HAVING COUNT(*) >= 10;  -- Minimum 10 shared chunks
```

**Filtering logic:**
1. **file_count <= 5000**: Ignore chunks appearing in >5000 files (like headers, metadata)
2. **cardinality <= 10**: Each chunk appears in at most 10 dd4918 files and 10 other files
3. **Product < 100**: Even after filtering, limit worst-case pairs per chunk
4. **HAVING >= 10**: Only keep file pairs sharing 10+ chunks

**Create indexes:**
```sql
CREATE INDEX idx_cand_dd ON candidate_pairs(dd_blob);
CREATE INDEX idx_cand_other ON candidate_pairs(other_blob);
CREATE INDEX idx_cand_shared ON candidate_pairs(shared_chunks DESC);
ANALYZE candidate_pairs;
```

**Expected output:** 100K-500K candidate pairs (vs billions without filtering)

**Estimated runtime:** 10-30 minutes

### Phase 2: Compute Similarity Metrics

**Create `file_similarity` materialized view:**

```sql
CREATE MATERIALIZED VIEW file_similarity AS
WITH file_chunk_counts AS (
    -- Only compute counts for blobs in candidate_pairs
    SELECT blobid, COUNT(*) AS total_chunks
    FROM file_chunks
    WHERE blobid IN (
        SELECT dd_blob FROM candidate_pairs
        UNION
        SELECT other_blob FROM candidate_pairs
    )
    GROUP BY blobid
)
SELECT
    cp.dd_blob AS dd4918_blobid,
    cp.other_blob AS other_blobid,
    cp.shared_chunks,
    dd_fc.total_chunks AS dd4918_total_chunks,
    other_fc.total_chunks AS other_total_chunks,
    -- Containment metrics (primary)
    cp.shared_chunks::float / NULLIF(dd_fc.total_chunks, 0) AS containment_dd,
    cp.shared_chunks::float / NULLIF(other_fc.total_chunks, 0) AS containment_other,
    cp.shared_chunks::float / NULLIF(LEAST(dd_fc.total_chunks, other_fc.total_chunks), 0) AS containment_max,
    -- Jaccard for reference
    cp.shared_chunks::float / NULLIF(dd_fc.total_chunks + other_fc.total_chunks - cp.shared_chunks, 0) AS jaccard
FROM candidate_pairs cp
JOIN file_chunk_counts dd_fc ON cp.dd_blob = dd_fc.blobid
JOIN file_chunk_counts other_fc ON cp.other_blob = other_fc.blobid
WHERE cp.shared_chunks::float / NULLIF(dd_fc.total_chunks, 0) >= 0.8  -- 80% of carved file must match
  AND cp.shared_chunks >= 10                                            -- Minimum absolute overlap
ORDER BY containment_dd DESC, shared_chunks DESC;
```

**Create indexes:**
```sql
CREATE INDEX idx_sim_dd ON file_similarity(dd4918_blobid);
CREATE INDEX idx_sim_containment ON file_similarity(containment_dd DESC);
ANALYZE file_similarity;
```

**Expected output:** 50K-200K high-quality matches

**Estimated runtime:** 5-15 minutes

### Phase 3: Analysis & Validation

**Top matches per carved file:**
```sql
CREATE MATERIALIZED VIEW top_matches_per_carved_file AS
WITH ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY dd4918_blobid ORDER BY containment_dd DESC, shared_chunks DESC) as rank
    FROM file_similarity
)
SELECT * FROM ranked WHERE rank <= 10;
```

**Match quality distribution:**
```sql
SELECT
    CASE
        WHEN containment_dd >= 0.95 THEN 'exact_or_near_exact'
        WHEN containment_dd >= 0.8 THEN 'high_confidence'
        WHEN containment_dd >= 0.5 THEN 'medium_confidence'
        ELSE 'low_confidence'
    END as match_quality,
    COUNT(DISTINCT dd4918_blobid) as carved_files,
    COUNT(*) as total_matches,
    AVG(containment_dd) as avg_containment_dd,
    AVG(shared_chunks) as avg_shared_chunks
FROM file_similarity
GROUP BY 1
ORDER BY 1;
```

**Unmatched carved files:**
```sql
CREATE TABLE dd4918_unique_final AS
SELECT blobid
FROM paths
WHERE medium_hash LIKE 'dd4918%'
  AND blobid IS NOT NULL
  AND blobid NOT IN (SELECT DISTINCT blobid FROM paths WHERE medium_hash NOT LIKE 'dd4918%')
  AND blobid NOT IN (SELECT dd4918_blobid FROM file_similarity);
```

These are truly unique files with no partial matches.

## Optional: Order-Aware Analysis (Phase 4)

For detecting contiguous runs vs scattered chunks, add chunk position analysis:

```sql
CREATE MATERIALIZED VIEW aligned_runs AS
WITH chunk_positions AS (
    SELECT
        fc1.blobid as dd_blob,
        fc2.blobid as other_blob,
        fc1.chunk_offset as dd_offset,
        fc2.chunk_offset as other_offset,
        fc1.chunk_offset / 16384 as dd_index,  -- Assuming avg chunk size
        fc2.chunk_offset / 16384 as other_index,
        fc1.chunk_hash
    FROM file_chunks fc1
    JOIN file_chunks fc2 ON fc1.chunk_hash = fc2.chunk_hash
    WHERE fc1.blobid IN (SELECT dd4918_blobid FROM file_similarity)
      AND fc2.blobid IN (SELECT other_blobid FROM file_similarity)
),
delta_groups AS (
    SELECT
        dd_blob,
        other_blob,
        dd_index - other_index as delta,
        COUNT(*) as run_length
    FROM chunk_positions
    GROUP BY dd_blob, other_blob, delta
)
SELECT
    dd_blob,
    other_blob,
    MAX(run_length) as max_contiguous_run
FROM delta_groups
GROUP BY dd_blob, other_blob
HAVING MAX(run_length) >= 5;  -- At least 5 contiguous chunks
```

**Use case:** Distinguish truncated files (long runs) from corrupted files (short scattered runs).

## Fallback: MinHash LSH (If Hybrid Is Too Slow)

If the hybrid approach takes >1 hour, implement Kimi's MinHash approach:

**Create MinHash signatures:**
```sql
CREATE UNLOGGED TABLE file_minhash (
    blobid        text PRIMARY KEY,
    chunk_cnt     int NOT NULL,
    minhash64     bigint[] NOT NULL,
    CHECK(array_length(minhash64,1)=64)
);

INSERT INTO file_minhash
SELECT blobid,
       count(*) AS chunk_cnt,
       array_agg(chunk_hash ORDER BY chunk_hash LIMIT 64) AS minhash64
FROM file_chunks
GROUP BY blobid;

CREATE INDEX file_minhash_gin ON file_minhash USING gin (minhash64);
```

**Self-join on MinHash arrays:**
```sql
-- GIN index makes this fast
SELECT f1.blobid, f2.blobid,
       (select count(*) from unnest(f1.minhash64) h1 JOIN unnest(f2.minhash64) h2 ON h1=h2) AS shared
FROM file_minhash f1
JOIN file_minhash f2 USING (minhash64)
WHERE f1.blobid < f2.blobid
HAVING shared >= 32;  -- Guarantees Jaccard >= 0.5
```

**Runtime:** 6-12 minutes (per Kimi's benchmarks)

## Database Configuration

**For optimal performance during view creation:**

```sql
SET work_mem = '4GB';              -- Array operations stay in memory
SET maintenance_work_mem = '8GB';  -- Index building
SET effective_io_concurrency = 32; -- SSD optimization
```

**After each materialized view creation:**
```sql
VACUUM ANALYZE table_name;
```

## Success Metrics

**Phase 0:**
- Histogram reveals data distribution
- Identify threshold for "stopword" chunks

**Phase 1:**
- candidate_pairs table size: 100K-500K rows (not billions)
- Runtime: 10-30 minutes

**Phase 2:**
- file_similarity rows: 50K-200K high-quality matches
- Runtime: 5-15 minutes
- containment_dd >= 0.8 for most matches

**Phase 3:**
- Carved files categorized:
  - Exact/near-exact matches (containment_dd >= 0.95)
  - High-confidence matches (0.8-0.95)
  - Unique files (no matches)

## Next Steps

1. ✅ Complete index creation on `file_chunks(blobid)` (completed 2025-11-22)
2. ✅ Run Phase 0 histogram query (completed 2025-11-22)
   - Found: Top chunk generates 1,068,616 pairs
   - Total pairs without filtering: 12,164,878
   - Confirms need for aggressive filtering
3. ✅ Filtering thresholds validated by histogram
4. 🔄 Execute Phase 1: Build candidate_pairs (running, started 2025-11-22 01:16 UTC)
5. Execute Phase 2: Compute file_similarity
6. Execute Phase 3: Analyze results and validate with sample files
7. Document findings and update this plan if needed

## References

- External AI consultation: 2025-11-21
  - Kimi: MinHash LSH approach (6-12 min runtime)
  - Web-Claude: Containment metrics, histogram analysis
  - ChatGPT: Two-phase design, order-aware signals
- FastCDC chunking: commit 55bb939
- Cross-medium chunks view: commit TBD (2025-11-21, 3h 44m creation time)
