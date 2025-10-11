-- Author: PB and Claude
-- Date: 2025-10-11
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/tests/test_migration_validation.sql
--
-- Validation tests for BUG-007 migration (sql/03-add-status-model.sql)
--
-- Usage:
--   psql -d copyjob -f tests/test_migration_validation.sql

\echo '=================================='
\echo 'BUG-007 Migration Validation Tests'
\echo '=================================='
\echo ''

-- ============================================================================
-- TEST 1: Verify columns exist with correct types
-- ============================================================================
\echo 'TEST 1: Verify status and error_type columns exist'

SELECT
    column_name,
    data_type,
    is_nullable,
    column_default
FROM information_schema.columns
WHERE table_name = 'inode'
  AND column_name IN ('status', 'error_type')
ORDER BY column_name;

\echo 'Expected: status (text, nullable, default pending), error_type (text, nullable, no default)'
\echo ''

-- ============================================================================
-- TEST 2: Verify CHECK constraints exist
-- ============================================================================
\echo 'TEST 2: Verify CHECK constraints on status and error_type'

SELECT
    conname as constraint_name,
    pg_get_constraintdef(oid) as constraint_definition
FROM pg_constraint
WHERE conrelid = 'inode'::regclass
  AND contype = 'c'
  AND (conname LIKE '%status%' OR conname LIKE '%error_type%')
ORDER BY conname;

\echo 'Expected: Constraints for status values and error_type values'
\echo ''

-- ============================================================================
-- TEST 3: Verify indexes were created
-- ============================================================================
\echo 'TEST 3: Verify new indexes exist'

SELECT
    indexname,
    indexdef
FROM pg_indexes
WHERE tablename = 'inode'
  AND indexname IN ('idx_inode_status_queue', 'idx_inode_error_type', 'idx_inode_failed_by_type')
ORDER BY indexname;

\echo 'Expected: 3 indexes for status querying'
\echo ''

-- ============================================================================
-- TEST 4: Verify data migration correctness
-- ============================================================================
\echo 'TEST 4: Verify status values are correct for existing data'

-- Check successful inodes have status='success'
SELECT
    'Success check' as test,
    COUNT(*) as count,
    COUNT(*) FILTER (WHERE status = 'success') as status_success_count,
    CASE
        WHEN COUNT(*) = COUNT(*) FILTER (WHERE status = 'success')
        THEN 'PASS'
        ELSE 'FAIL'
    END as result
FROM inode
WHERE blobid IS NOT NULL
LIMIT 1;

-- Check old failures have status='failed_retryable'
SELECT
    'Old failures check' as test,
    COUNT(*) as count,
    COUNT(*) FILTER (WHERE status = 'failed_retryable') as status_retryable_count,
    CASE
        WHEN COUNT(*) = COUNT(*) FILTER (WHERE status = 'failed_retryable')
        THEN 'PASS'
        ELSE 'FAIL'
    END as result
FROM inode
WHERE copied = true AND blobid IS NULL
LIMIT 1;

-- Check pending inodes have status='pending'
SELECT
    'Pending check' as test,
    COUNT(*) as count,
    COUNT(*) FILTER (WHERE status = 'pending') as status_pending_count,
    CASE
        WHEN COUNT(*) = COUNT(*) FILTER (WHERE status = 'pending')
        THEN 'PASS'
        ELSE 'FAIL'
    END as result
FROM inode
WHERE copied = false
LIMIT 1;

\echo 'Expected: All checks should show PASS'
\echo ''

-- ============================================================================
-- TEST 5: Verify no invalid states
-- ============================================================================
\echo 'TEST 5: Verify no invalid state combinations'

-- Success must have blobid
SELECT
    'Success without blobid' as invalid_state,
    COUNT(*) as count,
    CASE
        WHEN COUNT(*) = 0 THEN 'PASS'
        ELSE 'FAIL - INVALID STATE'
    END as result
FROM inode
WHERE status = 'success' AND blobid IS NULL;

-- Failures should not have blobid
SELECT
    'Failure with blobid' as invalid_state,
    COUNT(*) as count,
    CASE
        WHEN COUNT(*) = 0 THEN 'PASS'
        ELSE 'FAIL - INVALID STATE'
    END as result
FROM inode
WHERE status IN ('failed_retryable', 'failed_permanent') AND blobid IS NOT NULL;

\echo 'Expected: All should be PASS (0 invalid states)'
\echo ''

-- ============================================================================
-- TEST 6: Verify status distribution
-- ============================================================================
\echo 'TEST 6: Status distribution summary'

SELECT
    status,
    COUNT(*) as count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) as percentage
FROM inode
GROUP BY status
ORDER BY count DESC;

\echo ''

-- ============================================================================
-- TEST 7: Verify error_type distribution for failures
-- ============================================================================
\echo 'TEST 7: Error type distribution (failures only)'

SELECT
    error_type,
    status,
    COUNT(*) as count
FROM inode
WHERE status IN ('failed_retryable', 'failed_permanent')
GROUP BY error_type, status
ORDER BY count DESC;

\echo 'Expected: Most old failures should have error_type=unknown'
\echo ''

-- ============================================================================
-- TEST 8: Test constraint enforcement
-- ============================================================================
\echo 'TEST 8: Test CHECK constraints prevent invalid values'

-- This should fail with constraint violation
BEGIN;
\echo 'Attempting to insert invalid status (should fail)...'
DO $$
BEGIN
    INSERT INTO inode (medium_hash, ino, status)
    VALUES ('test_invalid', 99999, 'invalid_status');
    RAISE EXCEPTION 'TEST FAILED: Invalid status was accepted!';
EXCEPTION
    WHEN check_violation THEN
        RAISE NOTICE 'PASS: Invalid status correctly rejected';
END $$;
ROLLBACK;

\echo ''

-- ============================================================================
-- Summary
-- ============================================================================
\echo '=================================='
\echo 'Validation Tests Complete'
\echo '=================================='
\echo ''
\echo 'Manual verification needed:'
\echo '  1. Check all TEST results show PASS'
\echo '  2. Verify status distribution matches expectations'
\echo '  3. Confirm no invalid state combinations exist'
\echo ''
