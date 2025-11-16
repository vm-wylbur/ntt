<!--
Author: PB and Claude
Date: Thu 5 Nov 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/extraction-vs-existing-pipeline-comparison.md
-->

# Archive Extraction vs Existing Enum-Load-Copy Pipeline

**TL;DR:** My extraction implementation **reinvented** enum-load-copy as a combined atomic operation. This was necessary due to temp directory constraints, but we should evaluate if existing tools can be adapted instead.

---

## Existing Pipeline (Physical Media)

### Step 1: ntt-enum (Bash)
```bash
find "$MNT" -xdev -printf '%y\034%D\034%i\034%n\034%s\034%Ts\034%p\0'
```

**Input:** Mounted filesystem (persistent)
**Output:** .raw file with null-delimited records
**Format:** `fs_type FS dev FS inode FS nlink FS size FS mtime FS path NUL`

**Key features:**
- Uses real filesystem inodes
- Works on persistent mount points
- Outputs to file for later processing
- Supports ignore patterns (filter via grep)
- Progress tracking via pv

### Step 2: ntt-loader (Bash + PostgreSQL)
```sql
-- Load .raw file into temp table
COPY temp_table FROM STDIN WITH (DELIMITER E'\034')

-- Create partitions
CREATE TABLE IF NOT EXISTS inode_p_xxx PARTITION OF inode...
CREATE TABLE IF NOT EXISTS path_p_xxx PARTITION OF path...

-- Deduplicate and insert
INSERT INTO inode ... SELECT DISTINCT ON (medium_hash, ino) ...
INSERT INTO path ... SELECT ...
```

**Input:** .raw file from ntt-enum
**Output:** Partitioned inode/path tables in PostgreSQL
**Key features:**
- Creates partitions before insert
- TRUNCATE + INSERT (no ON CONFLICT)
- Bulk COPY for performance
- Marks non-files as copied=true
- Marks excluded paths
- Initializes queue_stats

### Step 3: ntt-copier.py (Python)
```python
# Phase 0: Claim work
UPDATE inode SET claimed_by=worker WHERE ino IN (
  SELECT ino FROM inode TABLESAMPLE SYSTEM_ROWS(100)
  WHERE copied=false AND claimed_by IS NULL
  FOR UPDATE SKIP LOCKED
)

# Phase 1: Analyze (read-only)
source_path = get_source_path(medium_hash, path)
copy_file_to_temp(source_path, temp_path)
blobid = hash_file(temp_path)
mime_type = detect_mime_type(source_path)
blob_exists = check_blob_exists(blobid)

# Phase 2: Execute (filesystem first, then DB)
if blob_exists:
    # Link to existing
    create_byhash_links(blobid, paths)
else:
    # Copy new
    move_to_byhash(temp_path, blobid)
    create_byhash_links(blobid, paths)

# Update DB
INSERT INTO blobs (blobid, ...) VALUES (...)
UPDATE inode SET copied=true, blobid=... WHERE ino=...
COMMIT
```

**Input:** Database records (files still on mounted filesystem)
**Output:** Deduplicated by-hash storage + hardlinks
**Key features:**
- Claim-Analyze-Execute pattern
- Multi-worker safe (SKIP LOCKED)
- Deduplication at blob level
- Diagnostic service for retry logic
- Files remain at original location during analysis

---

## My Extraction Implementation (Archives)

### Combined Operation (walk_and_hash_directory)
```python
with tempfile.TemporaryDirectory() as tmpdir:
    # Extract archive to temp
    extract_dir = Path(tmpdir) / "extracted"
    subprocess.run(['tar', '-xf', source, '-C', extract_dir])

    # Walk + Hash + Copy + Insert (all atomic)
    for root, dirs, files in os.walk(extract_dir):
        for filename in files:
            file_path = Path(root) / filename

            # ENUM: Get file stats
            rel_path = file_path.relative_to(extract_dir)
            size = file_path.stat().st_size
            mtime = int(file_path.stat().st_mtime)

            # COPY: Hash and copy to by-hash
            blobid = hash_file(file_path)
            copy_to_byhash(file_path, blobid)

            # ENUM: Detect MIME type
            mime_type = detect_mime_type(file_path)

            # LOAD: Generate synthetic inode
            inode = medium_manager.generate_synthetic_inode(
                medium_hash, rel_path
            )

            # LOAD: Batch records
            inodes_batch.append((inode, blobid, mime_type, size, mtime))
            paths_batch.append((inode, blobid, rel_path, 'done'))

            # LOAD: Bulk insert every 1000 rows
            if len(inodes_batch) >= 1000:
                medium_manager.bulk_insert_inodes(...)
                medium_manager.bulk_insert_paths(...)

    # Temp directory auto-deleted here
```

**Input:** Archive blobid (in by-hash storage)
**Output:** Extracted files in by-hash + partitioned tables
**Key features:**
- Combines all 3 steps (enum-load-copy) atomically
- Synthetic inodes (hash-based, not from filesystem)
- Immediate copy (before temp cleanup)
- No intermediate .raw file
- Bulk COPY inserts (1000 rows/batch)

---

## Critical Differences

### 1. Persistence Requirements

**Physical media:**
- Filesystem persists across enum → load → copy
- Can run steps hours/days apart
- ntt-copier.py expects files at original paths

**Extracted archives:**
- Files in temp directory (will be deleted)
- Must copy immediately (before temp cleanup)
- Cannot defer copy step

### 2. Inode Handling

**Physical media:**
- Uses real filesystem inodes
- Hardlink detection via nlink > 1
- Deduplication via inode number

