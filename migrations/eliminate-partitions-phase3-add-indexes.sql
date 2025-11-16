-- Author: PB and Claude
-- Date: 2025-11-15
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/migrations/eliminate-partitions-phase3-add-indexes.sql
--
-- PHASE 3: Add indexes after bulk data load
--
-- This creates PRIMARY KEY and necessary indexes AFTER all data is loaded.
-- Much faster than maintaining indexes during 231M row INSERT.
--
-- Run with: psql -d copyjob -f eliminate-partitions-phase3-add-indexes.sql
--
-- Expected time: 30-60 minutes for index creation
--

\timing on
\set ON_ERROR_STOP on

\echo '================================================================================'
\echo 'PHASE 3: Adding indexes to loaded data'
\echo '================================================================================'
\echo ''
\echo 'This will create PRIMARY KEY and indexes on paths_provisional'
\echo 'Expected time: 30-60 minutes'
\echo ''

-- ============================================================================
-- STEP 3.1: Add PRIMARY KEY to paths_provisional
-- ============================================================================

\echo '================================================================================'
\echo 'STEP 3.1: Creating PRIMARY KEY on paths_provisional'
\echo '================================================================================'
\echo 'This will take 20-40 minutes for 231M rows...'
\echo ''

ALTER TABLE paths_provisional
    ADD CONSTRAINT paths_provisional_pkey
    PRIMARY KEY (medium_hash, dev, ino, path);

\echo ''
\echo 'PRIMARY KEY created successfully'
\echo ''

-- ============================================================================
-- STEP 3.2: Analyze tables for query planner
-- ============================================================================

\echo '================================================================================'
\echo 'STEP 3.2: Analyzing tables for query planner'
\echo '================================================================================'

ANALYZE paths_provisional;
ANALYZE blobs_provisional;

\echo 'Analysis complete'
\echo ''

-- ============================================================================
-- STEP 3.3: Report final statistics
-- ============================================================================

\echo '================================================================================'
\echo 'Final statistics'
\echo '================================================================================'

SELECT
    'paths_provisional' as table_name,
    COUNT(*) as total_rows,
    pg_size_pretty(pg_relation_size('paths_provisional')) as table_size,
    pg_size_pretty(pg_total_relation_size('paths_provisional') - pg_relation_size('paths_provisional')) as index_size,
    pg_size_pretty(pg_total_relation_size('paths_provisional')) as total_size
FROM paths_provisional;

\echo ''
\echo '================================================================================'
\echo 'Phase 3 complete: Indexes created'
\echo 'Next step: Run phase4-verification.sql (formerly phase3-verification.sql)'
\echo '================================================================================'

\timing off
