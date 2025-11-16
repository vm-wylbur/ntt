<!--
Author: PB and Claude
Date: Thu 5 Nov 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/phase2-core-framework-report.md
-->

# Phase 2 Implementation Report: Core Extraction Framework

**Date:** 2025-11-05
**Status:** Complete
**Files Created:** 4 modules (queue, medium, handlers, CLI)

---

## What Was Implemented

### 1. Redis Queue Module (`bin/ntt_extractor_queue.py`)

**Purpose:** Persistent, multi-worker-safe extraction queue

**Key features:**
- **Priority queue** (sorted set) - smallest blobs first for quick wins
- **LIFO nested queue** (list) - depth-first traversal for nested archives
- **Deduplication** (set) - prevents re-extraction via PROCESSED set
- **In-progress tracking** (hash) - maps blobid → worker_id for monitoring
- **Worker registry** (hash) - tracks active workers by PID
- **Atomic operations** - ZPOPMIN, RPOP ensure multi-worker safety

**Data structures:**
```
PRIORITY:     Sorted set {item_json: size}
NESTED:       List [item_json, ...]  (LIFO via RPOP)
PROCESSED:    Set {blobid, ...}
IN_PROGRESS:  Hash {blobid: worker_id}
STATS:        Hash {queued: N, processed: N, failed: N}
WORKERS:      Hash {worker_id: pid}
```

**Why it's correct:**
1. Atomic operations (ZPOPMIN, RPOP) prevent race conditions between workers
2. Deduplication check happens in pop() before marking in-progress
3. Nested archives are checked first (depth-first) for memory efficiency
4. Recovery mechanism can clear stuck jobs without data loss

### 2. Medium Manager Module (`bin/ntt_extractor_medium.py`)

**Purpose:** Create extracted media and manage partitioned tables

**Key features:**
- **Synthetic inode generation** - hash(medium_hash || path) → int64
- **Partition creation** - CREATE TABLE ... PARTITION OF for medium_hash
- **Bulk COPY inserts** - PostgreSQL COPY for 10-100x faster than INSERT
- **Intermediate tracking** - marks .tar from .tar.gz for cleanup
- **Status updates** - extraction_status: pending → completed/failed

**Why it's correct:**
1. **Synthetic inodes are deterministic** - same path always gets same inode
2. **Unique constraint on source_blobid** - prevents duplicate extractions
3. **COPY batching** - uses StringIO buffer, much faster than executemany()
4. **Partition-per-medium** - follows existing NTT architecture (commit 30153f1)
5. **ON CONFLICT DO UPDATE** - idempotent medium creation

### 3. Handler Registry (`bin/ntt_extractor_handlers.py`)

**Purpose:** Dispatch table for MIME type → extraction function

**Key design:**
```python
MIME_HANDLERS = {
    'application/gzip': 'decompress_gzip',
    'application/x-tar': 'extract_tar',
    # ... 15 total formats
}
```

**Why it's correct:**
1. **Single source of truth** - get_supported_mime_types() used by init command
2. **No hardcoded lists** - handler registry drives database queries
3. **Stub handlers raise NotImplementedError** - fail-fast for Phase 2
4. **ExtractionResult dataclass** - structured return (medium_hash, files_extracted, nested_archives)
5. **Common infrastructure** - get_byhash_path(), copy_to_byhash(), detect_mime_type()

### 4. Main CLI (`bin/ntt-extractor.py`)

**Purpose:** Typer-based CLI with subcommands

**Commands:**
- `init` - Seed queue from PostgreSQL (uses handler registry for MIME types)
- `run` - Worker process (with graceful shutdown)
- `status` - Queue statistics
- `reset` - Clear all queue data
- `recover` - Clear stuck jobs from crashed workers

**Why it's correct:**
1. **uv shebang** - inline dependencies, matches ntt-copier.py pattern
2. **Signal handlers** - SIGINT/SIGTERM for graceful shutdown
3. **Worker ID tracking** - hostname-w{id}-{pid} format for multi-worker
4. **JSON logging** - loguru with serialize=True for structured logs
5. **Error handling** - try/except with mark_failed() on exceptions

---

## Verification Strategy

### Manual Tests (Recommended)

#### 1. Test Queue Operations
```bash
# Start Redis (if not running)
redis-server --daemonize yes

# Initialize queue (small test batch)
./bin/ntt-extractor.py init --limit 10

# Check status
./bin/ntt-extractor.py status

# Expected output:
# Queue size: 10
# Completed: 0
# Failed: 0
```

#### 2. Test Worker (Will Fail - Handlers Are Stubs)
```bash
# Run worker (should fail with NotImplementedError)
./bin/ntt-extractor.py run --max-jobs 1

# Expected: Handler stub warning in logs
# "Handler stub called: decompress_gzip(...)"
# "Handler implementation pending Phase 3"
```

