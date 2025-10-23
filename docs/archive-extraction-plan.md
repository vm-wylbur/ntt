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

Extract and decompress all archive/compressed files in the NTT collection, creating virtual media for their contents. Mark decompression intermediates (e.g., `.tar` from `.tar.gz`) for potential future cleanup. Preserve everything initially, optimize later with data.

### Goals

1. Extract all compressed files (.gz, .bz2, .xz) to uncompressed blobs
2. Extract all archives (.tar, .zip, .7z) to individual file blobs
3. Handle nested archives recursively (e.g., .tar.gz → .tar → files)
4. Create virtual media for extracted contents with proper path/inode entries
5. Enable deduplication across archive contents
6. Mark intermediates for optional future cleanup

### Key Design Decisions

- **Virtual medium per archive** - Each archive/compressed file becomes a virtual medium
- **Use archive blobid as medium_hash** - Natural 1:1 mapping
- **Keep intermediates initially** - Simpler code, measure impact, cleanup later if needed
- **Depth-first processing** - Process nested archives immediately
- **Cycle detection** - Prevent infinite loops from pathological archives

---

## Current State Analysis

**Compressed/Archive Files:**
- **Total:** 184,040 unique blobs (305 GB compressed)
- **gzip:** 149,670 blobs (101 GB) - avg 4.36x expansion
- **zip:** 6,804 blobs (94 GB) - avg 2.45x expansion
- **bzip2:** 21,320 blobs (67 GB) - avg 5.66x expansion
- **tar:** 306 blobs (35 GB) - minimal expansion
- **other:** 5,940 blobs (8 GB)

**Storage Capacity:**
- **Current:** 8.4 TB free on fastpool
- **Estimated expansion:** 800-900 GB (with 50% deduplication)
- **Remaining after:** 7.5-7.6 TB free

---

## Phase 1: Database Schema Changes

**Duration:** 1 day
**Status:** [ ] Not Started

### Tasks

- [ ] Create `sql/add-extraction-schema.sql`
- [ ] Add columns to medium table
- [ ] Add columns to blobs table
- [ ] Create indexes
- [ ] Test migration on development database
- [ ] Run migration on production
- [ ] Verify indexes created
- [ ] Backfill medium_type for existing physical media
- [ ] Mark non-extractable blobs

### Schema: Medium Table Extensions

```sql
-- Track virtual media and extraction metadata
ALTER TABLE medium
  ADD COLUMN medium_type TEXT DEFAULT 'physical',
  ADD COLUMN parent_medium_hash TEXT,
  ADD COLUMN extraction_method TEXT,
  ADD COLUMN extraction_depth INTEGER DEFAULT 0,
  ADD COLUMN extracted_at TIMESTAMP WITH TIME ZONE,
  ADD COLUMN extraction_status TEXT DEFAULT 'pending';

-- Constraints
ALTER TABLE medium
  ADD CONSTRAINT medium_type_check
  CHECK (medium_type IN ('physical', 'virtual', 'carved'));

ALTER TABLE medium
  ADD CONSTRAINT fk_parent_medium
  FOREIGN KEY (parent_medium_hash)
  REFERENCES medium(medium_hash)
  ON DELETE CASCADE;

-- Indexes
CREATE INDEX idx_medium_type ON medium(medium_type);
CREATE INDEX idx_medium_parent ON medium(parent_medium_hash)
  WHERE parent_medium_hash IS NOT NULL;
CREATE INDEX idx_medium_extraction_pending ON medium(medium_hash)
  WHERE extraction_status = 'pending';
```

**Column semantics:**
- `medium_type`: 'physical' (disk), 'virtual' (extracted/decompressed), 'carved'
- `parent_medium_hash`: Points to containing medium (NULL for physical media)
- `extraction_method`: 'gzip', 'bzip2', 'tar', 'zip', '7z', etc.
- `extraction_depth`: Distance from physical medium (0=physical, 1+=nested)
- `extracted_at`: When extraction completed
- `extraction_status`: 'pending', 'in_progress', 'complete', 'failed'

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
  AND column_name IN ('medium_type', 'parent_medium_hash', 'extraction_method');

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'blobs'
  AND column_name IN ('is_intermediate', 'extraction_status');

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

- [ ] Create `bin/ntt-extractor.py` skeleton
- [ ] Implement ExtractionQueue class (depth-first LIFO)
- [ ] Implement VirtualMediumManager
- [ ] Implement ProgressLogger with stats/ETA
- [ ] Add CLI argument parsing
- [ ] Add structured JSON logging to `/var/log/ntt/extractor.jsonl`
- [ ] Implement cycle detection algorithm
- [ ] Add max depth checking (limit: 20)
- [ ] Implement resumability (reset in_progress to pending)
- [ ] Test with mock extractors

### CLI Interface

```bash
ntt-extractor.py [options]

Options:
  --limit N           Process only N blobs
  --format TYPE       Only process format (gzip/bzip2/tar/zip/all)
  --batch-size N      Batch size for DB inserts (default: 1000)
  --max-depth N       Max extraction depth (default: 20)
  --dry-run           Show what would be extracted
  --resume            Resume from previous run (default: true)
```

