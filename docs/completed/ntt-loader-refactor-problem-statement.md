<!--
Author: PB and Claude
Date: Sat 16 Nov 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/ntt-loader-refactor-problem-statement.md
-->

# ntt-loader Refactor: Problem Statement

**Created:** 2025-11-16
**Context:** Post-partition-drop migration (Phase 4 complete)
**Status:** Analysis complete, implementation pending

---

## What is NTT?

**NTT (Name TBD) is a disk image deduplication and archival system.** It ingests physical media (hard drives, optical discs, tapes), enumerates filesystem contents, and deduplicates files to content-addressed blob storage.

**Pipeline stages:**
1. **Imaging** - Create disk images from physical media (ddrescue)
2. **Enumeration** (`ntt-enum`) - Walk mounted filesystem, extract inode metadata to .raw files
3. **Loading** (`ntt-loader`) - Import enumeration data into PostgreSQL ← **THIS TOOL**
4. **Copying** (`ntt-copier.py`) - Deduplicate files to by-hash storage with hardlinks
5. **Archiving** - Compress and move to cold storage

**Scale:** ~244,000 media processed, ~232 million filesystem paths, ~488,000 partition tables (being dropped)

**Input Format (.raw files):**
```
# NUL-separated records from ntt-enum (find-based filesystem walk)
f\034201\03412345\0341\03467890\0341637012345\034/path/to/file.txt\0
d\034201\03412346\0342\0344096\0341637012346\034/path/to/dir\0
```
Fields: `fs_type\034dev\034ino\034nlink\034size\034mtime\034path\0` (034 = ASCII FS delimiter)

---

## Executive Summary

**Problem:** ntt-loader is hardcoded for partitioned table architecture that no longer exists after Phase 4 migration.

**Impact:** Cannot ingest new media (including VXA tapes) until loader is refactored for unpartitioned schema.

**Root Cause:** Partitioning was introduced as a **performance optimization** to avoid ON CONFLICT overhead during deduplication. The entire partition architecture exists solely to support loader's TRUNCATE-based reload strategy.

**Solution Required:** Rewrite loader to work with single `paths` table (denormalized, unpartitioned).

**Why This Matters:** The loader is the ONLY reason partitioning existed. All 488,362 partition tables were created solely to support this tool's TRUNCATE-based reload optimization.

---

## Historical Context: Why Partitioning Existed

### The Original Problem (Pre-Partitioning)

**Background:** NTT needs to support **idempotent reloading** - running the loader multiple times on the same medium should produce identical results. This is critical for fixing enumeration errors or handling media that were re-imaged.

When loading enumeration data for a medium that was already loaded:

```sql
-- Without partitioning, this was SLOW:
INSERT INTO path (medium_hash, dev, ino, path, exclude_reason)
SELECT ...
FROM tmp_working_table
ON CONFLICT (medium_hash, ino, path) DO NOTHING;  -- Scanned ENTIRE path table!
```

**Performance issue:** ON CONFLICT scanned all ~200 million existing rows to check for duplicates, even though only ~1000 rows per medium were actually relevant.

### The Partitioning "Solution"

Partitioning was introduced to enable **fast reloading** via TRUNCATE:

```sql
-- Step 1: Auto-create partition for medium (ntt-loader lines 68-73)
CREATE TABLE IF NOT EXISTS path_p_${PARTITION_SUFFIX}
    PARTITION OF path FOR VALUES IN ('$MEDIUM_HASH');

-- Step 2: TRUNCATE partition before INSERT (ntt-loader line 238)
TRUNCATE path_p_${PARTITION_SUFFIX}, inode_p_${PARTITION_SUFFIX};

-- Step 3: INSERT without ON CONFLICT (ntt-loader lines 244-263)
INSERT INTO inode (...) SELECT ...;  -- No ON CONFLICT needed!
INSERT INTO path (...) SELECT ...;   -- Empty partition = zero conflict checks
```

**Key insight:** Partitioning enabled TRUNCATE, which enabled fast reload by eliminating ON CONFLICT overhead.

**Trade-off:**
- **Benefit:** Fast idempotent reloads (TRUNCATE is instant, no conflict checking)
- **Cost:** Created 488,362 partition tables (2 per medium × 244,181 media)
- **Problem:** Partition management became performance bottleneck (see `docs/partition-drop-performance-problem.md`)

