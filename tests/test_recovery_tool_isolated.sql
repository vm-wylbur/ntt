-- Author: PB and Claude
-- Date: 2025-10-11
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/tests/test_recovery_tool_isolated.sql
--
-- Create isolated test scenario for recovery tool testing
-- This simulates post-migration state without affecting production

\echo '=================================='
\echo 'Recovery Tool Test Setup'
\echo '=================================='
\echo ''

BEGIN;

-- Create test inode table with new columns
CREATE TEMP TABLE inode (
    id BIGSERIAL PRIMARY KEY,
    medium_hash TEXT NOT NULL,
    dev BIGINT,
    ino BIGINT NOT NULL,
    nlink INTEGER,
    size BIGINT,
    mtime BIGINT,
    blobid TEXT,
    copied BOOLEAN DEFAULT false,
    errors TEXT[] DEFAULT '{}',
    fs_type CHAR(1),
    mime_type VARCHAR(255),
    processed_at TIMESTAMPTZ,
    claimed_by TEXT,
    claimed_at TIMESTAMPTZ,
    status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'success', 'failed_retryable', 'failed_permanent')),
    error_type TEXT CHECK (error_type IS NULL OR error_type IN ('path_error', 'io_error', 'hash_error', 'permission_error', 'unknown'))
);

-- Insert test medium with various failure scenarios
INSERT INTO inode (medium_hash, ino, status, error_type, copied, blobid) VALUES
    -- Success cases
    ('test_recovery', 1, 'success', NULL, true, 'abc123'),
    ('test_recovery', 2, 'success', NULL, true, 'def456'),
    ('test_recovery', 3, 'success', NULL, true, 'ghi789'),

    -- Pending cases
    ('test_recovery', 10, 'pending', NULL, false, NULL),
    ('test_recovery', 11, 'pending', NULL, false, NULL),

    -- Failed retryable - path_error (simulating a78ccc01 scenario)
    ('test_recovery', 20, 'failed_retryable', 'path_error', true, NULL),
    ('test_recovery', 21, 'failed_retryable', 'path_error', true, NULL),
    ('test_recovery', 22, 'failed_retryable', 'path_error', true, NULL),
    ('test_recovery', 23, 'failed_retryable', 'path_error', true, NULL),
    ('test_recovery', 24, 'failed_retryable', 'path_error', true, NULL),

    -- Failed retryable - permission_error
    ('test_recovery', 30, 'failed_retryable', 'permission_error', true, NULL),
    ('test_recovery', 31, 'failed_retryable', 'permission_error', true, NULL),

    -- Failed retryable - unknown
    ('test_recovery', 40, 'failed_retryable', 'unknown', true, NULL),

    -- Failed permanent - io_error
    ('test_recovery', 50, 'failed_permanent', 'io_error', true, NULL),
    ('test_recovery', 51, 'failed_permanent', 'io_error', true, NULL);

\echo 'Test data created: medium_hash = test_recovery'
\echo ''

-- Show test data summary
SELECT
    status,
    error_type,
    COUNT(*) as count
FROM inode
WHERE medium_hash = 'test_recovery'
GROUP BY status, error_type
ORDER BY status, error_type;

\echo ''
\echo 'Test scenario ready!'
\echo ''
\echo 'Now you can test the recovery tool:'
\echo '  ./bin/ntt-recover-failed list-failures -m test_recovery'
\echo ''
\echo 'Keep this transaction open while testing (press Ctrl+C to rollback when done)'
\echo ''

-- Keep transaction open for testing
SELECT pg_sleep(300);  -- Wait 5 minutes for testing

ROLLBACK;
