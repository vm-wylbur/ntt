-- Author: PB and Claude
-- Date: 2025-10-05
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/sql/partition-migration-step2-partitions.sql
--
-- PARTITION MIGRATION - STEP 2: Create partitions for existing media
--
-- Creates one partition per existing medium_hash (16 total as of 2025-10-05)
-- Each partition will have its own indexes (auto-created from parent indexes)
--
-- Runtime: Fast (just creating empty tables, no data yet)

BEGIN;

-- ============================================================================
-- INODE PARTITIONS
-- ============================================================================

CREATE TABLE inode_p_1d7c9dc8 PARTITION OF inode_new
    FOR VALUES IN ('1d7c9dc81a26c871ccafc71ab284b4aa');

CREATE TABLE inode_p_236d5e0d PARTITION OF inode_new
    FOR VALUES IN ('236d5e0d89eb0e5e78edadf040a7a934');

CREATE TABLE inode_p_2ae4eb92 PARTITION OF inode_new
    FOR VALUES IN ('2ae4eb92379b9892ba93693e49f42e08');

CREATE TABLE inode_p_369372383 PARTITION OF inode_new
    FOR VALUES IN ('369372383055cdf9b0c19d17d055df93');

CREATE TABLE inode_p_488de202 PARTITION OF inode_new
    FOR VALUES IN ('488de202f73bd976de4e7048f4e1f39a');

CREATE TABLE inode_p_983dbb7d PARTITION OF inode_new
    FOR VALUES IN ('983dbb7dfb2a6ea867e233653a64f9d6');

CREATE TABLE inode_p_af1349b9 PARTITION OF inode_new
    FOR VALUES IN ('af1349b9f5f9a1a6a0404dea36dcc949');

CREATE TABLE inode_p_bb226d2a PARTITION OF inode_new
    FOR VALUES IN ('bb226d2ae226b3e048f486e38c55b3bd');

CREATE TABLE inode_p_beb2a986 PARTITION OF inode_new
    FOR VALUES IN ('beb2a986607940cd63f246292efdf0b8');

CREATE TABLE inode_p_c2676ab2 PARTITION OF inode_new
    FOR VALUES IN ('c2676ab2865c5392b7d4745681ebe5b7');

CREATE TABLE inode_p_cd3b7aec PARTITION OF inode_new
    FOR VALUES IN ('cd3b7aec32d3f6c3e2a4011f068895f9');

CREATE TABLE inode_p_cff53715 PARTITION OF inode_new
    FOR VALUES IN ('cff53715105387e3c20b6c2e4d7f305f');

CREATE TABLE inode_p_d9549175 PARTITION OF inode_new
    FOR VALUES IN ('d9549175fb3638efbc919bdc01cb3310');

CREATE TABLE inode_p_eba88f0c PARTITION OF inode_new
    FOR VALUES IN ('eba88f0c1464cf0aad224d9bceff8c47');

CREATE TABLE inode_p_test_baseline PARTITION OF inode_new
    FOR VALUES IN ('test_baseline_final');

CREATE TABLE inode_p_test_100k PARTITION OF inode_new
    FOR VALUES IN ('test_final_100k');

-- ============================================================================
-- PATH PARTITIONS
-- ============================================================================

CREATE TABLE path_p_1d7c9dc8 PARTITION OF path_new
    FOR VALUES IN ('1d7c9dc81a26c871ccafc71ab284b4aa');

CREATE TABLE path_p_236d5e0d PARTITION OF path_new
    FOR VALUES IN ('236d5e0d89eb0e5e78edadf040a7a934');

CREATE TABLE path_p_2ae4eb92 PARTITION OF path_new
    FOR VALUES IN ('2ae4eb92379b9892ba93693e49f42e08');

CREATE TABLE path_p_369372383 PARTITION OF path_new
    FOR VALUES IN ('369372383055cdf9b0c19d17d055df93');

CREATE TABLE path_p_488de202 PARTITION OF path_new
    FOR VALUES IN ('488de202f73bd976de4e7048f4e1f39a');

CREATE TABLE path_p_983dbb7d PARTITION OF path_new
    FOR VALUES IN ('983dbb7dfb2a6ea867e233653a64f9d6');

CREATE TABLE path_p_af1349b9 PARTITION OF path_new
    FOR VALUES IN ('af1349b9f5f9a1a6a0404dea36dcc949');

CREATE TABLE path_p_bb226d2a PARTITION OF path_new
    FOR VALUES IN ('bb226d2ae226b3e048f486e38c55b3bd');

CREATE TABLE path_p_beb2a986 PARTITION OF path_new
    FOR VALUES IN ('beb2a986607940cd63f246292efdf0b8');

CREATE TABLE path_p_c2676ab2 PARTITION OF path_new
    FOR VALUES IN ('c2676ab2865c5392b7d4745681ebe5b7');

CREATE TABLE path_p_cd3b7aec PARTITION OF path_new
    FOR VALUES IN ('cd3b7aec32d3f6c3e2a4011f068895f9');

CREATE TABLE path_p_cff53715 PARTITION OF path_new
    FOR VALUES IN ('cff53715105387e3c20b6c2e4d7f305f');

CREATE TABLE path_p_d9549175 PARTITION OF path_new
    FOR VALUES IN ('d9549175fb3638efbc919bdc01cb3310');

CREATE TABLE path_p_eba88f0c PARTITION OF path_new
    FOR VALUES IN ('eba88f0c1464cf0aad224d9bceff8c47');

CREATE TABLE path_p_test_baseline PARTITION OF path_new
    FOR VALUES IN ('test_baseline_final');

CREATE TABLE path_p_test_100k PARTITION OF path_new
    FOR VALUES IN ('test_final_100k');

-- ============================================================================
-- Add foreign key from path_new to inode_new (now that partitions exist)
-- Note: FK references (medium_hash, ino) in inode_new which is part of its PK
-- ============================================================================

ALTER TABLE path_new
    ADD CONSTRAINT path_new_medium_hash_ino_fkey
    FOREIGN KEY (medium_hash, ino) REFERENCES inode_new(medium_hash, ino) ON DELETE CASCADE;

COMMIT;

-- ============================================================================
-- VERIFICATION QUERIES
-- ============================================================================

-- Count partitions created
SELECT 'inode_new' as table_name,
       count(*) as partition_count
FROM pg_inherits
WHERE inhparent = 'inode_new'::regclass;

SELECT 'path_new' as table_name,
       count(*) as partition_count
FROM pg_inherits
WHERE inhparent = 'path_new'::regclass;

-- Expected output: 16 partitions each

-- List all partitions
SELECT
    nmsp_parent.nspname AS parent_schema,
    parent.relname AS parent_table,
    nmsp_child.nspname AS partition_schema,
    child.relname AS partition_name
FROM pg_inherits
    JOIN pg_class parent ON pg_inherits.inhparent = parent.oid
    JOIN pg_class child ON pg_inherits.inhrelid = child.oid
    JOIN pg_namespace nmsp_parent ON nmsp_parent.oid = parent.relnamespace
    JOIN pg_namespace nmsp_child ON nmsp_child.oid = child.relnamespace
WHERE parent.relname IN ('inode_new', 'path_new')
ORDER BY parent.relname, partition_name;
