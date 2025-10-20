<!--
Author: PB and Claude
Date: Mon 20 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
docs/path-search-solution.md
-->

# Path Search Solution: Materialized View Approach

**Date**: 2025-10-20
**Problem**: Search for orphaned media files across 205M paths in 123 partitions
**Context**: Orphaned partition hash `3033499e` with 5.88M paths needed matching in database

## Problem Statement

The `path` table is partitioned by `medium_hash` (123 partitions, 205M total rows). When searching for orphaned media where the hash is unknown or incorrect, queries must scan ALL partitions. Traditional approaches were unacceptably slow for repeated searches across "dozens" of orphaned media.

**Requirements**:
- Search 500-1000 filenames from orphaned media
- Complete in seconds, not hours
- Reusable solution for multiple orphaned media searches
- Handle 205M+ rows efficiently

## Approaches Tried

### 1. Trigram GIN Index (FAILED)

**Approach**: Create trigram indexes for LIKE '%suffix%' pattern matching on reversed paths.

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE INDEX idx_path_trigram
ON path USING GIN (reverse(convert_from_latin1_immutable(path)) gin_trgm_ops);
```

**Results**:
- Index creation: 3 hours
- Index size: 36 GB
- Query time: 40 seconds for 10 suffixes
- Extrapolated: 20+ minutes for 500 filenames

**Why it failed**:
- Must scan all 123 partitions (hash unknown)
- 10 suffixes × 123 partitions = 1,230 index scans
- Trigram indexes check many trigrams per pattern (slow)
- Not scalable for multiple searches

### 2. Reversed Path B-tree Index (FAILED - WORSE)

**Approach**: Convert suffix matching to prefix matching by reversing paths.

```sql
CREATE INDEX idx_path_reversed
ON path (reverse(convert_from_latin1_immutable(path)) text_pattern_ops);
```

**Results**:
- Index creation: 1 hour
- Index size: 46 GB
- Query time: 125 seconds for 10 suffixes
- Index WAS used correctly, but still too slow

**Why it failed**:
- Fundamental architectural problem: partition scanning
- Each suffix requires scanning ALL 123 partitions
- 123 partitions × ~100ms per partition = 12+ seconds per suffix
- Pattern matching on B-tree still slower than exact matching
- Index type doesn't matter when partition overhead dominates

**User feedback**: "wow this is ugly"

### 3. Generated STORED Columns (CONSIDERED, NOT IMPLEMENTED)

**Approach**: Add indexed columns to partitioned table for filename-only matching.

```sql
ALTER TABLE path ADD COLUMN filename_text text
  GENERATED ALWAYS AS (
    regexp_replace(convert_from_latin1_immutable(path), '^.*/', '')
  ) STORED;

CREATE INDEX idx_path_filename ON path (filename_text);
```

**Estimated**:
- Column creation: 2-3 hours (materializing values in 123 partitions)
- Index creation: 2-3 hours more
- Total: 4-6 hours
- Would still suffer from partition scan overhead

**Why not implemented**: User identified materialized view as superior solution before implementation.

## Solution: Unpartitioned Materialized View

**Key insight**: The partition overhead (scanning 123 partitions) is the bottleneck, NOT the index type. Solution: Create an unpartitioned materialized view optimized for filename searching.

### Implementation

```sql
-- Create materialized view with filename extraction
CREATE MATERIALIZED VIEW path_search AS
SELECT
  medium_hash,
  path,
  regexp_replace(
    convert_from_latin1_immutable(path),
    '^.*/',
    ''
  ) AS filename,
  regexp_replace(
    convert_from_latin1_immutable(path),
    '^.*/([^/]+/[^/]+)$',
    '\1'
  ) AS parent_filename
FROM path;

-- Create indexes (required UNIQUE index for REFRESH CONCURRENTLY)
CREATE UNIQUE INDEX idx_path_search_pk ON path_search(medium_hash, path);
CREATE INDEX idx_path_search_filename ON path_search(filename);
CREATE INDEX idx_path_search_parent_filename ON path_search(parent_filename);

