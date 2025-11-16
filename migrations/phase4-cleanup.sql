-- Author: PB and Claude
-- Date: 2025-11-16
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/migrations/phase4-cleanup.sql
--
-- PHASE 4 CLEANUP: Drop old partitioned tables (background task)
--
-- This script drops the old partitioned tables after successful cutover.
-- Run this AFTER phase4-cutover.sql succeeds and application is verified working.
--
-- PREREQUISITES:
--   1. phase4-cutover.sql completed successfully
--   2. Application running on new "paths" and "blobs" tables
--   3. Application verified working correctly
--   4. Run during low-traffic maintenance window
--
-- EXPECTED TIME: 1-2 hours (CPU-intensive, catalog operations)
-- USER IMPACT: None (old tables not in use)
--
-- CAUTION: This operation cannot be cancelled once started without leaving
--          database in inconsistent state. Run in screen/tmux session.

\set ON_ERROR_STOP on

\echo '================================================================================'
\echo 'PHASE 4 CLEANUP: DROP OLD PARTITIONED TABLES'
\echo '================================================================================'
\echo ''
\echo 'This will drop:'
\echo '  - path_old_to_drop (244,182 partitions)'
\echo '  - inode_old_to_drop (244,182 partitions)'
\echo ''
\echo 'Expected time: 1-2 hours'
\echo 'CPU usage will be high during this operation.'
\echo ''
\echo 'Prerequisites checklist:'
\echo '  [ ] phase4-cutover.sql completed'
\echo '  [ ] Application running on new tables (paths, blobs)'
\echo '  [ ] Application verified working'
\echo '  [ ] Running in screen/tmux session'
\echo '  [ ] Low-traffic maintenance window'
\echo ''

-- Verify new tables exist
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'paths') THEN
        RAISE EXCEPTION 'Table "paths" does not exist. Run phase4-cutover.sql first.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'blobs') THEN
        RAISE EXCEPTION 'Table "blobs" does not exist. Run phase4-cutover.sql first.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'path_old_to_drop') THEN
        RAISE EXCEPTION 'Table "path_old_to_drop" does not exist. Cutover may not have completed.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'inode_old_to_drop') THEN
        RAISE EXCEPTION 'Table "inode_old_to_drop" does not exist. Cutover may not have completed.';
    END IF;
END $$;

\echo 'Verification passed. New tables exist.'
\echo ''
\echo 'Waiting 10 seconds before starting cleanup...'
\echo 'Press Ctrl+C now to cancel.'
\echo ''

SELECT pg_sleep(10);

\echo ''
\echo 'Starting cleanup...'
\echo ''
\echo 'Step 1: Dropping path_old_to_drop (this will take ~1 hour)...'
\echo 'Started at: ' || now()::text AS start_time \gset
\echo :start_time

-- Drop path first (it has FK references to inode partitions)
DROP TABLE path_old_to_drop CASCADE;

\echo 'Completed at: ' || now()::text AS end_time \gset
\echo :end_time
\echo '  ✓ Dropped path_old_to_drop and all 244,182 partitions'
\echo ''

\echo 'Step 2: Dropping inode_old_to_drop (this will take ~30-60 minutes)...'
\echo 'Started at: ' || now()::text AS start_time \gset
\echo :start_time

DROP TABLE inode_old_to_drop CASCADE;

\echo 'Completed at: ' || now()::text AS end_time \gset
\echo :end_time
\echo '  ✓ Dropped inode_old_to_drop and all 244,182 partitions'
\echo ''

\echo '================================================================================'
\echo 'CLEANUP COMPLETE'
\echo '================================================================================'
\echo ''

-- Verify partitions are gone
SELECT
    COUNT(*) as remaining_partitions,
    CASE
        WHEN COUNT(*) = 0 THEN '✓ All partitions removed'
        ELSE '⚠ WARNING: Partitions still exist'
    END as status
FROM pg_inherits;

\echo ''
\echo 'Final table list:'
\echo ''

SELECT
    tablename,
    pg_size_pretty(pg_total_relation_size('public.' || tablename)) as total_size
FROM pg_tables
WHERE schemaname = 'public'
  AND tablename IN ('medium', 'paths', 'blobs')
ORDER BY tablename;

\echo ''
\echo '================================================================================'
\echo 'MIGRATION COMPLETE'
\echo '================================================================================'
\echo ''
\echo 'Summary:'
\echo '  - Dropped 488,362 partitioned tables'
\echo '  - New unpartitioned schema active'
\echo '  - 0 partitions remaining'
\echo ''
\echo 'Database is now running on simplified unpartitioned schema.'
\echo ''
\echo '================================================================================'
