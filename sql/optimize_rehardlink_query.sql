-- Indexes to optimize the --re-hardlink incomplete blob query
-- These speed up finding blobs where n_hardlinks < expected path count

-- Index on inode.hash for fast joins with blobs
-- This is critical for joining blobs.blobid to inode.hash
CREATE INDEX IF NOT EXISTS idx_inode_hash
  ON inode(hash);

-- Composite index for path table lookups
-- Already exists as primary key: (dev, ino, path)
-- But we might benefit from just (dev, ino) for the join
CREATE INDEX IF NOT EXISTS idx_path_dev_ino
  ON path(dev, ino);

-- Partial index on blobs for incomplete ones
-- This helps quickly identify blobs that might need work
CREATE INDEX IF NOT EXISTS idx_blobs_incomplete
  ON blobs(blobid)
  WHERE n_hardlinks = 0 OR n_hardlinks IS NULL;

-- Index on n_hardlinks for sorting/filtering
-- Already created in add_hardlink_tracking.sql but ensure it exists
CREATE INDEX IF NOT EXISTS idx_blobs_n_hardlinks
  ON blobs(n_hardlinks);

-- Analyze tables to update statistics for query planner
ANALYZE blobs;
ANALYZE inode;
ANALYZE path;

-- Show current index usage to verify
SELECT
    schemaname,
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) as index_size
FROM pg_stat_user_indexes
WHERE tablename IN ('blobs', 'inode', 'path')
ORDER BY tablename, indexname;
