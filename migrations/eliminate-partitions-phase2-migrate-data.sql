-- Author: PB and Claude
-- Date: 2025-11-15
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/migrations/eliminate-partitions-phase2-migrate-data.sql
--
-- PHASE 2: Migrate data using per-partition processing
--
-- IMPORTANT: This script takes 15-30 minutes using per-partition processing.
-- Cross-partition queries would take 1+ hour due to planning overhead.
--
-- Run with: psql -d copyjob -f eliminate-partitions-phase2-migrate-data.sql
--
-- Progress monitoring: Watch NOTICE messages for batch progress
--
-- Rollback: DROP TABLE paths_provisional; DROP TABLE blobs_provisional; (data migration is idempotent)

\timing on
\set ON_ERROR_STOP on

\echo '================================================================================'
\echo 'PHASE 2: Migrating data using per-partition processing'
\echo '================================================================================'
\echo ''
\echo 'Strategy: Process 244K partition pairs individually to avoid planning overhead'
\echo 'Expected time: 15-30 minutes (vs 1+ hour for cross-partition queries)'
\echo ''

-- ============================================================================
-- STEP 2.1: Populate blobs_provisional table
-- ============================================================================

\echo '================================================================================'
\echo 'STEP 2.1: Populating blobs_provisional table'
\echo '================================================================================'

BEGIN;

-- Copy from blobs_old (fast - 32 seconds for ~7M rows)
-- Note: size will be populated later from paths_provisional (Step 2.3)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'blobs_old') THEN
        RAISE NOTICE 'Copying blobs from blobs_old (size will be added in Step 2.3)...';

        INSERT INTO blobs_provisional (
            blobid,
            mime_type,
            last_checked,
            extraction_status,
            extracted_at,
            extraction_error
        )
        SELECT
            b.blobid,
            b.mime_type,
            b.last_checked,
            b.extraction_status,
            b.extracted_at,
            b.extraction_error
        FROM blobs_old b
        ON CONFLICT (blobid) DO NOTHING;

        RAISE NOTICE 'Copied % blobs from blobs_old', (SELECT COUNT(*) FROM blobs_provisional);
    ELSE
        RAISE NOTICE 'blobs_old does not exist, will populate from paths_provisional in Step 2.3';
    END IF;
END $$;

-- Temporarily disable FK constraint to allow path migration (if it exists)
-- We'll populate missing blobids in Step 2.3 from paths_provisional
\echo 'Temporarily disabling FK constraint for migration...'

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'paths_provisional_blobid_fkey'
        AND conrelid = 'paths_provisional'::regclass
    ) THEN
        ALTER TABLE paths_provisional DROP CONSTRAINT paths_provisional_blobid_fkey;
        RAISE NOTICE 'Dropped FK constraint';
    ELSE
        RAISE NOTICE 'FK constraint does not exist, skipping';
    END IF;
END $$;

COMMIT;

-- Report blob statistics
SELECT
    COUNT(*) as total_blobs,
    COUNT(*) FILTER (WHERE extraction_status IS NOT NULL) as with_extraction_status,
    pg_size_pretty(SUM(size)) as total_content_size,
    pg_size_pretty(pg_total_relation_size('blobs_provisional')) as table_size
FROM blobs_provisional;

\echo 'Step 2.1 complete'
\echo ''

-- ============================================================================
-- STEP 2.2: Populate paths_provisional table (per-partition processing)
-- ============================================================================

\echo '================================================================================'
\echo 'STEP 2.2: Populating paths_provisional using per-partition processing'
\echo '================================================================================'
\echo ''
\echo 'Why per-partition: Cross-partition planning takes 1.6s per query × 244K = 108 hours'
\echo 'Per-partition processing: Simple plans, proven 10-60× faster'
\echo ''
\echo 'Progress will be reported every 1000 partitions.'
\echo ''

DO $$
DECLARE
    partition_name text;
    inode_partition text;
    rows_inserted int;
    total_inserted int := 0;
    partition_count int := 0;
    total_partitions int;
    start_time timestamp;
    batch_start_count int := 0;
    elapsed interval;
