-- Create view for chunks appearing in both dd4918 (GRAID recovery) and other media
-- Author: PB and Claude
-- Date: 2025-11-21

\timing on
\set ECHO all

DO $$
BEGIN
    RAISE NOTICE '[%] Creating cross_medium_chunks view...', clock_timestamp();
    RAISE NOTICE 'Finding chunks that appear in GRAID recovery (dd4918) AND other media.';
END $$;

CREATE MATERIALIZED VIEW cross_medium_chunks AS
SELECT
    dc.chunk_hash,
    dc.file_count,
    COUNT(*) FILTER (WHERE fc.blobid IN (
        SELECT blobid FROM paths WHERE medium_hash LIKE 'dd4918%'
    )) as dd4918_files,
    COUNT(*) FILTER (WHERE fc.blobid NOT IN (
        SELECT blobid FROM paths WHERE medium_hash LIKE 'dd4918%'
    )) as other_media_files,
    array_agg(DISTINCT CASE
        WHEN fc.blobid IN (SELECT blobid FROM paths WHERE medium_hash LIKE 'dd4918%')
        THEN fc.blobid
    END) FILTER (WHERE fc.blobid IN (
        SELECT blobid FROM paths WHERE medium_hash LIKE 'dd4918%'
    )) as dd4918_blobids,
    array_agg(DISTINCT CASE
        WHEN fc.blobid NOT IN (SELECT blobid FROM paths WHERE medium_hash LIKE 'dd4918%')
        THEN fc.blobid
    END) FILTER (WHERE fc.blobid NOT IN (
        SELECT blobid FROM paths WHERE medium_hash LIKE 'dd4918%'
    )) as other_blobids
FROM duplicate_chunks dc
JOIN file_chunks fc ON dc.chunk_hash = fc.chunk_hash
GROUP BY dc.chunk_hash, dc.file_count
HAVING
    COUNT(*) FILTER (WHERE fc.blobid IN (
        SELECT blobid FROM paths WHERE medium_hash LIKE 'dd4918%'
    )) > 0
    AND COUNT(*) FILTER (WHERE fc.blobid NOT IN (
        SELECT blobid FROM paths WHERE medium_hash LIKE 'dd4918%'
    )) > 0
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