**Why we're removing partitions now:** Partition lock contention during concurrent operations became worse than the original ON CONFLICT overhead problem. The cure became worse than the disease.

---

## Current Loader Architecture (Partitioned)

**Note:** All line numbers reference `bin/ntt-loader` (337 lines total).

### Phase 0: Partition Creation (Lines 59-75)

```bash
PARTITION_SUFFIX="${MEDIUM_HASH:0:8}"  # First 8 chars of hash

psql "
CREATE TABLE IF NOT EXISTS inode_p_${PARTITION_SUFFIX}
    PARTITION OF inode FOR VALUES IN ('$MEDIUM_HASH');

CREATE TABLE IF NOT EXISTS path_p_${PARTITION_SUFFIX}
    PARTITION OF path FOR VALUES IN ('$MEDIUM_HASH');
"
```

**Purpose:** Ensure partition exists before INSERT
**Problem:** `inode` and `path` parent tables don't exist anymore

### Phase 1: Working Tables (Lines 77-106)

```sql
CREATE TABLE raw_$$ (
  fs_type char(1), dev bigint, ino bigint, nlink int,
  size bigint, mtime bigint, path text
);

CREATE TABLE tmp_path_$$ (
  medium_hash text, fs_type char(1), dev bigint, ino bigint,
  nlink int, size bigint, mtime numeric, path text, exclude_reason text
);
```

**Purpose:** Temporary staging for raw enumeration data
**Status:** Works fine, no changes needed

### Phase 2: Load Raw Data (Lines 108-166)

```bash
# Escape CR/LF in paths, convert null delimiter to LF
ntt-escape-raw.pl < "$FILE" | psql "
SET client_encoding = 'LATIN1';

COPY raw_$$(fs_type,dev,ino,nlink,size,mtime,path)
FROM STDIN
WITH (FORMAT text, DELIMITER E'\\034', NULL '');
"

# Transfer to working table with medium_hash
INSERT INTO tmp_path_$$ (medium_hash,fs_type,dev,ino,nlink,size,mtime,path)
SELECT '$MEDIUM_HASH', fs_type, dev, ino, nlink, size, mtime, path
FROM raw_$$;
```

**Purpose:** Parse 034-delimited .raw file (output from `ntt-enum`) into working table
**Input format:** NUL-separated records: `fs_type\034dev\034ino\034nlink\034size\034mtime\034path\0`
**Status:** Works fine, no changes needed

### Phase 2.5: Mark Exclusions (Lines 168-194)

```sql
-- Mark paths matching ignore patterns
UPDATE tmp_path_$$
SET exclude_reason = 'pattern_match'
WHERE path ~ '$PATTERNS';

-- Create indexes for deduplication
CREATE INDEX idx_tmp_path_$$_ino ON tmp_path_$$(ino);
CREATE INDEX idx_tmp_path_$$_ino_path ON tmp_path_$$(ino, path);
```

**Purpose:** Apply ignore patterns before final insert
**Status:** Works fine, but exclusion logic will need adjustment for denormalized schema

### Phase 3: Deduplication (Lines 196-294)

**This is where all the partitioning complexity lives.**

#### Step 1: Safety Checks (Lines 215-233)

```sql
-- Verify partition is attached before proceeding
IF NOT EXISTS (
  SELECT 1 FROM pg_inherits
  WHERE inhrelid = 'path_p_${PARTITION_SUFFIX}'::regclass
    AND inhparent = 'path'::regclass
) THEN
  RAISE EXCEPTION 'partition not attached';
END IF;
```

**Problem:** `path` and `inode` parent tables don't exist
**Fix needed:** Remove partition attachment checks

#### Step 2: TRUNCATE Reload (Line 238)

```sql
TRUNCATE path_p_${PARTITION_SUFFIX}, inode_p_${PARTITION_SUFFIX};
```

**Purpose:** Clear old data before reloading (idempotent reload strategy)
**Problem:** Partitions don't exist
**Fix needed:** Change reload strategy

**This is the CORE DESIGN DECISION that drove partitioning.**

#### Step 3: Insert Inodes (Lines 244-256)

