-- Author: PB and Claude
-- Date: 2025-10-17
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- Add remote backup tracking columns to blobs table

\echo '=== Adding remote backup tracking columns ==='
\echo ''

-- Add tracking columns
ALTER TABLE blobs
  ADD COLUMN IF NOT EXISTS remote_copied BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS remote_last_checked TIMESTAMP WITH TIME ZONE,
  ADD COLUMN IF NOT EXISTS remote_copy_failed BOOLEAN DEFAULT FALSE;

\echo 'Columns added:'
\echo '  - remote_copied: Boolean flag indicating if blob has been backed up to remote'
\echo '  - remote_last_checked: Timestamp of last successful remote backup verification'
\echo '  - remote_copy_failed: Boolean flag for failed remote backup attempts'
\echo ''

-- Create sparse index for finding uncompleted remote backups
\echo 'Creating sparse index for remote backup queries...'
CREATE INDEX IF NOT EXISTS idx_blobs_remote_pending
  ON blobs(blobid)
  WHERE remote_copied IS FALSE OR remote_copied IS NULL;

\echo '✓ Index created: idx_blobs_remote_pending'
\echo ''

-- Create index for failed remote backups
CREATE INDEX IF NOT EXISTS idx_blobs_remote_failed
  ON blobs(blobid)
  WHERE remote_copy_failed IS TRUE;

\echo '✓ Index created: idx_blobs_remote_failed'
\echo ''

-- Show current state
\echo 'Current remote backup status:'
SELECT
  COUNT(*) FILTER (WHERE remote_copied IS TRUE) as backed_up,
  COUNT(*) FILTER (WHERE remote_copied IS FALSE OR remote_copied IS NULL) as pending,
  COUNT(*) FILTER (WHERE remote_copy_failed IS TRUE) as failed,
  COUNT(*) as total
FROM blobs;

\echo ''
\echo '=== Schema changes complete ==='
