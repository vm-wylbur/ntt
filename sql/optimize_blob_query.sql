-- Alternative optimization strategies for finding incomplete blobs

-- Strategy 1: Add expected_hardlinks column to blobs table
-- This would be populated once and then used for fast queries
ALTER TABLE blobs ADD COLUMN IF NOT EXISTS expected_hardlinks INTEGER;

-- Populate it (this will take a while but only needs to run once)
UPDATE blobs b
SET expected_hardlinks = (
    SELECT COUNT(DISTINCT p.path)
    FROM inode i
    JOIN path p ON p.dev = i.dev AND p.ino = i.ino
    WHERE i.blobid = b.blobid
)
WHERE expected_hardlinks IS NULL;

-- Create index for fast incomplete queries
CREATE INDEX IF NOT EXISTS idx_blobs_incomplete_check
ON blobs(blobid)
WHERE n_hardlinks < expected_hardlinks;

-- Now the query becomes MUCH simpler and faster:
-- SELECT blobid, encode(blobid, 'escape') as hex_hash, n_hardlinks as actual, expected_hardlinks as expected
-- FROM blobs
-- WHERE n_hardlinks < expected_hardlinks
-- LIMIT 1000;

-- Strategy 2: Create a materialized view (refresh periodically)
CREATE MATERIALIZED VIEW IF NOT EXISTS blob_completeness AS
WITH blob_stats AS (
    SELECT
        i.blobid as blobid,
        COUNT(DISTINCT p.path) as expected_paths
    FROM inode i
    JOIN path p ON p.dev = i.dev AND p.ino = i.ino
    WHERE i.blobid IS NOT NULL
    GROUP BY i.blobid
)
SELECT
    b.blobid,
    COALESCE(b.n_hardlinks, 0) as actual_hardlinks,
    s.expected_paths,
    s.expected_paths - COALESCE(b.n_hardlinks, 0) as missing_hardlinks
FROM blobs b
JOIN blob_stats s ON s.blobid = b.blobid
WHERE COALESCE(b.n_hardlinks, 0) < s.expected_paths;

CREATE INDEX IF NOT EXISTS idx_blob_completeness_missing
ON blob_completeness(missing_hardlinks DESC);

-- Query the materialized view (FAST!)
-- SELECT * FROM blob_completeness
-- ORDER BY missing_hardlinks DESC
-- LIMIT 1000;

-- Refresh when needed (after batch updates)
-- REFRESH MATERIALIZED VIEW blob_completeness;

-- Strategy 3: Simpler heuristic - process blobs with very low n_hardlinks first
-- Most blobs should have many hardlinks, so any with < 10 are definitely incomplete
CREATE INDEX IF NOT EXISTS idx_blobs_low_hardlinks
ON blobs(n_hardlinks, blobid)
WHERE n_hardlinks < 10;

-- Fast query for obviously incomplete blobs
-- SELECT blobid, encode(blobid, 'escape') as hex_hash, n_hardlinks
-- FROM blobs
-- WHERE n_hardlinks < 10
-- ORDER BY n_hardlinks
-- LIMIT 1000;
