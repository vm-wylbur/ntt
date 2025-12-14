-- Create materialized view for chunks appearing in multiple files
-- Author: PB and Claude
-- Date: 2025-11-21

\timing on
\set ECHO all

DO $$
BEGIN
    RAISE NOTICE '[%] Creating duplicate_chunks materialized view...', clock_timestamp();
    RAISE NOTICE 'This will scan 102M chunks and may take several minutes.';
END $$;

CREATE MATERIALIZED VIEW duplicate_chunks AS
SELECT
    chunk_hash,
    COUNT(DISTINCT blobid) as file_count,
    COUNT(*) as occurrence_count,
    MIN(chunk_size) as min_size,
    MAX(chunk_size) as max_size,
    SUM(chunk_size) as total_bytes
FROM file_chunks
GROUP BY chunk_hash
HAVING COUNT(DISTINCT blobid) > 1
ORDER BY file_count DESC;

DO $$
DECLARE
    row_count bigint;
BEGIN
    SELECT COUNT(*) INTO row_count FROM duplicate_chunks;
    RAISE NOTICE '[%] Materialized view created with % duplicate chunks.', clock_timestamp(), row_count;
END $$;

-- Create indexes
DO $$
BEGIN
    RAISE NOTICE '[%] Creating indexes...', clock_timestamp();
END $$;

CREATE INDEX idx_dup_chunks_hash ON duplicate_chunks(chunk_hash);
CREATE INDEX idx_dup_chunks_file_count ON duplicate_chunks(file_count);

DO $$
BEGIN
    RAISE NOTICE '[%] Indexes created. View ready for use.', clock_timestamp();
    RAISE NOTICE 'To refresh: REFRESH MATERIALIZED VIEW duplicate_chunks;';
END $$;
