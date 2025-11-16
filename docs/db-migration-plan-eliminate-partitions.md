<!--
Author: PB and Claude
Date: Fri 15 Nov 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/db-migration-plan-eliminate-partitions.md
-->

# Database Migration Plan: Eliminate Partition Lock Contention

**Goal**: Migrate from 488,362 partitioned tables to unpartitioned architecture with blob + path tables + Redis work queue

**Source**: /data/cold/ntt-backup/pgdump/copyjob-2025-11-15T06:15:01-08:00.pgdump (20GB compressed)

---

## Migration Decisions

### Key Design Choices

1. **blobid data type: text (not bytea)**
   - Python generates hex strings via `.hexdigest()` (64 hex chars for BLAKE3-256)
   - Current production schema uses `text` in partitioned inode/path tables
   - No type conversion needed during migration

2. **storage_path: REMOVED (deterministic)**
   - Storage path is computed from blobid: `{storage_root}/{blobid[0:2]}/{blobid[2:4]}/{blobid}`
   - Eliminates redundant data storage
   - Simplifies migration (one less column)

3. **Indexes: deferred**
   - No indexes created during migration
   - Will be added later based on actual query patterns
   - Reduces migration time and complexity

---

## Current Schema Analysis

### Partition Count
- **244,181 inode partitions** (one per medium_hash)
- **244,181 path partitions** (one per medium_hash)
- **Total: 488,362 partitions**

### Current Tables

#### inode (partitioned by medium_hash)
```sql
CREATE TABLE inode (
    medium_hash     text        NOT NULL,
    dev             bigint      NOT NULL,
    ino             bigint      NOT NULL,
    nlink           integer,
    size            bigint,
    mtime           bigint,
    blobid          text,           -- blake3 hash (hex string)
    copied          boolean     DEFAULT false,
    copied_to       text,           -- DROPPED: deterministic from blobid
    errors          text[]      DEFAULT '{}',
    fs_type         char(1),
    mime_type       varchar(255),
    processed_at    timestamptz,
    by_hash_created boolean     DEFAULT false,
    claimed_by      text,           -- work queue coordination
    claimed_at      timestamptz,    -- work queue coordination
    PRIMARY KEY (medium_hash, ino)
) PARTITION BY LIST (medium_hash);
```

**Work queue columns to eliminate**: `claimed_by`, `claimed_at`, `copied` (moving to Redis)
**Redundant column to eliminate**: `copied_to` (deterministic from blobid)

#### path (partitioned by medium_hash)
```sql
CREATE TABLE path (
    medium_hash    text    NOT NULL,
    dev            bigint  NOT NULL,
    ino            bigint  NOT NULL,
    path           bytea   NOT NULL,
    broken         boolean DEFAULT false,
    blobid         text,
    exclude_reason text,
    PRIMARY KEY (medium_hash, path)
) PARTITION BY LIST (medium_hash);
```

**FK constraint**: path → inode (partition-to-partition FK)

#### blobs (already exists, unpartitioned)
```sql
CREATE TABLE blobs (
    blobid BYTEA PRIMARY KEY,      -- WRONG TYPE: should be text (hex string)
    last_checked TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    -- NEED TO ADD: size, mime_type, extraction_status
);
```

**Migration note**: Old blobs table has wrong data type (bytea vs text). We'll rename it to blobs_old and create new blob table with correct schema.

#### medium (unchanged)
```sql
CREATE TABLE medium (
    medium_hash  text PRIMARY KEY,
    medium_human text,
    added_at     timestamptz DEFAULT now(),
    health       text,
    image_path   text,
    enum_done    timestamptz,
    copy_done    timestamptz
);
```

---

## Target Schema (Proposal)

### New blobs_provisional table (enhanced)
```sql
CREATE TABLE blobs_provisional (
    blobid      text PRIMARY KEY,       -- blake3 hash (hex string, unique content identifier)
    size        bigint NOT NULL,        -- deterministic from blobid
    mime_type   text,                   -- deterministic from blobid
    first_seen  timestamptz DEFAULT now(),

    -- Keep existing verification columns
    last_checked timestamptz,

    -- Extraction tracking (from current blobs table)
    extraction_status   text,
    extracted_at        timestamptz,
    extraction_error    text
);

-- Note: storage_path is deterministic from blobid, computed as:
-- {storage_root}/{blobid[0:2]}/{blobid[2:4]}/{blobid}

-- Indexes will be added later based on actual query patterns
```

