-- Author: PB and Claude
-- Date: 2025-11-15
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/migrations/eliminate-partitions-phase3-verification.sql
--
-- PHASE 3: Verify data migration integrity
--
-- This script performs comprehensive verification of the migration.
-- All checks should show "OK" or matching counts.
--
-- If any check fails, DO NOT proceed to Phase 4 (cutover).

\set ON_ERROR_STOP on

\echo '================================================================================'
\echo 'PHASE 3: Data Migration Verification'
\echo '================================================================================'
\echo ''

-- ============================================================================
-- CHECK 1: Row count comparison
-- ============================================================================

\echo 'CHECK 1: Row count comparison'
\echo '------------------------------------------------------------'

SELECT 'inode (all partitions)' as table_name, COUNT(*) as row_count FROM inode
UNION ALL
SELECT 'path (all partitions)', COUNT(*) FROM path
UNION ALL
SELECT 'blobs_provisional', COUNT(*) FROM blobs_provisional
UNION ALL
SELECT 'paths_provisional', COUNT(*) FROM paths_provisional;

\echo ''

-- ============================================================================
-- CHECK 2: Path count verification (should be EQUAL)
-- ============================================================================

\echo 'CHECK 2: Path count verification'
\echo '------------------------------------------------------------'

WITH counts AS (
    SELECT COUNT(*) as old_paths FROM path
), new_counts AS (
    SELECT COUNT(*) as new_paths FROM paths_provisional
)
SELECT
    c.old_paths,
    n.new_paths,
    c.old_paths - n.new_paths as difference,
    CASE
        WHEN c.old_paths = n.new_paths THEN 'OK - Counts match'
        ELSE 'FAIL - Row count mismatch!'
    END as status
FROM counts c, new_counts n;

\echo ''

-- ============================================================================
-- CHECK 3: Hardlink deduplication preserved
-- ============================================================================

\echo 'CHECK 3: Hardlink deduplication preserved'
\echo '------------------------------------------------------------'

WITH old_hardlinks AS (
    SELECT
        COUNT(DISTINCT (medium_hash, ino)) as unique_inodes,
        COUNT(*) as total_paths,
        COUNT(*) - COUNT(DISTINCT (medium_hash, ino)) as hardlink_count
    FROM path
), new_hardlinks AS (
    SELECT
        COUNT(DISTINCT (medium_hash, ino)) as unique_inodes,
        COUNT(*) as total_paths,
        COUNT(*) - COUNT(DISTINCT (medium_hash, ino)) as hardlink_count
    FROM paths_provisional
)
SELECT
    'old schema' as schema,
    o.unique_inodes,
    o.total_paths,
    o.hardlink_count
FROM old_hardlinks o
UNION ALL
SELECT
    'new schema',
    n.unique_inodes,
    n.total_paths,
    n.hardlink_count
FROM new_hardlinks n;

\echo ''

-- ============================================================================
-- CHECK 4: Blob deduplication (unique blobids)
-- ============================================================================

\echo 'CHECK 4: Blob deduplication verification'
\echo '------------------------------------------------------------'

WITH old_blobs AS (
    SELECT COUNT(DISTINCT blobid) as unique_blobs
    FROM inode
    WHERE blobid IS NOT NULL
), new_blobs AS (
    SELECT COUNT(*) as unique_blobs
    FROM blobs_provisional
)
SELECT
    o.unique_blobs as old_unique_blobs,
    n.unique_blobs as new_unique_blobs,
    o.unique_blobs - n.unique_blobs as difference,
    CASE
        WHEN o.unique_blobs = n.unique_blobs THEN 'OK - Blob counts match'
        WHEN n.unique_blobs > o.unique_blobs THEN 'WARN - New schema has more blobs (acceptable)'
        ELSE 'FAIL - Missing blobs in new schema!'
    END as status
FROM old_blobs o, new_blobs n;

\echo ''

-- ============================================================================
-- CHECK 5: Spot check random media (detailed comparison)
-- ============================================================================

\echo 'CHECK 5: Spot check random media'
\echo '------------------------------------------------------------'

\echo 'Selecting 5 random media for detailed verification...'
\echo ''

DO $$
DECLARE
    m text;
    old_path_count int;
    new_path_count int;
    old_inode_count int;
    new_inode_count int;
    old_blob_count int;
    new_blob_count int;
    check_count int := 0;
    failed_checks int := 0;
