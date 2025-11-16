-- Author: PB and Claude
-- Date: 2025-11-16
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/migrations/phase4-cutover.sql
--
-- PHASE 4: Fast cutover to unpartitioned schema
--
-- This script renames tables for instant cutover (seconds, not hours).
-- Old partitioned tables remain as *_old_to_drop for background cleanup.
--
-- PREREQUISITES:
--   1. All workers stopped (ntt-copier, ntt-orchestrator, ntt-loader)
--   2. Phase 3 complete (paths_provisional and blobs_provisional ready)
--   3. Data verified: 231,628,765 paths, 9,310,725 blobs
--   4. Fresh pg_dump backup exists
--
-- EXPECTED DOWNTIME: 5-10 seconds
--
-- ROLLBACK: If cutover fails, rename tables back:
--   ALTER TABLE paths RENAME TO paths_provisional;
--   ALTER TABLE blobs RENAME TO blobs_provisional;
--   ALTER TABLE path_old_to_drop RENAME TO path;
--   ALTER TABLE inode_old_to_drop RENAME TO inode;

\set ON_ERROR_STOP on

\echo '================================================================================'
\echo 'PHASE 4: FAST CUTOVER TO UNPARTITIONED SCHEMA'
\echo '================================================================================'
\echo ''
\echo 'This will rename tables in a single transaction (5-10 seconds):'
\echo '  - path (244,182 partitions) → path_old_to_drop'
\echo '  - inode (244,182 partitions) → inode_old_to_drop'
\echo '  - paths_provisional → paths'
\echo '  - blobs_provisional → blobs'
\echo ''
\echo 'Old partitioned tables will be dropped later in background cleanup.'
\echo ''
\echo 'Press Ctrl+C now if workers are not stopped or backup is missing.'
\echo ''

-- Give user 5 seconds to cancel
SELECT pg_sleep(5);

\echo 'Starting cutover transaction...'
\echo ''

BEGIN;

\echo 'Step 1: Renaming old partitioned tables...'

ALTER TABLE path RENAME TO path_old_to_drop;
\echo '  ✓ path → path_old_to_drop'

ALTER TABLE inode RENAME TO inode_old_to_drop;
\echo '  ✓ inode → inode_old_to_drop'

\echo ''
\echo 'Step 2: Renaming new unpartitioned tables to production names...'

ALTER TABLE paths_provisional RENAME TO paths;
\echo '  ✓ paths_provisional → paths'

ALTER TABLE blobs_provisional RENAME TO blobs;
\echo '  ✓ blobs_provisional → blobs'

COMMIT;

\echo ''
\echo '================================================================================'
\echo 'CUTOVER COMPLETE'
\echo '================================================================================'
\echo ''

\echo 'Step 3: Updating table statistics...'
ANALYZE paths;
\echo '  ✓ Analyzed paths'

ANALYZE blobs;
\echo '  ✓ Analyzed blobs'

\echo ''
\echo '================================================================================'
\echo 'VERIFICATION'
\echo '================================================================================'
\echo ''

\echo 'New production tables:'
\echo ''

SELECT
    tablename,
    pg_size_pretty(pg_total_relation_size('public.' || tablename)) as total_size
FROM pg_tables
WHERE schemaname = 'public'
  AND tablename IN ('paths', 'blobs')
ORDER BY tablename;

\echo ''
\echo 'Old tables (ready for background cleanup):'
\echo ''

SELECT
    tablename,
    pg_size_pretty(pg_total_relation_size('public.' || tablename)) as total_size
FROM pg_tables
WHERE schemaname = 'public'
  AND tablename IN ('path_old_to_drop', 'inode_old_to_drop')
ORDER BY tablename;

\echo ''
\echo 'Partition verification (should be 0 for new tables):'
\echo ''

SELECT
    parent.relname as table_name,
    COUNT(*) as partition_count
FROM pg_inherits
JOIN pg_class parent ON pg_inherits.inhparent = parent.oid
WHERE parent.relname IN ('paths', 'blobs', 'path_old_to_drop', 'inode_old_to_drop')
GROUP BY parent.relname
ORDER BY parent.relname;

\echo ''
\echo '================================================================================'
\echo 'NEXT STEPS'
\echo '================================================================================'
\echo ''
\echo '1. Update application code to reference "paths" and "blobs" tables'
\echo '2. Restart workers: ntt-copier, ntt-orchestrator, ntt-loader'
\echo '3. Verify application functionality'
\echo '4. Schedule background cleanup (see: migrations/phase4-cleanup.sql)'
\echo ''
\echo 'Background cleanup will drop 488,362 partitions (1-2 hours).'
\echo 'This can run anytime during a low-traffic window with no user impact.'
\echo ''
\echo '================================================================================'
