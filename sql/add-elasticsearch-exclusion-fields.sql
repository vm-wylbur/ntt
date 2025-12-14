-- Author: PB and Claude
-- Date: 2025-11-22
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ---
-- ntt/sql/add-elasticsearch-exclusion-fields.sql

-- Add Elasticsearch exclusion metadata to blobs table
-- Purpose: Mark files to exclude from indexing and provide clean alternatives

ALTER TABLE blobs
  ADD COLUMN exclude_from_index boolean DEFAULT false,
  ADD COLUMN exclusion_reason text,
  ADD COLUMN clean_blobid_alternative text REFERENCES blobs(blobid);

-- Index for filtering excluded blobs
CREATE INDEX idx_blobs_exclude ON blobs(exclude_from_index)
  WHERE exclude_from_index = true;

-- Index on exclusion_reason for analysis
CREATE INDEX idx_blobs_exclusion_reason ON blobs(exclusion_reason)
  WHERE exclusion_reason IS NOT NULL;
