<!--
Author: PB and Claude
Date: Thu 23 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
docs/archive-extraction-plan.md
-->

# Archive Extraction Implementation Plan

**Status:** Planning
**Created:** 2025-10-23
**Estimated Duration:** 22-32 days
**Storage Impact:** ~800-900 GB (with intermediates)

## Overview

Extract and decompress all archive/compressed files in the NTT collection, creating extracted media for their contents. Mark decompression intermediates (e.g., `.tar` from `.tar.gz`) for potential future cleanup. Preserve everything initially, optimize later with data.

### Goals

1. Extract all compressed files (.gz, .bz2, .xz) to uncompressed blobs
2. Extract all archives (.tar, .zip, .7z) to individual file blobs
3. Handle nested archives recursively (e.g., .tar.gz → .tar → files)
4. Create extracted media for extracted contents with proper path/inode entries
5. Enable deduplication across archive contents
6. Mark intermediates for optional future cleanup

### Key Design Decisions

- **Extracted medium per archive** - Each archive/compressed file becomes a extracted medium
- **Use archive blobid as medium_hash** - Natural 1:1 mapping
- **One extraction per unique blob** - Same archive on multiple disks → extract once, unique index enforces this
- **Provenance via path table** - Query joins reveal all original locations of any blob
- **Keep intermediates initially** - Simpler code, measure impact, cleanup later if needed
- **Queue-based processing** - Process nested archives as they're discovered

---

## Current State Analysis (2025-11-05)

**Compressed/Archive Files:**
- **Total:** 239,183 unique blobs (1,983 GB compressed)

**Major formats by size:**
- **gzip:** 200,839 blobs (537 GB) - avg 4.36x expansion = ~2,341 GB
- **bzip2:** 21,668 blobs (444 GB) - avg 5.66x expansion = ~2,513 GB
- **zip:** 7,179 blobs (456 GB) - avg 2.45x expansion = ~1,117 GB
- **tar:** 343 blobs (328 GB) - minimal expansion = ~328 GB
- **xz:** 1,895 blobs (190 GB) - avg 6.0x expansion = ~1,140 GB
- **ar archives:** 4,773 blobs (11 GB)
- **JAR files:** 2,201 blobs (9.5 GB)
- **RAR:** 20 blobs (1.7 GB)
- **CAB:** 108 blobs (2.7 GB)
- **7z:** 5 blobs (55 MB)
- **Unix compress:** 30 blobs (701 MB)
- **Other:** ~320 blobs (3 GB)

**Storage Estimates:**
- **Current:** 8.4 TB free on fastpool
- **Conservative expansion:** ~7,500 GB uncompressed (no deduplication)
- **With 50% deduplication:** ~3,750 GB
- **With intermediates (~10%):** ~4,125 GB total
- **Remaining after:** 4.3 TB free (sufficient)

---

## Phase 1: Database Schema Changes

**Duration:** 1 day
**Status:** [x] Complete (2025-11-05)

### Tasks

- [x] Create `sql/04-add-extraction-schema.sql`
- [x] Add columns to medium table
- [x] Add columns to blobs table
- [x] Create indexes
- [x] Run migration on production
- [x] Verify indexes created
- [x] Backfill medium_type for existing physical media (252 physical media)
- [x] Blobs initialized (6,988,086 blobs with extraction_status='pending')

### Schema: Medium Table Extensions

```sql
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
```

**Column semantics:**
- `medium_type`: 'physical' (disk), 'extracted' (from archives/compression), 'carved' (PhotoRec)
- `source_blobid`: The archive blob that was extracted (NULL for physical media)
- `extraction_method`: 'gzip', 'bzip2', 'tar', 'zip', '7z', etc.
- `extracted_at`: When extraction completed

**Provenance tracking:**
- Each unique blob is extracted once (enforced by unique index)
- To find all original locations of extracted content, join back through path table
- Example: `backup.tar.gz` appears on 3 disks → extracted once, but path table shows all 3 original locations

### Schema: Blobs Table Extensions

```sql
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
CREATE INDEX idx_blobs_extractable ON blobs(blobid)
  WHERE mime_type IN ('application/gzip', 'application/x-bzip2',
                      'application/x-xz', 'application/zip',
                      'application/x-tar', 'application/x-7z-compressed',
                      'application/java-archive', 'application/vnd.rar')
    AND extraction_status = 'pending';

CREATE INDEX idx_blobs_intermediates ON blobs(blobid)
  WHERE is_intermediate = TRUE;

CREATE INDEX idx_blobs_extraction_failed ON blobs(blobid)
  WHERE extraction_status = 'failed';
```

