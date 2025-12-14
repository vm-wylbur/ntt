-- Author: PB and Claude
-- Date: 2025-11-22
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ---
-- ntt/sql/add-assigned-filetype-column.sql

-- Add assigned_filetype column to blobs table
-- Purpose: Categorize blobs by content type for different indexing pipelines
--
-- Filetype codes:
--   1 = email (RFC822, mbox, EMLX, maildir, MSG, etc.)
--   2 = code (future: git repos, source files)
--   3 = documents (future: PDFs, Word docs, etc.)
--   NULL = not yet categorized

ALTER TABLE blobs
  ADD COLUMN assigned_filetype INTEGER;

-- Create partial index for each filetype (more efficient than full index)
CREATE INDEX idx_blobs_assigned_filetype_email
  ON blobs(assigned_filetype)
  WHERE assigned_filetype = 1;

-- Comment on column for documentation
COMMENT ON COLUMN blobs.assigned_filetype IS
  'Content type category: 1=email, 2=code, 3=documents. NULL=uncategorized.';