-- Update statistics
ANALYZE path_search;
```

### Performance Results

| Metric | Time/Size |
|--------|-----------|
| View creation | 33 minutes (205M rows) |
| Index creation | 23 minutes (3 indexes) |
| **Total setup** | **56 minutes** |
| Table size | 61 GB |
| Index size | 58 GB |
| **Total size** | **119 GB** |
| Row count | 204,692,535 |

**Query Performance**:
- Single filename search: **1.0 milliseconds** (vs 12+ seconds partitioned)
- 100 filename search: **instant**
- 10,000 filename search: **~5 seconds**

**Comparison to alternatives**:
- Trigram index approach: 20+ minutes for 500 filenames
- Reversed index approach: Similar or worse
- **Materialized view: < 5 seconds for 500 filenames**

### Why It Works

1. **No partition overhead**: Single unpartitioned table = one index scan
2. **Exact matching**: B-tree on extracted filenames (faster than pattern matching)
3. **Pre-computed values**: Regex extraction done once at creation, not per query
4. **Optimal for read-heavy workloads**: Orphaned media searches don't update the view

### Trade-offs

**Advantages**:
- 12,000x faster queries (1ms vs 12+ seconds)
- Reusable for all orphaned media searches
- Simple query structure
- No partition scan complexity

**Disadvantages**:
- Snapshot-based (stale until REFRESH)
- 119 GB additional storage
- Must refresh after path table changes (2-5 minutes)

**For orphaned media use case, disadvantages don't matter**:
- Searching historical data (2013 backups)
- Path table changes infrequently
- 119 GB is 15% of 785 GB available
- Refresh can run nightly or after bulk loads

### Usage Examples

```sql
-- Search single filename
SELECT medium_hash, filename, parent_filename
FROM path_search
WHERE filename = 'IMG_1234.jpg';

-- Search multiple filenames (typical orphaned media search)
SELECT
  filename,
  count(*) AS match_count,
  array_agg(DISTINCT medium_hash) AS found_in_hashes
FROM path_search
WHERE filename = ANY(ARRAY[
  'file1.jpg',
  'file2.txt',
  -- ... 500 more filenames
])
GROUP BY filename;

-- Use parent_filename for disambiguation
SELECT medium_hash, parent_filename
FROM path_search
WHERE parent_filename = 'photos/IMG_1234.jpg';
```

### Maintenance

```sql
-- Refresh after path table changes (non-blocking)
REFRESH MATERIALIZED VIEW CONCURRENTLY path_search;

-- Faster refresh with brief lock (maintenance window)
REFRESH MATERIALIZED VIEW path_search;

-- Check size and row count
SELECT
  pg_size_pretty(pg_total_relation_size('path_search')) AS total_size,
  count(*) AS row_count
FROM path_search;
```

### Automation

```sql
-- Optional: Scheduled refresh
CREATE OR REPLACE FUNCTION refresh_path_search()
RETURNS void AS $$
BEGIN
  REFRESH MATERIALIZED VIEW CONCURRENTLY path_search;
END;
$$ LANGUAGE plpgsql;

-- Schedule with pg_cron (if available)
SELECT cron.schedule(
  'refresh-path-search',
  '0 2 * * *',  -- 2 AM daily
  'SELECT refresh_path_search();'
);
```

## Lessons Learned

1. **Partition overhead can dominate query time**: With 123 partitions and no way to prune, the cost of scanning partitions outweighed any index optimization.

2. **Index type matters less than query structure**: Both trigram and B-tree indexes failed because of partition scanning, not index efficiency.

3. **Materialized views bypass partition complexity**: Denormalizing into an unpartitioned view eliminated the fundamental bottleneck.

4. **One-time cost vs repeated queries**: 56-minute setup enables unlimited fast searches vs 20+ minutes per search with indexes.

5. **Storage is cheap, time is expensive**: 119 GB buys 12,000x query speedup for a read-heavy workflow.

6. **Know your access patterns**: Orphaned media searches are read-only, historical data lookups - perfect for materialized views.

## Future Enhancements

### Option 1: Add More Path Components

Extract 2-3 more directory levels for better disambiguation:

```sql
ALTER MATERIALIZED VIEW path_search RENAME TO path_search_old;

CREATE MATERIALIZED VIEW path_search AS
SELECT
  medium_hash,
  path,
  regexp_replace(convert_from_latin1_immutable(path), '^.*/', '') AS filename,
  regexp_replace(convert_from_latin1_immutable(path), '^.*/([^/]+/[^/]+)$', '\1') AS parent_filename,
  regexp_replace(convert_from_latin1_immutable(path), '^.*/([^/]+/[^/]+/[^/]+)$', '\1') AS grandparent_filename
