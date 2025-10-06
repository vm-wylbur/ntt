-- Author: PB and Claude
-- Date: 2025-10-05
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/sql/partition-migration-step3-copy-data.sql
--
-- PARTITION MIGRATION - STEP 3: Copy data from old tables to partitioned tables
--
-- Copies 122M paths and corresponding inodes from current tables to partitioned tables
-- Uses INSERT ... SELECT for transactional safety
--
-- Runtime estimate: 2-4 hours for 122M paths
-- Can be run with parallel workers if needed (one transaction per medium_hash)
--
-- Note: This script shows the single-transaction approach.
-- For production, consider per-medium batches (see step3-copy-data-batched.sql)

-- WARNING: This will take significant time. Consider running in screen/tmux.
-- Monitor progress with:
--   SELECT medium_hash, count(*) FROM inode_new GROUP BY medium_hash;
--   SELECT medium_hash, count(*) FROM path_new GROUP BY medium_hash;

BEGIN;

-- Disable autovacuum during bulk load for performance
ALTER TABLE inode_new SET (autovacuum_enabled = false);
ALTER TABLE path_new SET (autovacuum_enabled = false);

-- Tune for bulk insert
SET work_mem = '256MB';
SET maintenance_work_mem = '2GB';
SET synchronous_commit = OFF;

-- ============================================================================
-- COPY INODE DATA
-- ============================================================================

INSERT INTO inode_new (
    medium_hash, dev, ino, nlink, size, mtime, blobid, copied, copied_to,
    errors, fs_type, mime_type, processed_at, by_hash_created, claimed_by, claimed_at
)
SELECT
    medium_hash, dev, ino, nlink, size, mtime, blobid, copied, copied_to,
    errors, fs_type, mime_type, processed_at, by_hash_created, claimed_by, claimed_at
FROM inode;

-- ============================================================================
-- COPY PATH DATA
-- ============================================================================

INSERT INTO path_new (
    medium_hash, dev, ino, path, broken, blobid, exclude_reason
)
SELECT
    medium_hash, dev, ino, path, broken, blobid, exclude_reason
FROM path;

-- Re-enable autovacuum
ALTER TABLE inode_new SET (autovacuum_enabled = true);
ALTER TABLE path_new SET (autovacuum_enabled = true);

COMMIT;

-- ============================================================================
-- VERIFICATION QUERIES
-- ============================================================================

-- Compare row counts
SELECT 'inode' as table_name,
       (SELECT count(*) FROM inode) as old_count,
       (SELECT count(*) FROM inode_new) as new_count,
       (SELECT count(*) FROM inode) = (SELECT count(*) FROM inode_new) as counts_match;

SELECT 'path' as table_name,
       (SELECT count(*) FROM path) as old_count,
       (SELECT count(*) FROM path_new) as new_count,
       (SELECT count(*) FROM path) = (SELECT count(*) FROM path_new) as counts_match;

-- Compare per-medium counts
SELECT
    COALESCE(old.medium_hash, new.medium_hash) as medium_hash,
    COALESCE(old.inode_count, 0) as old_inode_count,
    COALESCE(new.inode_count, 0) as new_inode_count,
    COALESCE(old.path_count, 0) as old_path_count,
    COALESCE(new.path_count, 0) as new_path_count,
    COALESCE(old.inode_count, 0) = COALESCE(new.inode_count, 0) as inode_match,
    COALESCE(old.path_count, 0) = COALESCE(new.path_count, 0) as path_match
FROM
    (SELECT medium_hash, count(*) as inode_count FROM inode GROUP BY medium_hash) old
    FULL OUTER JOIN
    (SELECT medium_hash, count(*) as inode_count FROM inode_new GROUP BY medium_hash) new
    USING (medium_hash)
    FULL OUTER JOIN
    (SELECT medium_hash, count(*) as path_count FROM path GROUP BY medium_hash) old_path
    USING (medium_hash)
    FULL OUTER JOIN
    (SELECT medium_hash, count(*) as path_count FROM path_new GROUP BY medium_hash) new_path
    USING (medium_hash)
ORDER BY medium_hash;

-- Sample data comparison (check first 10 rows match)
SELECT 'Sample inode comparison' as check_name,
       bool_and(
           old.medium_hash = new.medium_hash AND
           old.ino = new.ino AND
           old.size = new.size AND
           old.copied = new.copied
       ) as sample_matches
FROM
    (SELECT * FROM inode ORDER BY medium_hash, ino LIMIT 10) old
    JOIN
    (SELECT * FROM inode_new ORDER BY medium_hash, ino LIMIT 10) new
    ON old.medium_hash = new.medium_hash AND old.ino = new.ino;

SELECT 'Sample path comparison' as check_name,
       bool_and(
           old.medium_hash = new.medium_hash AND
           old.ino = new.ino AND
           old.path = new.path
       ) as sample_matches
FROM
    (SELECT * FROM path ORDER BY medium_hash, ino, path LIMIT 10) old
    JOIN
    (SELECT * FROM path_new ORDER BY medium_hash, ino, path LIMIT 10) new
    ON old.medium_hash = new.medium_hash AND old.ino = new.ino AND old.path = new.path;

-- Check partition sizes
SELECT
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
    pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) AS table_size,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename) - pg_relation_size(schemaname||'.'||tablename)) AS index_size
FROM pg_tables
WHERE tablename LIKE 'inode_p_%' OR tablename LIKE 'path_p_%'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC
LIMIT 20;