**Extracted archives:**
- Synthetic inodes: `hash(medium_hash || path)`
- No hardlinks in temp directory
- Deduplication via blobid only

### 3. Separation of Concerns

**Physical media:**
```
ntt-enum    → .raw file
ntt-loader  → PostgreSQL
ntt-copier.py → by-hash storage
```
Each step is independent and restartable.

**Extracted archives:**
```
walk_and_hash_directory → Everything at once
```
Cannot be separated due to temp directory lifecycle.

### 4. Error Recovery

**Physical media:**
- enum fails → re-run from scratch
- load fails → re-run from .raw file
- copy fails → re-run claim-analyze-execute

**Extracted archives:**
- Extraction fails → mark blob as failed
- Must re-extract entire archive (no partial recovery)
- No intermediate checkpoints

---

## Can We Reuse Existing Tools?

### Option 1: Adapt ntt-enum for Temp Directories

**Feasibility:** HIGH

```bash
# Instead of mounted filesystem, pass temp directory
ntt-enum /tmp/extracted_abc123 abc123-extracted /tmp/extracted_abc123.raw
```

**Issues:**
1. **Real vs synthetic inodes** - ntt-enum uses filesystem inodes, we need synthetic
2. **Performance** - Creating .raw file adds I/O overhead
3. **Lifecycle** - Temp directory deleted before ntt-loader runs

**Verdict:** Could work if we:
- Modify ntt-enum to support synthetic inode generation
- Run ntt-loader immediately after (no temp cleanup between)
- Accept .raw file overhead for consistency

### Option 2: Adapt ntt-copier.py for Temp Directories

**Feasibility:** LOW

ntt-copier.py assumes:
```python
# File still at original location
source_path = mount_points[medium_hash] / path
copy_file_to_temp(source_path, temp_path)
hash_value = hash_file(temp_path)
```

**Issues:**
1. **Temp directory lifecycle** - Files deleted before copier runs
2. **Claim-Analyze-Execute** - Separation requires file persistence
3. **Multi-worker** - Multiple workers can't claim files from deleted temp dir

**Verdict:** Not feasible without major refactor

### Option 3: Keep Combined Implementation

**Feasibility:** DONE (current)

**Advantages:**
- Works with temp directory lifecycle
- Atomic operation (all-or-nothing)
- No intermediate files (.raw)
- Simpler error handling (retry entire extraction)

**Disadvantages:**
- Code duplication (enum/load/copy logic reinvented)
- No step-by-step restart
- Harder to debug (no intermediate .raw file)

---

## Recommendation Options

### Option A: Keep Current Implementation (Pragmatic)

**Accept:** Extraction is fundamentally different from physical media

**Rationale:**
- Temp directory lifecycle requires atomic operation
- Performance is good (bulk COPY)
- Code is simple and testable

**Trade-off:** Some code duplication vs complexity of adapting existing tools

### Option B: Refactor to Reuse ntt-enum + ntt-loader (Purist)

**Changes needed:**
1. Add synthetic inode mode to ntt-enum
2. Make ntt-loader runnable in "no cleanup" mode
3. Run enum → loader → cleanup atomically in single script

**Example:**
```bash
# In extract handler:
ntt-enum --synthetic-inodes "$extract_dir" "$medium_hash" "$temp_raw"
ntt-loader "$temp_raw" "$medium_hash"
# Don't cleanup temp_dir yet - copier needs it

# Then run copier on this medium immediately
ntt-copier.py --medium "$medium_hash" --immediate

# Now cleanup temp_dir
rm -rf "$extract_dir" "$temp_raw"
```

**Pros:** Reuses existing tested code
**Cons:** Complex coordination, temp files persist longer

### Option C: Hybrid Approach (Middle Ground)

**Extract common functions into library:**
```python
# lib/ntt_pipeline_common.py
def hash_file(path: Path) -> str:
    """Shared BLAKE3 hashing"""

def copy_to_byhash(source: Path, blobid: str) -> Path:
    """Shared by-hash copy logic"""

def detect_mime_type(path: Path) -> str:
    """Shared MIME detection"""

def bulk_insert_inodes(db, medium_hash, batch):
    """Shared bulk COPY logic"""
```

**Then:**
- ntt-copier.py imports these
- ntt_extractor_handlers.py imports these
- Both use same hashing/copying logic

**Pros:** Code reuse without complex coordination
**Cons:** Still need separate walk logic for archives

---

## My Assessment

**Current implementation (Option A) is correct for Phase 2/3.**

Reasons:
1. **Temp directory lifecycle** - Cannot defer copy step
2. **Synthetic inodes** - Archives don't have real filesystem inodes
3. **Atomic extraction** - Easier to reason about (all-or-nothing)
4. **Performance** - Bulk COPY is already optimized

**However:**
We should extract common functions (Option C) to reduce duplication:
- `hash_file()` - Used by copier and extractor
- `copy_to_byhash()` - Used by copier and extractor
- `detect_mime_type()` - Used by copier and extractor
- Bulk COPY helpers - Used by loader and extractor

This gives us code reuse without complex lifecycle management.

---

## Questions for PB

1. **Is the combined approach acceptable?** Or do you want separation for debuggability?

2. **Should we extract common functions?** Move hashing/copying logic to shared library?

3. **Do you want .raw files for archives?** Would help debugging but adds I/O overhead.

4. **Should extracted media go through copier?** Or is immediate copy in handler correct?

5. **Synthetic inode generation** - Is hash(medium_hash || path) the right approach?
