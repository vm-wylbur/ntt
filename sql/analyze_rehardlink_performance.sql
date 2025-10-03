-- Analyze performance of the --re-hardlink queries
-- Run these with: sudo -u postgres psql -d copyjob -f /home/pball/projects/ntt/sql/analyze_rehardlink_performance.sql

\timing on

-- First, update statistics on all tables
ANALYZE blobs;
ANALYZE inode;
ANALYZE path;

-- Check table sizes
\echo '=== Table Sizes ==='
SELECT
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size,
    n_live_tup as row_count
FROM pg_stat_user_tables
WHERE tablename IN ('blobs', 'inode', 'path')
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;

-- Check existing indexes
\echo '=== Existing Indexes ==='
SELECT
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) as index_size
FROM pg_stat_user_indexes
WHERE tablename IN ('blobs', 'inode', 'path')
ORDER BY tablename, indexname;

-- Analyze the main incomplete blobs query (LIMIT 10 for speed)
\echo '=== EXPLAIN: Find Incomplete Blobs (LIMIT 10) ==='
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
WITH blob_status AS (
    SELECT
        b.blobid,
        encode(b.blobid, 'escape') as hex_hash,
        COALESCE(b.n_hardlinks, 0) as actual,
        COUNT(DISTINCT p.path) as expected
    FROM blobs b
    JOIN inode i ON i.blobid = b.blobid
    JOIN path p ON p.dev = i.dev AND p.ino = i.ino
    GROUP BY b.blobid, b.n_hardlinks
)
SELECT blobid, hex_hash, actual, expected
FROM blob_status
WHERE actual < expected
ORDER BY expected - actual DESC
LIMIT 10;

-- Simpler query - just find blobs with n_hardlinks < some threshold
\echo '=== EXPLAIN: Simple Incomplete Check ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT blobid, n_hardlinks
FROM blobs
WHERE n_hardlinks < 10
LIMIT 100;

-- Alternative: Pre-calculate expected counts in a temp table
\echo '=== Alternative: Using Temp Table for Expected Counts ==='
EXPLAIN (ANALYZE, BUFFERS)
CREATE TEMP TABLE blob_expected AS
SELECT
    i.blobid as blobid,
    COUNT(DISTINCT p.path) as expected_paths
FROM inode i
JOIN path p ON p.dev = i.dev AND p.ino = i.ino
WHERE i.blobid IS NOT NULL
GROUP BY i.blobid;

-- Then the query becomes simpler
\echo '=== EXPLAIN: Query with Pre-calculated Expected ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    b.blobid,
    encode(b.blobid, 'escape') as hex_hash,
    COALESCE(b.n_hardlinks, 0) as actual,
    e.expected_paths as expected
FROM blobs b
JOIN blob_expected e ON e.blobid = b.blobid
WHERE COALESCE(b.n_hardlinks, 0) < e.expected_paths
LIMIT 100;

DROP TABLE IF EXISTS blob_expected;

-- Check if we're missing any crucial indexes
\echo '=== Missing Index Check ==='
SELECT
    'CREATE INDEX idx_' || tablename || '_' || attname || ' ON ' || tablename || '(' || attname || ');' as suggested_index
FROM (
    SELECT
        'inode' as tablename,
        'hash' as attname
    UNION ALL
    SELECT 'path', 'dev'
    UNION ALL
    SELECT 'path', 'ino'
    UNION ALL
    SELECT 'blobs', 'n_hardlinks'
) suggestions
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE tablename = suggestions.tablename
    AND indexdef LIKE '%' || suggestions.attname || '%'
);

-- Test if partial index helps
\echo '=== Test Partial Index on Incomplete Blobs ==='
-- This index only includes blobs that are likely incomplete
CREATE INDEX IF NOT EXISTS idx_blobs_likely_incomplete
ON blobs(blobid, n_hardlinks)
WHERE n_hardlinks < 100;

ANALYZE blobs;

EXPLAIN (ANALYZE, BUFFERS)
SELECT blobid, n_hardlinks
FROM blobs
WHERE n_hardlinks < 100
LIMIT 100;

\timing off
