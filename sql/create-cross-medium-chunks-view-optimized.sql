-- Create view for chunks appearing in both dd4918 (GRAID recovery) and other media
-- Author: PB and Claude
-- Date: 2025-11-21
-- OPTIMIZED VERSION: Uses CTEs to pre-filter blobids, avoiding correlated subqueries

\timing on
\set ECHO all

DO $$
BEGIN
    RAISE NOTICE '[%] Creating cross_medium_chunks view (optimized)...', clock_timestamp();
    RAISE NOTICE 'Finding chunks that appear in GRAID recovery (dd4918) AND other media.';
    RAISE NOTICE 'Optimization: Pre-filtering blobids with CTEs to avoid correlated subqueries.';
END $$;

CREATE MATERIALIZED VIEW cross_medium_chunks AS
WITH dd4918_blobids AS (
    -- Pre-filter: Get all blobids from dd4918 medium (GRAID recovery)
    SELECT DISTINCT blobid
    FROM paths
    WHERE medium_hash LIKE 'dd4918%'
      AND blobid IS NOT NULL
),
other_blobids AS (
    -- Pre-filter: Get all blobids NOT from dd4918
    SELECT DISTINCT blobid
    FROM paths
    WHERE medium_hash NOT LIKE 'dd4918%'
      AND blobid IS NOT NULL
),
dd4918_chunks AS (
    -- Join: Get chunks from dd4918 files
    SELECT fc.chunk_hash, fc.blobid
    FROM file_chunks fc
    INNER JOIN dd4918_blobids db ON fc.blobid = db.blobid
),
other_chunks AS (
    -- Join: Get chunks from other media files
    SELECT fc.chunk_hash, fc.blobid
    FROM file_chunks fc
    INNER JOIN other_blobids ob ON fc.blobid = ob.blobid
),
cross_chunks AS (
    -- Find chunks appearing in BOTH dd4918 AND other media
    SELECT DISTINCT dc.chunk_hash
    FROM dd4918_chunks dc
    INNER JOIN other_chunks oc ON dc.chunk_hash = oc.chunk_hash
)
-- Final aggregation: Get counts and blobid arrays for each cross-medium chunk
SELECT
    cc.chunk_hash,
    dc.file_count,
    COUNT(DISTINCT dchunk.blobid) as dd4918_files,
    COUNT(DISTINCT ochunk.blobid) as other_media_files,
    array_agg(DISTINCT dchunk.blobid) as dd4918_blobids,
    array_agg(DISTINCT ochunk.blobid) as other_blobids
FROM cross_chunks cc
JOIN duplicate_chunks dc ON cc.chunk_hash = dc.chunk_hash
LEFT JOIN dd4918_chunks dchunk ON cc.chunk_hash = dchunk.chunk_hash
LEFT JOIN other_chunks ochunk ON cc.chunk_hash = ochunk.chunk_hash
GROUP BY cc.chunk_hash, dc.file_count
ORDER BY dc.file_count DESC;

DO $$
DECLARE
    row_count bigint;
BEGIN
    SELECT COUNT(*) INTO row_count FROM cross_medium_chunks;
    RAISE NOTICE '[%] View created with % cross-medium chunks.', clock_timestamp(), row_count;
END $$;

-- Create indexes
DO $$
BEGIN
    RAISE NOTICE '[%] Creating indexes...', clock_timestamp();
END $$;

CREATE INDEX idx_cross_medium_hash ON cross_medium_chunks(chunk_hash);
CREATE INDEX idx_cross_medium_dd4918_count ON cross_medium_chunks(dd4918_files);
CREATE INDEX idx_cross_medium_other_count ON cross_medium_chunks(other_media_files);

DO $$
BEGIN
    RAISE NOTICE '[%] Indexes created. View ready for analysis.', clock_timestamp();
    RAISE NOTICE 'To refresh: REFRESH MATERIALIZED VIEW cross_medium_chunks;';
END $$;