### Components

**ExtractionQueue:**
- Depth-first (LIFO) queue implementation
- Query pending extractable blobs
- Sort by size ASC for quick wins
- Track processed count and stats

**VirtualMediumManager:**
- Create virtual medium records
- Create partitions (inode_p_*, path_p_*)
- Generate synthetic inodes: `ino = hash(medium_hash || path)`
- Bulk insert inode/path entries

**ProgressLogger:**
- Log every 60 seconds
- Track: blobs processed, files extracted, bytes added, rate, ETA
- Output format: `[timestamp] Progress: 1,234 blobs | 56,789 files | 45 GB | 123 blobs/hr | ETA: 5.2d`

**CycleDetector:**
```python
def would_create_cycle(blob_medium_hash, parent_medium_hash):
    """Traverse parent chain to detect cycles."""
    visited = set()
    current = parent_medium_hash

    while current:
        if current == blob_medium_hash:
            return True  # Cycle!
        if current in visited:
            return True  # Loop in chain
        visited.add(current)
        current = db.get_parent_medium(current)

    return False
```

### Validation

```bash
# Test dry-run
ntt-extractor.py --dry-run --limit 10

# Test depth limiting
ntt-extractor.py --max-depth 3 --limit 5

# Check logging
tail -f /var/log/ntt/extractor.jsonl
```

---

## Phase 3: Decompressor Implementation

**Duration:** 2 days
**Status:** [ ] Not Started
**Depends on:** Phase 2

### Tasks

- [ ] Implement Decompressor class
- [ ] Support gzip format (gunzip)
- [ ] Support bzip2 format (bunzip2)
- [ ] Support xz format (unxz)
- [ ] Implement filename extension stripping (.gz → '', .tar.gz → .tar)
- [ ] Add MIME detection of decompressed content
- [ ] Mark intermediate files correctly
- [ ] Test with sample compressed files
- [ ] Validate intermediate marking

### Algorithm

```python
def decompress_blob(blobid, mime_type, parent_medium, depth):
    """
    Decompress single-file compression formats.

    Creates virtual medium containing decompressed file.
    Marks decompressed blob as intermediate.
    """
    # 1. Load blob from by-hash
    blob_path = get_byhash_path(blobid)

    # 2. Decompress streaming with hash computation
    with tempfile.NamedTemporaryFile() as temp:
        decompressed_hash = decompress_and_hash(
            blob_path,
            temp.name,
            algorithm=mime_to_algorithm(mime_type)
        )

        # 3. Detect MIME type of result
        decompressed_mime = detect_mime(temp.name)

        # 4. Copy to by-hash (with dedup check)
        if not blob_exists(decompressed_hash):
            copy_to_byhash(temp.name, decompressed_hash)
            insert_blob(decompressed_hash, mime=decompressed_mime)

        # 5. Mark as intermediate
        update_blob(
            decompressed_hash,
            is_intermediate=True,
            intermediate_of=blobid
        )

    # 6. Create virtual medium
    create_virtual_medium(
        medium_hash=blobid,
        parent_medium_hash=parent_medium,
        extraction_method=mime_to_method(mime_type),
        extraction_depth=depth
    )

    # 7. Add file to virtual medium
    original_filename = get_original_filename(blobid)
    decompressed_filename = strip_extension(original_filename, mime_type)

    insert_inode_and_path(
        medium_hash=blobid,
        path=f'/{decompressed_filename}',
        ino=generate_synthetic_ino(blobid, decompressed_filename),
        blobid=decompressed_hash,
        size=get_file_size(decompressed_hash)
    )

    # 8. If decompressed content is extractable, queue it
    if decompressed_mime in EXTRACTABLE_MIMES:
        queue.push((decompressed_hash, decompressed_mime, blobid, depth+1))

    # 9. Mark original blob as complete
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

## Phase 4: Archive Extractor Implementation

**Duration:** 3 days
**Status:** [ ] Not Started
**Depends on:** Phase 2

### Tasks

- [ ] Implement ArchiveExtractor class
- [ ] Support tar format
- [ ] Support zip format
- [ ] Support 7z format (if available)
- [ ] Implement temp directory management with cleanup
- [ ] Add bulk inode/path insertion (batches of 1000)
- [ ] Handle special files (symlinks → skip, directories → mark type='d')
- [ ] Test with sample archives
- [ ] Validate partition creation

### Algorithm

```python
def extract_archive(blobid, mime_type, parent_medium, depth):
    """
    Extract multi-file archives.

    Creates virtual medium containing all extracted files.
    Marks extracted files as NOT intermediate (they're real files).
    """
    # 1. Load blob from by-hash
    blob_path = get_byhash_path(blobid)

    # 2. Create temp extraction directory
    with tempfile.TemporaryDirectory() as temp_dir:
        # 3. Extract archive
        extract_to_dir(blob_path, temp_dir, mime_type)

        # 4. Create virtual medium
        create_virtual_medium(
            medium_hash=blobid,
            parent_medium_hash=parent_medium,
            extraction_method=mime_to_method(mime_type),
            extraction_depth=depth
        )

        # 5. Walk extracted filesystem
        extracted_files = []
        for root, dirs, files in os.walk(temp_dir):
            for filename in files:
                filepath = os.path.join(root, filename)
                relative_path = os.path.relpath(filepath, temp_dir)

                # Compute hash
                file_hash = compute_blake3(filepath)
                file_mime = detect_mime(filepath)
                file_size = os.path.getsize(filepath)

                # Copy to by-hash (with dedup)
                if not blob_exists(file_hash):
                    copy_to_byhash(filepath, file_hash)
                    insert_blob(file_hash, mime=file_mime, is_intermediate=False)

                # Track for batch insert
                extracted_files.append({
                    'path': f'/{relative_path}',
                    'ino': generate_synthetic_ino(blobid, relative_path),
                    'blobid': file_hash,
                    'size': file_size,
                    'mime': file_mime
                })

                # Queue if extractable
                if file_mime in EXTRACTABLE_MIMES:
                    queue.push((file_hash, file_mime, blobid, depth+1))

        # 6. Bulk insert inode/path entries
        batch_insert_inodes_and_paths(blobid, extracted_files, batch_size=1000)

        # 7. Mark complete
        update_blob(
            blobid,
            extraction_status='complete',
            files_extracted=len(extracted_files)
        )
