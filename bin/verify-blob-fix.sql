-- Verify batch mode blob fix is working
-- Author: PB and Claude
-- Date: 2025-10-21
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/bin/verify-blob-fix.sql
--
-- Purpose: Verify that batch mode correctly populates blobs table
--          Run after processing test medium to confirm fix works

\echo '=== ORPHAN CHECK ==='
\echo 'This should return 0 if fix is working'

SELECT COUNT(*) as orphaned_count
FROM inode i
LEFT JOIN blobs b ON i.blobid = b.blobid
WHERE i.copied = true
  AND i.blobid IS NOT NULL
  AND b.blobid IS NULL;

\echo ''
\echo '=== PROCESSED_AT CHECK ==='
\echo 'Recent files should have processed_at timestamp'

SELECT
    COUNT(*) as total_recent_success,
    COUNT(*) FILTER (WHERE processed_at IS NOT NULL) as has_timestamp,
    COUNT(*) FILTER (WHERE processed_at IS NULL) as no_timestamp
FROM inode
WHERE status = 'success'
  AND copied = true
  AND processed_at > NOW() - INTERVAL '1 hour';

\echo ''
\echo '=== BLOBS TABLE CHECK ==='
\echo 'Recent blobs should have external_copied = false (pending backup)'

SELECT
    COUNT(*) as recent_blobs,
    COUNT(*) FILTER (WHERE external_copied = false OR external_copied IS NULL) as pending_backup,
    COUNT(*) FILTER (WHERE external_last_checked > NOW() - INTERVAL '1 hour') as recently_checked
FROM blobs
WHERE blobid IN (
    SELECT DISTINCT blobid
    FROM inode
    WHERE processed_at > NOW() - INTERVAL '1 hour'
      AND blobid IS NOT NULL
);

\echo ''
\echo '=== SUCCESS ==='
\echo 'If orphaned_count = 0, has_timestamp > 0, and pending_backup > 0, fix is working!'
