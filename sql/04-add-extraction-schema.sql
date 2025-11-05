-- Author: PB and Claude
-- Date: 2025-11-05
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/sql/04-add-extraction-schema.sql
--
-- Add schema support for archive/compression extraction
-- Enables tracking of extracted media (from .tar, .zip, .gz, etc.)
-- One extraction per unique blob with full provenance via path table

BEGIN;

-- =============================================================================
-- MEDIUM TABLE EXTENSIONS
-- =============================================================================

-- Track extracted media and extraction metadata
ALTER TABLE medium
  ADD COLUMN medium_type TEXT DEFAULT 'physical',
  ADD COLUMN source_blobid TEXT,
  ADD COLUMN extraction_method TEXT,
  ADD COLUMN extracted_at TIMESTAMP WITH TIME ZONE;

-- Constraints
ALTER TABLE medium
  ADD CONSTRAINT medium_type_check
  CHECK (medium_type IN ('physical', 'extracted', 'carved'));

-- Indexes
CREATE INDEX idx_medium_type ON medium(medium_type);
CREATE INDEX idx_medium_source_blobid ON medium(source_blobid)
  WHERE source_blobid IS NOT NULL;

-- One extraction per blob (deduplication)
CREATE UNIQUE INDEX idx_medium_one_extraction_per_blob
  ON medium(source_blobid)
  WHERE medium_type = 'extracted';

-- =============================================================================
-- BLOBS TABLE EXTENSIONS
-- =============================================================================

-- Track intermediate files and extraction state
ALTER TABLE blobs
  ADD COLUMN is_intermediate BOOLEAN DEFAULT FALSE,
  ADD COLUMN intermediate_of TEXT,
  ADD COLUMN extraction_status TEXT DEFAULT 'pending',
  ADD COLUMN extracted_at TIMESTAMP WITH TIME ZONE,
  ADD COLUMN extraction_error TEXT,
  ADD COLUMN files_extracted INTEGER;

-- Constraints
ALTER TABLE blobs
  ADD CONSTRAINT fk_intermediate_of
  FOREIGN KEY (intermediate_of)
  REFERENCES blobs(blobid)
  ON DELETE SET NULL;

-- Indexes
CREATE INDEX idx_blobs_extraction_pending ON blobs(blobid)
  WHERE extraction_status = 'pending';

CREATE INDEX idx_blobs_extraction_status ON blobs(extraction_status);

CREATE INDEX idx_blobs_intermediates ON blobs(blobid)
  WHERE is_intermediate = TRUE;

CREATE INDEX idx_blobs_extraction_failed ON blobs(blobid)
  WHERE extraction_status = 'failed';

-- =============================================================================
-- BACKFILL
-- =============================================================================

-- Mark all existing media as 'physical' (already done by DEFAULT, but explicit)
UPDATE medium SET medium_type = 'physical' WHERE medium_type IS NULL;

-- Note: We don't mark blobs as extractable/not_extractable here
-- The extractor tool will detect mime_type from blob content at runtime

COMMIT;

-- =============================================================================
-- VALIDATION QUERIES (run after migration)
-- =============================================================================

-- Check schema changes applied
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_name = 'medium'
  AND column_name IN ('medium_type', 'source_blobid', 'extraction_method', 'extracted_at')
ORDER BY column_name;

SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_name = 'blobs'
  AND column_name IN ('is_intermediate', 'intermediate_of', 'extraction_status', 'extracted_at', 'extraction_error', 'files_extracted')
ORDER BY column_name;

-- Check indexes created
SELECT indexname, indexdef
FROM pg_indexes
WHERE tablename IN ('medium', 'blobs')
  AND (indexname LIKE '%extraction%' OR indexname LIKE '%intermediate%')
ORDER BY tablename, indexname;

-- Check backfill
SELECT medium_type, COUNT(*) as count
FROM medium
GROUP BY medium_type
ORDER BY medium_type;

SELECT extraction_status, COUNT(*) as count
FROM blobs
GROUP BY extraction_status
ORDER BY extraction_status;
