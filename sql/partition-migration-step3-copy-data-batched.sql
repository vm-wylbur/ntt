-- Author: PB and Claude
-- Date: 2025-10-05
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/sql/partition-migration-step3-copy-data-batched.sql
--
-- PARTITION MIGRATION - STEP 3 (BATCHED): Copy data per medium for progress tracking
--
-- This is a safer alternative to step3-copy-data.sql that processes one medium at a time.
-- Benefits:
--   - Can monitor progress medium-by-medium
--   - Partial failure only loses one medium's work
--   - Can parallelize across multiple psql sessions if needed
--
-- Usage: psql -f partition-migration-step3-copy-data-batched.sql
--
-- Runtime: ~2-4 hours total (varies by medium size)

\timing on

-- Tune session for bulk operations
SET work_mem = '256MB';
SET maintenance_work_mem = '2GB';
SET synchronous_commit = OFF;

-- Disable autovacuum during migration
ALTER TABLE inode_new SET (autovacuum_enabled = false);
ALTER TABLE path_new SET (autovacuum_enabled = false);

-- ============================================================================
-- COPY FUNCTION: Process one medium at a time
-- ============================================================================

DO $$
DECLARE
    medium_rec RECORD;
    inode_count BIGINT;
    path_count BIGINT;
    start_time TIMESTAMP;
BEGIN
    -- Loop through each medium
    FOR medium_rec IN
        SELECT medium_hash FROM medium ORDER BY medium_hash
    LOOP
        start_time := clock_timestamp();

        RAISE NOTICE '==================================================';
        RAISE NOTICE 'Processing medium: %', medium_rec.medium_hash;
        RAISE NOTICE 'Started at: %', start_time;

        -- Copy inodes for this medium
        INSERT INTO inode_new (
            medium_hash, dev, ino, nlink, size, mtime, blobid, copied, copied_to,
            errors, fs_type, mime_type, processed_at, by_hash_created, claimed_by, claimed_at
        )
        SELECT
            medium_hash, dev, ino, nlink, size, mtime, blobid, copied, copied_to,
            errors, fs_type, mime_type, processed_at, by_hash_created, claimed_by, claimed_at
        FROM inode
        WHERE medium_hash = medium_rec.medium_hash;

        GET DIAGNOSTICS inode_count = ROW_COUNT;
        RAISE NOTICE '  Copied % inodes', inode_count;

        -- Copy paths for this medium
        INSERT INTO path_new (
            medium_hash, dev, ino, path, broken, blobid, exclude_reason
        )
        SELECT
            medium_hash, dev, ino, path, broken, blobid, exclude_reason
        FROM path
        WHERE medium_hash = medium_rec.medium_hash;

        GET DIAGNOSTICS path_count = ROW_COUNT;
        RAISE NOTICE '  Copied % paths', path_count;
        RAISE NOTICE '  Duration: %', clock_timestamp() - start_time;
        RAISE NOTICE '';

        -- Commit after each medium (allows progress tracking)
        COMMIT;

    END LOOP;

    RAISE NOTICE '==================================================';
    RAISE NOTICE 'All media copied successfully';
    RAISE NOTICE '==================================================';
END $$;

-- Re-enable autovacuum
ALTER TABLE inode_new SET (autovacuum_enabled = true);
ALTER TABLE path_new SET (autovacuum_enabled = true);

-- ============================================================================
-- VERIFICATION
-- ============================================================================

\echo 'Verification: Comparing row counts...'

SELECT 'inode' as table_name,
       (SELECT count(*) FROM inode) as old_count,
       (SELECT count(*) FROM inode_new) as new_count,
       (SELECT count(*) FROM inode) = (SELECT count(*) FROM inode_new) as counts_match;

SELECT 'path' as table_name,
       (SELECT count(*) FROM path) as old_count,
       (SELECT count(*) FROM path_new) as new_count,
       (SELECT count(*) FROM path) = (SELECT count(*) FROM path_new) as counts_match;

\echo 'Per-medium verification...'

SELECT
    COALESCE(old.medium_hash, new.medium_hash) as medium_hash,
    COALESCE(old.count, 0) as old_paths,
    COALESCE(new.count, 0) as new_paths,
    COALESCE(old.count, 0) = COALESCE(new.count, 0) as match
FROM
    (SELECT medium_hash, count(*) FROM path GROUP BY medium_hash) old
    FULL OUTER JOIN
    (SELECT medium_hash, count(*) FROM path_new GROUP BY medium_hash) new
    USING (medium_hash)
ORDER BY medium_hash;

\echo 'Partition sizes...'

SELECT
    tablename,
    pg_size_pretty(pg_total_relation_size('public.'||tablename)) AS total_size
FROM pg_tables
WHERE tablename LIKE 'path_p_%'
ORDER BY pg_total_relation_size('public.'||tablename) DESC;