### New paths_provisional table (unpartitioned, no inode FK)
```sql
CREATE TABLE paths_provisional (
    medium_hash text REFERENCES medium(medium_hash) ON DELETE CASCADE,
    dev         bigint,
    ino         bigint,
    path        bytea,

    -- Per-instance metadata (varies across media):
    mtime       bigint,
    size        bigint,               -- needed before hash computed
    fs_type     char(1),              -- 'f', 'd', 'l'
    nlink       int,

    -- Link to deduplicated content (NULL until copied):
    blobid      text REFERENCES blobs_provisional(blobid),

    -- Status (work queue moved to Redis):
    copied      boolean DEFAULT false,
    processed_at timestamptz,

    -- Existing columns:
    broken         boolean DEFAULT false,
    exclude_reason text,

    PRIMARY KEY (medium_hash, dev, ino, path)
);

-- Indexes will be added later based on actual query patterns
```

**CRITICAL CHANGE**: No FK to inode table (inode table eliminated entirely)

---

## Migration Strategy

### Phase 1: Schema Creation (Fast)

**Estimated time**: 2 minutes (simplified - no indexes)

```sql
BEGIN;

-- Step 1: Rename existing blobs → blobs_old
ALTER TABLE blobs RENAME TO blobs_old;

-- Step 2: Create new blobs_provisional table
CREATE TABLE blobs_provisional (
    blobid      text PRIMARY KEY,
    size        bigint NOT NULL,
    mime_type   text,
    first_seen  timestamptz DEFAULT now(),
    last_checked timestamptz,
    extraction_status   text,
    extracted_at        timestamptz,
    extraction_error    text
);

-- Indexes will be created later based on actual query patterns

-- Step 3: Create new unpartitioned paths_provisional table
CREATE TABLE paths_provisional (
    medium_hash text REFERENCES medium(medium_hash) ON DELETE CASCADE,
    dev         bigint,
    ino         bigint,
    path        bytea,
    mtime       bigint,
    size        bigint,
    fs_type     char(1),
    nlink       int,
    blobid      text REFERENCES blobs_provisional(blobid),
    copied      boolean DEFAULT false,
    processed_at timestamptz,
    broken         boolean DEFAULT false,
    exclude_reason text,
    PRIMARY KEY (medium_hash, dev, ino, path)
);

-- Indexes will be created later based on actual query patterns

COMMIT;
```

### Phase 2: Data Migration (Partition-by-Partition Processing)

**Critical Insight**: With 488,364 partitions, cross-partition queries have massive planning overhead (1.6s per query × 244K media = 108 hours just in planning). Past experience shows that processing partitions individually is **10-60× faster** than cross-partition queries.

**Data to migrate**:
1. **blobs_provisional table**: Copy from blobs_old, then add size from single inode pass
2. **paths_provisional table**: Direct partition-to-partition processing (no cross-partition planning)

**Estimated time**: 15-30 minutes (based on 22,984-partition precedent scaled to 244K)

#### Step 2.1: Populate blobs_provisional table

**Source**: blobs_old for most data, single inode pass for size

```sql
-- Step 1: Copy from blobs_old (fast - 32 seconds for 7M rows)
INSERT INTO blobs_provisional (
    blobid, mime_type, last_checked,
    extraction_status, extracted_at, extraction_error
)
SELECT blobid, mime_type, last_checked,
       extraction_status, extracted_at, extraction_error
FROM blobs_old
ON CONFLICT (blobid) DO NOTHING;

-- Step 2: Add size from single inode pass (using hash aggregation)
WITH inode_sizes AS (
    SELECT DISTINCT ON (blobid) blobid, size
    FROM inode
    WHERE blobid IS NOT NULL AND size IS NOT NULL
    ORDER BY blobid
)
UPDATE blobs_provisional
SET size = inode_sizes.size
FROM inode_sizes
WHERE blobs_provisional.blobid = inode_sizes.blobid;

-- Step 3: Insert any blobs from inode not in blobs_old
INSERT INTO blobs_provisional (blobid, size, mime_type, first_seen)
SELECT DISTINCT ON (blobid)
    blobid, size, mime_type,
    MIN(processed_at) FILTER (WHERE processed_at IS NOT NULL) OVER (PARTITION BY blobid)
FROM inode
WHERE blobid IS NOT NULL
  AND size IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM blobs_provisional WHERE blobid = inode.blobid)
ON CONFLICT (blobid) DO NOTHING;
```