**Column semantics:**
- `is_intermediate`: TRUE for decompression intermediates (.tar from .tar.gz)
- `intermediate_of`: Parent compressed blobid
- `extraction_status`: 'pending', 'in_progress', 'complete', 'failed', 'not_extractable'
- `extracted_at`: When extraction completed
- `extraction_error`: Error message if failed
- `files_extracted`: Count of files extracted (stats/validation)

### Validation

```sql
-- Check schema changes applied
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'medium'
  AND column_name IN ('medium_type', 'source_blobid', 'extraction_method');

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'blobs'
  AND column_name IN ('is_intermediate', 'extraction_status');

-- Check indexes created
SELECT indexname FROM pg_indexes
WHERE tablename = 'medium'
  AND indexname LIKE '%extraction%';

-- Check backfill
SELECT medium_type, COUNT(*) FROM medium GROUP BY medium_type;
SELECT extraction_status, COUNT(*) FROM blobs GROUP BY extraction_status;
```

---

## Phase 2: Core Extraction Framework

**Duration:** 3-4 days
**Status:** [ ] Not Started
**Depends on:** Phase 1

### Tasks

- [ ] Create `bin/ntt-extractor.py` main CLI (uv shebang, Typer, loguru)
- [ ] Create `bin/ntt_extractor_queue.py` Redis queue module
- [ ] Create `bin/ntt_extractor_medium.py` medium/partition manager
- [ ] Create `bin/ntt_extractor_handlers.py` handler registry stub
- [ ] Implement CLI commands: init, run, status, reset
- [ ] Implement Redis queue: priority queue, nested LIFO, deduplication
- [ ] Implement medium manager: partitions, COPY bulk inserts, synthetic inodes
- [ ] Add multi-worker support (fork-based parallelism)
- [ ] Add graceful shutdown (SIGINT/SIGTERM handling)
- [ ] Test with mock handlers (no real extraction)

### CLI Interface

```bash
ntt-extractor.py [options]

Options:
  --limit N           Process only N blobs
  --format TYPE       Only process format (gzip/bzip2/tar/zip/all)
  --batch-size N      Batch size for DB inserts (default: 1000)
  --dry-run           Show what would be extracted
  --resume            Resume from previous run (default: true)
```

### Components

**ExtractionQueue (Redis-backed):**
- Use Redis LPUSH/RPOP for LIFO (depth-first) queue
- Persistent across crashes/restarts
- Enables parallel workers pulling from same queue
- Query pending extractable blobs from PostgreSQL
- Use Redis sorted set for size-based prioritization
- Track processed count and stats in Redis

**ExtractedMediumManager:**
- Create extracted medium records
- Create partitions (inode_p_*, path_p_*)
- Generate synthetic inodes: `ino = hash(medium_hash || path)`
- Bulk insert inode/path entries

**ProgressLogger:**
- Log every 60 seconds
- Track: blobs processed, files extracted, bytes added, rate, ETA
- Output format: `[timestamp] Progress: 1,234 blobs | 56,789 files | 45 GB | 123 blobs/hr | ETA: 5.2d`

**DeduplicationChecker:**
```python
def already_extracted(blobid):
    """Check if this blob has already been extracted."""
    result = db.query("""
        SELECT medium_hash FROM medium
        WHERE source_blobid = %s
          AND medium_type = 'extracted'
    """, (blobid,))
    return result[0] if result else None
```

### Validation

```bash
# Test dry-run
ntt-extractor.py --dry-run --limit 10

# Test deduplication (extract same blob twice)
ntt-extractor.py --limit 5
ntt-extractor.py --limit 5  # Should skip all 5

# Check logging
tail -f /var/log/ntt/extractor.jsonl
```

---

## Phase 3: Extraction Handlers Implementation

**Duration:** 4-5 days
**Status:** [ ] Not Started
**Depends on:** Phase 2

### Overview

Implement all extraction handlers using handler registry pattern. Each MIME type maps to a handler function. Handlers fall into two categories:

1. **Decompressors** (single-file): gzip, bzip2, xz, compress, lzip
2. **Archive extractors** (multi-file): tar, zip, rar, 7z, cab, ar

### Tasks

**Handler Registry:**
- [ ] Create `MIME_HANDLERS` dict mapping MIME → handler function
- [ ] Implement `get_extractable_mime_types()` for query filtering
- [ ] Implement `extract_blob()` router that dispatches to handlers

**Decompression Handlers (200K+ blobs, 1.2 TB):**
- [ ] `decompress_gzip()` - gzip (200K blobs, 537 GB)
- [ ] `decompress_bzip2()` - bzip2 (21K blobs, 444 GB)
- [ ] `decompress_xz()` - xz (1.9K blobs, 190 GB)
- [ ] `decompress_unix_compress()` - Unix .Z (30 blobs, 701 MB)
- [ ] `decompress_lzip()` - lzip (2 blobs, 163 KB)

