-- Author: PB and Claude
-- Date: 2025-10-11
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/tests/test_migration_sample.sql
--
-- Test BUG-007 migration on small sample

\echo '=================================='
\echo 'BUG-007 Migration Test on Sample'
\echo '=================================='
\echo ''

BEGIN;

-- ============================================================================
-- Step 1: Create test table with sample data
-- ============================================================================
\echo 'Step 1: Creating test table with sample data...'

CREATE TABLE inode_test (LIKE inode INCLUDING ALL);

-- Get diverse sample: successes, failures, pending
-- Success cases (have blobid)
INSERT INTO inode_test
SELECT * FROM inode
WHERE blobid IS NOT NULL
LIMIT 300;

-- Old failure cases (copied=true but no blobid)
INSERT INTO inode_test
SELECT * FROM inode
WHERE copied = true AND blobid IS NULL
LIMIT 100;

-- Pending cases (not yet copied)
INSERT INTO inode_test
SELECT * FROM inode
WHERE copied = false
LIMIT 600;

\echo ''
SELECT 'Test table created with ' || COUNT(*) || ' rows' as status FROM inode_test;
\echo ''

-- ============================================================================
-- Step 2: Show baseline state
-- ============================================================================
\echo 'Step 2: Baseline state before migration'
\echo ''

SELECT
    CASE
        WHEN blobid IS NOT NULL THEN 'success'
        WHEN copied = true AND blobid IS NULL THEN 'old_failure'
        WHEN copied = false THEN 'pending'
    END as current_state,
    COUNT(*) as count
FROM inode_test
GROUP BY current_state
ORDER BY current_state;

\echo ''

-- ============================================================================
-- Step 3: Apply migration (add columns)
-- ============================================================================
\echo 'Step 3: Adding status and error_type columns...'

ALTER TABLE inode_test
ADD COLUMN status TEXT DEFAULT 'pending'
    CHECK (status IN ('pending', 'success', 'failed_retryable', 'failed_permanent'));

ALTER TABLE inode_test
ADD COLUMN error_type TEXT
    CHECK (error_type IS NULL OR error_type IN (
        'path_error', 'io_error', 'hash_error', 'permission_error', 'unknown'
    ));

\echo '✓ Columns added'
\echo ''

-- ============================================================================
-- Step 4: Migrate data
-- ============================================================================
\echo 'Step 4: Migrating data...'

-- Mark successful copies
UPDATE inode_test
SET status = 'success'
WHERE blobid IS NOT NULL;

\echo '  Updated ' || (SELECT COUNT(*) FROM inode_test WHERE status = 'success') || ' rows to success'

-- Mark failed copies as retryable
UPDATE inode_test
SET status = 'failed_retryable',
    error_type = 'unknown'
WHERE copied = true AND blobid IS NULL;

\echo '  Updated ' || (SELECT COUNT(*) FROM inode_test WHERE status = 'failed_retryable') || ' rows to failed_retryable'

-- Pending items remain status='pending' from default
\echo '  Left ' || (SELECT COUNT(*) FROM inode_test WHERE status = 'pending') || ' rows as pending'
\echo ''

-- ============================================================================
-- Step 5: Validation checks
-- ============================================================================
\echo 'Step 5: Running validation checks...'
\echo ''

-- Check 1: Status distribution
\echo 'Check 1: Status distribution'
SELECT status, COUNT(*) as count
FROM inode_test
GROUP BY status
ORDER BY status;
\echo ''

-- Check 2: No invalid states (success without blobid)
\echo 'Check 2: Invalid states (should be 0)'
SELECT
    'Success without blobid' as invalid_state,
    COUNT(*) as count,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END as result
FROM inode_test
WHERE status = 'success' AND blobid IS NULL;

SELECT
    'Failure with blobid' as invalid_state,
    COUNT(*) as count,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END as result
FROM inode_test
WHERE status IN ('failed_retryable', 'failed_permanent') AND blobid IS NOT NULL;
\echo ''

-- Check 3: Constraint enforcement
\echo 'Check 3: Testing constraint enforcement...'
DO $$
BEGIN
    BEGIN
        UPDATE inode_test
        SET status = 'invalid_status'
        WHERE medium_hash = (SELECT medium_hash FROM inode_test LIMIT 1)
          AND ino = (SELECT ino FROM inode_test LIMIT 1);
        RAISE EXCEPTION 'FAIL: Invalid status was accepted!';
    EXCEPTION
        WHEN check_violation THEN
            RAISE NOTICE 'PASS: Invalid status correctly rejected';
    END;
END $$;
\echo ''

-- Check 4: All rows migrated correctly
\echo 'Check 4: Migration correctness'
SELECT
    CASE
        WHEN COUNT(*) = COUNT(*) FILTER (
            WHERE (blobid IS NOT NULL AND status = 'success')
               OR (copied = true AND blobid IS NULL AND status = 'failed_retryable')
               OR (copied = false AND status = 'pending')
        ) THEN 'PASS: All rows migrated correctly'
        ELSE 'FAIL: Some rows have incorrect status'
    END as result,
    COUNT(*) as total_rows,
    COUNT(*) FILTER (WHERE status = 'success') as success_count,
    COUNT(*) FILTER (WHERE status = 'failed_retryable') as failed_count,
    COUNT(*) FILTER (WHERE status = 'pending') as pending_count
FROM inode_test;
\echo ''

-- ============================================================================
-- Summary
-- ============================================================================
\echo '=================================='
\echo 'Migration Test Summary'
\echo '=================================='
\echo ''
\echo 'The migration logic has been tested on a sample of 1000 rows.'
\echo ''
\echo 'Review the results above. If all checks PASS:'
\echo '  - Status column works correctly'
\echo '  - Data migration logic is sound'
\echo '  - Constraints prevent invalid states'
\echo '  - Ready to consider full migration'
\echo ''
\echo 'Next step: Review and decide whether to proceed with full migration'
\echo ''

-- Cleanup
DROP TABLE inode_test;

\echo 'Test table cleaned up.'
\echo ''

ROLLBACK;  -- Don't commit - this is just a test
