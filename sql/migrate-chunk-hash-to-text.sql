-- Migration: Convert chunk_hash from bytea to text (hex)
-- Author: PB and Claude
-- Date: 2025-11-21

\timing on
\set ECHO all

DO $$
BEGIN
    RAISE NOTICE 'Starting migration at %', clock_timestamp();
END $$;

BEGIN;

-- Step 1: Add new text column
DO $$
BEGIN
    RAISE NOTICE '[%] Step 1: Adding chunk_hash_hex column...', clock_timestamp();
END $$;

ALTER TABLE file_chunks ADD COLUMN chunk_hash_hex text;

DO $$
BEGIN
    RAISE NOTICE '[%] Step 1 complete. Column added.', clock_timestamp();
END $$;

-- Step 2: Populate with hex-encoded values (102M rows - will take time)
DO $$
BEGIN
    RAISE NOTICE '[%] Step 2: Converting 102M bytea values to hex text...', clock_timestamp();
    RAISE NOTICE 'This will take several minutes. Please wait...';
END $$;

UPDATE file_chunks SET chunk_hash_hex = encode(chunk_hash, 'hex');

DO $$
DECLARE
    row_count bigint;
BEGIN
    SELECT COUNT(*) INTO row_count FROM file_chunks WHERE chunk_hash_hex IS NOT NULL;
    RAISE NOTICE '[%] Step 2 complete. Converted % rows.', clock_timestamp(), row_count;
END $$;

-- Step 3: Drop old bytea column
DO $$
BEGIN
    RAISE NOTICE '[%] Step 3: Dropping old chunk_hash column...', clock_timestamp();
END $$;

ALTER TABLE file_chunks DROP COLUMN chunk_hash;

DO $$
BEGIN
    RAISE NOTICE '[%] Step 3 complete. Old column dropped.', clock_timestamp();
END $$;

-- Step 4: Rename new column to chunk_hash
DO $$
BEGIN
    RAISE NOTICE '[%] Step 4: Renaming chunk_hash_hex to chunk_hash...', clock_timestamp();
END $$;

ALTER TABLE file_chunks RENAME COLUMN chunk_hash_hex TO chunk_hash;

DO $$
BEGIN
    RAISE NOTICE '[%] Step 4 complete. Column renamed.', clock_timestamp();
END $$;

-- Step 5: Recreate index on new text column
DO $$
BEGIN
    RAISE NOTICE '[%] Step 5: Creating index on chunk_hash...', clock_timestamp();
    RAISE NOTICE 'This will take several minutes. Please wait...';
END $$;

CREATE INDEX idx_chunk_hash ON file_chunks(chunk_hash);

DO $$
BEGIN
    RAISE NOTICE '[%] Step 5 complete. Index created.', clock_timestamp();
    RAISE NOTICE 'Migration complete!';
END $$;

COMMIT;

DO $$
BEGIN
    RAISE NOTICE 'Migration committed at %', clock_timestamp();
END $$;
