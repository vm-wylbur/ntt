-- Create blobs table for content-addressable storage verification
-- Author: PB and Claude
-- Date: 2025-09-29
-- 
-- This table tracks unique content blobs by their hash
-- Future: will hold metadata currently in inode table
--
-- ntt/sql/create_blobs_table.sql

-- Create blobs table
CREATE TABLE IF NOT EXISTS blobs (
    blobid BYTEA PRIMARY KEY,  -- The blake3 hash (unique content identifier)
    last_checked TIMESTAMPTZ,  -- Last verification timestamp (timezone-aware)
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL  -- When blob was first seen
);

-- Create index for verification queries
CREATE INDEX IF NOT EXISTS idx_blobs_last_checked 
ON blobs(last_checked) 
WHERE last_checked IS NOT NULL;

-- Comment the table and columns
COMMENT ON TABLE blobs IS 'Content-addressable blob storage tracking for NTT';
COMMENT ON COLUMN blobs.blobid IS 'Blake3 hash of file content (primary key)';
COMMENT ON COLUMN blobs.last_checked IS 'Last time this blob was verified to exist on disk';
COMMENT ON COLUMN blobs.created_at IS 'When this blob was first added to the system';

-- Grant permissions (adjust user as needed)
-- GRANT SELECT, INSERT, UPDATE ON blobs TO ntt_user;

