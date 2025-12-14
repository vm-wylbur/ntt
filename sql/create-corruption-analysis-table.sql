-- Create table for dd4918 corruption analysis results
-- Author: PB and Claude
-- Date: 2025-11-22
-- Purpose: Store byte-level corruption analysis from carved GRAID recovery files

\timing on
\set ECHO all

DO $$
BEGIN
    RAISE NOTICE '[%] Creating dd4918_corruption_analysis table...', clock_timestamp();
END $$;

-- Drop if exists
DROP TABLE IF EXISTS dd4918_corruption_analysis;

CREATE TABLE dd4918_corruption_analysis (
    dd_blobid text NOT NULL,
    other_blobid text NOT NULL,
    status text NOT NULL CHECK (status IN ('identical', 'truncated', 'corrupted')),
    dd_size bigint NOT NULL,
    other_size bigint NOT NULL,
    diff_count bigint NOT NULL,
    first_diff_byte bigint,  -- NULL if no diffs

    -- Extra bytes analysis (NULL if not applicable)
    extra_bytes bigint,
    extra_all_zeros boolean,
    extra_pct_zeros numeric(5,2),
    extra_pct_printable numeric(5,2),
    extra_entropy numeric(5,3),

    PRIMARY KEY (dd_blobid, other_blobid)
);

DO $$
BEGIN
    RAISE NOTICE '[%] Creating indexes...', clock_timestamp();
END $$;

CREATE INDEX idx_corruption_dd ON dd4918_corruption_analysis(dd_blobid);
CREATE INDEX idx_corruption_other ON dd4918_corruption_analysis(other_blobid);
CREATE INDEX idx_corruption_status ON dd4918_corruption_analysis(status);

-- Index for finding files with extra padding
CREATE INDEX idx_corruption_extra_zeros ON dd4918_corruption_analysis(extra_all_zeros)
    WHERE extra_bytes IS NOT NULL;

-- Index for size-based queries
CREATE INDEX idx_corruption_sizes ON dd4918_corruption_analysis(dd_size, other_size);

ANALYZE dd4918_corruption_analysis;

DO $$
BEGIN
    RAISE NOTICE '[%] Table created successfully.', clock_timestamp();
    RAISE NOTICE 'Use bin/load-corruption-analysis.py to load data from JSONL files.';
END $$;
