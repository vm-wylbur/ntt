-- NTT Incremental Deduplication Report
-- Shows what each medium contributes in chronological order
--
-- Metrics per medium:
-- - new_paths: Path strings never seen on earlier media
-- - dup_paths: Path strings seen on earlier media
-- - new_blobs: Unique content never seen on earlier media
-- - dup_blobs: Content seen on earlier media (deduplicated)
-- - new_gb/dup_gb: Storage impact in GB
-- - cumulative_blobs/cumulative_gb: Running totals
--
-- Usage: psql postgres:///copyjob -f sql/incremental-dedup-report.sql

WITH ordered_media AS (
  -- Order all media chronologically by when they were added
  -- Include media that have at least some blob data (even if enum_done not set)
  SELECT DISTINCT
    m.medium_hash,
    m.medium_human,
    m.added_at,
    ROW_NUMBER() OVER (ORDER BY m.added_at) as seq
  FROM medium m
  WHERE m.health = 'ok'
    AND EXISTS (SELECT 1 FROM blob_media_matrix bmm WHERE bmm.medium_hash = m.medium_hash)
),

path_first_seen AS (
  -- For each unique path string, find which medium saw it first
  SELECT
    p.path,
    MIN(om.seq) as first_seen_seq
  FROM path p
  JOIN ordered_media om ON p.medium_hash = om.medium_hash
  WHERE p.exclude_reason IS NULL
  GROUP BY p.path
),

blob_first_seen AS (
  -- For each unique blob, find which medium saw it first
  SELECT
    bmm.blobid,
    MIN(om.seq) as first_seen_seq
  FROM blob_media_matrix bmm
  JOIN ordered_media om ON bmm.medium_hash = om.medium_hash
  GROUP BY bmm.blobid
)

-- Main query: aggregate per medium with new vs duplicate counts
SELECT
  om.seq,
  om.medium_hash,
  COALESCE(om.medium_human, '(unnamed)') as medium_human,
  om.added_at,

  -- Path counts (new = first time seeing this path string)
  COUNT(DISTINCT p.path) FILTER (WHERE pfs.first_seen_seq = om.seq) as new_paths,
  COUNT(DISTINCT p.path) FILTER (WHERE pfs.first_seen_seq < om.seq) as dup_paths,

  -- Blob counts (new = first time seeing this content)
  COUNT(DISTINCT bmm.blobid) FILTER (WHERE bfs.first_seen_seq = om.seq) as new_blobs,
  COUNT(DISTINCT bmm.blobid) FILTER (WHERE bfs.first_seen_seq < om.seq) as dup_blobs,

  -- Storage sizes in GB
  ROUND(SUM(bmm.size) FILTER (WHERE bfs.first_seen_seq = om.seq) / 1024.0^3, 2) as new_gb,
  ROUND(SUM(bmm.size) FILTER (WHERE bfs.first_seen_seq < om.seq) / 1024.0^3, 2) as dup_gb,

  -- Cumulative totals (running sum via window function)
  SUM(COUNT(DISTINCT bmm.blobid) FILTER (WHERE bfs.first_seen_seq = om.seq))
    OVER (ORDER BY om.seq ROWS UNBOUNDED PRECEDING) as cumulative_blobs,
  ROUND(SUM(SUM(bmm.size) FILTER (WHERE bfs.first_seen_seq = om.seq))
    OVER (ORDER BY om.seq ROWS UNBOUNDED PRECEDING) / 1024.0^3, 2) as cumulative_gb

FROM ordered_media om
LEFT JOIN path p ON om.medium_hash = p.medium_hash AND p.exclude_reason IS NULL
LEFT JOIN path_first_seen pfs ON p.path = pfs.path
LEFT JOIN blob_media_matrix bmm ON om.medium_hash = bmm.medium_hash
LEFT JOIN blob_first_seen bfs ON bmm.blobid = bfs.blobid

GROUP BY om.seq, om.medium_hash, om.medium_human, om.added_at
ORDER BY om.seq;