BEGIN
    FOR m IN
        SELECT medium_hash
        FROM medium
        ORDER BY RANDOM()
        LIMIT 5
    LOOP
        check_count := check_count + 1;

        -- Get counts from old schema
        SELECT COUNT(*) INTO old_path_count
        FROM path WHERE medium_hash = m;

        SELECT COUNT(*) INTO old_inode_count
        FROM inode WHERE medium_hash = m;

        SELECT COUNT(DISTINCT blobid) INTO old_blob_count
        FROM inode WHERE medium_hash = m AND blobid IS NOT NULL;

        -- Get counts from new schema
        SELECT COUNT(*) INTO new_path_count
        FROM paths_provisional WHERE medium_hash = m;

        SELECT COUNT(DISTINCT ino) INTO new_inode_count
        FROM paths_provisional WHERE medium_hash = m;

        SELECT COUNT(DISTINCT blobid) INTO new_blob_count
        FROM paths_provisional WHERE medium_hash = m AND blobid IS NOT NULL;

        -- Report
        RAISE NOTICE '';
        RAISE NOTICE 'Medium: % (check %/5)', m, check_count;
        RAISE NOTICE '  Paths: old=%, new=% %',
                     old_path_count,
                     new_path_count,
                     CASE WHEN old_path_count = new_path_count THEN '[OK]' ELSE '[FAIL]' END;
        RAISE NOTICE '  Inodes: old=%, new=% %',
                     old_inode_count,
                     new_inode_count,
                     CASE WHEN old_inode_count = new_inode_count THEN '[OK]' ELSE '[FAIL]' END;
        RAISE NOTICE '  Unique blobs: old=%, new=% %',
                     old_blob_count,
                     new_blob_count,
                     CASE WHEN old_blob_count = new_blob_count THEN '[OK]' ELSE '[FAIL]' END;

        -- Track failures
        IF old_path_count != new_path_count OR
           old_inode_count != new_inode_count OR
           old_blob_count != new_blob_count THEN
            failed_checks := failed_checks + 1;
        END IF;
    END LOOP;

    RAISE NOTICE '';
    IF failed_checks = 0 THEN
        RAISE NOTICE 'Spot check complete: All 5 media verified successfully [OK]';
    ELSE
        RAISE WARNING 'Spot check FAILED: % of 5 media had mismatches', failed_checks;
    END IF;
END $$;

\echo ''

-- ============================================================================
-- CHECK 6: Foreign key integrity verification
-- ============================================================================

\echo 'CHECK 6: Foreign key integrity verification'
\echo '------------------------------------------------------------'

\echo 'Checking for orphaned blobids in paths_provisional (should be 0)...'

SELECT
    COUNT(*) as orphaned_blobids,
    CASE
        WHEN COUNT(*) = 0 THEN 'OK - No orphaned blobids'
        ELSE 'FAIL - Found paths referencing non-existent blobs!'
    END as status
FROM paths_provisional p
WHERE p.blobid IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM blobs_provisional b WHERE b.blobid = p.blobid);

\echo ''

-- ============================================================================
-- CHECK 7: Verify copied status consistency
-- ============================================================================

\echo 'CHECK 7: Copied status consistency'
\echo '------------------------------------------------------------'

WITH old_copied AS (
    SELECT
        COUNT(*) FILTER (WHERE copied = true) as old_copied_count,
        COUNT(*) FILTER (WHERE copied = false) as old_unclaimed_count
    FROM inode
), new_copied AS (
    SELECT
        COUNT(*) FILTER (WHERE copied = true) as new_copied_count,
        COUNT(*) FILTER (WHERE copied = false) as new_unclaimed_count
    FROM paths_provisional
)
SELECT
    o.old_copied_count,
    n.new_copied_count,
    o.old_copied_count - n.new_copied_count as copied_diff,
    o.old_unclaimed_count,
    n.new_unclaimed_count,
    o.old_unclaimed_count - n.new_unclaimed_count as unclaimed_diff,
    CASE
        WHEN o.old_copied_count = n.new_copied_count AND
             o.old_unclaimed_count = n.new_unclaimed_count
        THEN 'OK - Copied status preserved'
        ELSE 'WARN - Copied status differs (may be acceptable if work in progress)'
    END as status
FROM old_copied o, new_copied n;

\echo ''

-- ============================================================================
-- CHECK 8: Disk space comparison
-- ============================================================================

\echo 'CHECK 8: Disk space comparison'
\echo '------------------------------------------------------------'

SELECT
    'old schema (partitioned)' as schema,
    pg_size_pretty(
        pg_total_relation_size('inode') +
        pg_total_relation_size('path')
    ) as total_size
UNION ALL
SELECT
    'new schema (unpartitioned)',
    pg_size_pretty(
        pg_total_relation_size('blobs_provisional') +
        pg_total_relation_size('paths_provisional')
    );

\echo ''

-- ============================================================================
-- FINAL SUMMARY
-- ============================================================================

\echo '================================================================================'
\echo 'VERIFICATION SUMMARY'
\echo '================================================================================'
\echo ''
\echo 'Review the checks above. All should show OK or matching counts.'
\echo ''
\echo 'If any check shows FAIL, DO NOT proceed to Phase 4.'
\echo 'Investigate the failure and fix before cutover.'
\echo ''
\echo 'If all checks pass:'
\echo '  1. Stop all ntt-copier workers'
\echo '  2. Run eliminate-partitions-phase4-cutover.sql'
\echo ''
\echo '================================================================================'
