-- Author: PB and Claude
-- Date: 2025-10-05
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/sql/partition-migration-step4-add-trigger.sql
--
-- PARTITION MIGRATION - STEP 4: Re-create triggers on new tables
--
-- The queue_stats trigger needs to be recreated on the new partitioned inode table

BEGIN;

-- Check if queue_stats table exists (might need to be created)
CREATE TABLE IF NOT EXISTS queue_stats (
    medium_hash TEXT PRIMARY KEY,
    unclaimed_count INT DEFAULT 0
);

-- Check if the trigger function exists
-- (Assuming it was created in a previous migration - we need to verify)

-- Recreate the trigger on inode_new
CREATE TRIGGER trigger_queue_stats_new
    AFTER INSERT OR UPDATE ON inode_new
    FOR EACH ROW
    EXECUTE FUNCTION update_queue_stats();

-- Note: After cutover, we'll drop the trigger from the old inode table

COMMIT;

-- ============================================================================
-- VERIFICATION
-- ============================================================================

-- List triggers on both tables
SELECT
    tgname as trigger_name,
    tgrelid::regclass as table_name,
    tgtype,
    tgenabled
FROM pg_trigger
WHERE tgrelid IN ('inode'::regclass, 'inode_new'::regclass)
  AND tgname NOT LIKE 'RI_%'  -- Exclude FK triggers
ORDER BY table_name, trigger_name;