**Progress tracking**:
```sql
SELECT COUNT(*) FROM blobs_provisional;
```

#### Step 2.2: Populate paths_provisional table (Per-Partition Processing)

**Strategy**: Process partition pairs directly (path_XXXXX + inode_XXXXX) to avoid cross-partition query planning overhead.

**Why this is faster**:
- No cross-partition planning (eliminates 108+ hours of planning time)
- Simple execution plans per partition pair
- Proven: 22,984 partitions in 15 minutes vs 1+ hour for cross-partition query

```sql
DO $$
DECLARE
    partition_name text;
    inode_partition text;
    rows_inserted int;
    total_inserted int := 0;
    partition_count int := 0;
    total_partitions int;
    start_time timestamp;
    elapsed interval;
BEGIN
    -- Count total partitions
    SELECT COUNT(*) INTO total_partitions
    FROM pg_tables WHERE tablename LIKE 'path_%';

    RAISE NOTICE 'Starting per-partition migration for % partitions', total_partitions;
    start_time := clock_timestamp();

    -- Process each partition pair
    FOR partition_name IN
        SELECT tablename
        FROM pg_tables
        WHERE tablename LIKE 'path_%'
        ORDER BY tablename
    LOOP
        -- Derive corresponding inode partition name
        inode_partition := 'inode_' || substring(partition_name from 6);

        -- Insert from this partition pair only
        EXECUTE format('
            INSERT INTO paths_provisional (
                medium_hash, dev, ino, path,
                mtime, size, fs_type, nlink,
                blobid, copied, processed_at,
                broken, exclude_reason
            )
            SELECT
                p.medium_hash, p.dev, p.ino, p.path,
                i.mtime, i.size, i.fs_type, i.nlink,
                i.blobid, i.copied, i.processed_at,
                p.broken, p.exclude_reason
            FROM %I p
            JOIN %I i USING (medium_hash, ino)
        ', partition_name, inode_partition);

        GET DIAGNOSTICS rows_inserted = ROW_COUNT;
        total_inserted := total_inserted + rows_inserted;
        partition_count := partition_count + 1;

        -- Progress every 1000 partitions
        IF partition_count % 1000 = 0 THEN
            elapsed := clock_timestamp() - start_time;
            RAISE NOTICE 'Progress: %/% partitions (%.1f%%), % paths inserted, elapsed: %',
                         partition_count, total_partitions,
                         (partition_count::float / total_partitions * 100),
                         total_inserted, elapsed;
            COMMIT;
            start_time := clock_timestamp();
        END IF;
    END LOOP;

    -- Final commit
    COMMIT;

    elapsed := clock_timestamp() - start_time;
    RAISE NOTICE 'Migration complete: % partitions, % paths inserted, final elapsed: %',
                 partition_count, total_inserted, elapsed;
END $$;
```

**Progress tracking**:
```sql
-- Check progress per medium
SELECT
    m.medium_hash,
    COUNT(DISTINCT p_old.path) as old_paths,
    COUNT(DISTINCT p_new.path) as new_paths,
    COUNT(DISTINCT p_old.path) - COUNT(DISTINCT p_new.path) as remaining
FROM medium m
LEFT JOIN path p_old ON m.medium_hash = p_old.medium_hash
LEFT JOIN paths_provisional p_new ON m.medium_hash = p_new.medium_hash
GROUP BY m.medium_hash
HAVING COUNT(DISTINCT p_old.path) != COUNT(DISTINCT p_new.path)
ORDER BY remaining DESC
LIMIT 20;
```

### Phase 3: Verification (Fast)

**Estimated time**: 10 minutes

