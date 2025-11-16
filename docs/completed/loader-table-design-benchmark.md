<!--
Author: PB and Claude
Date: 2025-11-16
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/loader-table-design-benchmark.md
-->

# PostgreSQL Bulk Load Performance: Two-Table vs Single-Table with UPDATE

**Date:** 2025-11-16
**Context:** ntt-loader refactoring - choosing optimal temp table strategy
**Goal:** Empirically determine which approach is faster for bulk loading with metadata addition

---

## Background

We're loading large datasets (300K to 54M rows) from delimiter-separated files into PostgreSQL. The raw data needs a metadata column (`medium_hash`) added. We need to choose between two approaches.

## Current Schema

**Raw file format (7 fields, 034-delimited):**
```
fs_type \034 dev \034 ino \034 nlink \034 size \034 mtime \034 path \0
```

**Final working table needs:**
- All 7 raw fields
- `medium_hash` (text) - same value for all rows
- `exclude_reason` (text, initially NULL)

---

## Approach A: Two Tables with INSERT Transfer (Current)

```sql
-- Step 1: Create raw import table (exact match to file format)
CREATE TEMP TABLE raw_import (
  fs_type  char(1),
  dev      bigint,
  ino      bigint,
  nlink    int,
  size     bigint,
  mtime    bigint,
  path     text
);

-- Step 2: COPY from file
COPY raw_import(fs_type, dev, ino, nlink, size, mtime, path)
FROM STDIN WITH (FORMAT text, DELIMITER E'\\034', NULL '');

-- Step 3: Create working table with metadata column
CREATE TEMP TABLE working (
  medium_hash    text,
  fs_type        char(1),
  dev            bigint,
  ino            bigint,
  nlink          int,
  size           bigint,
  mtime          bigint,
  path           text,
  exclude_reason text
);

-- Step 4: INSERT with medium_hash added
INSERT INTO working (medium_hash, fs_type, dev, ino, nlink, size, mtime, path)
SELECT 'abc123hash', fs_type, dev, ino, nlink, size, mtime, path
FROM raw_import;

-- Step 5: Later operations on working table
UPDATE working SET exclude_reason = 'pattern_match' WHERE path ~ '/tmp/';
CREATE INDEX idx_working_ino ON working(ino);
-- ... more processing ...
```

**Pros:**
- Raw data preserved in `raw_import` for debugging
- Clear separation of import vs business logic
- INSERT is append-only (no dead tuples)

**Cons:**
- Two table creates/drops
- Extra INSERT step to transfer data

---

## Approach B: Single Table with UPDATE (Proposed)

```sql
-- Step 1: Create working table with all columns
CREATE TEMP TABLE working (
  medium_hash    text,
  fs_type        char(1),
  dev            bigint,
  ino            bigint,
  nlink          int,
  size           bigint,
  mtime          bigint,
  path           text,
  exclude_reason text
);

-- Step 2: COPY into subset of columns (medium_hash left NULL)
COPY working(fs_type, dev, ino, nlink, size, mtime, path)
FROM STDIN WITH (FORMAT text, DELIMITER E'\\034', NULL '');

-- Step 3: UPDATE to add medium_hash (full table scan + write)
UPDATE working SET medium_hash = 'abc123hash';

-- Step 4: Later operations on working table
UPDATE working SET exclude_reason = 'pattern_match' WHERE path ~ '/tmp/';
CREATE INDEX idx_working_ino ON working(ino);
-- ... more processing ...
```

**Pros:**
- Single table lifecycle
- One fewer table to manage

**Cons:**
- UPDATE creates dead tuples (VACUUM overhead)
- Full table scan + rewrite for UPDATE
- Can't inspect raw COPY results separately

---

## Request for External LLM

**Please create a PostgreSQL benchmark script that:**

1. **Generates realistic test data** at three scales:
   - Small: 300,000 rows
   - Medium: 5,000,000 rows
   - Large: 50,000,000 rows

2. **Test data characteristics:**
   - 7 columns matching our schema above
   - `path` column: 50-200 character strings
   - `dev`, `ino`, `size`, `mtime`: random bigints
   - `nlink`: random int 1-100
   - `fs_type`: random char from {f, d, l}

3. **Runs both approaches** with timing:
   - Use `\timing on` in psql
   - Or use `EXPLAIN ANALYZE`
   - Or use pg_stat_statements
   - Measure EACH step separately (COPY, INSERT/UPDATE, total)

4. **Output format:**
   ```
   Scale: 300K rows
   Approach A (Two-table):
     - COPY: X.XX seconds
     - INSERT transfer: X.XX seconds
     - Total: X.XX seconds

   Approach B (Single-table UPDATE):
     - COPY: X.XX seconds
     - UPDATE medium_hash: X.XX seconds
     - Total: X.XX seconds

   Winner: Approach X is Y% faster
   ```

5. **Test environment notes:**
   - PostgreSQL version (ideally 14+)
   - Disk type (SSD/HDD)
   - work_mem, maintenance_work_mem settings
   - Any relevant tuning parameters

---

## Additional Questions

1. **Does the winner change with scale?** (300K vs 5M vs 50M rows)
2. **Dead tuple overhead**: Does Approach B's UPDATE create measurable bloat?
3. **Memory usage**: Which approach uses more RAM?
4. **Variance**: Run each test 3 times - is one approach more consistent?

---

## Deliverables

Please provide:
1. **Benchmark script** (SQL or bash+psql)
2. **Results table** with timing for all scales
3. **Recommendation** with rationale
4. **Any surprises** or unexpected findings

---

## Notes

- Both approaches are followed by additional UPDATEs (exclude_reason) and index creation
- The working table is temporary and dropped after final INSERT to permanent `paths` table
- We care most about the 5M-50M row range (typical production workload)
- If performance is similar (within 10%), we prefer Approach A for debuggability

---

## Example Test Data Generation

```sql
-- Generate test file (034-delimited, null-terminated records)
-- Can use Python/Perl/bash to generate:
-- f\034<dev>\034<ino>\034<nlink>\034<size>\034<mtime>\034/path/to/file\0

-- Or generate directly in PostgreSQL and export
```

Thank you for running this benchmark!

---

## Benchmark Results

**Status:** ✅ COMPLETED (2025-11-16)

**Executed by:** Web-Claude

**Results:** See `docs/lessons/postgres-insert-vs-update-benchmark-2025-11-16.md`

**Key Findings:**
- Two-Table INSERT wins by 21-32% across all scales (300K, 1M, 3M rows)
- UPDATE creates 100% dead tuples (table duplication)
- INSERT is append-only with zero bloat

**Recommendation:** Use Two-Table INSERT approach (implemented in ntt-loader)

**Applied in:** Commit fa93b4c - ntt-loader refactoring
