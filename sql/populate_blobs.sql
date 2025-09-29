-- Populate blobs table from existing inode hashes
-- Only inserts unique hashes that don't already exist
--
-- ntt/sql/populate_blobs.sql

-- Insert unique hashes from inode table into blobs
INSERT INTO blobs (blobid, created_at)
SELECT DISTINCT 
    hash as blobid,
    COALESCE(MIN(processed_at), NOW()) as created_at  -- Use NOW() if no processed_at
FROM inode
WHERE hash IS NOT NULL
  AND hash NOT IN (SELECT blobid FROM blobs)  -- Skip existing blobs
GROUP BY hash;

-- Report what was added
SELECT 
    (SELECT COUNT(*) FROM blobs) as total_blobs,
    (SELECT COUNT(DISTINCT hash) FROM inode WHERE hash IS NOT NULL) as total_unique_hashes,
    (SELECT COUNT(*) FROM inode WHERE hash IS NOT NULL) as total_hashed_inodes;