```sql
INSERT INTO inode (medium_hash,fs_type,dev,ino,nlink,size,mtime,copied,claimed_by)
SELECT DISTINCT ON (medium_hash, ino)
       '$MEDIUM_HASH', fs_type, dev, ino, nlink, size, mtime,
       CASE WHEN fs_type = 'f' THEN false ELSE true END,
       CASE WHEN fs_type = 'f' THEN NULL ELSE 'NON_FILE' END
FROM tmp_path_$$
ORDER BY medium_hash, ino;
```

**Problem:** `inode` table doesn't exist (replaced by denormalized `paths`)
**Fix needed:** Insert into `paths` table instead, with inode fields denormalized

#### Step 4: Insert Paths (Lines 261-263)

```sql
INSERT INTO path (medium_hash,dev,ino,path,exclude_reason)
SELECT '$MEDIUM_HASH', dev, ino, convert_to(path, 'LATIN1'), exclude_reason
FROM tmp_path_$$;
```

**Problem:** Inserting into separate `path` table (now need single denormalized insert)
**Fix needed:** Combine with inode insert into `paths` table

#### Step 5: Mark Excluded Inodes (Lines 267-276)

```sql
UPDATE inode
SET copied = true, claimed_by = 'EXCLUDED'
WHERE medium_hash = '$MEDIUM_HASH'
  AND NOT EXISTS (
    SELECT 1 FROM path WHERE ... AND exclude_reason IS NULL
  );
```

**Problem:** `inode` table doesn't exist
**Fix needed:** Update `paths.copied` and `paths.claimed_by` for excluded paths

#### Step 6: Queue Stats (Lines 279-289)

```sql
INSERT INTO queue_stats (medium_hash, unclaimed_count, total_count)
SELECT '$MEDIUM_HASH',
  COUNT(*) FILTER (WHERE copied = false AND claimed_by IS NULL),
  COUNT(*)
FROM inode_p_${PARTITION_SUFFIX}
```

**Problem:** Querying partition that doesn't exist
**Fix needed:** Query `paths` table grouped by medium_hash

#### Step 7: ANALYZE (Lines 292-293)

```sql
ANALYZE inode_p_${PARTITION_SUFFIX};
ANALYZE path_p_${PARTITION_SUFFIX};
```

**Problem:** Partitions don't exist
**Fix needed:** `ANALYZE paths;` (only if schema changed)

---

## New Schema: Denormalized `paths` Table

**Post-migration schema (created in Phase 4 cutover, November 2025):**

**Old (partitioned):** Separate `inode` and `path` parent tables, each with 244,181 child partitions
**New (unpartitioned):** Single `paths` table with denormalized inode metadata

```sql
CREATE TABLE paths (
    medium_hash text NOT NULL,
    path bytea NOT NULL,

    -- Inode metadata (denormalized)
    dev bigint NOT NULL,
    ino bigint NOT NULL,

    -- File metadata
    size bigint,
    mtime numeric,
    fs_type char(1),
    nlink integer,

    -- Exclusion tracking
    exclude_reason text,

    -- Deduplication results
    blobid text,
    mime_type text,

    -- Copy worker coordination
    copied boolean DEFAULT false,
    claimed_by text,
    claimed_at timestamp with time zone,
    processed_at timestamp with time zone,

    PRIMARY KEY (medium_hash, path),
    FOREIGN KEY (medium_hash) REFERENCES medium(medium_hash),
    FOREIGN KEY (blobid) REFERENCES blobs(blobid)
);
```

**Key differences from partitioned schema:**

1. **Single table** instead of `inode` + `path` partitions (488,362 tables → 1 table)
2. **Denormalized** - inode metadata (dev, ino, size, mtime, etc.) duplicated for each hardlink path
3. **No partitioning** - all 232M paths in one table, partitioned by medium_hash in old schema
4. **path is bytea** - preserves exact filesystem bytes (unchanged from old schema)
5. **Same columns** - just restructured, same information stored
6. **Same indexes** - PRIMARY KEY (medium_hash, path), INDEX (blobid)

---

## Refactoring Requirements

### Critical Changes

1. **Remove partition creation** (lines 59-75)
   - Delete entire Phase 0

