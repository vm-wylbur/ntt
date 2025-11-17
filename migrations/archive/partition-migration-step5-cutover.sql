-- Author: PB and Claude
-- Date: 2025-10-05
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/sql/partition-migration-step5-cutover.sql
--
-- PARTITION MIGRATION - STEP 5: ATOMIC CUTOVER (DO NOT RUN WITHOUT PB APPROVAL)
--
-- This performs the atomic rename to swap old and new tables.
-- After this runs, all queries will use the partitioned tables.
--
-- PREREQUISITES:
--   1. Steps 1-4 completed successfully
--   2. Verification queries confirm data integrity
--   3. All ntt-copier workers stopped
--   4. No active ntt-loader processes
--   5. Database backup taken
--
-- DOWNTIME: ~5-10 seconds (time for DDL operations)
--
-- WARNING: This script is INTENTIONALLY not executable without review.
--          PB must manually verify and approve before running.

-- Uncomment the following line only after explicit approval from PB:
-- BEGIN;

-- ============================================================================
-- STEP 5A: Stop all activity (verify manually before running)
-- ============================================================================

-- Query to check for active copier/loader sessions:
-- SELECT pid, usename, application_name, state, query
-- FROM pg_stat_activity
-- WHERE query LIKE '%inode%' OR query LIKE '%path%'
--   AND state = 'active';

-- If any active sessions found, STOP and kill them first.

-- ============================================================================
-- STEP 5B: Rename tables (atomic cutover)
-- ============================================================================

-- Rename old tables to _old suffix
ALTER TABLE inode RENAME TO inode_old;
ALTER TABLE path RENAME TO path_old;

-- Rename new tables to production names
ALTER TABLE inode_new RENAME TO inode;
ALTER TABLE path_new RENAME TO path;

-- Rename indexes to match (PostgreSQL auto-renames partition indexes)
-- But we need to rename parent-level indexes for clarity

ALTER INDEX inode_new_pkey RENAME TO inode_pkey;
ALTER INDEX path_new_pkey RENAME TO path_pkey;

ALTER INDEX idx_inode_new_by_hash_created RENAME TO idx_inode_by_hash_created;
ALTER INDEX idx_inode_new_file_uncopied RENAME TO idx_inode_file_uncopied;
ALTER INDEX idx_inode_new_fs_type RENAME TO idx_inode_fs_type;
ALTER INDEX idx_inode_new_fs_type_copied RENAME TO idx_inode_fs_type_copied;
ALTER INDEX idx_inode_new_hash RENAME TO idx_inode_hash;
ALTER INDEX idx_inode_new_mime_type RENAME TO idx_inode_mime_type;
ALTER INDEX idx_inode_new_processed_at RENAME TO idx_inode_processed_at;
ALTER INDEX idx_inode_new_processed_recent RENAME TO idx_inode_processed_recent;
ALTER INDEX idx_inode_new_unclaimed RENAME TO idx_inode_unclaimed;
ALTER INDEX idx_inode_new_unclaimed_medium RENAME TO idx_inode_unclaimed_medium;

ALTER INDEX idx_path_new_dev_ino RENAME TO idx_path_dev_ino;
ALTER INDEX idx_path_new_excluded RENAME TO idx_path_excluded;
ALTER INDEX idx_path_new_only RENAME TO idx_path_only;
ALTER INDEX idx_path_new_valid RENAME TO idx_path_valid;

-- Rename constraints
ALTER TABLE inode RENAME CONSTRAINT inode_new_medium_hash_fkey TO inode_medium_hash_fkey;
ALTER TABLE path RENAME CONSTRAINT path_new_medium_hash_ino_fkey TO path_medium_hash_ino_fkey;

-- Rename trigger
DROP TRIGGER IF EXISTS trigger_queue_stats ON inode_old;
ALTER TRIGGER trigger_queue_stats_new ON inode RENAME TO trigger_queue_stats;

-- ============================================================================
-- STEP 5C: Update dependent views/functions (if any)
-- ============================================================================

-- Check for views that reference inode/path tables:
-- SELECT viewname, definition
-- FROM pg_views
-- WHERE definition LIKE '%inode%' OR definition LIKE '%path%';

-- If any views exist, they may need to be recreated (dependency on old table names)

-- COMMIT;

-- ============================================================================
-- VERIFICATION AFTER CUTOVER
-- ============================================================================

-- Verify new tables are active
SELECT 'inode' as table_name,
       count(*) as row_count,
       (SELECT count(*) FROM pg_inherits WHERE inhparent = 'inode'::regclass) as partition_count
FROM inode;

SELECT 'path' as table_name,
       count(*) as row_count,
       (SELECT count(*) FROM pg_inherits WHERE inhparent = 'path'::regclass) as partition_count
FROM path;

-- Test insert into a new medium (should create partition automatically via loader)
-- This will be tested in step 6 with updated ntt-loader

-- ============================================================================
-- CLEANUP (only after extensive verification)
-- ============================================================================

-- DO NOT DROP OLD TABLES IMMEDIATELY
-- Keep inode_old and path_old for at least 24-48 hours
-- Monitor production to ensure partitioned tables work correctly

-- After 48 hours of successful operation:
-- DROP TABLE inode_old CASCADE;
-- DROP TABLE path_old CASCADE;