```

### Test Cases

```bash
# Test simple tar
ntt-extractor.py --format tar --limit 1

# Test large archive (10K+ files)
# Validate batch insertion performance

# Test nested archive
# Archive containing .zip → verify both extracted

# Check partition creation
psql -c "\dt inode_p_*" | tail -20
```

---

## Phase 5: Integration Testing

**Duration:** 2 days
**Status:** [ ] Not Started
**Depends on:** Phase 3, Phase 4

### Test Scenarios

- [ ] **Simple decompression:** `file.txt.gz` → single file
- [ ] **Simple archive:** `backup.tar` → 100 files
- [ ] **Compressed archive:** `backup.tar.gz` → .tar (intermediate) → 100 files
- [ ] **Nested archives:** `outer.zip` → `inner.tar.gz` → .tar → files
- [ ] **Deep nesting:** 10 levels deep (test max depth)
- [ ] **Cycle detection:** Crafted archive containing itself
- [ ] **Deduplication:** Two archives with shared files
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

-- Check virtual media created
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

-- Check parent relationships valid
SELECT COUNT(*)
FROM medium
WHERE medium_type = 'virtual'
  AND parent_medium_hash IS NULL;
-- Should be 0
```

---

## Phase 6: Pilot Run

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

### Decision Gate

**Proceed to full run if:**
- [ ] Failure rate < 10%
- [ ] Deduplication rate > 20% OR intermediate overhead < 50%
- [ ] Storage estimate validated (within 20% of projection)
- [ ] Processing rate > 200 blobs/hour
- [ ] No critical bugs found

**If not, investigate and iterate.**

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

## Phase 8: Validation and Quality Checks

**Duration:** 1 day
**Status:** [ ] Not Started
**Depends on:** Phase 7

### Integrity Checks

Run all validation queries from Phase 5, plus:

```sql
-- Check all virtual media have parents
SELECT COUNT(*)
FROM medium
WHERE medium_type = 'virtual'
  AND parent_medium_hash IS NULL;
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
    WHERE m.medium_type = 'virtual'
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
SELECT 'Virtual media created', COUNT(*)
FROM medium WHERE medium_type = 'virtual'
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
| 1. Schema migration | 1 day | None | [ ] |
| 2. Core framework | 3-4 days | Phase 1 | [ ] |
| 3. Decompressor | 2 days | Phase 2 | [ ] |
| 4. Archive extractor | 3 days | Phase 2 | [ ] |
| 5. Integration testing | 2 days | Phase 3, 4 | [ ] |
| 6. Pilot run | 3-5 days | Phase 5 | [ ] |
| 7. Full production | 7-14 days | Phase 6 | [ ] |
| 8. Validation | 1 day | Phase 7 | [ ] |
| 9. Cleanup tool (future) | 2-3 days | - | [ ] |
| **Total** | **22-32 days** | | **0% complete** |

---

## Success Criteria

### Must Have

- [ ] All extractable blobs processed (extraction_status != 'pending')
- [ ] Intermediate files marked correctly (is_intermediate flag accurate)
- [ ] Virtual media created with correct parent relationships
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
- Use single partition for all virtual media (architectural change)

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

**Why virtual media model?**
- Clean schema (no path syntax hacks)
- Natural parent relationships (graph traversal)
- Supports arbitrary nesting
- Consistent with current architecture
- Scales to millions of archives

**Why depth-first processing?**
- More coherent (fully process each archive tree)
- Better for debugging (clear lineage)
- Natural recursion model
- Cache-friendly (parent context hot)

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