BEGIN
    -- Count total partitions (both path_% and path_p_% patterns)
    SELECT COUNT(*) INTO total_partitions
    FROM pg_tables
    WHERE tablename LIKE 'path\_%' ESCAPE '\'
       OR tablename LIKE 'path\_p\_%' ESCAPE '\';

    RAISE NOTICE 'Starting per-partition migration for % path partitions', total_partitions;
    RAISE NOTICE 'Progress will be reported every 1000 partitions with insertion rate';
    RAISE NOTICE 'Expected rate WITHOUT indexes: 50,000-100,000 rows/sec';
    RAISE NOTICE '';
    start_time := clock_timestamp();

    -- Process each partition pair directly (no cross-partition planning)
    -- Handles both path_HASH and path_p_HASH naming patterns
    FOR partition_name IN
        SELECT tablename
        FROM pg_tables
        WHERE tablename LIKE 'path\_%' ESCAPE '\'
           OR tablename LIKE 'path\_p\_%' ESCAPE '\'
        ORDER BY tablename
    LOOP
        -- Derive corresponding inode partition name
        -- path_HASH → inode_HASH or path_p_HASH → inode_p_HASH
        inode_partition := 'inode_' || substring(partition_name from 6);

        -- Insert from this specific partition pair only
        -- Use LEFT JOIN to preserve paths even if inode metadata is missing
        EXECUTE format('
            INSERT INTO paths_provisional (
                medium_hash, dev, ino, path,
                mtime, size, fs_type, nlink,
                blobid, copied, processed_at,
                broken, exclude_reason
            )
            SELECT
                p.medium_hash,
                p.dev,
                p.ino,
                p.path,
                i.mtime,
                i.size,
                i.fs_type,
                i.nlink,
                i.blobid,
                i.copied,
                i.processed_at,
                p.broken,
                p.exclude_reason
            FROM %I p
            LEFT JOIN %I i USING (medium_hash, ino)
        ', partition_name, inode_partition);

        GET DIAGNOSTICS rows_inserted = ROW_COUNT;
        total_inserted := total_inserted + rows_inserted;
        partition_count := partition_count + 1;

        -- Log large partitions (path_p_* partitions are typically huge)
        IF partition_name LIKE 'path\_p\_%' ESCAPE '\' THEN
            RAISE NOTICE 'Processed large partition % (% rows), total so far: %',
                         partition_name, rows_inserted, total_inserted;
        END IF;

        -- Report progress every 1000 partitions and commit
        IF partition_count % 1000 = 0 THEN
            elapsed := clock_timestamp() - start_time;
            RAISE NOTICE 'Progress: %/% partitions (%.1f%%), % paths inserted, last 1000 partitions: % in %, rate: %/sec',
                         partition_count,
                         total_partitions,
                         (partition_count::float / total_partitions * 100),
                         total_inserted,
                         (total_inserted - batch_start_count),
                         elapsed,
                         ROUND(((total_inserted - batch_start_count)::numeric / EXTRACT(EPOCH FROM elapsed))::numeric, 0);
            COMMIT;
            batch_start_count := total_inserted;
            start_time := clock_timestamp();
        END IF;
    END LOOP;

    -- Final commit
    COMMIT;

    elapsed := clock_timestamp() - start_time;
    RAISE NOTICE 'Migration complete: % partitions processed, % paths inserted, final batch elapsed: %',
                 partition_count, total_inserted, elapsed;
END $$;

\echo ''
\echo 'Step 2.2 complete'
\echo ''

-- ============================================================================
-- STEP 2.3: Populate missing blobids and sizes from paths_provisional
-- ============================================================================

\echo '================================================================================'
\echo 'STEP 2.3: Populating missing blobids and sizes from paths_provisional'
\echo '================================================================================'

\echo 'Creating temporary distinct blobids list (this may take 2-5 minutes)...'

-- Create temp table with distinct blobids from paths (much faster than NOT EXISTS)
CREATE TEMP TABLE temp_blobids AS
SELECT DISTINCT ON (blobid) blobid, size, 'application/octet-stream'::text as mime_type
FROM paths_provisional
WHERE blobid IS NOT NULL
ORDER BY blobid;

\echo 'Inserting missing blobids into blobs_provisional...'

-- Insert only the missing blobids (uses temp table, much faster)
INSERT INTO blobs_provisional (blobid, size, mime_type)
SELECT t.blobid, t.size, t.mime_type
FROM temp_blobids t
WHERE NOT EXISTS (SELECT 1 FROM blobs_provisional WHERE blobid = t.blobid)
ON CONFLICT (blobid) DO NOTHING;

\echo 'Updating sizes for existing blobs...'

-- Update sizes for existing blobs (now uses temp table)
UPDATE blobs_provisional
SET size = t.size
FROM temp_blobids t
WHERE blobs_provisional.blobid = t.blobid
  AND blobs_provisional.size IS NULL;

DROP TABLE temp_blobids;

\echo 'Re-enabling foreign key constraint...'

-- Re-enable FK constraint
ALTER TABLE paths_provisional
    ADD CONSTRAINT paths_provisional_blobid_fkey
    FOREIGN KEY (blobid) REFERENCES blobs_provisional(blobid);

\echo 'Step 2.3 complete'
\echo ''

-- ============================================================================
-- STEP 2.4: Verify migration completeness
-- ============================================================================

\echo '================================================================================'
\echo 'STEP 2.4: Verifying migration completeness'
\echo '================================================================================'

DO $$
DECLARE
    expected_count bigint := 231628765;  -- From SELECT COUNT(*) FROM path
    actual_count bigint;
BEGIN
    SELECT COUNT(*) INTO actual_count FROM paths_provisional;

    RAISE NOTICE 'Expected paths: %', expected_count;
    RAISE NOTICE 'Migrated paths: %', actual_count;

    IF actual_count != expected_count THEN
        RAISE EXCEPTION 'Migration incomplete: expected % paths, got % (missing %)',
                        expected_count, actual_count, (expected_count - actual_count);
    END IF;

    RAISE NOTICE 'SUCCESS: All % paths migrated successfully', actual_count;
END $$;

\echo 'Step 2.4 complete: Migration verified'
\echo ''

-- ============================================================================
-- STEP 2.5: Post-migration statistics
-- ============================================================================

\echo '================================================================================'
\echo 'Post-migration statistics'
\echo '================================================================================'

SELECT
    'paths_provisional' as table_name,
    COUNT(*) as total_paths,
    COUNT(DISTINCT medium_hash) as media_count,
    COUNT(DISTINCT (medium_hash, ino)) as unique_inodes,
    COUNT(*) - COUNT(DISTINCT (medium_hash, ino)) as hardlink_instances,
    COUNT(*) FILTER (WHERE copied = true) as copied_paths,
    COUNT(*) FILTER (WHERE copied = false) as unclaimed_paths,
    pg_size_pretty(pg_total_relation_size('paths_provisional')) as table_size
FROM paths_provisional;

\echo ''
\echo '================================================================================'
\echo 'Phase 2 complete: All 231,628,765 paths migrated and verified'
\echo 'Next step: Run phase3-verification.sql'
\echo '================================================================================'

\timing off
