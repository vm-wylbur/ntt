-- NTT Incremental Deduplication Report (Blob-centric)
-- Shows what each medium contributes in terms of unique content
--
-- Metrics per medium:
-- - new_blobs: Unique content (by hash) never seen on earlier media
-- - dup_blobs: Content seen on earlier media (deduplicated)
-- - new_gb/dup_gb: Storage impact in GB
-- - cumulative_blobs/cumulative_gb: Running totals
-- - dedup_ratio: Percentage of data that was deduplicated
--
-- Note: Path analysis excluded for performance (would require expensive joins)
--
-- Usage: psql postgres:///copyjob -f sql/incremental-dedup-report-blobs-only.sql

WITH ordered_media AS (
  -- Order all media chronologically by when they were added
  SELECT DISTINCT
    m.medium_hash,
    COALESCE(m.medium_human, SUBSTRING(m.medium_hash, 1, 12) || '...') as medium_name,
    m.added_at,
    ROW_NUMBER() OVER (ORDER BY m.added_at) as seq
  FROM medium m
  WHERE m.health = 'ok'
    AND EXISTS (SELECT 1 FROM blob_media_matrix bmm WHERE bmm.medium_hash = m.medium_hash)
),

blob_first_seen AS (
  -- For each unique blob, find which medium (by sequence) saw it first
  SELECT
    bmm.blobid,
    bmm.size,
    MIN(om.seq) as first_seen_seq
  FROM blob_media_matrix bmm
  JOIN ordered_media om ON bmm.medium_hash = om.medium_hash
  GROUP BY bmm.blobid, bmm.size
),

per_medium_blobs AS (
  -- Join blobs back to their media with first_seen info
  SELECT
    om.seq,
    om.medium_hash,
    om.medium_name,
    om.added_at,
    bmm.blobid,
    bmm.size,
    bfs.first_seen_seq
  FROM ordered_media om
  JOIN blob_media_matrix bmm ON om.medium_hash = bmm.medium_hash
  JOIN blob_first_seen bfs ON bmm.blobid = bfs.blobid
)

-- Final aggregation per medium
SELECT
  seq,
  medium_hash,
  medium_name,
  added_at::date as added_date,

  -- Blob counts
  COUNT(*) FILTER (WHERE first_seen_seq = seq) as new_blobs,
  COUNT(*) FILTER (WHERE first_seen_seq < seq) as dup_blobs,

  -- Storage sizes in GB
  ROUND(SUM(size) FILTER (WHERE first_seen_seq = seq) / 1024.0^3, 2) as new_gb,
  ROUND(SUM(size) FILTER (WHERE first_seen_seq < seq) / 1024.0^3, 2) as dup_gb,

  -- Deduplication ratio for this medium
  CASE
    WHEN SUM(size) > 0 THEN
      ROUND(100.0 * SUM(size) FILTER (WHERE first_seen_seq < seq) / SUM(size), 1)
    ELSE 0
  END as dedup_pct,

  -- Cumulative totals (window functions over ordered sequence)
  SUM(COUNT(*) FILTER (WHERE first_seen_seq = seq))
    OVER (ORDER BY seq ROWS UNBOUNDED PRECEDING) as cumulative_blobs,
  ROUND(SUM(SUM(size) FILTER (WHERE first_seen_seq = seq))
    OVER (ORDER BY seq ROWS UNBOUNDED PRECEDING) / 1024.0^3, 2) as cumulative_gb

FROM per_medium_blobs
GROUP BY seq, medium_hash, medium_name, added_at
ORDER BY seq;
