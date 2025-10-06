-- Author: PB and Claude
-- Date: 2025-10-06
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/sql/migrate-to-p2p-fk-step1-add-partition-fks.sql
--
-- Phase 2B: Migrate from parent-level FK to partition-to-partition FK
-- Step 1: Add partition-level FK constraints as NOT VALID (instant, no data scan)
--
-- This step is INSTANT - it does not scan existing data
-- NOT VALID means the constraint is enforced for new data but existing data is not checked
-- We'll validate existing data in Step 2
--
-- Expected time: <5 seconds for all 17 partitions

\timing on
\set ON_ERROR_STOP on

BEGIN;

\echo '=========================================='
\echo 'Step 1: Adding partition-level FK constraints (NOT VALID)'
\echo 'Expected time: <5 seconds'
\echo 'This step does NOT scan data - it is instant'
\echo '=========================================='
\echo ''

-- Create partition-level FK constraints for all partition pairs
-- Pattern: path_p_XXXXXXXX → inode_p_XXXXXXXX
DO $step1$
DECLARE
    partition_hash text;
    partition_count int := 0;
    total_partitions int;
BEGIN
    -- Count total partitions
    SELECT COUNT(*) INTO total_partitions
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname LIKE 'path_p_%'
      AND c.relkind = 'r'  -- Only regular tables, not indexes
      AND c.relispartition
      AND n.nspname = 'public';

    RAISE NOTICE 'Found % path partitions to migrate', total_partitions;
    RAISE NOTICE '';

    -- Add FK constraint for each partition pair
    FOR partition_hash IN
        SELECT regexp_replace(c.relname, 'path_p_', '')
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relname LIKE 'path_p_%'
          AND c.relkind = 'r'  -- Only regular tables, not indexes
          AND c.relispartition
          AND n.nspname = 'public'
        ORDER BY c.relname
    LOOP
        -- Create FK constraint as NOT VALID (instant operation)
        EXECUTE format(
            'ALTER TABLE path_p_%s
             ADD CONSTRAINT fk_path_to_inode_p_%s
             FOREIGN KEY (medium_hash, ino)
             REFERENCES inode_p_%s (medium_hash, ino)
             ON DELETE CASCADE
             NOT VALID;',
            partition_hash, partition_hash, partition_hash
        );

        partition_count := partition_count + 1;
        RAISE NOTICE '[%/%] ✓ Added NOT VALID FK for partition: path_p_% → inode_p_%',
                     partition_count, total_partitions, partition_hash, partition_hash;
    END LOOP;

    RAISE NOTICE '';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Successfully added % partition-level FK constraints', partition_count;
    RAISE NOTICE 'All constraints are NOT VALID (will validate in Step 2)';
    RAISE NOTICE '========================================';
END;
$step1$;

COMMIT;

\echo ''
\echo 'Step 1 complete. Constraints added but not yet validated.'
\echo 'Next: Run step2-validate.sql to validate existing data'
\echo ''

-- Verify constraints were created
\echo 'Verification: Listing new partition-level FK constraints...'
\echo ''

SELECT
    cl.relname as partition_table,
    c.conname as fk_constraint,
    cl2.relname as references_partition,
    CASE WHEN c.convalidated THEN 'VALID' ELSE 'NOT VALID' END as status
FROM pg_constraint c
JOIN pg_class cl ON cl.oid = c.conrelid
JOIN pg_class cl2 ON cl2.oid = c.confrelid
WHERE c.contype = 'f'
  AND cl.relname LIKE 'path_p_%'
  AND c.conname LIKE 'fk_path_to_inode_p_%'
ORDER BY cl.relname
LIMIT 5;

\echo ''
\echo '(Showing first 5 partitions - all should show "NOT VALID" status)'
\echo ''
