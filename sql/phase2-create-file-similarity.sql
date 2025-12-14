-- Phase 2: Compute similarity metrics using containment approach
-- Author: PB and Claude
-- Date: 2025-11-21
-- Purpose: Calculate containment-based similarity for all candidate pairs
--          Identifies truncated/corrupted files that Jaccard similarity would miss

\timing on
\set ECHO all

DO $$
BEGIN
    RAISE NOTICE '[%] Phase 2: Creating file_similarity view...', clock_timestamp();
    RAISE NOTICE 'Computing containment metrics for candidate pairs.';
END $$;

-- Drop if exists
DROP MATERIALIZED VIEW IF EXISTS file_similarity;

CREATE MATERIALIZED VIEW file_similarity AS
WITH file_chunk_counts AS (
    -- Only compute counts for blobs in candidate_pairs
    SELECT blobid, COUNT(*) AS total_chunks
    FROM file_chunks
    WHERE blobid IN (
        SELECT dd_blob FROM candidate_pairs
        UNION
        SELECT other_blob FROM candidate_pairs
    )
    GROUP BY blobid
)
SELECT
    cp.dd_blob AS dd4918_blobid,
    cp.other_blob AS other_blobid,
    cp.shared_chunks,
    dd_fc.total_chunks AS dd4918_total_chunks,
    other_fc.total_chunks AS other_total_chunks,
    -- Containment metrics (primary)
    cp.shared_chunks::float / NULLIF(dd_fc.total_chunks, 0) AS containment_dd,
    cp.shared_chunks::float / NULLIF(other_fc.total_chunks, 0) AS containment_other,
    cp.shared_chunks::float / NULLIF(LEAST(dd_fc.total_chunks, other_fc.total_chunks), 0) AS containment_max,
    -- Jaccard for reference (will be low for truncated files)
    cp.shared_chunks::float / NULLIF(dd_fc.total_chunks + other_fc.total_chunks - cp.shared_chunks, 0) AS jaccard
FROM candidate_pairs cp
JOIN file_chunk_counts dd_fc ON cp.dd_blob = dd_fc.blobid
JOIN file_chunk_counts other_fc ON cp.other_blob = other_fc.blobid
WHERE cp.shared_chunks::float / NULLIF(dd_fc.total_chunks, 0) >= 0.8  -- 80% of carved file must match
  AND cp.shared_chunks >= 10                                            -- Minimum absolute overlap
ORDER BY containment_dd DESC, shared_chunks DESC;

DO $$
DECLARE
    row_count bigint;
BEGIN
    SELECT COUNT(*) INTO row_count FROM file_similarity;
    RAISE NOTICE '[%] Created file_similarity with % high-quality matches.', clock_timestamp(), row_count;
END $$;

-- Create indexes
DO $$
BEGIN
    RAISE NOTICE '[%] Creating indexes on file_similarity...', clock_timestamp();
END $$;

CREATE INDEX idx_sim_dd ON file_similarity(dd4918_blobid);
CREATE INDEX idx_sim_containment ON file_similarity(containment_dd DESC);

ANALYZE file_similarity;

DO $$
BEGIN
    RAISE NOTICE '[%] Phase 2 complete. Ready for Phase 3 analysis.', clock_timestamp();
END $$;
