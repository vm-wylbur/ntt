-- Author: PB and Claude
-- Date: 2025-10-13
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- Backfill blobs table with blobids that exist in inode but missing from blobs
--
-- CONTEXT:
-- Investigation on 2025-10-13 discovered 1,053,484 blobs (17.1%) present in
-- /data/cold/by-hash/ and in inode table but missing from blobs table.
-- All files verified to exist on disk.
--
-- Root cause: blobs table is populated by ntt-copier.py during copy operations.
-- These files were copied but database inserts failed/were skipped.

\echo '=== Backfilling missing blobs ==='
\echo ''
\echo 'Finding blobs in inode table but missing from blobs table...'
\echo ''

-- Insert missing blobids with n_hardlinks=0 (will be updated by future integrity checks)
INSERT INTO blobs (blobid, n_hardlinks)
SELECT DISTINCT i.blobid, 0 as n_hardlinks
FROM inode i
LEFT JOIN blobs b ON i.blobid = b.blobid
WHERE i.blobid IS NOT NULL
  AND b.blobid IS NULL
ON CONFLICT (blobid) DO NOTHING;

\echo ''
\echo '=== Backfill complete ==='
\echo ''
\echo 'Verifying counts...'

SELECT
  'blobs table' as source,
  COUNT(*) as count
FROM blobs
UNION ALL
SELECT
  'inode table (unique blobids)' as source,
  COUNT(DISTINCT blobid) as count
FROM inode
WHERE blobid IS NOT NULL;

\echo ''
\echo 'Expected: Both counts should now match at ~6,252,591'
