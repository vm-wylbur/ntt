-- Populate blob_media_matrix from path table (permanent data)
-- This creates the permanent mapping of which blobs came from which media
--
-- Run before: generating deduplication reports
-- Safe to run multiple times (uses ON CONFLICT DO NOTHING)
--
-- Note: Uses path.blobid (permanent) not inode (temporary)
-- The path table is the source of truth - it persists after source media is unmounted

INSERT INTO blob_media_matrix (blobid, medium_hash, size)
SELECT DISTINCT
  p.blobid,
  p.medium_hash,
  i.size
FROM path p
JOIN inode i ON (p.medium_hash, p.ino) = (i.medium_hash, i.ino)
WHERE p.blobid IS NOT NULL
  AND p.exclude_reason IS NULL
  AND i.copied = true
ON CONFLICT DO NOTHING;

-- Report what was populated
SELECT
  COUNT(*) as total_entries,
  COUNT(DISTINCT blobid) as unique_blobs,
  COUNT(DISTINCT medium_hash) as media_count,
  ROUND(SUM(size) / 1024.0^3, 2) as total_gb
FROM blob_media_matrix;
