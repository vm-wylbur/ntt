-- Author: PB and Claude
-- Date: 2025-11-15
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/migrations/eliminate-partitions-rollback.sql
--
-- ROLLBACK: Restore from pg_dump backup
--
-- USE CASES:
--   1. Rollback before Phase 4 cutover (simple table drops)
--   2. Rollback after Phase 4 cutover (requires pg_restore)
--
-- This script handles both cases.

\set ON_ERROR_STOP on

\echo '================================================================================'
\echo 'ROLLBACK: Eliminate Partitions Migration'
\echo '================================================================================'
\echo ''

-- ============================================================================
-- CASE 1: Rollback before cutover (Phase 1-3)
-- ============================================================================

\echo 'Checking if rollback is before or after cutover...'

DO $$
DECLARE
    has_old_tables boolean;
    has_new_tables boolean;
BEGIN
    -- Check if old partitioned tables still exist
    SELECT EXISTS (
        SELECT 1 FROM pg_tables WHERE tablename = 'inode'
    ) INTO has_old_tables;

    -- Check if new tables exist
    SELECT EXISTS (
        SELECT 1 FROM pg_tables WHERE tablename IN ('paths_provisional', 'blobs_provisional')
    ) INTO has_new_tables;

    IF has_old_tables AND has_new_tables THEN
        RAISE NOTICE 'Status: Before cutover (old and new tables exist)';
        RAISE NOTICE 'Rollback strategy: Drop new tables, keep old tables';
        RAISE NOTICE '';

        -- Drop new tables
        RAISE NOTICE 'Dropping paths_provisional...';
        DROP TABLE IF EXISTS paths_provisional CASCADE;

        RAISE NOTICE 'Dropping blobs_provisional...';
        DROP TABLE IF EXISTS blobs_provisional CASCADE;

        -- Restore blobs table if it was renamed
        IF EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'blobs_old') THEN
            RAISE NOTICE 'Renaming blobs_old → blobs...';
            ALTER TABLE blobs_old RENAME TO blobs;
        END IF;

        RAISE NOTICE '';
        RAISE NOTICE 'Rollback complete: New tables dropped, old schema intact';
        RAISE NOTICE 'You can safely continue using the partitioned schema.';

    ELSIF NOT has_old_tables AND NOT has_new_tables THEN
        RAISE NOTICE 'Status: After cutover (old tables dropped, new tables renamed)';
        RAISE NOTICE 'Rollback strategy: Restore from pg_dump';
        RAISE NOTICE '';
        RAISE WARNING 'Cannot rollback automatically - old partitioned tables were dropped.';
        RAISE NOTICE '';
        RAISE NOTICE 'To rollback:';
        RAISE NOTICE '  1. Stop all workers';
        RAISE NOTICE '  2. Drop current database:';
        RAISE NOTICE '     dropdb copyjob';
        RAISE NOTICE '  3. Restore from backup:';
        RAISE NOTICE '     createdb copyjob';
        RAISE NOTICE '     pg_restore -d copyjob /data/cold/ntt-backup/pgdump/copyjob-2025-11-15T06:15:01-08:00.pgdump';
        RAISE NOTICE '';
        RAISE EXCEPTION 'Manual rollback required - see instructions above';

    ELSE
        RAISE WARNING 'Unexpected state: has_old_tables=%, has_new_tables=%', has_old_tables, has_new_tables;
        RAISE EXCEPTION 'Cannot determine rollback strategy - database in inconsistent state';
    END IF;
END $$;

\echo ''
\echo '================================================================================'
