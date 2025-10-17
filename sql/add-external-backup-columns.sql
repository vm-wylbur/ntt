-- Author: PB and Claude
-- Date: 2025-10-13
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- Add external backup tracking columns to blobs table

\echo '=== Adding external backup tracking columns ==='
\echo ''

-- Add tracking columns
ALTER TABLE blobs
  ADD COLUMN IF NOT EXISTS external_copied BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS external_last_checked TIMESTAMP WITH TIME ZONE;

\echo 'Columns added:'
\echo '  - external_copied: Boolean flag indicating if blob has been backed up'
\echo '  - external_last_checked: Timestamp of last successful backup verification'
\echo ''

-- Create sparse index for finding uncompleted backups
\echo 'Creating sparse index for backup queries...'
CREATE INDEX IF NOT EXISTS idx_blobs_external_pending
  ON blobs(blobid)
  WHERE external_copied IS FALSE OR external_copied IS NULL;

\echo '✓ Index created: idx_blobs_external_pending'
\echo ''

-- Show current state
\echo 'Current backup status:'
SELECT
  COUNT(*) FILTER (WHERE external_copied IS TRUE) as backed_up,
  COUNT(*) FILTER (WHERE external_copied IS FALSE OR external_copied IS NULL) as pending,
  COUNT(*) as total
FROM blobs;

\echo ''
\echo '=== Schema changes complete ==='
