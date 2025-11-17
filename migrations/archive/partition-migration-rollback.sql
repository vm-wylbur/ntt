-- Author: PB and Claude
-- Date: 2025-10-05
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/sql/partition-migration-rollback.sql
--
-- PARTITION MIGRATION - ROLLBACK: Safely remove partitioned tables
--
-- Use this script to rollback the migration if problems are discovered
-- BEFORE cutover (step 5)
--
-- After cutover, rollback is more complex (reverse the rename operations)

-- ============================================================================
-- ROLLBACK BEFORE CUTOVER (if step 5 hasn't run)
-- ============================================================================

BEGIN;

-- Drop foreign key first (prevents cascade issues)
ALTER TABLE path_new DROP CONSTRAINT IF EXISTS path_new_medium_hash_ino_fkey;

-- Drop partitioned tables (CASCADE drops all partitions)
DROP TABLE IF EXISTS inode_new CASCADE;
DROP TABLE IF EXISTS path_new CASCADE;

COMMIT;

-- Verify old tables still exist and are intact
SELECT 'inode' as table_name, count(*) as row_count FROM inode;
SELECT 'path' as table_name, count(*) as row_count FROM path;

\echo 'Rollback complete - old tables still active'

-- ============================================================================
-- ROLLBACK AFTER CUTOVER (if step 5 has run)
-- ============================================================================

-- If cutover was performed and you need to revert:

-- BEGIN;

-- -- Rename partitioned tables back to _new suffix
-- ALTER TABLE inode RENAME TO inode_new;
-- ALTER TABLE path RENAME TO path_new;

-- -- Rename old tables back to production names
-- ALTER TABLE inode_old RENAME TO inode;
-- ALTER TABLE path_old RENAME TO path;

-- -- Revert index renames (sample - adjust based on what was renamed)
-- ALTER INDEX inode_pkey RENAME TO inode_old_pkey;
-- ALTER INDEX inode_old_pkey_original RENAME TO inode_pkey;  -- etc.

-- -- Revert trigger
-- DROP TRIGGER IF EXISTS trigger_queue_stats ON inode_new;
-- -- Recreate trigger on old table if needed

-- COMMIT;

-- WARNING: Post-cutover rollback is complex and risky.
-- Only use if absolutely necessary and after careful verification.
