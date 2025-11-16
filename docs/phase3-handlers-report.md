<!--
Author: PB and Claude
Date: Thu 5 Nov 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/phase3-handlers-report.md
-->

# Phase 3 Implementation Report: Extraction Handlers

**Date:** 2025-11-05
**Status:** Complete
**Handlers Implemented:** 15 formats (5 decompression + 6 archive + 3 compound + 1 nested walker)

---

## What Was Implemented

### 1. Common Infrastructure

**Added functions:**
```python
hash_file(path) -> str
    # BLAKE3 hash using 64KB chunks
    # Returns hex digest

walk_and_hash_directory(extract_dir, medium_manager, medium_hash)
    # Walk extracted directory
    # Hash each file, copy to by-hash
    # Create inodes/paths (batched COPY)
    # Detect nested archives
    # Returns: (file_count, nested_archives)
```

**Why it's correct:**
1. **BLAKE3 chunked reading** - 64KB chunks prevent memory exhaustion on large files
2. **Batched inserts** - walk_and_hash_directory() batches every 1000 rows
3. **Nested detection** - checks MIME type against MIME_HANDLERS registry
4. **Deduplication** - copy_to_byhash() checks dest.exists() before copying
5. **Hardlink first** - tries os.link() before shutil.copy2() for same-filesystem efficiency

### 2. Decompression Handlers (5 formats)

**Implementation pattern:**
```python
def _decompress_generic(db, blobid, command, method_name):
    # 1. Get source from by-hash
    # 2. Decompress to temp file
    # 3. Hash decompressed file
    # 4. Copy to by-hash
    # 5. Create medium + partition
    # 6. Insert single inode/path for "/decompressed"
    # 7. Check if result is nested archive
    # 8. Return ExtractionResult
```

**Handlers:**
- `decompress_gzip` - `gzip -dc`
- `decompress_bzip2` - `bzip2 -dc`
- `decompress_xz` - `xz -dc`
- `decompress_compress` - `uncompress -c`
- `decompress_lzip` - `lzip -dc`

**Why it's correct:**
1. **-dc flags** - decompress to stdout, read from file (not stdin)
2. **Temp file output** - writes to tmpdir file (not stream) for hashing
3. **Nested detection** - checks if decompressed file is archive (e.g., .tar from .tar.gz)
4. **Automatic cleanup** - tempfile.TemporaryDirectory() auto-removes on exit
5. **Single inode** - path="/decompressed" since compression produces single file

### 3. Archive Handlers (6 formats)

**Implementation pattern:**
```python
def extract_tar(db, blobid):
    # 1. Get source from by-hash
    # 2. Extract to temp directory
    # 3. Create medium + partition
    # 4. Walk directory (hash, copy, insert, detect nested)
    # 5. Return ExtractionResult
```

**Handlers:**
- `extract_tar` - `tar -xf`
- `extract_zip` - `unzip -q -d`
- `extract_ar` - `ar x` (cwd=extract_dir)
- `extract_rar` - `unrar x -inul`
- `extract_cab` - `cabextract -q -d`
- `extract_7z` - `7z x -o`

**Why it's correct:**
1. **Quiet flags** - `-q`, `-inul` suppress progress output
2. **Output directory** - `-C`, `-d`, `-o` specify extract location
3. **Working directory** - ar uses cwd=extract_dir since it lacks -d flag
4. **Relative paths** - walk_and_hash_directory() uses file_path.relative_to(extract_dir)
5. **Nested detection** - automatically queues any .tar.gz, .zip, etc found inside

### 4. Compound Handlers (3 formats)

**tar.gz/tar.bz2/tar.xz:**
```python
def extract_tar_gz(db, blobid):
    # tar -xzf (tar handles gzip internally)

def extract_tar_bz2(db, blobid):
    # tar -xjf (tar handles bzip2 internally)

def extract_tar_xz(db, blobid):
    # tar -xJf (tar handles xz internally)
```

**Why it's correct:**
1. **Single-step extraction** - tar natively supports compressed input
2. **No intermediate .tar** - avoids creating temporary .tar file
3. **Atomic operation** - extraction happens in one command
4. **Same structure** - produces same result as two-step (decompress → extract)

**Alternative approach (not used):**
- Could decompress first → get .tar blobid → mark intermediate → extract .tar
- Decided against: adds complexity, intermediate tracking, and disk I/O
- Trade-off: Lose .tar blobid tracking but gain simplicity

### 5. Nested Archive Handling

**Detection:**
```python
# In walk_and_hash_directory()
mime_type = detect_mime_type(file_path)
if mime_type in MIME_HANDLERS:
    nested_archives.append((blobid, mime_type))
```

**Queuing:**
```python
# In ntt-extractor.py run() command
for nested_blobid, nested_mime in result.nested_archives:
    queue.push_nested(nested_blobid, nested_mime)
```

