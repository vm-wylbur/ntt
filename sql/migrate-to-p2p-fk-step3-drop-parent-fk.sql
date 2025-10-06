-- Author: PB and Claude
-- Date: 2025-10-06
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/sql/migrate-to-p2p-fk-step3-drop-parent-fk.sql
--
-- Phase 2B: Migrate from parent-level FK to partition-to-partition FK
-- Step 3: Drop parent-level FK constraint
--
-- CRITICAL: Only run this AFTER Step 2 completes successfully
-- This step is INSTANT - no data scan required
--
-- Expected time: <1 second

\timing on
\set ON_ERROR_STOP on

BEGIN;

\echo '=========================================='
\echo 'Step 3: Dropping parent-level FK constraint'
\echo 'Expected time: <1 second'
\echo '=========================================='
\echo ''

-- First, verify that all partition-level FKs are VALID
DO $preflight$
DECLARE
    not_validated_count int;
BEGIN
    SELECT COUNT(*) INTO not_validated_count
    FROM pg_constraint c
    JOIN pg_class cl ON cl.oid = c.conrelid
    WHERE c.contype = 'f'
      AND cl.relname LIKE 'path_p_%'
      AND c.conname LIKE 'fk_path_to_inode_p_%'
      AND NOT c.convalidated;

    IF not_validated_count > 0 THEN
        RAISE EXCEPTION 'Found % partition FK constraints that are NOT VALID! Run step2-validate.sql first.', not_validated_count;
    END IF;

    RAISE NOTICE '✓ Preflight check passed: All % partition-level FKs are VALID',
                 (SELECT COUNT(*) FROM pg_constraint c JOIN pg_class cl ON cl.oid = c.conrelid
                  WHERE c.contype = 'f' AND cl.relname LIKE 'path_p_%' AND c.conname LIKE 'fk_path_to_inode_p_%');
END;
$preflight$;

\echo ''

-- Find and drop the parent-level FK constraint
DO $drop_parent_fk$
DECLARE
    parent_fk_name text;
    parent_fk_count int;
BEGIN
    -- Find parent-level FK constraint name
    SELECT c.conname INTO parent_fk_name
    FROM pg_constraint c
    JOIN pg_class cl ON cl.oid = c.conrelid
    JOIN pg_class cl2 ON cl2.oid = c.confrelid
    WHERE c.contype = 'f'
      AND cl.relname = 'path'
      AND cl2.relname = 'inode';

    IF parent_fk_name IS NULL THEN
        RAISE WARNING 'No parent-level FK constraint found (may already be dropped)';
        RETURN;
    END IF;

    RAISE NOTICE 'Found parent-level FK constraint: %', parent_fk_name;
    RAISE NOTICE 'Dropping parent-level FK...';

    -- Drop the parent-level FK
    EXECUTE format('ALTER TABLE path DROP CONSTRAINT %I;', parent_fk_name);

    RAISE NOTICE '✓ Successfully dropped parent-level FK constraint: %', parent_fk_name;

    -- Verify it's gone
    SELECT COUNT(*) INTO parent_fk_count
    FROM pg_constraint c
    JOIN pg_class cl ON cl.oid = c.conrelid
    JOIN pg_class cl2 ON cl2.oid = c.confrelid
    WHERE c.contype = 'f'
      AND cl.relname = 'path'
      AND cl2.relname = 'inode';

    IF parent_fk_count > 0 THEN
        RAISE EXCEPTION 'Parent-level FK still exists after drop attempt!';
    END IF;

    RAISE NOTICE '✓ Verified: Parent-level FK successfully removed';
END;
$drop_parent_fk$;

COMMIT;

\echo ''
\echo '=========================================='
\echo 'Step 3 complete. Parent-level FK removed.'
\echo 'Next: Run step4-verify.sql to verify new architecture'
\echo '=========================================='
\echo ''

-- Show current FK architecture
\echo 'Current FK architecture (first 5 partitions):'
\echo ''

SELECT
    cl.relname as partition_table,
    c.conname as fk_constraint,
    cl2.relname as references_partition,
    'VALID' as status
FROM pg_constraint c
JOIN pg_class cl ON cl.oid = c.conrelid
JOIN pg_class cl2 ON cl2.oid = c.confrelid
WHERE c.contype = 'f'
  AND cl.relname LIKE 'path_p_%'
ORDER BY cl.relname
LIMIT 5;

\echo ''
\echo 'Verify: All FKs should be partition-to-partition (path_p_XXXXXXXX → inode_p_XXXXXXXX)'
\echo ''
