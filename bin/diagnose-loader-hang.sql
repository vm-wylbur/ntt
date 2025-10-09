-- Author: PB and Claude
-- Date: 2025-10-07
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/bin/diagnose-loader-hang.sql
--
-- Diagnostic script to identify why loader hangs for 12.5 minutes on 6 records

-- ============================================================================
-- 1. CHECK FOREIGN KEY ARCHITECTURE
-- ============================================================================
\echo '============================================================================'
\echo '1. CHECKING FOREIGN KEY ARCHITECTURE'
\echo '============================================================================'

-- Check for parent-level FK (the problem)
\echo '\n--- Parent-level FK constraints (PROBLEM if exists) ---'
SELECT
    conname as constraint_name,
    conrelid::regclass as from_table,
    confrelid::regclass as to_table,
    pg_get_constraintdef(oid) as definition
FROM pg_constraint
WHERE contype = 'f'
  AND conrelid = 'path'::regclass
  AND confrelid = 'inode'::regclass;

-- Check for partition-to-partition FKs (the solution)
\echo '\n--- Partition-to-partition FK constraints (GOOD if exists) ---'
SELECT
    cl.relname as path_partition,
    c.conname as fk_constraint,
    cl2.relname as inode_partition,
    CASE WHEN c.convalidated THEN 'VALID' ELSE 'NOT VALID' END as status
FROM pg_constraint c
JOIN pg_class cl ON cl.oid = c.conrelid
JOIN pg_class cl2 ON cl2.oid = c.confrelid
WHERE c.contype = 'f'
  AND cl.relname LIKE 'path_p_%'
ORDER BY cl.relname;

-- ============================================================================
-- 2. CHECK PARTITION PRUNING FOR THE PROBLEMATIC QUERY
-- ============================================================================
\echo '\n============================================================================'
\echo '2. TESTING PARTITION PRUNING ON SELECT COUNT QUERY'
\echo '============================================================================'

-- This is the exact query that hung (from line 279-284 of ntt-loader)
\echo '\n--- EXPLAIN for SELECT COUNT from parent table ---'
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT COUNT(*)
FROM inode
WHERE medium_hash = 'af1349b9f5f9a1a6a0404dea36dcc949'
  AND claimed_by = 'EXCLUDED';

\echo '\n--- EXPLAIN for SELECT COUNT from specific partition ---'
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT COUNT(*)
FROM inode_p_af1349b9
WHERE medium_hash = 'af1349b9f5f9a1a6a0404dea36dcc949'
  AND claimed_by = 'EXCLUDED';

-- ============================================================================
-- 3. CHECK INDEX COVERAGE FOR FK VALIDATION
-- ============================================================================
\echo '\n============================================================================'
\echo '3. CHECKING INDEX COVERAGE (FK validation performance)'
\echo '============================================================================'

-- Check if path partitions have FULL indexes on (medium_hash, ino)
-- Partial indexes may not be used for FK checks
\echo '\n--- Path partition indexes (need FULL index on (medium_hash, ino) for FK) ---'
SELECT
    tablename,
    indexname,
    indexdef,
    CASE
        WHEN indexdef LIKE '%WHERE%' THEN 'PARTIAL (may not help FK)'
        ELSE 'FULL (good for FK)'
    END as index_type
FROM pg_indexes
WHERE tablename LIKE 'path_p_%'
  AND indexdef LIKE '%(medium_hash%ino)%'
ORDER BY tablename, indexname;

-- ============================================================================
-- 4. CHECK STATISTICS FRESHNESS
-- ============================================================================
\echo '\n============================================================================'
\echo '4. CHECKING STATISTICS FRESHNESS'
\echo '============================================================================'

\echo '\n--- Last ANALYZE time for inode partitions ---'
SELECT
    schemaname,
    relname,
    n_live_tup as rows,
    last_analyze,
    last_autoanalyze,
    CASE
        WHEN last_analyze IS NULL AND last_autoanalyze IS NULL THEN 'NEVER ANALYZED'
        WHEN last_analyze > COALESCE(last_autoanalyze, '-infinity'::timestamptz) THEN 'manual'
        ELSE 'auto'
    END as analyze_type
FROM pg_stat_user_tables
WHERE relname LIKE 'inode_p_%'
ORDER BY relname;

-- ============================================================================
-- 5. CHECK TRIGGER CONFIGURATION
-- ============================================================================
\echo '\n============================================================================'
\echo '5. CHECKING TRIGGER CONFIGURATION'
\echo '============================================================================'

\echo '\n--- Triggers on inode partitions ---'
SELECT
    c.relname as table_name,
    t.tgname as trigger_name,
    CASE
        WHEN t.tgtype::int & 1 = 1 THEN 'ROW'
        ELSE 'STATEMENT'
    END as level,
    pg_get_triggerdef(t.oid) as definition
FROM pg_trigger t
JOIN pg_class c ON t.tgrelid = c.oid
WHERE c.relname LIKE 'inode_p_%'
  AND NOT t.tgisinternal
  AND t.tgname LIKE '%queue%'
ORDER BY c.relname, t.tgname;

-- ============================================================================
-- 6. CHECK CURRENT PARTITION STATE
-- ============================================================================
\echo '\n============================================================================'
\echo '6. CHECKING PARTITION STATE'
\echo '============================================================================'

\echo '\n--- All inode partitions ---'
SELECT
    c.relname as partition_name,
    pg_size_pretty(pg_relation_size(c.oid)) as size,
    (SELECT count(*) FROM inode WHERE medium_hash = regexp_replace(
        pg_get_expr(c.relpartbound, c.oid),
        'FOR VALUES IN \(''(.+?)''\)',
        '\1'
    )) as row_count
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
JOIN pg_class parent ON parent.oid = i.inhparent
WHERE parent.relname = 'inode'
  AND c.relispartition
ORDER BY c.relname;

-- ============================================================================
-- 7. CHECK FOR LOCK CONTENTION
-- ============================================================================
\echo '\n============================================================================'
\echo '7. CHECKING FOR CURRENT LOCKS'
\echo '============================================================================'

\echo '\n--- Current locks on inode tables ---'
SELECT
    pid,
    usename,
    application_name,
    state,
    wait_event_type,
    wait_event,
    query_start,
    state_change,
    query
FROM pg_stat_activity
WHERE query LIKE '%inode%'
  AND state != 'idle'
  AND pid != pg_backend_pid()
ORDER BY query_start;

-- ============================================================================
-- SUMMARY
-- ============================================================================
\echo '\n============================================================================'
\echo 'DIAGNOSTIC SUMMARY'
\echo '============================================================================'
\echo ''
\echo 'Key questions answered:'
\echo '1. Parent-level FK exists? (Should be NO after P2P migration)'
\echo '2. Partition pruning works? (Should see "Seq Scan on inode_p_af1349b9" only)'
\echo '3. FK indexes present? (Should be FULL indexes, not PARTIAL)'
\echo '4. Statistics fresh? (Should have recent ANALYZE)'
\echo '5. Triggers optimized? (Should be STATEMENT level, not ROW level)'
\echo ''