2. **Remove partition safety checks** (lines 215-233)
   - Delete attachment verification logic

3. **Replace TRUNCATE reload strategy** (line 238)
   - Options:
     - **A) DELETE then INSERT:** `DELETE FROM paths WHERE medium_hash = '$MEDIUM_HASH'`
     - **B) UPSERT:** Keep existing ON CONFLICT DO UPDATE (slower but safer)
     - **C) Version tracking:** Add `load_version` column, mark old rows obsolete

4. **Combine inode + path inserts** (lines 244-263)
   - Single INSERT into `paths` with all denormalized columns
   - Handle hardlinks: multiple paths → same (dev, ino) → duplicate inode metadata

5. **Update exclusion logic** (lines 267-276)
   - Update `paths.copied` and `paths.claimed_by` directly
   - No separate inode/path coordination needed

6. **Fix queue_stats query** (lines 279-289)
   - Query `paths` table with `WHERE medium_hash = '$MEDIUM_HASH'`

7. **Simplify ANALYZE** (lines 292-293)
   - Single `ANALYZE paths;` or skip if not needed

### Performance Considerations

**Original partitioned loader performance:** ~6 minutes for 11.2M paths
- 5min COPY + 30sec dedupe
- Fast because TRUNCATE eliminates ON CONFLICT overhead

**New unpartitioned loader challenges:**

1. **DELETE instead of TRUNCATE:**
   ```sql
   DELETE FROM paths WHERE medium_hash = '$MEDIUM_HASH';  -- How long for 11.2M rows?
   ```
   - Needs testing with large media
   - May need autovacuum tuning

2. **Hardlink handling:**
   ```sql
   -- Old schema: DISTINCT ON (medium_hash, ino) → single inode row
   -- New schema: Multiple path rows with duplicated inode metadata

   -- Example: 3 hardlinks to same inode
   -- Old: 1 inode row + 3 path rows = 4 rows total
   -- New: 3 paths rows (inode metadata duplicated) = 3 rows total
   ```
   - More data duplication but simpler query model

3. **Index strategy:**
   ```sql
   -- Current indexes on paths:
   PRIMARY KEY (medium_hash, path)  -- For uniqueness
   INDEX (blobid)                    -- For blob lookups

   -- May need additional indexes:
   INDEX (medium_hash, dev, ino)     -- For hardlink queries?
   INDEX (medium_hash, copied)       -- For queue_stats?
   ```

### Data Flow Comparison

**Old (partitioned):**
```
.raw file
  → raw_$$ temp table
  → tmp_path_$$ working table (with exclusions)
  → TRUNCATE partition
  → INSERT into inode partition (DISTINCT ON ino)
  → INSERT into path partition (all paths)
```

**New (unpartitioned):**
```
.raw file
  → raw_$$ temp table
  → tmp_path_$$ working table (with exclusions)
  → DELETE FROM paths WHERE medium_hash = '$MEDIUM_HASH'
  → INSERT into paths (denormalized, one row per path)
```

---

## Implementation Strategy

### Option A: Minimal Changes (DELETE-based reload)

```sql
-- Phase 3 refactored:

-- Delete existing data for this medium (idempotent reload)
DELETE FROM paths WHERE medium_hash = '$MEDIUM_HASH';

-- Insert all paths with denormalized inode metadata
INSERT INTO paths (
  medium_hash, path, dev, ino, size, mtime, fs_type, nlink,
  exclude_reason, copied, claimed_by
)
SELECT
  '$MEDIUM_HASH',
  convert_to(path, 'LATIN1'),
  dev, ino, size, mtime, fs_type, nlink,
  exclude_reason,
  CASE WHEN fs_type = 'f' AND exclude_reason IS NULL THEN false ELSE true END,
  CASE WHEN fs_type = 'f' AND exclude_reason IS NULL THEN NULL
       WHEN exclude_reason IS NOT NULL THEN 'EXCLUDED'
       ELSE 'NON_FILE' END
FROM tmp_path_$$;

-- Update queue_stats
INSERT INTO queue_stats (medium_hash, unclaimed_count, total_count)
SELECT
  '$MEDIUM_HASH',
  COUNT(*) FILTER (WHERE copied = false AND claimed_by IS NULL),
  COUNT(*)
FROM paths
WHERE medium_hash = '$MEDIUM_HASH'
ON CONFLICT (medium_hash) DO UPDATE
SET unclaimed_count = EXCLUDED.unclaimed_count,
    total_count = EXCLUDED.total_count,
    last_updated = NOW();
```

