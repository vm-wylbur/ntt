-- Author: PB and Claude
-- Date: 2025-10-11
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/tests/setup_test_scenarios.sql
--
-- Create test scenarios for BUG-007 testing
--
-- Usage:
--   psql -d copyjob -f tests/setup_test_scenarios.sql
--
-- This creates test inodes in various states to verify the fix works correctly

\echo '=================================='
\echo 'BUG-007 Test Scenario Setup'
\echo '=================================='
\echo ''

BEGIN;

-- ============================================================================
-- Choose a test medium (or create one)
-- ============================================================================
\echo 'Step 1: Select test medium'
\echo ''

-- Show available test media (small ones for safety)
SELECT
    medium_hash,
    medium_human,
    COUNT(*) as inode_count
FROM inode
JOIN medium USING (medium_hash)
GROUP BY medium_hash, medium_human
HAVING COUNT(*) < 1000
ORDER BY inode_count
LIMIT 5;

\echo ''
\echo 'Please choose a test medium from above (prefer smallest one)'
\echo 'Set it: \set test_medium ''<hash>'''
\echo ''

-- Example: \set test_medium 'abc123def456'

-- ============================================================================
-- Scenario 1: Create path_error failures
-- ============================================================================
\echo 'Scenario 1: Simulating path_error failures'

-- Find some pending inodes and mark them as failed with path_error
-- UPDATE inode
-- SET status = 'failed_retryable',
--     error_type = 'path_error',
--     copied = true,
--     errors = ARRAY['FileNotFoundError: No such file or directory: /mnt/ntt/:test_medium/data/absolute/path/file.txt']
-- WHERE medium_hash = :'test_medium'
--   AND status = 'pending'
--   AND copied = false
-- LIMIT 5
-- RETURNING ino, status, error_type;

\echo 'Uncomment the UPDATE above and replace :test_medium with your hash'
\echo ''

-- ============================================================================
-- Scenario 2: Create io_error failures (permanent)
-- ============================================================================
\echo 'Scenario 2: Simulating io_error failures (permanent)'

-- UPDATE inode
-- SET status = 'failed_permanent',
--     error_type = 'io_error',
--     copied = true,
--     errors = ARRAY['OSError: Input/output error']
-- WHERE medium_hash = :'test_medium'
--   AND status = 'pending'
--   AND copied = false
-- LIMIT 3
-- RETURNING ino, status, error_type;

\echo 'Uncomment the UPDATE above and replace :test_medium with your hash'
\echo ''

-- ============================================================================
-- Scenario 3: Create permission_error failures
-- ============================================================================
\echo 'Scenario 3: Simulating permission_error failures'

-- UPDATE inode
-- SET status = 'failed_retryable',
--     error_type = 'permission_error',
--     copied = true,
--     errors = ARRAY['PermissionError: Permission denied']
-- WHERE medium_hash = :'test_medium'
--   AND status = 'pending'
--   AND copied = false
-- LIMIT 2
-- RETURNING ino, status, error_type;

\echo 'Uncomment the UPDATE above and replace :test_medium with your hash'
\echo ''

-- ============================================================================
-- Scenario 4: Verify test scenarios created
-- ============================================================================
\echo 'Scenario 4: Verify test setup'

-- Show test scenario summary
-- SELECT
--     status,
--     error_type,
--     COUNT(*) as count
-- FROM inode
-- WHERE medium_hash = :'test_medium'
-- GROUP BY status, error_type
-- ORDER BY status, error_type;

\echo 'Uncomment the SELECT above to see test scenario summary'
\echo ''

-- ============================================================================
-- Rollback or Commit
-- ============================================================================
\echo '=================================='
\echo 'Review changes above. Type:'
\echo '  COMMIT;   to apply test scenarios'
\echo '  ROLLBACK; to cancel'
\echo '=================================='

-- Don't auto-commit - let user decide
ROLLBACK;  -- Change to COMMIT after reviewing