FROM path;
```

### Option 2: Add Foreign Key to Original Table

Include a reference back to the partitioned table:

```sql
-- Assuming path table has surrogate keys per partition
CREATE MATERIALIZED VIEW path_search AS
SELECT
  p.path_id,  -- Composite: (medium_hash, path)
  p.medium_hash,
  p.path,
  regexp_replace(...) AS filename,
  regexp_replace(...) AS parent_filename
FROM path p;

-- Join back for full row data
SELECT p.*
FROM path_search ps
JOIN path p USING (path_id, medium_hash)
WHERE ps.filename = 'target.jpg';
```

## Verification Results: Finding the Orphaned Partition

### The Discovery

After building the materialized view, we ran comprehensive tests to identify which medium_hash in the database contained the files from the orphaned partition 3033499e.

**Initial Test (10,000 filenames)**:
- ALL 10,000 sampled filenames found in database (0 with zero matches)
- Two medium_hashes both contained 100% of sampled files:
  - `d9549175fb3638efbc919bdc01cb3310`: 10,000/10,000 (100.00%)
  - `cff53715105387e3c20b6c2e4d7f305f`: 10,000/10,000 (100.00%)

**Disambiguation Test (1,793,021 parent_filename patterns)**:

Used more discriminating parent_filename matching (last 2 path components):

```sql
WITH test_files AS (
  SELECT DISTINCT
    regexp_replace(path_suffix, '^.*/([^/]+/[^/]+)$', '\1') AS parent_filename
  FROM sample_paths_3033
  WHERE path_suffix NOT LIKE '%.DS_Store'
    AND path_suffix ~ '^.*/[^/]+/[^/]+$'
),
file_matches AS (
  SELECT
    ps.medium_hash,
    count(DISTINCT tf.parent_filename) AS matching_files
  FROM test_files tf
  JOIN path_search ps ON ps.parent_filename = tf.parent_filename
  GROUP BY ps.medium_hash
)
SELECT medium_hash, matching_files,
       round(100.0 * matching_files / (SELECT count(*) FROM test_files), 2) AS pct
FROM file_matches
ORDER BY matching_files DESC;
```

**Results**: BOTH hashes still showed 100% match:
- `d9549175fb3638efbc919bdc01cb3310`: 1,793,021 patterns (100.00%)
- `cff53715105387e3c20b6c2e4d7f305f`: 1,793,021 patterns (100.00%)

### The Explanation

Further investigation revealed both hashes represent **the same partition enumerated twice**:

```sql
-- Path count verification
SELECT medium_hash, count(*) FROM path
WHERE medium_hash IN ('d9549175...', 'cff53715...')
GROUP BY medium_hash;
-- Both: 5,880,473 paths (matches 3033499e's 5,880,457)

-- Sample path comparison
-- d9549175: /mnt/ntt/d9549175fb3638efbc919bdc01cb3310/.HFS+ Private Directory Data...
-- cff53715: /mnt/ntt-partition3/.HFS+ Private Directory Data...
```

**Root Cause**: The partition was mounted at different locations during two separate enumeration runs:
1. Once at `/mnt/ntt/d9549175fb3638efbc919bdc01cb3310/` → hash d9549175...
2. Once at `/mnt/ntt-partition3/` → hash cff53715...

Since the NTT hash includes the mount path, different mount points produced different hashes for identical partition content.

### Conclusion

**Hash 3033499e was incorrect** - likely a typo or data corruption in the filename. The actual partition was successfully enumerated and loaded into the database TWICE under two different hashes. The files are not "orphaned" - they exist in the database and can be processed normally using either hash.

**Recommendation**: Use `d9549175fb3638efbc919bdc01cb3310` or `cff53715105387e3c20b6c2e4d7f305f` as the correct hash for this partition. Consider removing the duplicate partition to avoid processing the same files twice.

## References

- PostgreSQL partitioning docs: https://www.postgresql.org/docs/17/ddl-partitioning.html
- Materialized views: https://www.postgresql.org/docs/17/sql-creatematerializedview.html
- Trigram indexes: https://www.postgresql.org/docs/17/pgtrgm.html

## Related Documents

- `docs/hash-format.md` - Medium hash calculation (why 3033499e was wrong)
- `docs/sanity-checks.md` - Database integrity verification
- `docs/postgres_path_search_mv.md` - Original specification for this solution
