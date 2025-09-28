-- NTT Schema Migration: Add file type tracking
-- Date: 2025-09-28
-- Purpose: Add fs_type and mime_type columns for intelligent file processing

-- Add filesystem type column
-- Values: 'd'=directory, 'f'=file, 'l'=symlink, 's'=socket,
--         'p'=pipe, 'b'=block device, 'c'=char device, 'u'=unknown
ALTER TABLE inode ADD COLUMN IF NOT EXISTS fs_type CHAR(1);

-- Add MIME type column for content type detection
-- Regular files: actual MIME types like 'image/jpeg', 'text/plain'
-- Directories: 'inode/directory'
-- Symlinks: 'inode/symlink'
-- Other: 'inode/socket', 'inode/fifo', 'inode/blockdevice', 'inode/chardevice'
ALTER TABLE inode ADD COLUMN IF NOT EXISTS mime_type VARCHAR(255);

-- Create indexes for efficient filtering
CREATE INDEX IF NOT EXISTS idx_inode_fs_type ON inode(fs_type);
CREATE INDEX IF NOT EXISTS idx_inode_mime_type ON inode(mime_type);

-- Index for finding unprocessed files of specific type
CREATE INDEX IF NOT EXISTS idx_inode_file_uncopied
ON inode(fs_type, copied)
WHERE fs_type = 'f' AND copied = false;

-- Note: Existing 13.4M+ records will have NULL fs_type and mime_type
-- The updated ntt-copier will detect and populate these values progressively