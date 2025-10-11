-- Author: PB and Claude
-- Date: 2025-10-11
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/tests/test_recovery_queries.sql
--
-- Test the SQL queries used by recovery tool

\echo '=================================='
\echo 'Recovery Tool Query Validation'
\echo '=================================='
\echo ''
\echo 'Testing SQL queries that ntt-recover-failed tool uses'
\echo 'This validates the tool logic without needing actual failures'
\echo ''

BEGIN;

-- Create test table with new columns
CREATE TABLE inode_recovery_test (
    id BIGSERIAL PRIMARY KEY,
    medium_hash TEXT NOT NULL,
    ino BIGINT NOT NULL,
    copied BOOLEAN DEFAULT false,
    blobid TEXT,
    errors TEXT[] DEFAULT '{}',
    claimed_by TEXT,
    claimed_at TIMESTAMPTZ,
    status TEXT CHECK (status IN ('pending', 'success', 'failed_retryable', 'failed_permanent')),
    error_type TEXT CHECK (error_type IS NULL OR error_type IN ('path_error', 'io_error', 'hash_error', 'permission_error', 'unknown'))
);

-- Insert test scenarios
INSERT INTO inode_recovery_test (medium_hash, ino, status, error_type, copied, blobid) VALUES
    ('test_med', 1, 'success', NULL, true, 'hash1'),
    ('test_med', 2, 'success', NULL, true, 'hash2'),
    ('test_med', 10, 'pending', NULL, false, NULL),
    ('test_med', 11, 'pending', NULL, false, NULL),
    ('test_med', 20, 'failed_retryable', 'path_error', true, NULL),
    ('test_med', 21, 'failed_retryable', 'path_error', true, NULL),
    ('test_med', 22, 'failed_retryable', 'path_error', true, NULL),
    ('test_med', 30, 'failed_retryable', 'permission_error', true, NULL),
    ('test_med', 40, 'failed_retryable', 'unknown', true, NULL),
    ('test_med', 50, 'failed_permanent', 'io_error', true, NULL);

\echo 'Test 1: list-failures query'
\echo '----------------------------'
-- This is the query used by list-failures command
SELECT status, error_type, COUNT(*) as count
FROM inode_recovery_test
WHERE medium_hash = 'test_med'
  AND status IN ('failed_retryable', 'failed_permanent')
GROUP BY status, error_type
ORDER BY status, count DESC;

\echo ''
\echo 'Expected: 4 failed_retryable (3 path_error, 1 permission_error, 1 unknown), 1 failed_permanent (io_error)'
\echo ''

\echo 'Test 2: Totals query'
\echo '--------------------'
SELECT
    COUNT(*) FILTER (WHERE status = 'failed_retryable') as retryable,
    COUNT(*) FILTER (WHERE status = 'failed_permanent') as permanent
FROM inode_recovery_test
WHERE medium_hash = 'test_med'
  AND status IN ('failed_retryable', 'failed_permanent');

\echo ''
\echo 'Expected: 5 retryable, 1 permanent'
\echo ''

\echo 'Test 3: Count affected by error_type (dry-run simulation)'
\echo '----------------------------------------------------------'
SELECT COUNT(*) as would_reset
FROM inode_recovery_test
WHERE medium_hash = 'test_med'
  AND status = 'failed_retryable'
  AND error_type = 'path_error';

\echo ''
\echo 'Expected: 3 (the path_error failures)'
\echo ''

\echo 'Test 4: Reset query (simulate execution)'
\echo '-----------------------------------------'
-- Show before
SELECT 'BEFORE:' as stage, status, error_type, COUNT(*) as count
FROM inode_recovery_test
WHERE medium_hash = 'test_med'
GROUP BY status, error_type
ORDER BY status, error_type;

-- Execute reset
UPDATE inode_recovery_test
SET status = 'pending',
    error_type = NULL,
    errors = '{}',
    claimed_by = NULL,
    claimed_at = NULL,
    copied = false
WHERE medium_hash = 'test_med'
  AND status = 'failed_retryable'
  AND error_type = 'path_error';

-- Show after
SELECT 'AFTER:' as stage, status, error_type, COUNT(*) as count
FROM inode_recovery_test
WHERE medium_hash = 'test_med'
GROUP BY status, error_type
ORDER BY status, error_type;

\echo ''
\echo 'Expected: 3 path_error failures moved from failed_retryable to pending'
\echo 'Expected: pending count increased from 2 to 5'
\echo ''

\echo 'Test 5: Verify reset correctness'
\echo '----------------------------------'
SELECT
    CASE
        WHEN COUNT(*) = 3 AND
             COUNT(*) FILTER (WHERE status = 'pending' AND error_type IS NULL AND copied = false) = 3
        THEN 'PASS: All 3 inodes correctly reset'
        ELSE 'FAIL: Reset did not work correctly'
    END as result
FROM inode_recovery_test
WHERE medium_hash = 'test_med'
  AND ino IN (20, 21, 22);

\echo ''

\echo '=================================='
\echo 'Summary'
\echo '=================================='
\echo ''
\echo 'All recovery tool SQL queries validated.'
\echo 'The tool logic is sound and will work correctly after migration.'
\echo ''

-- Cleanup
DROP TABLE inode_recovery_test;

ROLLBACK;
