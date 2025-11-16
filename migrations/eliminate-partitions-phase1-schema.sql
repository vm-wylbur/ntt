-- Author: PB and Claude
-- Date: 2025-11-15
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/migrations/eliminate-partitions-phase1-schema.sql
--
-- PHASE 1: Create new unpartitioned schema (blobs_provisional + paths_provisional)
--
-- This creates new tables WITHOUT dropping old partitioned tables.
-- Safe to run - no data loss risk.
--
-- Rollback: DROP TABLE paths_provisional; DROP TABLE blobs_provisional; ALTER TABLE blobs_old RENAME TO blobs;

BEGIN;

\echo '================================================================================'
\echo 'PHASE 1: Creating new unpartitioned schema'
\echo '================================================================================'

-- ============================================================================
-- STEP 1: Rename existing blobs table
-- ============================================================================

\echo 'Step 1: Renaming blobs → blobs_old'

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'blobs') THEN
        ALTER TABLE blobs RENAME TO blobs_old;
        RAISE NOTICE 'Renamed blobs → blobs_old';
    ELSE
        RAISE NOTICE 'Table blobs does not exist, skipping rename';
    END IF;
END $$;

-- ============================================================================
-- STEP 2: Create new blobs_provisional table (content-addressed storage)
-- ============================================================================

\echo 'Step 2: Creating blobs_provisional table'

CREATE TABLE blobs_provisional (
    blobid      text PRIMARY KEY,       -- blake3 hash (hex string, unique content identifier)
    size        bigint,                 -- deterministic from blobid (will be populated from inode)
    mime_type   text,                   -- deterministic from blobid
    first_seen  timestamptz DEFAULT now(),

    -- Verification tracking (from blobs_old)
    last_checked timestamptz,

    -- Extraction tracking (from blobs_old)
    extraction_status   text,
    extracted_at        timestamptz,
    extraction_error    text
);

\echo 'Blobs_provisional table created (indexes will be added later)'

-- ============================================================================
-- STEP 3: Create new unpartitioned paths_provisional table
-- ============================================================================

\echo 'Step 3: Creating paths_provisional table (unpartitioned)'

CREATE TABLE paths_provisional (
    medium_hash text NOT NULL REFERENCES medium(medium_hash) ON DELETE CASCADE,
    dev         bigint NOT NULL,
    ino         bigint NOT NULL,
    path        bytea NOT NULL,

    -- Per-instance metadata (varies across media, from inode table):
    mtime       bigint,
    size        bigint,               -- needed before blobid computed
    fs_type     char(1),              -- 'f', 'd', 'l'
    nlink       int,

    -- Link to deduplicated content (NULL until copied):
    blobid      text REFERENCES blobs_provisional(blobid),

    -- Status (work queue moved to Redis):
    copied      boolean DEFAULT false,
    processed_at timestamptz,

    -- Existing path columns:
    broken         boolean DEFAULT false,
    exclude_reason text

    -- NO PRIMARY KEY OR INDEXES during bulk load!
    -- Will be added in Phase 3 after data migration completes
);

\echo 'Paths_provisional table created (indexes will be added later)'

-- ============================================================================
-- VERIFICATION
-- ============================================================================

\echo ''
\echo '================================================================================'
\echo 'VERIFICATION'
\echo '================================================================================'

SELECT 'blobs_provisional' as table_name,
       pg_size_pretty(pg_total_relation_size('blobs_provisional')) as size;

SELECT 'paths_provisional' as table_name,
       pg_size_pretty(pg_total_relation_size('paths_provisional')) as size;

\echo ''
\echo 'Phase 1 complete: New schema created successfully'
\echo 'Next step: Run phase2-migrate-data.sql'

COMMIT;
