-- Author: PB and Claude
-- Date: 2025-10-11
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/sql/03-add-status-model.sql
--
-- BUG-007: Add status model to distinguish success from failure
--
-- Problem: copied=true conflates "successfully copied" with "gave up after max retries"
-- Solution: Add explicit status and error_type columns for proper state tracking
--
-- This enables:
--   1. Recovery after fixing root causes (PATH_ERROR vs permanent IO_ERROR)
--   2. Clear distinction between success and failure states
--   3. Targeted retry logic based on error classification

BEGIN;

-- ============================================================================
-- STEP 1: Add new columns with constraints
-- ============================================================================

-- Status column: Track inode processing state
ALTER TABLE inode
ADD COLUMN IF NOT EXISTS status TEXT DEFAULT 'pending'
    CHECK (status IN ('pending', 'success', 'failed_retryable', 'failed_permanent'));

-- Error type column: Classify failures for targeted recovery
ALTER TABLE inode
ADD COLUMN IF NOT EXISTS error_type TEXT
    CHECK (error_type IS NULL OR error_type IN (
        'path_error',       -- Path too long, path not found (likely fixable)
        'io_error',         -- Bad media, read errors (permanent)
        'hash_error',       -- Hash computation failed (transient)
        'permission_error', -- Access denied (might be fixable)
        'unknown'           -- Unclassified error
    ));

-- ============================================================================
-- STEP 2: Migrate existing data
-- ============================================================================

-- Mark successful copies (have blob_id)
UPDATE inode
SET status = 'success'
WHERE blobid IS NOT NULL;

-- Mark failed copies (copied=true but no blob_id) as retryable
-- Assumption: most failures after max retries might be recoverable
UPDATE inode
SET status = 'failed_retryable',
    error_type = 'unknown'  -- Unknown because we don't have classification yet
WHERE copied = true
  AND blobid IS NULL;

-- Pending items remain status='pending' (from DEFAULT)

-- ============================================================================
-- STEP 3: Create indexes for efficient querying
-- ============================================================================

-- Index for work queue queries (find pending and retryable items)
CREATE INDEX IF NOT EXISTS idx_inode_status_queue
    ON inode(medium_hash, status)
    WHERE status IN ('pending', 'failed_retryable');

-- Index for finding items by error type (for targeted recovery)
CREATE INDEX IF NOT EXISTS idx_inode_error_type
    ON inode(error_type)
    WHERE error_type IS NOT NULL;

-- Index for finding failures by medium and error type
CREATE INDEX IF NOT EXISTS idx_inode_failed_by_type
    ON inode(medium_hash, error_type, status)
    WHERE status IN ('failed_retryable', 'failed_permanent');

-- ============================================================================
-- STEP 4: Add documentation
-- ============================================================================

COMMENT ON COLUMN inode.status IS
    'Processing status: pending (not attempted), success (copied successfully), '
    'failed_retryable (max retries but might be fixable), '
    'failed_permanent (unrecoverable error like bad media)';

COMMENT ON COLUMN inode.error_type IS
    'Error classification for failures: path_error (fixable path issues), '
    'io_error (bad media/permanent), hash_error (transient), '
    'permission_error (access denied), unknown (unclassified)';

COMMIT;

-- ============================================================================
-- VERIFICATION QUERIES
-- ============================================================================

-- Check status distribution
SELECT status, COUNT(*) as count
FROM inode
GROUP BY status
ORDER BY status;

-- Check error type distribution for failures
SELECT error_type, COUNT(*) as count
FROM inode
WHERE status IN ('failed_retryable', 'failed_permanent')
GROUP BY error_type
ORDER BY count DESC;

-- Verify no invalid states (should return 0 rows)
SELECT COUNT(*) as invalid_states
FROM inode
WHERE (status = 'success' AND blobid IS NULL)
   OR (status IN ('failed_retryable', 'failed_permanent') AND blobid IS NOT NULL);