**Why it's correct:**
1. **LIFO queue** - Redis RPUSH + RPOP ensures depth-first traversal
2. **Deduplication** - push_nested() checks PROCESSED set before queuing
3. **Full provenance** - nested blobs get their own medium with source_blobid
4. **Transitive closure** - unlimited nesting depth (archive in archive in archive...)

---

## Verification Strategy

### 1. Test Single Decompression
```bash
# Create test .gz file
echo "test content" | gzip > /tmp/test.gz
BLOBID=$(blake3sum /tmp/test.gz | cut -d' ' -f1)
cp /tmp/test.gz /data/fast/ntt/by-hash/${BLOBID:0:2}/${BLOBID:2:4}/$BLOBID

# Queue and extract
./bin/ntt-extractor.py init --limit 1 --format-filter application/gzip
./bin/ntt-extractor.py run --max-jobs 1

# Verify
psql -d copyjob -c "
  SELECT medium_hash, extraction_method, files_extracted
  FROM medium WHERE medium_type = 'extracted';"
# Expected: 1 row, files_extracted=1

psql -d copyjob -c "
  SELECT path, mime_type FROM path WHERE path = '/decompressed';"
# Expected: /decompressed with mime_type = text/plain
```

### 2. Test Archive Extraction
```bash
# Create test .tar archive
mkdir /tmp/test_archive
echo "file1" > /tmp/test_archive/file1.txt
echo "file2" > /tmp/test_archive/file2.txt
tar -cf /tmp/test.tar -C /tmp/test_archive .

# Copy to by-hash and queue
BLOBID=$(blake3sum /tmp/test.tar | cut -d' ' -f1)
cp /tmp/test.tar /data/fast/ntt/by-hash/${BLOBID:0:2}/${BLOBID:2:4}/$BLOBID

./bin/ntt-extractor.py init --limit 1 --format-filter application/x-tar
./bin/ntt-extractor.py run --max-jobs 1

# Verify
psql -d copyjob -c "
  SELECT COUNT(*) FROM path WHERE medium_hash IN (
    SELECT medium_hash FROM medium WHERE medium_type = 'extracted'
  );"
# Expected: 2 (file1.txt, file2.txt)
```

### 3. Test Nested Archives
```bash
# Create nested .tar.gz (archive inside archive)
mkdir /tmp/inner
echo "inner content" > /tmp/inner/inner.txt
tar -czf /tmp/inner.tar.gz -C /tmp/inner .

mkdir /tmp/outer
cp /tmp/inner.tar.gz /tmp/outer/
tar -czf /tmp/outer.tar.gz -C /tmp/outer .

# Copy to by-hash and queue
BLOBID=$(blake3sum /tmp/outer.tar.gz | cut -d' ' -f1)
cp /tmp/outer.tar.gz /data/fast/ntt/by-hash/${BLOBID:0:2}/${BLOBID:2:4}/$BLOBID

./bin/ntt-extractor.py init --limit 1
./bin/ntt-extractor.py run  # Process until queue empty

# Verify depth-first extraction
psql -d copyjob -c "
  SELECT medium_hash, source_blobid, extraction_method, files_extracted
  FROM medium WHERE medium_type = 'extracted' ORDER BY extracted_at;"
# Expected: 2 rows (outer.tar.gz → inner.tar.gz → inner.txt)

# Verify provenance chain
psql -d copyjob -c "
  SELECT m1.extraction_method as outer, m2.extraction_method as inner
  FROM medium m1
  JOIN medium m2 ON m2.source_blobid IN (
    SELECT blobid FROM path WHERE medium_hash = m1.medium_hash
  )
  WHERE m1.medium_type = 'extracted';"
# Expected: outer=tar.gz, inner=tar.gz
```

### 4. Test Deduplication
```bash
# Queue same blob twice
./bin/ntt-extractor.py init --limit 1
./bin/ntt-extractor.py init --limit 1  # Should not double-queue

./bin/ntt-extractor.py status
# Expected: Queue size = 1 (not 2)

# Run extraction
./bin/ntt-extractor.py run --max-jobs 1

# Try to queue again (should skip - already in PROCESSED)
./bin/ntt-extractor.py init --limit 1
./bin/ntt-extractor.py status
# Expected: Queue size = 0 (blob already processed)
```

---

## Why We Think It's Correct

### 1. Subprocess Safety
- **check=True** - raises CalledProcessError on non-zero exit
- **stderr=PIPE** - captures error messages
- **Temp directories** - automatic cleanup on context exit
- **No shell=True** - prevents command injection

### 2. Data Integrity
- **BLAKE3 hashing** - content-addressable storage ensures correctness
- **Deduplication** - same file hash → same by-hash path (idempotent)
- **Synthetic inodes** - deterministic hash(medium_hash || path)
- **Batch commits** - 1000 rows per COPY for atomicity

