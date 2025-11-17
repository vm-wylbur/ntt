-- Author: PB and Claude
-- Date: 2025-10-05
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/sql/partition-migration-step1-create.sql
--
-- PARTITION MIGRATION - STEP 1: Create partitioned tables
--
-- This migration converts inode and path tables to LIST partitioning by medium_hash.
-- Benefits:
--   - New medium inserts hit empty partition (zero ON CONFLICT overhead)
--   - Queries by medium_hash use partition pruning
--   - Each medium has isolated indexes (11M rows vs 122M rows)
--
-- Expected performance improvement:
--   - bb22 load (11.2M paths): Hours → ~30 seconds for dedupe phase
--
-- Safety: Creates new tables (_new suffix), does NOT modify existing tables
-- Rollback: Simply drop the _new tables

BEGIN;

-- ============================================================================
-- STEP 1A: Create partitioned parent tables
-- ============================================================================

-- Partitioned inode table
CREATE TABLE inode_new (
    medium_hash     text        NOT NULL,
    dev             bigint      NOT NULL,
    ino             bigint      NOT NULL,
    nlink           integer,
    size            bigint,
    mtime           bigint,
    blobid          text,
    copied          boolean     DEFAULT false,
    copied_to       text,
    errors          text[]      DEFAULT '{}',
    fs_type         char(1),
    mime_type       varchar(255),
    processed_at    timestamptz,
    by_hash_created boolean     DEFAULT false,
    claimed_by      text,
    claimed_at      timestamptz,
    PRIMARY KEY (medium_hash, ino)
) PARTITION BY LIST (medium_hash);

-- Partitioned path table
CREATE TABLE path_new (
    medium_hash    text    NOT NULL,
    dev            bigint  NOT NULL,
    ino            bigint  NOT NULL,
    path           bytea   NOT NULL,
    broken         boolean DEFAULT false,
    blobid         text,
    exclude_reason text,
    PRIMARY KEY (medium_hash, path)
) PARTITION BY LIST (medium_hash);

-- ============================================================================
-- STEP 1B: Create indexes on parent tables (will auto-create on partitions)
-- ============================================================================

-- Inode indexes (from current production schema)
CREATE INDEX idx_inode_new_by_hash_created ON inode_new (by_hash_created)
    WHERE by_hash_created = false;

CREATE INDEX idx_inode_new_file_uncopied ON inode_new (fs_type, copied)
    WHERE fs_type = 'f' AND copied = false;

CREATE INDEX idx_inode_new_fs_type ON inode_new (fs_type);

CREATE INDEX idx_inode_new_fs_type_copied ON inode_new (fs_type, copied)
    WHERE fs_type = 'f' AND copied = true;

CREATE INDEX idx_inode_new_hash ON inode_new (blobid)
    WHERE blobid IS NOT NULL;

CREATE INDEX idx_inode_new_mime_type ON inode_new (mime_type);

CREATE INDEX idx_inode_new_processed_at ON inode_new (processed_at)
    WHERE processed_at IS NOT NULL;

CREATE INDEX idx_inode_new_processed_recent ON inode_new (processed_at DESC)
    WHERE copied = true;

CREATE INDEX idx_inode_new_unclaimed ON inode_new (claimed_at)
    WHERE copied = false AND claimed_by IS NULL;

CREATE INDEX idx_inode_new_unclaimed_medium ON inode_new (medium_hash, ino)
    WHERE copied = false AND claimed_by IS NULL;

-- Path indexes (from current production schema)
CREATE INDEX idx_path_new_dev_ino ON path_new (dev, ino);

CREATE INDEX idx_path_new_excluded ON path_new (medium_hash, ino)
    WHERE exclude_reason IS NOT NULL;

CREATE INDEX idx_path_new_only ON path_new (path);

CREATE INDEX idx_path_new_valid ON path_new (medium_hash, ino)
    WHERE exclude_reason IS NULL;

-- ============================================================================
-- STEP 1C: Create foreign key from inode_new to medium
-- ============================================================================

ALTER TABLE inode_new
    ADD CONSTRAINT inode_new_medium_hash_fkey
    FOREIGN KEY (medium_hash) REFERENCES medium(medium_hash) ON DELETE CASCADE;

-- Note: Foreign key from path_new to inode_new will be added after partitions are created
-- (PostgreSQL requires partitions to exist before FK between partitioned tables)

COMMIT;

-- ============================================================================
-- VERIFICATION QUERIES
-- ============================================================================

-- Verify parent tables exist
SELECT 'inode_new' as table_name,
       count(*) as partition_count
FROM pg_inherits
WHERE inhparent = 'inode_new'::regclass;

SELECT 'path_new' as table_name,
       count(*) as partition_count
FROM pg_inherits
WHERE inhparent = 'path_new'::regclass;

-- Expected output: 0 partitions (will be created in step 2)