**Pros:**
- Minimal code changes
- Preserves idempotent reload behavior
- Simple to understand

**Cons:**
- DELETE performance unknown for large media (11M+ rows)
- May create bloat requiring VACUUM

### Option B: Versioned Upsert (no DELETE)

```sql
-- Add load_version to paths table
ALTER TABLE paths ADD COLUMN load_version integer DEFAULT 1;

-- Track version in medium table
ALTER TABLE medium ADD COLUMN last_load_version integer DEFAULT 0;

-- Increment version on reload
UPDATE medium SET last_load_version = last_load_version + 1
WHERE medium_hash = '$MEDIUM_HASH'
RETURNING last_load_version AS new_version;

-- Insert with new version
INSERT INTO paths (..., load_version)
SELECT ..., $new_version
FROM tmp_path_$$;

-- Mark old versions as obsolete (for cleanup later)
UPDATE paths
SET copied = true, claimed_by = 'OBSOLETE'
WHERE medium_hash = '$MEDIUM_HASH'
  AND load_version < $new_version;
```

**Pros:**
- No DELETE (faster, less bloat)
- Preserves history for debugging
- Can clean up asynchronously

**Cons:**
- More complex
- Requires schema changes
- Old rows accumulate until cleanup

### Option C: Hybrid (UPSERT for incremental, DELETE for fresh)

```sql
-- Detect if this is a reload or first load
IF EXISTS (SELECT 1 FROM paths WHERE medium_hash = '$MEDIUM_HASH' LIMIT 1) THEN
  -- Reload: DELETE old data
  DELETE FROM paths WHERE medium_hash = '$MEDIUM_HASH';
END IF;

-- Insert (no ON CONFLICT needed if deleted, or use DO NOTHING for safety)
INSERT INTO paths (...) SELECT ... ON CONFLICT DO NOTHING;
```

**Pros:**
- Flexible
- Optimized for common case (fresh loads)

**Cons:**
- Most complex
- Edge cases to handle

---

## Recommended Approach

**Start with Option A (DELETE-based reload):**

1. Simplest to implement and test
2. Preserves existing reload semantics
3. Performance can be measured and optimized later
4. Can migrate to Option B if DELETE proves too slow

**Performance validation needed:**
- Test DELETE performance on large media (11M+ paths)
- Monitor VACUUM impact
- Compare against old TRUNCATE-based times

---

## Testing Plan

### Phase 1: Smoke Test with Small Media
- **Test medium:** VXA tape1 (348K paths) - enumeration already complete
- **Validate:** INSERT works into unpartitioned paths table
- **Validate:** DELETE + reload works (idempotency)
- **Validate:** Row counts match before/after reload
- **Success criteria:** Completes without errors, queue_stats updated correctly

### Phase 2: Load Test with Large Media
- **Test medium:** Largest existing medium (54M paths, hash: 236d5e0d89eb0e5e78edadf040a7a934)
- **Measure:** DELETE performance (how long to delete 54M rows?)
- **Measure:** Total load time (COPY + dedupe + INSERT)
- **Compare:** Against old baseline (6min for 11.2M paths)
- **Monitor:** VACUUM impact and table bloat

### Phase 3: Edge Cases
- Reload same medium twice (idempotency)
- Media with all excluded paths
- Media with no files (only directories)
- Media with many hardlinks

---

## Migration Checklist

- [ ] Remove partition creation code (lines 59-75)
- [ ] Remove partition safety checks (lines 215-233)
- [ ] Replace TRUNCATE with DELETE (line 238)
- [ ] Combine inode + path insert into single `paths` insert (lines 244-263)
- [ ] Update exclusion logic for denormalized schema (lines 267-276)
- [ ] Fix queue_stats query (lines 279-289)
- [ ] Simplify ANALYZE (lines 292-293)
- [ ] Remove references to `inode_p_*` and `path_p_*`
- [ ] Update error messages and logging
- [ ] Test with VXA tape1 enumeration
- [ ] Update documentation

