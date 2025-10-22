-- Backfill orphaned blobs into blobs table
-- Author: PB and Claude
-- Date: 2025-10-21
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/bin/backfill-orphaned-blobs.sql
--
-- Purpose: Populate blobs table with blobids that exist in inode table
--          but are missing from blobs table. This fixes the gap caused
--          by batch mode not inserting into blobs table.
--
-- See: docs/blob-table-orphan-analysis.md for full analysis

-- Verification query (run first to see what will be backfilled)
-- \echo '=== BEFORE BACKFILL ==='
SELECT
    'Before' as status,
    COUNT(DISTINCT i.blobid) as unique_orphaned_blobids,
    COUNT(*) as total_orphaned_inode_rows,
    pg_size_pretty(SUM(i.size)) as total_size
FROM inode i
LEFT JOIN blobs b ON i.blobid = b.blobid
WHERE i.blobid IS NOT NULL
  AND b.blobid IS NULL
  AND i.status = 'success';

-- Backfill: Insert orphaned blobids into blobs table
-- Groups by blobid and counts hardlinks from inode table
\echo '=== STARTING BACKFILL ==='

INSERT INTO blobs (blobid, n_hardlinks)
SELECT
    i.blobid,
    COUNT(*) as n_hardlinks
FROM inode i
WHERE i.blobid IS NOT NULL
  AND i.status = 'success'
  AND NOT EXISTS (
      SELECT 1 FROM blobs b WHERE b.blobid = i.blobid
  )
GROUP BY i.blobid
ON CONFLICT (blobid) DO UPDATE
SET n_hardlinks = blobs.n_hardlinks + EXCLUDED.n_hardlinks;

-- Show results
\echo '=== BACKFILL COMPLETE ==='

-- Verification query (run after to confirm)
SELECT
    'After' as status,
    COUNT(DISTINCT i.blobid) as unique_orphaned_blobids,
    COUNT(*) as total_orphaned_inode_rows,
    pg_size_pretty(SUM(i.size)) as total_size
FROM inode i
LEFT JOIN blobs b ON i.blobid = b.blobid
WHERE i.blobid IS NOT NULL
  AND b.blobid IS NULL
  AND i.status = 'success';

-- Summary of what was added
SELECT
    'Summary' as report,
    COUNT(*) as new_blobs_added,
    pg_size_pretty(SUM(n_hardlinks)) as total_hardlinks
FROM blobs
WHERE external_copied IS NULL;

\echo '=== Done. All orphaned blobids have been backfilled into blobs table. ==='
