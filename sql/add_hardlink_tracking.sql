-- Add columns to track by-hash creation and hardlink counts
-- This enables better tracking of the copy process and recovery from partial runs

-- Add by_hash_created to inode table
-- This tracks whether the by-hash file has been created for this inode's content
ALTER TABLE inode
  ADD COLUMN IF NOT EXISTS by_hash_created BOOLEAN DEFAULT FALSE;

-- Add n_hardlinks to blobs table
-- This tracks how many archived hardlinks have been created for this blob
ALTER TABLE blobs
  ADD COLUMN IF NOT EXISTS n_hardlinks INTEGER DEFAULT 0;

-- Create index for finding inodes that need by-hash creation
CREATE INDEX IF NOT EXISTS idx_inode_by_hash_created
  ON inode(by_hash_created)
  WHERE by_hash_created = FALSE;

-- Create index for finding incomplete blobs
CREATE INDEX IF NOT EXISTS idx_blobs_n_hardlinks
  ON blobs(n_hardlinks);

-- View to show blob completion status
CREATE OR REPLACE VIEW blob_hardlink_status AS
SELECT
    b.blobid,
    encode(b.blobid, 'escape') as blobid_hex,
    b.n_hardlinks as actual_hardlinks,
    COUNT(DISTINCT p.path) as expected_hardlinks,
    COUNT(DISTINCT p.path) - b.n_hardlinks as missing_hardlinks,
    CASE
        WHEN b.n_hardlinks = COUNT(DISTINCT p.path) THEN 'complete'
        WHEN b.n_hardlinks > 0 THEN 'partial'
        ELSE 'none'
    END as status
FROM blobs b
JOIN inode i ON i.hash = b.blobid::bytea
JOIN path p ON p.dev = i.dev AND p.ino = i.ino
GROUP BY b.blobid, b.n_hardlinks;

-- Query to find incomplete blobs
-- Usage: SELECT * FROM blob_hardlink_status WHERE status != 'complete' ORDER BY missing_hardlinks DESC LIMIT 10;

COMMENT ON COLUMN inode.by_hash_created IS 'True if by-hash file has been created for this inodes content';
COMMENT ON COLUMN blobs.n_hardlinks IS 'Number of archived hardlinks created for this blob';
COMMENT ON VIEW blob_hardlink_status IS 'Shows completion status of hardlinks for each blob';