---

## Impact on Other Tools

**ntt-copier.py:** ✅ Already updated for unpartitioned schema (Phase 4 migration, Nov 2025)
- Queries `paths` table directly instead of `inode` partitions
- Uses denormalized columns (dev, ino, size, etc. in paths table)
- No changes needed for loader refactor

**ntt-orchestrator:** ✅ No changes needed
- Only calls ntt-enum and ntt-loader as subprocesses
- No direct database interaction
- Agnostic to table structure

**ntt-enum:** ✅ No changes needed
- Only writes .raw files (034-delimited filesystem enumeration)
- No database interaction
- Output format unchanged

---

## Success Criteria

1. **Functional:** Can load VXA tape1 enumeration (348K paths) successfully
2. **Performance:** Load time ≤ 2x old baseline for equivalent media
3. **Idempotent:** Reloading same medium produces identical results
4. **Queue Stats:** ntt-copier can claim work after loading

---

## References

**Migration Background:**
- **Phase 4 Cutover Script:** `migrations/phase4-cutover.sql` - Created unpartitioned `paths` table schema
- **Partition Drop Rationale:** `docs/proposal-eliminate-partition-lock-contention.md` - Why we're removing partitions
- **Performance Analysis:** `docs/partition-drop-performance-problem.md` - Lock contention measurements

**Loader Context:**
- **Current Loader:** `bin/ntt-loader` (337 lines, partitioned version) - LINE NUMBERS IN THIS DOC
- **Enumeration Tool:** `bin/ntt-enum` - Generates .raw files this loader consumes
- **VXA Test Case:** `docs/vxa-tape-ingestion-plan.md` - First medium to test refactored loader

**Related Tools:**
- **Copy Worker:** `bin/ntt-copier.py` - Already updated for unpartitioned schema (Phase 4)
- **Orchestrator:** `bin/ntt-orchestrator` - Calls ntt-enum and ntt-loader

---

## Glossary

**Terms for external reviewers:**

- **medium** - A physical storage device (hard drive, optical disc, tape) being ingested
- **medium_hash** - BLAKE3 hash of medium's signature (first 1MB + last 1MB of image file)
- **enumeration** - Filesystem walk extracting inode metadata (dev, ino, path, size, mtime, etc.)
- **.raw file** - Output from ntt-enum: NUL-separated records (034 field delimiter)
- **paths table** - PostgreSQL table storing all enumerated filesystem paths (232M rows)
- **partition** - Old architecture: one child table per medium (488,362 tables total)
- **denormalized** - Inode metadata duplicated across hardlink paths (simpler queries, more storage)
- **idempotent reload** - Running loader multiple times produces identical results
- **TRUNCATE** - Fast table clear (no row-level processing, instant with partitions)
- **ON CONFLICT** - PostgreSQL upsert mechanism (must scan existing rows for duplicates)
- **034 delimiter** - ASCII FS character (octal 034, hex 0x1C, "File Separator")
- **bytea** - PostgreSQL binary data type (preserves exact filesystem bytes, not UTF-8)
- **claimed_by** - Copy worker coordination: which process owns this file for deduplication
- **blobid** - Content-addressed identifier (BLAKE3 hash of file contents)

---

## Implementation

**Status:** ✅ COMPLETED (2025-11-16)

**Commit:** fa93b4c - Refactor ntt-loader for unpartitioned schema with empirical validation

**Changes:**
- `bin/ntt-loader` - Refactored for DELETE-based reload (230 lines changed)
- `bin/ntt-loader-partitioned` - Preserved old version for rollback (336 lines)
- `migrations/add-paths-indexes.sql` - Added missing indexes for copier (90 lines)

**Testing:**
- VXA Tape 1: 348,739 paths loaded successfully
- Pattern exclusions: 14,428 paths marked
- Queue stats: 315,572 files ready for copier

**Benchmark Validation:**
- Web-Claude tested INSERT vs UPDATE at 300K/1M/3M scales
- Two-table INSERT wins by 21-32% with zero bloat
- Results captured in `docs/lessons/postgres-insert-vs-update-benchmark-2025-11-16.md`