**Archive Handlers (38K+ blobs, 800 GB):**
- [ ] `extract_tar()` - tar archives (343 blobs, 328 GB)
- [ ] `extract_zip()` - zip, JAR, APK, EPUB (9.5K blobs, 465 GB)
- [ ] `extract_ar()` - ar/static libraries (4.7K blobs, 11 GB)
- [ ] `extract_rar()` - RAR (20 blobs, 1.7 GB)
- [ ] `extract_cab()` - CAB (108 blobs, 2.7 GB)
- [ ] `extract_7z()` - 7zip (5 blobs, 55 MB)

**Common Infrastructure:**
- [ ] Implement `get_byhash_path()` - locate blob in by-hash storage
- [ ] Implement `copy_to_byhash()` - copy extracted file to by-hash with dedup
- [ ] Implement MIME detection with `python-magic`
- [ ] Mark intermediates correctly (decompressed .tar from .tar.gz)
- [ ] Handle nested archives (queue for recursive extraction)
- [ ] Error handling and logging for corrupt/password-protected files

### Handler Registry Pattern

```python
# MIME type → handler function mapping
MIME_HANDLERS = {
    # Compression (single-file, creates intermediates)
    'application/gzip': decompress_gzip,
    'application/x-bzip2': decompress_bzip2,
    'application/x-xz': decompress_xz,
    'application/x-compress': decompress_unix_compress,
    'application/x-lzip': decompress_lzip,

    # Archives (multi-file, creates extracted media)
    'application/x-tar': extract_tar,
    'application/zip': extract_zip,
    'application/java-archive': extract_zip,  # JAR = ZIP
    'application/epub+zip': extract_zip,      # EPUB = ZIP
    'application/vnd.android.package-archive': extract_zip,  # APK = ZIP
    'application/x-7z-compressed': extract_7z,
    'application/vnd.rar': extract_rar,
    'application/vnd.ms-cab-compressed': extract_cab,
    'application/x-archive': extract_ar,
}

def get_extractable_mime_types() -> list:
    """Get list of supported MIME types for query filtering."""
    return list(MIME_HANDLERS.keys())

def extract_blob(blobid: str, mime_type: str, db) -> Tuple[List[Dict], List[Tuple]]:
    """
    Route to appropriate handler.

    Returns:
        extracted_files: List of {path, blobid, size, mtime}
        nested_archives: List of (blobid, mime_type) to queue
    """
    handler = MIME_HANDLERS.get(mime_type)
    if not handler:
        raise ValueError(f"No handler for MIME type: {mime_type}")

    return handler(blobid, db)
```

### Decompression Handler Template

```python
def decompress_gzip(blobid: str, db):
    """
    Decompress single-file compression formats.

    Creates extracted medium containing decompressed file.
    Marks decompressed blob as intermediate.
    """
    # 1. Check if already extracted (dedup)
    existing = db.query("""
        SELECT medium_hash FROM medium
        WHERE source_blobid = %s
          AND medium_type = 'extracted'
    """, (blobid,))

    if existing:
        log.info(f"Blob {blobid} already extracted, skipping")
        update_blob(blobid, extraction_status='complete')
        return existing[0]

    # 2. Load blob from by-hash
    blob_path = get_byhash_path(blobid)

    # 3. Decompress streaming with hash computation
    with tempfile.NamedTemporaryFile() as temp:
        decompressed_hash = decompress_and_hash(
            blob_path,
            temp.name,
            algorithm=mime_to_algorithm(mime_type)
        )

        # 4. Detect MIME type of result
        decompressed_mime = detect_mime(temp.name)

        # 5. Copy to by-hash (with dedup check)
        if not blob_exists(decompressed_hash):
            copy_to_byhash(temp.name, decompressed_hash)
            insert_blob(decompressed_hash, mime=decompressed_mime)

        # 6. Mark as intermediate
        update_blob(
            decompressed_hash,
            is_intermediate=True,
            intermediate_of=blobid
        )

    # 7. Create extracted medium
    create_extracted_medium(
        medium_hash=blobid,
        source_blobid=blobid,
        medium_type='extracted',
        extraction_method=mime_to_method(mime_type)
    )

    # 8. Add file to extracted medium
    original_filename = get_original_filename(blobid)
    decompressed_filename = strip_extension(original_filename, mime_type)

    insert_inode_and_path(
        medium_hash=blobid,
        path=f'/{decompressed_filename}',
        ino=generate_synthetic_ino(blobid, decompressed_filename),
        blobid=decompressed_hash,
        size=get_file_size(decompressed_hash)
    )

    # 9. If decompressed content is extractable, queue it
    if decompressed_mime in EXTRACTABLE_MIMES:
        queue.push((decompressed_hash, decompressed_mime))

    # 10. Mark original blob as complete
    update_blob(blobid, extraction_status='complete', files_extracted=1)
```

