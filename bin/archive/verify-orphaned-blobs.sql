-- NTT Orphaned Blobs Verification Query
-- Identifies blobids in inode table that are missing from blobs table
-- Author: dev-claude
-- Date: 2025-10-21

-- Summary counts
SELECT
    'Summary' as report_section,
    COUNT(DISTINCT i.blobid) as unique_orphaned_blobids,
    COUNT(*) as total_orphaned_inode_rows,
    SUM(i.size) as total_orphaned_bytes,
    pg_size_pretty(SUM(i.size)) as total_orphaned_size
FROM inode i
LEFT JOIN blobs b ON i.blobid = b.blobid
WHERE i.blobid IS NOT NULL
  AND b.blobid IS NULL
  AND i.status = 'success';

-- Breakdown by medium
SELECT
    'By Medium' as report_section,
    i.medium_hash,
    m.medium_human,
    COUNT(DISTINCT i.blobid) as unique_orphaned_blobids,
    COUNT(*) as orphaned_files,
    pg_size_pretty(SUM(i.size)) as total_size
FROM inode i
LEFT JOIN blobs b ON i.blobid = b.blobid
LEFT JOIN medium m ON i.medium_hash = m.medium_hash
WHERE i.blobid IS NOT NULL
  AND b.blobid IS NULL
  AND i.status = 'success'
GROUP BY i.medium_hash, m.medium_human
ORDER BY COUNT(DISTINCT i.blobid) DESC
LIMIT 20;

-- Validation: Check if orphaned blobs exist on filesystem
-- Sample 10 orphaned blobids to verify they're real
SELECT
    'Sample Check' as report_section,
    i.blobid,
    COUNT(*) as inode_count,
    MIN(i.size) as min_size,
    MAX(i.size) as max_size
FROM inode i
LEFT JOIN blobs b ON i.blobid = b.blobid
WHERE i.blobid IS NOT NULL
  AND b.blobid IS NULL
  AND i.status = 'success'
GROUP BY i.blobid
ORDER BY COUNT(*) DESC
LIMIT 10;

-- Check processed_at correlation
SELECT
    'Processed_at Analysis' as report_section,
    COUNT(*) FILTER (WHERE processed_at IS NULL) as no_timestamp,
    COUNT(*) FILTER (WHERE processed_at IS NOT NULL) as has_timestamp,
    COUNT(*) as total
FROM inode i
LEFT JOIN blobs b ON i.blobid = b.blobid
WHERE i.blobid IS NOT NULL
  AND b.blobid IS NULL
  AND i.status = 'success';

-- Check when these were created (via medium copy_done timestamps)
SELECT
    'Timeline Analysis' as report_section,
    DATE(m.copy_done) as copy_date,
    COUNT(DISTINCT i.blobid) as unique_orphaned_blobids,
    COUNT(*) as orphaned_files
FROM inode i
LEFT JOIN blobs b ON i.blobid = b.blobid
LEFT JOIN medium m ON i.medium_hash = m.medium_hash
WHERE i.blobid IS NOT NULL
  AND b.blobid IS NULL
  AND i.status = 'success'
  AND m.copy_done IS NOT NULL
GROUP BY DATE(m.copy_done)
ORDER BY copy_date DESC
LIMIT 20;
