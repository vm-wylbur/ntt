-- Phase 1: Build candidate pairs with aggressive filtering
-- Author: PB and Claude
-- Date: 2025-11-21
-- Purpose: Create filtered list of (dd4918_blob, other_blob, shared_chunks) pairs
--          to prevent combinatorial explosion before similarity scoring

\timing on
\set ECHO all

DO $$
BEGIN
    RAISE NOTICE '[%] Phase 1: Creating candidate_pairs table...', clock_timestamp();
    RAISE NOTICE 'Applying aggressive filtering to prevent pair explosion.';
END $$;

-- Drop if exists
DROP TABLE IF EXISTS candidate_pairs;

CREATE TABLE candidate_pairs AS
WITH dd4918_all_blobs AS (
    -- All dd4918 blobs (we'll identify unique ones later)
    SELECT DISTINCT blobid
    FROM paths
    WHERE medium_hash LIKE 'dd4918%'
      AND blobid IS NOT NULL
),
cm_filtered AS (
    -- Filter out high-frequency "stopword" chunks
    SELECT *
    FROM cross_medium_chunks
    WHERE file_count <= 5000                                    -- Global frequency cap
      AND cardinality(dd4918_blobids) <= 10                     -- Per-chunk dd4918 cap
      AND cardinality(other_blobids) <= 10                      -- Per-chunk other cap
      AND cardinality(dd4918_blobids) * cardinality(other_blobids) < 100  -- Pair explosion cap
)
SELECT
    dd_blob,
    other_blob,
    COUNT(*) AS shared_chunks
FROM cm_filtered cm,
     unnest(cm.dd4918_blobids) AS dd_blob,
     unnest(cm.other_blobids) AS other_blob
WHERE dd_blob IN (SELECT blobid FROM dd4918_all_blobs)
GROUP BY dd_blob, other_blob
HAVING COUNT(*) >= 10;  -- Minimum 10 shared chunks

DO $$
DECLARE
    row_count bigint;
BEGIN
    SELECT COUNT(*) INTO row_count FROM candidate_pairs;
    RAISE NOTICE '[%] Created candidate_pairs with % pairs.', clock_timestamp(), row_count;
END $$;

-- Create indexes
DO $$
BEGIN
    RAISE NOTICE '[%] Creating indexes on candidate_pairs...', clock_timestamp();
END $$;

CREATE INDEX idx_cand_dd ON candidate_pairs(dd_blob);
CREATE INDEX idx_cand_other ON candidate_pairs(other_blob);
CREATE INDEX idx_cand_shared ON candidate_pairs(shared_chunks DESC);

ANALYZE candidate_pairs;

DO $$
BEGIN
    RAISE NOTICE '[%] Phase 1 complete. Ready for Phase 2.', clock_timestamp();
END $$;