### 3. Provenance Tracking
- **source_blobid** - links extracted medium to original archive
- **Unique constraint** - one extraction per blob (sql/04-add-extraction-schema.sql:36-38)
- **Path table joins** - can query: "where did this extracted file come from?"

Example provenance query:
```sql
-- Find original location of extracted file
SELECT archive_path.path as archive_location
FROM path extracted_file
JOIN medium vm ON vm.medium_hash = extracted_file.medium_hash
JOIN path archive_path ON archive_path.blobid = vm.source_blobid
WHERE extracted_file.path = '/some/extracted/file.txt'
  AND vm.medium_type = 'extracted';
```

### 4. Nested Archive Handling
- **Depth-first traversal** - LIFO queue minimizes temp disk usage
- **Transitive closure** - unlimited nesting depth
- **Deduplication check** - push_nested() checks PROCESSED before queuing
- **Automatic detection** - MIME type check against handler registry

### 5. Error Handling
- **try/except in run()** - mark_failed() on handler exceptions
- **Redis recovery** - recover command clears stuck jobs
- **Status tracking** - extraction_status: pending → completed/failed

---

## Implementation Details

### Handler Registry Dispatch
```python
# In ntt-extractor.py run()
handler_name = MIME_HANDLERS.get(mime_type)
# Example: 'application/gzip' → 'decompress_gzip'

handler_func = handlers[handler_name]
# handlers dict maps name string → function reference

result = handler_func(db, blobid)
# Calls actual function (e.g., decompress_gzip(db, blobid))
```

**Why this works:**
- Handler registry (MIME_HANDLERS) is single source of truth
- get_supported_mime_types() used by init command for database query
- Same registry used by nested detection in walk_and_hash_directory()
- Adding new format = update MIME_HANDLERS + implement function

### Temporary Directory Pattern
```python
with tempfile.TemporaryDirectory() as tmpdir:
    extract_dir = Path(tmpdir) / "extracted"
    # ... extraction happens ...
    # ... files hashed and copied to by-hash ...
# tmpdir automatically deleted here
```

**Why this works:**
- Automatic cleanup even on exceptions
- Unique tmpdir per extraction (no collisions)
- Files copied to by-hash before cleanup (not moved)

### Batched Bulk Inserts
```python
# In walk_and_hash_directory()
if len(inodes_batch) >= 1000:
    medium_manager.bulk_insert_inodes(medium_hash, inodes_batch)
    medium_manager.bulk_insert_paths(medium_hash, paths_batch)
    inodes_batch.clear()
    paths_batch.clear()

# Insert remaining at end
if inodes_batch:
    medium_manager.bulk_insert_inodes(medium_hash, inodes_batch)
    medium_manager.bulk_insert_paths(medium_hash, paths_batch)
```

**Why this works:**
- COPY is 10-100x faster than INSERT
- 1000 rows is good balance (not too large for memory, not too small for overhead)
- Final insert handles remainder (e.g., 1200 files → 1000 + 200)

---

## Known Limitations

### 1. No Intermediate .tar Tracking (Compound Formats)
**Issue:** tar.gz extracted directly, .tar blobid not recorded

**Impact:** Cannot query "show me all .tar files"

**Rationale:** Simplicity > completeness. Can implement later if needed.

**Future fix:**
```python
def extract_tar_gz_with_intermediate(db, blobid):
    # 1. Decompress .gz → get .tar blobid
    # 2. Mark .tar as intermediate_of=original_blobid
    # 3. Extract .tar
    # 4. Return both .tar and final extraction results
```

### 2. Error Recovery Is Basic
**Issue:** Failed extractions stay in PROCESSED set (no retry)

**Impact:** Transient failures (disk full, network) require manual re-queue

**Future fix:** Add retry logic with exponential backoff

### 3. No Progress Tracking for Large Archives
**Issue:** No progress bars or percentage complete

**Impact:** Large .zip files look "stuck" during extraction

**Future fix:** Add progress callback using subprocess output parsing

### 4. No Disk Space Checks
**Issue:** Doesn't check available disk before extraction

**Impact:** Could fill /tmp and crash

**Future fix:** Check df output before extraction, skip if <10GB free

---

## Files Modified

- `bin/ntt_extractor_handlers.py` - Added all 15 handlers + infrastructure (654 lines total)
- `bin/ntt-extractor.py` - Added blake3 dependency

---

## Phase 2 + Phase 3 Summary

**Total implementation:**
- 4 modules (queue, medium, handlers, CLI)
- 1,542 lines of code
- 15 extraction formats supported
- Redis-backed persistent queue
- Multi-worker safe
- Full provenance tracking
- Nested archive support
- Bulk COPY inserts for performance

**Ready for Phase 4:** Pilot run on small subset to validate implementation.
