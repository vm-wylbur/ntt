-- Author: PB and Claude
-- Date: 2025-11-16
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/migrations/add-paths-indexes.sql
--
-- Add indexes to paths table for loader and copier operations
--
-- PREREQUISITES:
--   - Phase 4 cutover complete (paths table exists with 232M rows)
--   - No copier or loader running
--
-- EXPECTED TIME: 60-120 minutes (30-60 min per index)
-- USER IMPACT: None (CONCURRENT builds don't block queries)
--
-- RATIONALE:
--   - (medium_hash, dev, ino): Needed for hardlink grouping in copier
--   - (medium_hash, claimed_by): Needed for queue operations (WHERE claimed_by IS NULL)

\set ON_ERROR_STOP on
\timing on

\echo '================================================================================'
\echo 'Adding indexes to paths table'
\echo '================================================================================'
\echo ''
\echo 'This will create 2 indexes on 232M rows:'
\echo '  1. (medium_hash, dev, ino) - for hardlink queries'
\echo '  2. (medium_hash, claimed_by) - for queue operations'
\echo ''
\echo 'Expected time: 60-120 minutes total'
\echo 'Using CONCURRENTLY to avoid blocking queries'
\echo ''

-- Index 1: For hardlink grouping (copier needs this)
\echo '================================================================================'
\echo 'Step 1: Creating index on (medium_hash, dev, ino)'
\echo '================================================================================'
\echo 'Started at: ' || now()::text AS start_time \gset
\echo :start_time
\echo ''

CREATE INDEX CONCURRENTLY idx_paths_medium_dev_ino 
  ON paths(medium_hash, dev, ino);

\echo ''
\echo 'Completed at: ' || now()::text AS end_time \gset
\echo :end_time
\echo '  ✓ Index created: idx_paths_medium_dev_ino'
\echo ''

-- Index 2: For queue operations (loader and copier need this)
\echo '================================================================================'
\echo 'Step 2: Creating index on (medium_hash, claimed_by)'
\echo '================================================================================'
\echo 'Started at: ' || now()::text AS start_time \gset
\echo :start_time
\echo ''

CREATE INDEX CONCURRENTLY idx_paths_medium_claimed 
  ON paths(medium_hash, claimed_by);

\echo ''
\echo 'Completed at: ' || now()::text AS end_time \gset
\echo :end_time
\echo '  ✓ Index created: idx_paths_medium_claimed'
\echo ''

-- Verify indexes were created
\echo '================================================================================'
\echo 'Verification'
\echo '================================================================================'
\echo ''

SELECT 
    indexname,
    pg_size_pretty(pg_relation_size(indexname::regclass)) as size
FROM pg_indexes 
WHERE tablename = 'paths' 
  AND indexname LIKE 'idx_paths_%'
ORDER BY indexname;

\echo ''
\echo '================================================================================'
\echo 'Index creation complete'
\echo '================================================================================'
\echo ''

\timing off
