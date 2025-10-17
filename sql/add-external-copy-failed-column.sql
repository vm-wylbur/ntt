-- Author: PB and Claude
-- Date: 2025-10-13
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- Add external_copy_failed column for tracking failed backup attempts

\echo '=== Adding external_copy_failed column ==='
\echo ''

ALTER TABLE blobs
  ADD COLUMN IF NOT EXISTS external_copy_failed BOOLEAN DEFAULT FALSE;

\echo '✓ Column added: external_copy_failed'
\echo ''

\echo 'Creating index for failed copies...'
CREATE INDEX IF NOT EXISTS idx_blobs_external_failed
  ON blobs(blobid)
  WHERE external_copy_failed IS TRUE;

\echo '✓ Index created: idx_blobs_external_failed'
\echo ''
\echo '=== Complete ==='
