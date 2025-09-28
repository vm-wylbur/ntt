-- Add processed_at timestamp column to track when items are successfully processed
-- This records the completion time for files copied, directories marked, and symlinks marked

ALTER TABLE inode
ADD COLUMN processed_at TIMESTAMP WITH TIME ZONE;

-- Create index for common queries on processed items
CREATE INDEX idx_inode_processed_at ON inode(processed_at)
WHERE processed_at IS NOT NULL;

-- Create index for finding recently processed items
CREATE INDEX idx_inode_processed_recent ON inode(processed_at DESC)
WHERE copied = true;

COMMENT ON COLUMN inode.processed_at IS 'Timestamp when this inode was successfully processed (copied/marked)';