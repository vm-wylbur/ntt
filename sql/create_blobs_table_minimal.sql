-- Minimal blobs table - just unique blobids and verification tracking
-- 
-- ntt/sql/create_blobs_table_minimal.sql

-- Create blobs table
CREATE TABLE IF NOT EXISTS blobs (
    blobid BYTEA PRIMARY KEY,      -- The blake3 hash (unique content identifier)
    last_checked TIMESTAMPTZ       -- Last verification timestamp (NULL initially)
);

-- Create index for verification queries
CREATE INDEX IF NOT EXISTS idx_blobs_last_checked 
ON blobs(last_checked) 
WHERE last_checked IS NOT NULL;

-- Comment the table and columns
COMMENT ON TABLE blobs IS 'Unique content blobs by hash';
COMMENT ON COLUMN blobs.blobid IS 'Blake3 hash of file content (primary key)';
COMMENT ON COLUMN blobs.last_checked IS 'Last time this blob was verified to exist on disk';