### Test Cases

```bash
# Test single file decompression
# data.csv.gz → data.csv
ntt-extractor.py --format gzip --limit 1

# Test compressed archive
# backup.tar.gz → backup.tar (intermediate) → then extracts
ntt-extractor.py --format gzip --limit 1

# Validate intermediate marking
psql -c "SELECT blobid, is_intermediate, intermediate_of FROM blobs WHERE is_intermediate LIMIT 5"
```

---


## Phase 4: Integration Testing

**Duration:** 2 days
**Status:** [ ] Not Started
**Depends on:** Phase 3, Phase 4

### Test Scenarios

- [ ] **Simple decompression:** `file.txt.gz` → single file
- [ ] **Simple archive:** `backup.tar` → 100 files
- [ ] **Compressed archive:** `backup.tar.gz` → .tar (intermediate) → 100 files
- [ ] **Nested archives:** `outer.zip` → `inner.tar.gz` → .tar → files
- [ ] **Duplicate blob deduplication:** Same archive on multiple disks → extracted once
- [ ] **Content deduplication:** Two archives with shared files → blobs stored once
- [ ] **Corrupted file:** Incomplete .gz (test error handling)
- [ ] **Password-protected:** Encrypted .zip (test graceful failure)
- [ ] **Interruption:** Kill process mid-extraction, verify resume works

### Validation Queries

```sql
-- Check intermediates marked correctly
SELECT
  COUNT(*) as intermediate_count,
  pg_size_pretty(SUM(i.size)::bigint) as intermediate_size
FROM blobs b
JOIN inode i ON i.blobid = b.blobid
WHERE b.is_intermediate;

-- Check extracted media created
SELECT medium_type, extraction_method, COUNT(*)
FROM medium
GROUP BY medium_type, extraction_method;

-- Check extraction stats
SELECT
  extraction_method,
  COUNT(*) as archives,
  AVG(files_extracted) as avg_files,
  SUM(files_extracted) as total_files
FROM blobs
WHERE extraction_status = 'complete'
GROUP BY extraction_method;

-- Find failures
SELECT
  extraction_error,
  COUNT(*)
FROM blobs
WHERE extraction_status = 'failed'
GROUP BY extraction_error;

-- Verify no orphaned partitions
SELECT tablename
FROM pg_tables
WHERE tablename LIKE 'inode_p_%'
  AND tablename NOT IN (
    SELECT 'inode_p_' || LEFT(medium_hash, 8)
    FROM medium
  );

-- Check source_blobid populated for extracted media
SELECT COUNT(*)
FROM medium
WHERE medium_type = 'extracted'
  AND source_blobid IS NULL;
-- Should be 0

-- Test provenance query: find all original locations of an extracted file
SELECT
  extracted.path as extracted_path,
  vm.source_blobid as archive_blobid,
  archive_paths.path as archive_original_path,
  archive_paths.medium_hash as original_disk_hash
FROM path extracted
JOIN medium vm ON vm.medium_hash = extracted.medium_hash
JOIN path archive_paths ON archive_paths.blobid = vm.source_blobid
WHERE extracted.blobid = 'some_target_file_blob'
  AND vm.medium_type = 'extracted'
LIMIT 10;
```

---

## Phase 5: Pilot Run

**Duration:** 3-5 days
**Status:** [ ] Not Started
**Depends on:** Phase 5

### Scope

Process 1,000 random extractable blobs to:
- Validate full pipeline
- Measure actual deduplication rate
- Measure intermediate overhead
- Validate storage estimates
- Tune performance

### Tasks

- [ ] Sample 1000 random blobs stratified by type
- [ ] Run extraction with monitoring
- [ ] Collect metrics (processing rate, dedup, failures)
- [ ] Analyze intermediate overhead
- [ ] Validate random samples manually
- [ ] Adjust estimates for full run
- [ ] Document findings

### Process

```bash
# Mark 1000 random blobs for pilot (stratified sample)
psql -c "
  WITH stratified AS (
    SELECT blobid, mime_type,
           ROW_NUMBER() OVER (PARTITION BY mime_type ORDER BY RANDOM()) as rn
    FROM blobs
    WHERE mime_type IN ('application/gzip', 'application/x-bzip2',
                        'application/x-tar', 'application/zip')
      AND extraction_status = 'pending'
  )
  UPDATE blobs
  SET extraction_status = 'pilot'
  WHERE blobid IN (
    SELECT blobid FROM stratified WHERE rn <= 250
  )"

# Run extraction
ntt-extractor.py --limit 1000

# Monitor progress
tail -f /var/log/ntt/extractor.jsonl

# Watch status
watch -n 60 "psql -c \"SELECT extraction_status, COUNT(*) FROM blobs GROUP BY extraction_status\""
```

