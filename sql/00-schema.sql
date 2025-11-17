-- NTT v2.0 schema (Post-partition elimination, Nov 2025)
-- For migration history, see: docs/schema-evolution.md
CREATE EXTENSION IF NOT EXISTS blake3;

-- ============================================================================
-- Medium table (disk/archive metadata)
-- ============================================================================
CREATE TABLE medium (
    medium_hash       text PRIMARY KEY,
    medium_human      text,
    added_at          timestamptz DEFAULT now(),
    health            text CHECK (health IN ('ok', 'incomplete', 'corrupt', 'failed')),
    image_path        text,
    enum_done         timestamptz,
    copy_done         timestamptz,
    message           text,
    diagnostics       text,
    problems          jsonb,
    medium_type       text DEFAULT 'physical' CHECK (medium_type IN ('physical', 'extracted', 'carved')),
    source_blobid     text,
    extraction_method text,
    extracted_at      timestamptz
);

-- ============================================================================
-- Paths table (unpartitioned, denormalized)
-- ============================================================================
-- Replaces old separate inode + path tables with partitions.
-- All file metadata is stored here in a single table.
CREATE TABLE paths (
    medium_hash    text NOT NULL REFERENCES medium(medium_hash) ON DELETE CASCADE,
    dev            bigint NOT NULL,
    ino            bigint NOT NULL,
    path           bytea NOT NULL,
    mtime          bigint,
    size           bigint,
    fs_type        char(1),
    nlink          int,
    blobid         text,
    copied         boolean DEFAULT false,
    processed_at   timestamptz,
    broken         boolean DEFAULT false,
    exclude_reason text
);

CREATE INDEX idx_paths_medium_hash ON paths(medium_hash);
CREATE INDEX idx_paths_medium_hash_copied ON paths(medium_hash, copied) WHERE copied = false;
CREATE INDEX idx_paths_medium_hash_ino ON paths(medium_hash, ino);
CREATE INDEX idx_paths_medium_hash_ino_path ON paths(medium_hash, ino, path);

-- ============================================================================
-- Blobs table (content-addressed storage)
-- ============================================================================
CREATE TABLE blobs (
    blobid            text PRIMARY KEY,
    size              bigint,
    mime_type         text,
    first_seen        timestamptz DEFAULT now(),
    last_checked      timestamptz,
    extraction_status text,
    extracted_at      timestamptz,
    extraction_error  text
);

CREATE INDEX idx_blobs_blobid ON blobs(blobid);