```sql
-- 1. Row count verification
SELECT 'inode' as table_name, COUNT(*) as row_count FROM inode
UNION ALL
SELECT 'path' as table_name, COUNT(*) FROM path
UNION ALL
SELECT 'blobs_provisional' as table_name, COUNT(*) FROM blobs_provisional
UNION ALL
SELECT 'paths_provisional' as table_name, COUNT(*) FROM paths_provisional;

-- 2. Verify no data loss (paths)
SELECT
    COUNT(*) as old_paths,
    (SELECT COUNT(*) FROM paths_provisional) as new_paths,
    COUNT(*) - (SELECT COUNT(*) FROM paths_provisional) as difference
FROM path;

-- Expected: difference = 0

-- 3. Verify hardlink deduplication preserved
SELECT
    'old' as schema,
    COUNT(DISTINCT (medium_hash, ino)) as unique_inodes,
    COUNT(*) as total_paths
FROM path
UNION ALL
SELECT
    'new' as schema,
    COUNT(DISTINCT (medium_hash, ino)) as unique_inodes,
    COUNT(*) as total_paths
FROM paths_provisional;

-- Expected: same counts

-- 4. Verify blob deduplication
SELECT
    COUNT(DISTINCT blobid) as unique_blobs_old
FROM inode
WHERE blobid IS NOT NULL;

SELECT COUNT(*) as unique_blobs_new FROM blobs_provisional;

-- Expected: same count

-- Expected: same count

-- 5. Spot check random medium
SELECT medium_hash FROM medium ORDER BY RANDOM() LIMIT 1 \gset

SELECT
    'inode' as source,
    COUNT(*) as count,
    COUNT(DISTINCT blobid) as unique_blobs
FROM inode
WHERE medium_hash = :'medium_hash'
UNION ALL
SELECT
    'paths_provisional' as source,
    COUNT(*) as count,
    COUNT(DISTINCT blobid) as unique_blobs
FROM paths_provisional
WHERE medium_hash = :'medium_hash';

-- Expected: same counts
```

### Phase 4: Cutover (Fast, but requires downtime)

**Estimated time**: 2 minutes

**CRITICAL**: Stop all ntt-copier workers before cutover

```sql
BEGIN;

-- Step 1: Drop old partitioned tables
DROP TABLE path CASCADE;  -- drops all 244,181 partitions
DROP TABLE inode CASCADE; -- drops all 244,181 partitions

-- Step 2: Rename new tables
ALTER TABLE blobs_provisional RENAME TO blobs;
ALTER TABLE paths_provisional RENAME TO path;

-- Step 3: Drop old blobs table
DROP TABLE blobs_old;

COMMIT;
```

### Phase 5: Update Application Code

**Scripts to update**:

1. **ntt-loader** (bin/ntt-loader):
   - Remove partition creation DDL
   - Change INSERT target: `inode` → `path`
   - Add Redis queue population

2. **ntt-copier.py** (bin/ntt-copier.py):
   - Replace `SELECT ... FOR UPDATE SKIP LOCKED` → `r.lpop('work:{medium}')`
   - Change hash computation: update `path` table (not `inode`)
   - INSERT into `blob` table with `ON CONFLICT DO NOTHING`

3. **ntt-orchestrator** (bin/ntt-orchestrator):
   - Remove partition existence checks
   - Add Redis queue management

---

## Rollback Strategy

### Before Cutover (Phase 1-3)

**Safe**: Simply drop new tables and keep using old schema

```sql
DROP TABLE paths_provisional;
DROP TABLE blobs_provisional;
ALTER TABLE blobs_old RENAME TO blobs;
```

### After Cutover (Phase 4)

**Requires restore from pg_dump**

```bash
# 1. Stop all workers
killall ntt-copier.py

# 2. Drop new schema
psql "$NTT_DB_URL" -c "DROP TABLE path CASCADE; DROP TABLE blobs CASCADE;"

# 3. Restore from backup
pg_restore -d copyjob /data/cold/ntt-backup/pgdump/copyjob-2025-11-15T06:15:01-08:00.pgdump

# 4. Verify
psql "$NTT_DB_URL" -c "SELECT COUNT(*) FROM inode; SELECT COUNT(*) FROM path;"
```

---

## Disk Space Requirements

### Current Database Size
**Source**: pg_dump = 20GB compressed

**Estimate uncompressed**: 20GB × 3-5 = 60-100GB (typical pg_dump compression ratio)

### Migration Working Space

**Phase 2 requires**:
- `blobs_provisional` table: ~5-10GB (unique content hashes + metadata)
- `paths_provisional` table: ~50-90GB (all paths + denormalized inode metadata)

**Total working space**: 60-100GB + 55-100GB = **115-200GB minimum**

### After Cutover