### Metrics to Collect

```sql
-- Processing rate
SELECT
  COUNT(*) as blobs_processed,
  EXTRACT(EPOCH FROM (MAX(extracted_at) - MIN(extracted_at))) / 3600 as hours,
  COUNT(*) / NULLIF(EXTRACT(EPOCH FROM (MAX(extracted_at) - MIN(extracted_at))) / 3600, 0) as blobs_per_hour
FROM blobs
WHERE extraction_status IN ('complete', 'pilot');

-- Deduplication analysis
SELECT
  SUM(files_extracted) as total_files_extracted,
  COUNT(DISTINCT blobid) as unique_blobs_created,
  ROUND((1 - COUNT(DISTINCT blobid)::numeric / SUM(files_extracted)) * 100, 2) as dedup_percentage
FROM blobs
WHERE extraction_status = 'complete'
  AND extracted_at > (SELECT MIN(extracted_at) FROM blobs WHERE extraction_status = 'pilot');

-- Intermediate overhead
SELECT
  COUNT(*) FILTER (WHERE is_intermediate) as intermediate_count,
  COUNT(*) FILTER (WHERE NOT is_intermediate) as final_count,
  pg_size_pretty(SUM(i.size) FILTER (WHERE b.is_intermediate)::bigint) as intermediate_size,
  pg_size_pretty(SUM(i.size) FILTER (WHERE NOT b.is_intermediate)::bigint) as final_size,
  ROUND(SUM(i.size) FILTER (WHERE b.is_intermediate) / NULLIF(SUM(i.size), 0) * 100, 2) as intermediate_pct
FROM blobs b
JOIN inode i ON i.blobid = b.blobid
WHERE b.extracted_at > (SELECT MIN(extracted_at) FROM blobs WHERE extraction_status = 'pilot');

-- Storage added
SELECT
  pg_size_pretty(SUM(i.size)::bigint) as total_added
FROM blobs b
JOIN inode i ON i.blobid = b.blobid
WHERE b.extracted_at > (SELECT MIN(extracted_at) FROM blobs WHERE extraction_status = 'pilot');

-- Failure analysis
SELECT
  extraction_error,
  COUNT(*),
  ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM blobs WHERE extraction_status IN ('complete', 'failed', 'pilot')), 2) as pct
FROM blobs
WHERE extraction_status = 'failed'
GROUP BY extraction_error
ORDER BY COUNT(*) DESC;
```

---

## Phase 6: Pilot Validation

**Duration:** 0.5 days
**Status:** [ ] Not Started
**Depends on:** Phase 5

### Purpose

Validate pilot run before proceeding to full production. This is a **decision gate** - only proceed if validation passes.

### Integrity Checks

```sql
-- Check all pilot blobs processed
SELECT extraction_status, COUNT(*)
FROM blobs
WHERE extraction_status IN ('pilot', 'complete', 'failed')
GROUP BY extraction_status;
-- Expect: 1000 total (complete + failed)

-- Check extracted media have source_blobid
SELECT COUNT(*)
FROM medium
WHERE medium_type = 'extracted'
  AND source_blobid IS NULL
  AND extracted_at > (SELECT MIN(extracted_at) FROM blobs WHERE extraction_status = 'complete');
-- Expected: 0

-- Check intermediate relationships
SELECT COUNT(*)
FROM blobs b1
WHERE b1.is_intermediate
  AND b1.extracted_at > (SELECT MIN(extracted_at) FROM blobs WHERE extraction_status = 'complete')
  AND NOT EXISTS (
    SELECT 1 FROM blobs b2
    WHERE b2.blobid = b1.intermediate_of
  );
-- Expected: 0

-- Check extraction counts match inode counts
SELECT COUNT(*)
FROM blobs b
WHERE b.extraction_status = 'complete'
  AND b.extracted_at > (SELECT MIN(extracted_at) FROM blobs WHERE extraction_status = 'complete')
  AND b.files_extracted != (
    SELECT COUNT(*)
    FROM inode
    WHERE medium_hash = b.blobid
  );
-- Expected: 0

-- Check no orphaned partitions
SELECT tablename
FROM pg_tables
WHERE tablename LIKE 'inode_p_%'
  AND SUBSTRING(tablename, 9) NOT IN (
    SELECT LEFT(medium_hash, 8) FROM medium
  );
-- Expected: 0 rows
```

### Sample Verification