#### 3. Test Deduplication
```bash
# Initialize same data twice
./bin/ntt-extractor.py init --limit 5
./bin/ntt-extractor.py init --limit 5  # Should not double-queue

# Check status - queue should still be 5, not 10
./bin/ntt-extractor.py status
```

#### 4. Test Medium Manager (Python REPL)
```python
import sys
sys.path.insert(0, '/home/pball/projects/ntt/bin')

from ntt_db import get_db_connection
from ntt_extractor_medium import ExtractionMediumManager

db = get_db_connection()
mgr = ExtractionMediumManager(db)

# Test synthetic inode generation
inode1 = mgr.generate_synthetic_inode('abc123', '/foo/bar.txt')
inode2 = mgr.generate_synthetic_inode('abc123', '/foo/bar.txt')
assert inode1 == inode2  # Deterministic

inode3 = mgr.generate_synthetic_inode('abc123', '/foo/baz.txt')
assert inode1 != inode3  # Different path → different inode
```

### Database Verification
```sql
-- Check extraction schema applied
SELECT column_name FROM information_schema.columns
WHERE table_name = 'medium' AND column_name IN ('source_blobid', 'extraction_method');

-- Check pending blobs count
SELECT extraction_status, COUNT(*) FROM blobs GROUP BY extraction_status;
-- Expected: 6,988,086 pending

-- Check handler MIME types match database
SELECT mime_type, COUNT(*) FROM inode
WHERE mime_type IN (
  'application/gzip', 'application/x-bzip2', 'application/x-xz',
  'application/x-compress', 'application/x-lzip',
  'application/x-tar', 'application/zip', 'application/x-archive',
  'application/vnd.rar', 'application/vnd.ms-cab-compressed',
  'application/x-7z-compressed', 'application/x-gzip',
  'application/x-bzip', 'application/x-lzma'
)
GROUP BY mime_type
ORDER BY COUNT(*) DESC;
-- Should match our 15 formats
```

---

## Why We Think It's Correct

### 1. Architecture Alignment
- **Partitioning:** Follows partition-to-partition FK architecture (commit 30153f1)
- **Logging:** Uses loguru JSON format (like ntt-copier.py)
- **CLI:** Uses Typer + uv shebang (matches ntt-copier.py)
- **Database:** Uses psycopg3 with get_db_connection() from ntt_db.py

### 2. Data Integrity
- **One extraction per blob:** Unique index on source_blobid enforces deduplication
- **Atomic queue operations:** Redis ZPOPMIN/RPOP prevent race conditions
- **Provenance tracking:** source_blobid enables path table joins for history
- **Status tracking:** extraction_status prevents re-querying completed blobs

### 3. Performance
- **Bulk COPY:** StringIO + COPY is 10-100x faster than INSERT loops
- **Priority queue:** Process small files first for quick throughput metrics
- **Depth-first:** LIFO nested queue minimizes temp disk usage

### 4. Multi-Worker Safety
- **Worker registration:** Tracks PIDs for monitoring
- **Atomic pop:** ZPOPMIN ensures only one worker gets each blob
- **Graceful shutdown:** Signal handlers prevent corruption on SIGINT
- **Recovery:** recover command clears stuck jobs from crashed workers

### 5. Extensibility (Phase 3)
- **Handler registry:** Easy to add new formats by updating MIME_HANDLERS dict
- **ExtractionResult:** Structured return enables nested archive tracking
- **Common infrastructure:** Shared functions (get_byhash_path, copy_to_byhash, detect_mime_type)

---

## Known Limitations (By Design)

1. **Handlers are stubs** - Phase 3 will implement actual extraction logic
2. **No retry logic** - Failed extractions stay in PROCESSED set (may add later)
3. **No progress tracking per blob** - Could add percentage for large archives
4. **No disk space checks** - Should add before extraction (future enhancement)

---

## Next Steps (Phase 3)

Implement actual extraction handlers:
1. Decompression handlers (gzip, bzip2, xz, compress, lzip)
2. Archive handlers (tar, zip, ar, rar, cab, 7z)
3. Compound handlers (tar.gz, tar.bz2, tar.xz)
4. Intermediate handling (mark .tar from .tar.gz)
5. Nested archive detection and queuing

---

## Files Created

- `bin/ntt_extractor_queue.py` - Redis queue (217 lines)
- `bin/ntt_extractor_medium.py` - Medium/partition manager (207 lines)
- `bin/ntt_extractor_handlers.py` - Handler registry + stubs (197 lines)
- `bin/ntt-extractor.py` - Main CLI (267 lines)

**Total:** 888 lines of framework code ready for Phase 3 handlers.
