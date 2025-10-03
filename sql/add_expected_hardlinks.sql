-- Add expected_hardlinks column to blobs table for fast incomplete detection
-- This is a one-time optimization that makes finding incomplete blobs instant

-- Step 1: Add the column
ALTER TABLE blobs ADD COLUMN IF NOT EXISTS expected_hardlinks INTEGER;

-- Step 2: Create index for the column (before populating for better performance)
CREATE INDEX IF NOT EXISTS idx_blobs_expected_hardlinks
ON blobs(expected_hardlinks);

-- Step 3: Populate the column with expected counts
-- This will take several minutes for 735K blobs but only needs to run once
-- The query counts distinct paths for each blob
\echo 'Populating expected_hardlinks (this will take a few minutes)...'
\timing on

UPDATE blobs b
SET expected_hardlinks = subq.expected_count
FROM (
    SELECT
        i.blobid as blobid,
        COUNT(DISTINCT p.path) as expected_count
    FROM inode i
    JOIN path p ON p.dev = i.dev AND p.ino = i.ino
    WHERE i.blobid IS NOT NULL
    GROUP BY i.blobid
) subq
WHERE b.blobid = subq.blobid
  AND b.expected_hardlinks IS NULL;

\timing off

-- Step 4: Create a partial index for incomplete blobs
-- This makes finding incomplete blobs extremely fast
CREATE INDEX IF NOT EXISTS idx_blobs_incomplete_fast
ON blobs(blobid, n_hardlinks, expected_hardlinks)
WHERE n_hardlinks < expected_hardlinks;

-- Step 5: Analyze the table to update statistics
ANALYZE blobs;

-- Step 6: Show statistics
\echo 'Statistics after population:'
SELECT
    COUNT(*) as total_blobs,
    COUNT(expected_hardlinks) as populated,
    COUNT(*) FILTER (WHERE n_hardlinks = expected_hardlinks) as complete,
    COUNT(*) FILTER (WHERE n_hardlinks < expected_hardlinks) as incomplete,
    COUNT(*) FILTER (WHERE expected_hardlinks IS NULL) as not_populated
FROM blobs;

-- Step 7: Test the new fast query
\echo 'Testing new fast query for incomplete blobs:'
\timing on

EXPLAIN (ANALYZE, BUFFERS)
SELECT
    blobid,
    encode(blobid, 'escape') as hex_hash,
    n_hardlinks as actual,
    expected_hardlinks as expected
FROM blobs
WHERE n_hardlinks < expected_hardlinks
ORDER BY expected_hardlinks - n_hardlinks DESC
LIMIT 10;

\timing off

-- Show sample of incomplete blobs
\echo 'Sample of incomplete blobs:'
SELECT
    encode(blobid, 'escape') as hex_hash,
    n_hardlinks as actual,
    expected_hardlinks as expected,
    expected_hardlinks - n_hardlinks as missing
FROM blobs
WHERE n_hardlinks < expected_hardlinks
ORDER BY expected_hardlinks - n_hardlinks DESC
LIMIT 10;