```bash
# Verify 20 random extracted files exist in by-hash
for i in {1..20}; do
  psql -t -c "
    SELECT i.blobid, p.path, m.medium_hash
    FROM inode i
    JOIN path p USING (medium_hash, ino)
    JOIN medium m USING (medium_hash)
    WHERE m.medium_type = 'extracted'
      AND m.extracted_at > (SELECT MIN(extracted_at) FROM blobs WHERE extraction_status = 'complete')
      AND i.fs_type = 'f'
    ORDER BY RANDOM()
    LIMIT 1
  " | while read blobid path medium; do
    blob_path="/data/fast/ntt/by-hash/${blobid:0:2}/${blobid:2:2}/$blobid"
    if [ ! -f "$blob_path" ]; then
      echo "ERROR: Missing blob $blobid for $medium:$path"
    else
      echo "OK: $blobid"
    fi
  done
done
```

### Provenance Verification

```sql
-- Test provenance query: can we find original locations?
SELECT
  extracted.path as extracted_path,
  vm.source_blobid as archive_blobid,
  COUNT(DISTINCT archive_paths.path) as original_locations
FROM path extracted
JOIN medium vm ON vm.medium_hash = extracted.medium_hash
JOIN path archive_paths ON archive_paths.blobid = vm.source_blobid
WHERE vm.medium_type = 'extracted'
  AND vm.extracted_at > (SELECT MIN(extracted_at) FROM blobs WHERE extraction_status = 'complete')
GROUP BY extracted.path, vm.source_blobid
LIMIT 10;
-- Should show files with their archive source and original location count
```

### Decision Gate Criteria

**Proceed to full run if ALL pass:**
- [ ] Failure rate < 10%
- [ ] Deduplication rate > 20% OR intermediate overhead < 50%
- [ ] Storage estimate within 20% of projection
- [ ] Processing rate > 200 blobs/hour
- [ ] All integrity checks pass (0 errors)
- [ ] Sample verification: 20/20 files exist
- [ ] Provenance queries work correctly
- [ ] No critical bugs found

**If any fail:** Investigate, fix, reset pilot, re-run.

---

## Phase 7: Full Production Run

**Duration:** 7-14 days
**Status:** [ ] Not Started
**Depends on:** Phase 6

### Scope

Process all 184,040 extractable blobs.

### Tasks

- [ ] Reset pilot blobs to pending
- [ ] Start long-running extraction process
- [ ] Monitor disk space every 6 hours
- [ ] Check for failures daily
- [ ] Validate random samples (10/day)
- [ ] Track progress metrics
- [ ] Document any issues encountered

### Process

```bash
# Reset pilot to pending
psql -c "UPDATE blobs SET extraction_status = 'pending' WHERE extraction_status = 'pilot'"

# Start extraction (background, resumable)
nohup ntt-extractor.py > /var/log/ntt/extractor.log 2>&1 &
echo $! > /tmp/ntt-extractor.pid

# Monitor disk space
watch -n 3600 'df -h /data/fast'

# Monitor progress
watch -n 300 'psql -c "SELECT extraction_status, COUNT(*) FROM blobs GROUP BY extraction_status"'

# Daily status report
psql -c "
  SELECT
    extraction_status,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as pct
  FROM blobs
  WHERE mime_type IN (extractable_types)
  GROUP BY extraction_status
  ORDER BY extraction_status"
```

### Estimated Timeline

**Conservative estimate:**
- 184,040 blobs
- Processing rate: 400 blobs/hour (conservative)
- Total: 460 hours = 19.2 days (24/7)

**Optimistic estimate:**
- Processing rate: 800 blobs/hour (with optimizations)
- Total: 230 hours = 9.6 days (24/7)

**Realistic:** 10-14 days continuous runtime

### Monitoring Alerts

Set up alerts for:
- [ ] Disk space < 1 TB → immediate action
- [ ] Extraction failures > 5% → investigate
- [ ] No progress for 2 hours → check if hung
- [ ] Partition count > 400K → warn
- [ ] Processing rate drops 50% → investigate

---

## Phase 8: Final Quality Checks

**Duration:** 1 day
**Status:** [ ] Not Started
**Depends on:** Phase 7

### Purpose

Comprehensive quality checks after full production run completes. This validates the **entire extraction campaign** (all 239K blobs), not just a sample.

### Integrity Checks

All checks from Phase 6 (Pilot Validation), applied to full dataset:

```sql
-- Check all extracted media have source_blobid
SELECT COUNT(*)
FROM medium
WHERE medium_type = 'extracted'
  AND source_blobid IS NULL;
-- Expected: 0

-- Check intermediate relationships valid
SELECT COUNT(*)
FROM blobs b1
WHERE b1.is_intermediate
  AND NOT EXISTS (
    SELECT 1 FROM blobs b2
    WHERE b2.blobid = b1.intermediate_of
  );
-- Expected: 0

-- Check extraction counts match
SELECT COUNT(*)
FROM blobs b
WHERE b.extraction_status = 'complete'
  AND b.files_extracted != (
    SELECT COUNT(*)
    FROM inode
    WHERE medium_hash = b.blobid
  );
-- Expected: 0

-- Check all partitions have corresponding media
SELECT COUNT(*)
FROM pg_tables
WHERE tablename LIKE 'inode_p_%'
  AND SUBSTRING(tablename, 9) NOT IN (
    SELECT LEFT(medium_hash, 8) FROM medium
  );
-- Expected: 0
```

### Sample Verification

```bash
# Verify 100 random extracted files
for i in {1..100}; do
  psql -t -c "
    SELECT i.blobid, p.path, m.medium_hash
    FROM inode i
    JOIN path p USING (medium_hash, ino)
    JOIN medium m USING (medium_hash)
    WHERE m.medium_type = 'extracted'
      AND i.fs_type = 'f'
    ORDER BY RANDOM()
    LIMIT 1
  " | while read blobid path medium; do
    blob_path="/data/fast/ntt/by-hash/${blobid:0:2}/${blobid:2:2}/$blobid"
    if [ ! -f "$blob_path" ]; then
      echo "ERROR: Missing blob $blobid for $medium:$path"
    fi
  done
done
```

### Final Metrics Report

```sql
-- Overall extraction summary
SELECT
  'Total extractable blobs' as metric,
  COUNT(*) as value
FROM blobs
WHERE mime_type IN (extractable_types)
UNION ALL
SELECT 'Completed successfully', COUNT(*)
FROM blobs WHERE extraction_status = 'complete'
UNION ALL
SELECT 'Failed', COUNT(*)
FROM blobs WHERE extraction_status = 'failed'
UNION ALL
SELECT 'Files extracted', SUM(files_extracted)
FROM blobs WHERE extraction_status = 'complete'
UNION ALL
SELECT 'Extracted media created', COUNT(*)
FROM medium WHERE medium_type = 'extracted'
UNION ALL
SELECT 'Partitions created', COUNT(*) / 2
FROM pg_tables WHERE tablename LIKE 'inode_p_%' OR tablename LIKE 'path_p_%';

-- Storage impact
SELECT
  pg_size_pretty(SUM(i.size)::bigint) as total_extracted,
  pg_size_pretty(SUM(CASE WHEN b.is_intermediate THEN i.size ELSE 0 END)::bigint) as intermediate_size,
  pg_size_pretty(SUM(CASE WHEN NOT b.is_intermediate THEN i.size ELSE 0 END)::bigint) as final_content_size,
  ROUND(SUM(CASE WHEN b.is_intermediate THEN i.size ELSE 0 END) / NULLIF(SUM(i.size), 0) * 100, 2) as intermediate_pct
FROM blobs b
JOIN inode i ON i.blobid = b.blobid
WHERE b.extracted_at IS NOT NULL;

-- Deduplication savings
WITH extraction_stats AS (
  SELECT
    SUM(files_extracted) as total_extracted,
    COUNT(DISTINCT i.blobid) as unique_blobs
  FROM blobs b
  JOIN inode i ON i.blobid = b.blobid
  WHERE b.extraction_status = 'complete'
)
SELECT
  total_extracted,
  unique_blobs,
  total_extracted - unique_blobs as duplicates_eliminated,
  ROUND((1 - unique_blobs::numeric / total_extracted) * 100, 2) as dedup_percentage
FROM extraction_stats;
```

---

## Phase 9: Future Cleanup Tool (Optional)

**Duration:** 2-3 days (when needed)
**Status:** [ ] Not Started
**Priority:** Low

### Purpose

Delete intermediate blobs to reclaim storage if space becomes constrained.

### Tool: `bin/ntt-cleanup-intermediates.py`

**Features:**
- Query intermediates older than threshold (default: 90 days)
- Verify parent and extracted contents still exist
- Delete from by-hash storage
- Soft delete in database (mark as deleted)
- Dry-run mode
- Report space reclaimed

**Safety checks:**
- Never delete if parent missing
- Never delete if extracted contents missing
- Require explicit confirmation for actual deletion

### Implementation Tasks

- [ ] Create `bin/ntt-cleanup-intermediates.py`
- [ ] Implement safety verification
- [ ] Add dry-run mode
- [ ] Add age threshold parameter
- [ ] Test on small sample
- [ ] Document usage

---

## Timeline Summary

