-- Author: PB and Claude
-- Date: 2025-10-06
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/sql/migrate-to-p2p-fk-rollback.sql
--
-- Phase 2B: Rollback script for partition-to-partition FK migration
--
-- EMERGENCY USE ONLY: Use this to rollback to parent-level FK if migration fails
--
-- Expected time: ~2 minutes

\timing on
\set ON_ERROR_STOP on

BEGIN;

\echo '=========================================='
\echo 'ROLLBACK: Reverting to parent-level FK'
\echo 'WARNING: This is an emergency rollback procedure'
\echo '=========================================='
\echo ''

-- Step 1: Drop all partition-level FK constraints
\echo '[1/2] Dropping partition-level FK constraints...'

DO $rollback_drop$
DECLARE
    partition_hash text;
    partition_count int := 0;
    total_partitions int;
BEGIN
    SELECT COUNT(*) INTO total_partitions
    FROM pg_class c
    WHERE c.relname LIKE 'path_p_%' AND c.relispartition;

    FOR partition_hash IN
        SELECT regexp_replace(c.relname, 'path_p_', '')
        FROM pg_class c
        WHERE c.relname LIKE 'path_p_%' AND c.relispartition
        ORDER BY c.relname
    LOOP
        -- Drop FK constraint if it exists
        BEGIN
            EXECUTE format(
                'ALTER TABLE path_p_%s DROP CONSTRAINT IF EXISTS fk_path_to_inode_p_%s;',
                partition_hash, partition_hash
            );
            partition_count := partition_count + 1;
            RAISE NOTICE '[%/%] Dropped FK for partition: path_p_%',
                         partition_count, total_partitions, partition_hash;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE WARNING 'Failed to drop FK for partition path_p_%: %',
                             partition_hash, SQLERRM;
        END;
    END LOOP;

    RAISE NOTICE 'Dropped FK constraints for % partitions', partition_count;
END;
$rollback_drop$;

\echo ''

-- Step 2: Recreate parent-level FK
\echo '[2/2] Recreating parent-level FK constraint...'

DO $rollback_create$
DECLARE
    parent_fk_exists int;
BEGIN
    -- Check if parent FK already exists
    SELECT COUNT(*) INTO parent_fk_exists
    FROM pg_constraint c
    JOIN pg_class cl ON cl.oid = c.conrelid
    JOIN pg_class cl2 ON cl2.oid = c.confrelid
    WHERE c.contype = 'f'
      AND cl.relname = 'path'
      AND cl2.relname = 'inode';

    IF parent_fk_exists > 0 THEN
        RAISE WARNING 'Parent-level FK already exists - skipping creation';
        RETURN;
    END IF;

    -- Recreate parent-level FK
    ALTER TABLE path
        ADD CONSTRAINT path_medium_hash_ino_fkey
        FOREIGN KEY (medium_hash, ino)
        REFERENCES inode (medium_hash, ino)
        ON DELETE CASCADE;

    RAISE NOTICE '✓ Parent-level FK constraint recreated';
END;
$rollback_create$;

COMMIT;

\echo ''
\echo '=========================================='
\echo 'Rollback complete'
\echo 'Reverted to parent-level FK architecture'
\echo '=========================================='
\echo ''

-- Verify rollback
\echo 'Verification:'
\echo ''

SELECT
    'Parent-level FK' as fk_type,
    COUNT(*) as count,
    CASE
        WHEN COUNT(*) = 1 THEN '✓ Rollback successful'
        ELSE '✗ Rollback may have failed'
    END as status
FROM pg_constraint c
JOIN pg_class cl ON cl.oid = c.conrelid
JOIN pg_class cl2 ON cl2.oid = c.confrelid
WHERE c.contype = 'f'
  AND cl.relname = 'path'
  AND cl2.relname = 'inode'
UNION ALL
SELECT
    'Partition-level FKs' as fk_type,
    COUNT(*) as count,
    CASE
        WHEN COUNT(*) = 0 THEN '✓ All partition FKs removed'
        ELSE '⚠ Some partition FKs remain'
    END as status
FROM pg_constraint c
JOIN pg_class cl ON cl.oid = c.conrelid
WHERE c.contype = 'f'
  AND cl.relname LIKE 'path_p_%'
  AND c.conname LIKE 'fk_path_to_inode_p_%';

\echo ''
