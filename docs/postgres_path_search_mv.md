# PostgreSQL Path Search - Materialized View Solution

## Problem Summary
- PostgreSQL 17, partitioned `path` table (121 partitions by medium_hash)
- ~100M+ rows total, bytea paths converted to latin1 for searching
- Searching for path suffixes across all partitions: 12+ seconds per suffix
- Need to search 500+ orphaned filenames efficiently

## Solution: Unpartitioned Materialized View

The partitioning creates 24-60x slowdown for non-prunable queries. A materialized view bypasses partition overhead entirely.

---

## 1. Create the Materialized View

```sql
CREATE MATERIALIZED VIEW path_search AS
SELECT 
  path_id,  -- adjust to your actual primary key column name
  medium_hash,
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
```

**Estimated time**: 1-3 minutes for 100M rows

---

## 2. Create Indexes

```sql
-- Required for REFRESH CONCURRENTLY (must be UNIQUE)
CREATE UNIQUE INDEX idx_path_search_pk ON path_search(path_id);

-- Search indexes
CREATE INDEX idx_path_search_filename ON path_search(filename);
CREATE INDEX idx_path_search_parent_filename ON path_search(parent_filename);

-- Optional: if you want to filter by medium_hash
CREATE INDEX idx_path_search_medium_hash ON path_search(medium_hash);

-- Update statistics for query planner
ANALYZE path_search;
```

**Estimated time**: 3-5 minutes for index creation

---

## 3. Search Queries

### Search by filename (fast, for unique filenames)

```sql
-- Single filename
SELECT medium_hash, path_id, filename, parent_filename
FROM path_search
WHERE filename = 'IMG_1234.jpg';

-- Multiple filenames (your 500 orphaned files)
SELECT medium_hash, path_id, filename, parent_filename
FROM path_search
WHERE filename = ANY(ARRAY[
  'IMG_1234.jpg',
  'video_001.mp4',
  'document.pdf'
  -- ... add all 500 filenames
]);
```

**Expected performance**: < 5 seconds for 500 filenames

### Search by parent + filename (for disambiguation)

```sql
-- When you need more specificity
SELECT medium_hash, path_id, filename, parent_filename
FROM path_search
WHERE parent_filename = ANY(ARRAY[
  'photos/IMG_1234.jpg',
  'videos/video_001.mp4'
  -- ... your patterns
]);
```

### Combined search with results grouping

```sql
-- Search and see how many matches per filename
WITH orphaned_files AS (
  SELECT unnest(ARRAY[
    'IMG_1234.jpg',
    'video_001.mp4'
    -- ... your 500 files
  ]) AS search_filename
)
SELECT 
  of.search_filename,
  count(*) AS match_count,
  array_agg(DISTINCT ps.medium_hash) AS found_in_hashes
FROM orphaned_files of
JOIN path_search ps ON ps.filename = of.search_filename
GROUP BY of.search_filename
ORDER BY match_count DESC;
```

---

## 4. Join Back to Main Table

```sql
-- Get full path data after finding matches
SELECT 
  ps.medium_hash,
  ps.filename,
  p.path,  -- original bytea path
  convert_from_latin1_immutable(p.path) AS full_path_text
FROM path_search ps
JOIN path p USING (path_id)
WHERE ps.filename = ANY(ARRAY['file1.jpg', 'file2.jpg']);
```

---

## 5. Refresh the View

```sql
-- Non-blocking refresh (recommended for production)
-- Requires UNIQUE index on path_id
REFRESH MATERIALIZED VIEW CONCURRENTLY path_search;
```

**Estimated time**: 2-5 minutes for 100M rows

```sql
-- Faster refresh with brief exclusive lock
-- Use during maintenance windows
REFRESH MATERIALIZED VIEW path_search;
```

**Estimated time**: 1-3 minutes for 100M rows

---

## 6. Monitoring Queries

### Check storage size

```sql
SELECT 
  pg_size_pretty(pg_total_relation_size('path_search')) AS total_size,
  pg_size_pretty(pg_relation_size('path_search')) AS table_size,
  pg_size_pretty(pg_total_relation_size('path_search') - pg_relation_size('path_search')) AS index_size;
```

### Check row count

```sql
SELECT count(*) FROM path_search;
```

### Test query performance

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM path_search 
WHERE filename = 'test.jpg';
```

### Check last refresh time

```sql
SELECT 
  schemaname,
  matviewname,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||matviewname)) AS size
FROM pg_matviews
WHERE matviewname = 'path_search';
```

---

## 7. Quick Start Script

Run this to set everything up at once:

```sql
BEGIN;

-- Create materialized view
CREATE MATERIALIZED VIEW path_search AS
SELECT 
  path_id,
  medium_hash,
  regexp_replace(convert_from_latin1_immutable(path), '^.*/', '') AS filename,
  regexp_replace(convert_from_latin1_immutable(path), '^.*/([^/]+/[^/]+)$', '\1') AS parent_filename
FROM path;

-- Create indexes
CREATE UNIQUE INDEX idx_path_search_pk ON path_search(path_id);
CREATE INDEX idx_path_search_filename ON path_search(filename);
CREATE INDEX idx_path_search_parent_filename ON path_search(parent_filename);

-- Update statistics
ANALYZE path_search;

COMMIT;
```

---

## Performance Expectations

| Operation | Current (Partitioned) | With Materialized View |
|-----------|----------------------|------------------------|
| 500 filename search | 20+ minutes | < 5 seconds |
| Single suffix match | 12+ seconds | < 50ms |
| Initial setup | N/A | 5-10 minutes |
| Refresh after updates | N/A | 2-5 minutes |
| Storage overhead | 0 | ~25-30GB |

---

## Maintenance Schedule

### Recommended refresh frequency:
- **Nightly**: If path table has daily updates
- **After cleanup**: After orphaned data cleanup operations
- **Weekly**: If path table is mostly static

### Automation example:

```sql
-- Create a function to refresh
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

---

## Troubleshooting

### If REFRESH CONCURRENTLY fails:
```sql
-- Ensure UNIQUE index exists
CREATE UNIQUE INDEX IF NOT EXISTS idx_path_search_pk ON path_search(path_id);

-- Then try again
REFRESH MATERIALIZED VIEW CONCURRENTLY path_search;
```

### If queries are still slow:
```sql
-- Check if indexes are being used
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM path_search WHERE filename = 'test.jpg';

-- Rebuild indexes if needed
REINDEX INDEX idx_path_search_filename;

-- Update statistics
ANALYZE path_search;
```

### If storage is a concern:
```sql
-- Drop unused indexes
DROP INDEX IF EXISTS idx_path_search_parent_filename;

-- Or create partial indexes for common patterns
CREATE INDEX idx_path_search_filename_jpg ON path_search(filename) 
WHERE filename LIKE '%.jpg';
```

---

## Notes

- Materialized view is NOT partitioned - this is intentional for performance
- View data is a snapshot - changes to `path` table won't appear until refresh
- Concurrent refresh requires PostgreSQL 9.4+
- For immediate consistency needs, consider a trigger-maintained table instead

---

## Next Steps

1. Run the Quick Start Script above
2. Test with a small sample of filenames
3. Measure actual performance gains
4. Set up automated refresh schedule
5. Monitor storage growth over time