| Phase | Duration | Dependencies | Status |
|-------|----------|--------------|--------|
| 1. Schema migration | 1 day | None | [x] Complete |
| 2. Core framework | 3-4 days | Phase 1 | [ ] |
| 3. Extraction handlers | 4-5 days | Phase 2 | [ ] |
| 4. Integration testing | 2 days | Phase 3 | [ ] |
| 5. Pilot run | 3-5 days | Phase 4 | [ ] |
| 6. Pilot validation | 0.5 days | Phase 5 | [ ] |
| 7. Full production | 7-14 days | Phase 6 | [ ] |
| 8. Final quality checks | 1 day | Phase 7 | [ ] |
| 9. Cleanup tool (future) | 2-3 days | - | [ ] |
| **Total** | **24.5-36.5 days** | | **3% complete** |

---

## Success Criteria

### Must Have

- [ ] All extractable blobs processed (extraction_status != 'pending')
- [ ] Intermediate files marked correctly (is_intermediate flag accurate)
- [ ] Extracted media created with source_blobid populated
- [ ] All integrity checks pass (see Phase 8)
- [ ] Storage increase < 1.2 TB
- [ ] Failure rate < 10%
- [ ] No data corruption (random sampling validates blobs)

### Nice to Have

- [ ] Deduplication savings > 20%
- [ ] Processing rate > 500 blobs/hour
- [ ] Zero critical bugs
- [ ] Automated monitoring dashboard
- [ ] Parallel processing implemented

---

## Risk Mitigation

### Risk 1: Storage Overflow

**Probability:** Medium
**Impact:** High

**Mitigation:**
- Monitor disk space continuously (every 6 hours)
- Set alert at 1 TB free
- Pause extraction if < 500 GB free

**Contingency:**
- Implement cleanup tool early
- Delete intermediates to reclaim ~440 GB
- Acquire additional storage if needed

### Risk 2: Database Partition Explosion

**Probability:** Low
**Impact:** Medium

**Mitigation:**
- Test partition creation performance in Phase 5
- Monitor partition count during pilot
- Set alert at 400K partitions

**Contingency:**
- Consolidate small partitions if needed
- Use single partition for all extracted media (architectural change)

### Risk 3: Processing Too Slow

**Probability:** Medium
**Impact:** Medium

**Mitigation:**
- Measure rate in pilot run
- Optimize hot paths if needed
- Consider parallel workers

**Contingency:**
- Accept longer timeline (up to 30 days)
- Implement parallelization mid-project
- Process only high-value archives (skip smallest)

### Risk 4: High Failure Rate

**Probability:** Low
**Impact:** Medium

**Mitigation:**
- Extensive testing in Phase 5
- Robust error handling
- Graceful degradation

**Contingency:**
- Skip problematic formats (e.g., only .gz and .zip)
- Investigate failures, fix bugs, re-process
- Accept partial completion if failures isolated

### Risk 5: Corrupted/Malicious Archives

**Probability:** Low
**Impact:** Low

**Mitigation:**
- Use standard extraction tools (tar, unzip)
- Limit extraction size and time
- Run in restricted environment

**Contingency:**
- Mark as failed and skip
- Manual investigation for important archives

---

## Notes

### Design Rationale

**Why keep intermediates?**
- Simpler code (no temp file juggling)
- Easier error recovery (blob in by-hash)
- Deduplication opportunities
- Reversible decision (can cleanup later)
- Measured overhead: ~440 GB (10% of total expansion)

**Why extracted media model?**
- Clean schema (no path syntax hacks)
- One extraction per unique blob (enforced by unique index)
- Provenance preserved via path table joins
- Consistent with current architecture
- Scales to millions of archives

**Why one-extraction-per-blob?**
- Eliminates redundant extraction work
- Same blob on 10 disks → extract once, reference everywhere
- Provenance fully preserved (query path table for all original locations)
- Simple deduplication logic (single unique index)
- Natural extension of content-addressable storage model

### Open Questions

- [ ] Should we prioritize certain archive types? (e.g., .tar.gz before .7z)
- [ ] Should we implement parallel workers from start or add later?
- [ ] What's acceptable failure rate for exotic formats?
- [ ] Should intermediates have expiration policy from start?

### Future Enhancements

**After Phase 8 complete:**
1. **Parallel processing** - Multiple workers for 3-5x speedup
2. **Archive content search** - Full-text search across archive contents
3. **Virtual mount** - FUSE filesystem to browse archives as directories
4. **Compression analysis** - Which formats compress best, inform future workflows
5. **Incremental extraction** - Auto-extract new archives as they're ingested

---

## References

- Database schema: `docs/medium-columns-guide.md`
- Hash format: `docs/hash-format.md`
- Ignore patterns: `docs/ignore-patterns-guide.md`
- Storage estimates: Analysis conducted 2025-10-23
- Similar project: External backup plan (`docs/external-backup-plan.md`)
