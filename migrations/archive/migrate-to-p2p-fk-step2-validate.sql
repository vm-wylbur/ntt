-- Author: PB and Claude
-- Date: 2025-10-06
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/sql/migrate-to-p2p-fk-step2-validate.sql
--
-- Phase 2B: Migrate from parent-level FK to partition-to-partition FK
-- Step 2: Validate all partition-level FK constraints
--
-- This step SCANS data but does NOT block queries (validation happens in background)
-- Each partition validation takes ~30-60 seconds depending on row count
--
-- Expected time: ~8-15 minutes for all 17 partitions
-- Safe to run during production (non-blocking)

\timing on
\set ON_ERROR_STOP on

\echo '=========================================='
\echo 'Step 2: Validating partition-level FK constraints'
\echo 'Expected time: ~8-15 minutes for all 17 partitions'
\echo 'This step scans data but does NOT block queries'
\echo '=========================================='
\echo ''

-- Validate all partition FK constraints
-- This checks that all existing data satisfies the FK constraint
DO $step2$
DECLARE
    partition_hash text;
    partition_count int := 0;
    total_partitions int;
    start_time timestamp;
    validation_time interval;
    row_count bigint;
BEGIN
    -- Count total partitions
    SELECT COUNT(*) INTO total_partitions
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname LIKE 'path_p_%'
      AND c.relkind = 'r'  -- Only regular tables, not indexes
      AND c.relispartition
      AND n.nspname = 'public';

    RAISE NOTICE 'Validating FK constraints for % partitions...', total_partitions;
    RAISE NOTICE '';

    -- Validate FK constraint for each partition
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
        -- Get row count for progress reporting
        EXECUTE format('SELECT COUNT(*) FROM path_p_%s', partition_hash)
        INTO row_count;

        start_time := clock_timestamp();

        -- Validate the constraint (checks all existing data)
        EXECUTE format(
            'ALTER TABLE path_p_%s
             VALIDATE CONSTRAINT fk_path_to_inode_p_%s;',
            partition_hash, partition_hash
        );

        validation_time := clock_timestamp() - start_time;
        partition_count := partition_count + 1;

        RAISE NOTICE '[%/%] ✓ Validated FK for path_p_% (% rows) in %',
                     partition_count, total_partitions, partition_hash,
                     row_count, validation_time;
    END LOOP;

    RAISE NOTICE '';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Successfully validated % partition-level FK constraints', partition_count;
    RAISE NOTICE 'All constraints are now VALID and enforced';
    RAISE NOTICE '========================================';
END;
$step2$;

\echo ''
\echo 'Step 2 complete. All partition-level FK constraints validated.'
\echo 'Next: Run step3-drop-parent-fk.sql to remove parent-level FK'
\echo ''

-- Verify all constraints are now VALID
\echo 'Verification: Checking constraint status...'
\echo ''

SELECT
    COUNT(*) as total_constraints,
    SUM(CASE WHEN c.convalidated THEN 1 ELSE 0 END) as validated_constraints,
    SUM(CASE WHEN NOT c.convalidated THEN 1 ELSE 0 END) as not_validated_constraints
FROM pg_constraint c
JOIN pg_class cl ON cl.oid = c.conrelid
WHERE c.contype = 'f'
  AND cl.relname LIKE 'path_p_%'
  AND c.conname LIKE 'fk_path_to_inode_p_%';

\echo ''
\echo 'Expected: total_constraints = 17+, validated_constraints = 17+, not_validated_constraints = 0'
\echo ''

-- Check for any FK violations (should be zero)
\echo 'Checking for FK violations (should find none)...'
\echo ''

DO $check$
DECLARE
    partition_hash text;
    violation_count bigint;
    total_violations bigint := 0;
BEGIN
    FOR partition_hash IN
        SELECT regexp_replace(c.relname, 'path_p_', '')
        FROM pg_class c
        WHERE c.relname LIKE 'path_p_%'
          AND c.relkind = 'r'  -- Only regular tables, not indexes
          AND c.relispartition
        ORDER BY c.relname
    LOOP
        EXECUTE format(
            'SELECT COUNT(*)
             FROM path_p_%s p
             LEFT JOIN inode_p_%s i ON (p.medium_hash, p.ino) = (i.medium_hash, i.ino)
             WHERE i.ino IS NULL',
            partition_hash, partition_hash
        ) INTO violation_count;

        IF violation_count > 0 THEN
            RAISE WARNING 'Found % orphaned rows in path_p_%', violation_count, partition_hash;
            total_violations := total_violations + violation_count;
        END IF;
    END LOOP;

    IF total_violations = 0 THEN
        RAISE NOTICE '✓ No FK violations found - all data is valid';
    ELSE
        RAISE EXCEPTION 'Found % total FK violations - data integrity issue!', total_violations;
    END IF;
END;
$check$;

\echo ''
