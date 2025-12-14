-- Phase 3: Analysis queries for file similarity results
-- Author: PB and Claude
-- Date: 2025-11-21
-- Purpose: Analyze match quality, identify unmatched files, create top matches view

\timing on
\set ECHO all

DO $$
BEGIN
    RAISE NOTICE '[%] Phase 3: Creating analysis views and running quality checks...', clock_timestamp();
END $$;

-- Top matches per carved file (limit to top 10 per file)
DROP MATERIALIZED VIEW IF EXISTS top_matches_per_carved_file;

CREATE MATERIALIZED VIEW top_matches_per_carved_file AS
WITH ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY dd4918_blobid ORDER BY containment_dd DESC, shared_chunks DESC) as rank
    FROM file_similarity
)
SELECT * FROM ranked WHERE rank <= 10;

DO $$
DECLARE
    row_count bigint;
BEGIN
    SELECT COUNT(*) INTO row_count FROM top_matches_per_carved_file;
    RAISE NOTICE '[%] Created top_matches_per_carved_file with % matches.', clock_timestamp(), row_count;
END $$;

CREATE INDEX idx_top_matches_dd ON top_matches_per_carved_file(dd4918_blobid);
CREATE INDEX idx_top_matches_rank ON top_matches_per_carved_file(rank);

-- Match quality distribution
DO $$
BEGIN
    RAISE NOTICE '[%] Analyzing match quality distribution...', clock_timestamp();
END $$;

SELECT
    CASE
        WHEN containment_dd >= 0.95 THEN 'exact_or_near_exact'
        WHEN containment_dd >= 0.8 THEN 'high_confidence'
        WHEN containment_dd >= 0.5 THEN 'medium_confidence'
        ELSE 'low_confidence'
    END as match_quality,
    COUNT(DISTINCT dd4918_blobid) as carved_files,
    COUNT(*) as total_matches,
    ROUND(AVG(containment_dd)::numeric, 3) as avg_containment_dd,
    ROUND(AVG(containment_other)::numeric, 3) as avg_containment_other,
    ROUND(AVG(jaccard)::numeric, 3) as avg_jaccard,
    ROUND(AVG(shared_chunks)::numeric, 1) as avg_shared_chunks
FROM file_similarity
GROUP BY 1
ORDER BY 1;

-- Coverage statistics
DO $$
BEGIN
    RAISE NOTICE '[%] Computing coverage statistics...', clock_timestamp();
END $$;

WITH dd4918_unique AS (
    SELECT COUNT(DISTINCT blobid) as total
    FROM paths
    WHERE medium_hash LIKE 'dd4918%'
      AND blobid IS NOT NULL
      AND blobid NOT IN (SELECT DISTINCT blobid FROM paths WHERE medium_hash NOT LIKE 'dd4918%')
),
matched AS (
    SELECT COUNT(DISTINCT dd4918_blobid) as matched_count
    FROM file_similarity
)
SELECT
    du.total as total_unique_dd4918_blobs,
    m.matched_count as blobs_with_partial_matches,
    du.total - m.matched_count as blobs_with_no_matches,
    ROUND(100.0 * m.matched_count / du.total, 2) as pct_matched
FROM dd4918_unique du, matched m;

-- Identify truly unique files (no partial matches at all)
DROP TABLE IF EXISTS dd4918_unique_final;

CREATE TABLE dd4918_unique_final AS
SELECT blobid
FROM paths
WHERE medium_hash LIKE 'dd4918%'
  AND blobid IS NOT NULL
  AND blobid NOT IN (SELECT DISTINCT blobid FROM paths WHERE medium_hash NOT LIKE 'dd4918%')
  AND blobid NOT IN (SELECT dd4918_blobid FROM file_similarity);

DO $$
DECLARE
    row_count bigint;
BEGIN
    SELECT COUNT(*) INTO row_count FROM dd4918_unique_final;
    RAISE NOTICE '[%] Found % truly unique files with no matches.', clock_timestamp(), row_count;
END $$;

CREATE INDEX idx_unique_final_blobid ON dd4918_unique_final(blobid);

-- Sample of best matches for validation
DO $$
BEGIN
    RAISE NOTICE '[%] Showing sample of best matches for validation...', clock_timestamp();
END $$;

SELECT
    dd4918_blobid,
    other_blobid,
    shared_chunks,
    dd4918_total_chunks,
    other_total_chunks,
    ROUND(containment_dd::numeric, 3) as cont_dd,
    ROUND(containment_other::numeric, 3) as cont_other,
    ROUND(jaccard::numeric, 3) as jaccard
FROM file_similarity
WHERE rank = 1  -- Only best match per file
ORDER BY containment_dd DESC
LIMIT 20;

DO $$
BEGIN
    RAISE NOTICE '[%] Phase 3 analysis complete.', clock_timestamp();
END $$;