**Old tables dropped**: Frees 60-100GB
**Final database size**: 50-90GB (blobs + path only)

**Net disk savings**: ~15-25% due to:
- Eliminated duplicate metadata in 488,362 partitions
- Removed redundant storage_path column (deterministic from blobid)
- No per-partition overhead

---

## Time Estimates

| Phase | Description | Estimated Time |
|-------|-------------|----------------|
| 1 | Schema creation (no indexes) | 2 min |
| 2.1 | Migrate blob table | 5 min |
| 2.2 | Migrate path table (per-partition) | 15-30 min |
| 3 | Verification | 10 min |
| 4 | Cutover (downtime) | 2 min |
| **Total** | | **30-50 minutes** |

**Critical path**: Phase 2.2 (path migration) - scales linearly with partition count

**Performance basis**: Past experience with 22,984 partitions completed in 15 minutes. With 244K partitions (10.6× more), estimated 15-30 minutes using per-partition processing vs 1+ hour for cross-partition queries.

---

## Risk Analysis

### High Risk

1. **Data loss during migration**
   - **Mitigation**: Extensive verification queries (Phase 3)
   - **Rollback**: Restore from pg_dump

2. **Out of disk space during migration**
   - **Mitigation**: Pre-check available space (need 200GB free)
   - **Recovery**: Drop paths_provisional, free space, retry with smaller batches

3. **Long transaction causing lock contention**
   - **Mitigation**: Batch by medium_hash (100 media per commit)
   - **Recovery**: Cancel migration, rollback

### Medium Risk

1. **Verification fails (row count mismatch)**
   - **Mitigation**: Debug with spot checks, identify missing data
   - **Rollback**: Drop new tables, investigate

2. **Application code not updated**
   - **Mitigation**: Test all scripts on staging database first
   - **Recovery**: Quick script fixes (no schema change needed)

### Low Risk

1. **Cutover takes longer than expected**
   - **Impact**: 2-5 minutes downtime instead of 2 minutes
   - **Mitigation**: Pre-stage all cutover SQL

---

## Prerequisites

### Before Starting

1. **Verify backup exists and is restorable**
   ```bash
   pg_restore --list /data/cold/ntt-backup/pgdump/copyjob-2025-11-15T06:15:01-08:00.pgdump | head
   ```

2. **Check disk space**
   ```bash
   df -h /var/lib/postgresql  # need 200GB free
   ```

3. **Stop all workers**
   ```bash
   killall ntt-copier.py
   killall ntt-orchestrator
   ```

4. **Create test database**
   ```bash
   createdb copyjob_migration_test
   pg_restore -d copyjob_migration_test /data/cold/ntt-backup/pgdump/copyjob-2025-11-15T06:15:01-08:00.pgdump
   ```

5. **Test migration on test database first**

---

## Implementation Status

✅ **Migration scripts created**:
- `migrations/eliminate-partitions-phase1-schema.sql`
- `migrations/eliminate-partitions-phase2-migrate-data.sql`
- `migrations/eliminate-partitions-phase3-verification.sql`
- `migrations/eliminate-partitions-phase4-cutover.sql`
- `migrations/eliminate-partitions-rollback.sql`

✅ **Phase 1 complete** (2025-11-15):
- Renamed `blobs` → `blobs_old`
- Created `blobs_provisional` table (empty, 16 kB)
- Created `paths_provisional` table (empty, 16 kB)
- Old partitioned schema still intact

## Next Steps

1. **Test on copyjob_migration_test database**
   ```bash
   createdb copyjob_migration_test
   pg_restore -d copyjob_migration_test /data/cold/ntt-backup/pgdump/copyjob-2025-11-15T06:15:01-08:00.pgdump
   psql -d copyjob_migration_test -f migrations/eliminate-partitions-phase1-schema.sql
   ```

2. **Measure actual migration time on test database**
3. **Verify all checks pass in phase3**
4. **Schedule production migration window**
5. **Update application code** (ntt-loader, ntt-copier.py, ntt-orchestrator)
6. **Execute production migration**

---

## References

- `docs/proposal-eliminate-partition-lock-contention.md` - Original proposal
- `docs/lessons/partition-migration-postmortem-2025-10-05.md` - Previous partition migration issues
- `sql/partition-migration-step*.sql` - Previous partition migration scripts (for reference)
