<!--
Author: PB and Claude
Date: Sat 16 Nov 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/ntt-copier-refactor-problem-statement.md
-->

# ntt-copier Refactor: Problem Statement

**Created:** 2025-11-16
**Context:** Post-Phase 4 partition drop migration
**Status:** Planning - copier currently BROKEN (queries non-existent tables)

---

## Executive Summary

**Problem:** ntt-copier.py queries `inode` and `path` parent tables that were dropped in Phase 4 migration.

**Impact:** Copy worker is completely non-functional - cannot claim or process any files.

**Root Cause:** Phase 4 migration (commit 448ab15) dropped partitioned `inode`/`path` tables but did NOT update copier code.

**Complexity:** This is NOT a simple find-replace. Schema change includes:
1. Separate tables (`inode` + `path`) → single `paths` table
2. Database-based claiming (`claimed_by` column) → Redis queue (like extractor)
3. Denormalized data (multiple path rows per inode for hardlinks)
4. All partition-pruning optimizations must be removed

---

## What is ntt-copier?

**Role in Pipeline:** Stage 4 - Deduplicate files to content-addressed blob storage

**Pipeline Stages:**
1. **Imaging** - Create disk images from physical media
2. **Enumeration** (`ntt-enum`) - Walk filesystem, extract inode metadata
3. **Loading** (`ntt-loader`) - Import enumeration data into PostgreSQL ✅ **UPDATED (commit fa93b4c)**
4. **Copying** (`ntt-copier.py`) - Deduplicate files to by-hash storage ❌ **BROKEN**
5. **Archiving** - Compress and move to cold storage

**Scale:**
- ~232M paths in database
- ~315K unclaimed files ready for processing (from VXA Tape 1 test)
- 1790 lines of Python code
- Critical performance path (processes all file content)

---

## Current Architecture (Partitioned Schema - BROKEN)

### Database Schema (OLD - doesn't exist anymore)

**Separate tables:**
```sql
CREATE TABLE inode (
    id          bigserial PRIMARY KEY,
    medium_hash text NOT NULL,
    ino         bigint NOT NULL,
    dev         bigint NOT NULL,
    size        bigint,
    mtime       bigint,
    fs_type     char(1),
    nlink       int,

    -- Blob linkage
    blobid      text REFERENCES blobs(blobid),

    -- Work queue columns
    copied      boolean DEFAULT false,
    claimed_by  text,
    claimed_at  timestamptz,

    -- Diagnostics
    status      text,
    error_type  text,
    errors      text[]
) PARTITION BY LIST (medium_hash);

CREATE TABLE path (
    medium_hash text NOT NULL,
    ino         bigint NOT NULL,
    path        bytea NOT NULL,
    dev         bigint NOT NULL,
    exclude_reason text,
    PRIMARY KEY (medium_hash, ino, path)
) PARTITION BY LIST (medium_hash);
```

**Key insight:** One `inode` row per unique (medium_hash, ino), multiple `path` rows for hardlinks.

### Claim-Analyze-Execute Pattern

**Phase 0: Claim Work (bin/ntt-copier.py:502-595)**

Uses database columns for work queue:

```python
def fetch_and_claim_batch(self) -> Optional[list[dict]]:
    """Atomically claim batch using UPDATE + claimed_by column"""
    claim_query = """
        WITH candidate AS (
            SELECT medium_hash, ino, dev, size, mtime, nlink, id
            FROM inode
            WHERE medium_hash = %s
              AND copied = false
              AND claimed_by IS NULL    -- ← Database-based queue
              AND id >= %s
            ORDER BY id
            LIMIT %s
            FOR UPDATE SKIP LOCKED
        )
        UPDATE inode i
        SET claimed_by = %s, claimed_at = NOW()    -- ← Claim with worker ID
        FROM candidate c
        WHERE (i.medium_hash, i.ino) = (c.medium_hash, c.ino)
        RETURNING i.*;
    """
```

**Critical optimization (line 514-518):**
```python
# CRITICAL: UPDATE WHERE clause uses composite PK (medium_hash, ino) for partition pruning
# Using WHERE i.id = c.id would scan ALL partitions (~7000ms)
# Using WHERE (i.medium_hash, i.ino) = (c.medium_hash, c.ino) enables runtime partition
# pruning - PostgreSQL can determine target partition from CTE rows (~13ms)
# Performance: 500x faster (verified 2025-10-07 via EXPLAIN ANALYZE)
```

**Phase 1: Analyze (filesystem operations)**
- Get paths from `path` table for inode
- Mount medium if needed
- Copy file to temp location
- Hash with BLAKE3
- Detect MIME type

**Phase 2: Execute (database + filesystem)**
- Move to by-hash storage (hardlink if exists, copy if new)
- Update `inode.copied = true, inode.blobid = hash`
- Update `path.blobid = hash` for all hardlink paths
- Insert into `blobs` table

### All Database Queries

**Queries to inode table:**
1. Line 245: `SELECT MAX(id) FROM inode WHERE medium_hash = %s` - Get max ID for random probing
2. Line 408-409: `UPDATE inode` - Mark broken inodes
3. Line 460-465: `SELECT * FROM inode WHERE ... claimed_by IS NULL` - Check max retries
4. Line 482-488: `UPDATE inode SET claimed_by = 'MAX_RETRIES_EXCEEDED'` - Mark failed
5. Line 522-536: Claim batch query (main work queue)
6. Line 531-534: `UPDATE inode SET claimed_by = %s, claimed_at = NOW()` - Claim
7. Line 955-963: `UPDATE inode SET copied = true, blobid = ...` - Mark success
8. Line 983-997: `UPDATE inode SET status = 'failed_permanent'` - Mark failures
9. Line 1008-1018: `UPDATE inode SET status = 'failed_retryable'` - Mark retryable
10. Line 1224-1234: `UPDATE inode SET copied = true` - Single-inode mode success
11. Line 1248-1257: `UPDATE inode SET status = 'failed_permanent'` - Single-inode permanent failure
12. Line 1286-1295: `UPDATE inode SET broken = true` - Mark broken
13. Line 1658-1667: `UPDATE inode SET copied = true` - Batch mode success
14. Line 1688-1698: `UPDATE inode SET status = 'failed'` - Batch mode failure

**Queries to path table:**
1. Line 942-950: `UPDATE path SET blobid = updates.blob_id` - Update all hardlink paths
2. Line 1387: `strategies.parse_partition_path(paths[0], medium_hash)` - Parse path

**Query to both:**
- JOIN patterns to get path + inode data together

---

## New Architecture (Unpartitioned Schema - REQUIRED)

### Database Schema (POST-Phase 4)

**Single denormalized table:**
```sql
CREATE TABLE paths (
    medium_hash text NOT NULL REFERENCES medium(medium_hash),
    dev         bigint NOT NULL,
    ino         bigint NOT NULL,
    path        bytea NOT NULL,

    -- Inode metadata (denormalized - duplicated for hardlinks)
    mtime       bigint,
    size        bigint,
    fs_type     char(1),
    nlink       int,

    -- Blob linkage
    blobid      text REFERENCES blobs(blobid),

    -- Status columns
    copied      boolean DEFAULT false,
    processed_at timestamptz,
    broken      boolean DEFAULT false,
    exclude_reason text,

    PRIMARY KEY (medium_hash, dev, ino, path),

    -- NO claimed_by, claimed_at columns!
    -- Work queue moved to Redis (see below)
);
```

**Key differences:**
1. **Single table**: All path + inode data in one table
2. **Denormalized**: Inode metadata (size, mtime, etc.) duplicated for each hardlink
3. **No work queue columns**: No `claimed_by`, `claimed_at` in database
4. **No id column**: No synthetic bigserial ID (PRIMARY KEY is composite)
5. **No partitioning**: All 232M rows in single table

**Migration rationale (from migrations/eliminate-partitions-phase1-schema.sql:31-32):**
```sql
-- Status (work queue moved to Redis):
copied      boolean DEFAULT false,
```

### Redis Queue Architecture (Like Extractor)

**Reference implementation:** `bin/ntt_extractor_queue.py` (already working for extraction)

**Redis keys for copier:**
```python
# Work queue
UNCLAIMED = 'ntt:copy:unclaimed:{medium_hash}'      # Set: unclaimed (medium_hash, dev, ino) tuples
IN_PROGRESS = 'ntt:copy:in_progress:{medium_hash}'  # Hash: {(medium_hash, dev, ino): worker_id}
FAILED = 'ntt:copy:failed:{medium_hash}'            # Set: permanently failed (medium_hash, dev, ino)

# Stats
STATS = 'ntt:copy:stats:{medium_hash}'              # Hash: counters
WORKERS = 'ntt:copy:workers'                         # Hash: {worker_id: pid}
```

**Claim operation becomes:**
```python
def claim_batch(medium_hash: str, worker_id: str, batch_size: int) -> List[Tuple]:
    """Claim batch from Redis (atomic using Lua script)"""
    # Pop batch_size items from UNCLAIMED set
    # Add to IN_PROGRESS hash with worker_id
    # Return claimed (medium_hash, dev, ino) tuples
```

**Why Redis?**
1. **Fast atomic operations**: SPOP is instant, no table locks
2. **Multi-worker safe**: Built-in atomic operations
3. **Persistent**: Redis AOF/RDB ensures no lost work
4. **Simpler schema**: No claim columns in database
5. **Already proven**: Extractor uses this pattern successfully

**Queue initialization:**
```sql
-- Populate Redis queue from database
SELECT medium_hash, dev, ino
FROM paths
WHERE medium_hash = %s
  AND copied = false
  AND exclude_reason IS NULL
  AND fs_type = 'f'
-- Worker calls redis.sadd(UNCLAIMED, json.dumps((medium_hash, dev, ino)))
```

### Hardlink Handling Challenge

**OLD schema:**
- One inode row per unique (medium_hash, ino)
- Claim one inode → process all hardlink paths
- Query: `SELECT path FROM path WHERE medium_hash = %s AND ino = %s`

**NEW schema:**
- Multiple path rows per unique (medium_hash, dev, ino)
- Each path row has duplicated inode metadata
- Need to group by (medium_hash, dev, ino) to find hardlinks

**Query patterns:**
```sql
-- Get all hardlink paths for claimed (medium_hash, dev, ino)
SELECT path, size, mtime
FROM paths
WHERE medium_hash = %s
  AND dev = %s
  AND ino = %s;

-- After processing, update ALL hardlink paths
UPDATE paths
SET copied = true,
    blobid = %s,
    processed_at = NOW()
WHERE medium_hash = %s
  AND dev = %s
  AND ino = %s;
```

**Important:**
- Process ONE unique (medium_hash, dev, ino) at a time
- Copy file ONCE (pick any path, they're all hardlinks to same content)
- Update ALL path rows for that (medium_hash, dev, ino)

---

## Refactoring Requirements

### Critical Changes

#### 1. Remove All inode Table References

**Affected lines:** 245, 408, 460, 482, 522, 531, 955, 983, 1008, 1224, 1248, 1286, 1658, 1688

**Replace with:**
- Queries to `paths` table
- GROUP BY (medium_hash, dev, ino) to deduplicate hardlinks
- WHERE clauses without `claimed_by` (Redis handles this)

#### 2. Implement Redis Queue Integration

**New dependencies:**
```python
# Add to script dependencies
dependencies = [
    "psycopg[binary]",
    "loguru",
    "pyyaml",
    "blake3",
    "python-magic",
    "typer",
    "bitmath",
    "redis",  # ← NEW
]
```

**New module:** `ntt_copier_queue.py` (like `ntt_extractor_queue.py`)

**Queue operations:**
```python
class RedisCopyQueue:
    def initialize_from_db(medium_hash: str) -> int
        """Seed Redis queue from paths table"""

    def claim_batch(worker_id: str, batch_size: int) -> List[Tuple]
        """Atomic batch claim from Redis"""

    def mark_completed(medium_hash, dev, ino, blobid: str)
        """Remove from IN_PROGRESS, update database"""

    def mark_failed(medium_hash, dev, ino, error: str, permanent: bool)
        """Handle failure (retry or permanent)"""

    def get_stats() -> dict
        """Get queue statistics"""
```

#### 3. Update __init__ Method

**Current (BROKEN - line 243-248):**
```python
# Calculate max_id for this medium (used for random probe strategy)
with self.conn.cursor() as cur:
    cur.execute("""
        SELECT MAX(id) FROM inode WHERE medium_hash = %s
    """, (self.medium_hash,))
    result = cur.fetchone()
    self.max_id = result['max'] if result and result['max'] else 0
```

**NEW:**
```python
# Initialize Redis queue
self.queue = RedisCopyQueue(
    redis_url=os.environ.get('REDIS_URL', 'redis://localhost:6379/0'),
    worker_id=self.worker_id
)

# Seed queue from database on first run
unclaimed_count = self.queue.initialize_from_db(
    db=self.conn,
    medium_hash=self.medium_hash
)
logger.info(f"Queue initialized: {unclaimed_count} unclaimed files")
```

#### 4. Rewrite fetch_and_claim_batch()

**Current (BROKEN - line 502-595):** 81 lines of complex SQL with partition pruning

**NEW (~15 lines):**
```python
def fetch_and_claim_batch(self) -> Optional[list[dict]]:
    """Claim batch from Redis and fetch details from database"""

    # Claim (medium_hash, dev, ino) tuples from Redis
    claimed_keys = self.queue.claim_batch(
        worker_id=self.worker_id,
        batch_size=self.batch_size
    )

    if not claimed_keys:
        return None

    # Fetch file details from database (one row per unique (medium_hash, dev, ino))
    # Use ANY(...) for efficient bulk query
    with self.conn.cursor() as cur:
        cur.execute("""
            SELECT DISTINCT ON (medium_hash, dev, ino)
                medium_hash, dev, ino, size, mtime, fs_type, nlink
            FROM paths
            WHERE (medium_hash, dev, ino) = ANY(%s)
              AND fs_type = 'f'
        """, (claimed_keys,))
        return cur.fetchall()
```

**Simplification:** No more:
- Random ID probing (no `id` column)
- Partition pruning optimization (no partitions)
- `claimed_by` column updates (Redis handles it)
- `FOR UPDATE SKIP LOCKED` (Redis atomic operations)

#### 5. Update All Success/Failure Handlers

**Pattern for success updates:**
```python
# OLD (BROKEN):
UPDATE inode SET copied = true, blobid = %s WHERE medium_hash = %s AND ino = %s

# NEW:
UPDATE paths
SET copied = true, blobid = %s, processed_at = NOW()
WHERE medium_hash = %s AND dev = %s AND ino = %s
# Updates ALL hardlink paths automatically
```

**Failure handling:**
```python
# OLD: Write to inode.errors array, update status
# NEW: Write to diagnostic system + Redis failed set
self.queue.mark_failed(medium_hash, dev, ino, error_msg, permanent=True)
```

#### 6. Remove Partition-Pruning Comments

**Search and remove:**
- All comments mentioning "partition pruning"
- References to "runtime partition selection"
- Performance notes about partition scanning

**Lines affected:** 507, 514-518, 538, 1005-1006

#### 7. Update Hardlink Path Queries

**OLD (separate path table):**
```python
# Get paths for inode
cur.execute("""
    SELECT path FROM path
    WHERE medium_hash = %s AND ino = %s
""", (medium_hash, ino))
```

**NEW (single paths table):**
```python
# Get all hardlink paths for (medium_hash, dev, ino)
cur.execute("""
    SELECT path, size, mtime FROM paths
    WHERE medium_hash = %s AND dev = %s AND ino = %s
""", (medium_hash, dev, ino))
```

**Note:** Now includes `dev` in WHERE clause (part of deduplication key)

---

## Implementation Strategy

### Option A: Incremental Refactor (RECOMMENDED)

**Phase 1: Redis Queue Only**
- Create `ntt_copier_queue.py` (copy from extractor queue)
- Replace `fetch_and_claim_batch()` with Redis version
- Keep database updates as-is (paths table)
- Test basic claim → process → mark complete cycle

**Phase 2: Update Database Queries**
- Change all `inode` → `paths`
- Add `dev` to all WHERE clauses
- Update `copied`, remove `claimed_by` references
- Test with VXA Tape 1 (315K files)

**Phase 3: Remove Dead Code**
- Remove partition-pruning optimizations
- Remove `max_id` calculation
- Clean up comments
- Update documentation

**Pros:**
- Testable at each phase
- Can rollback to partitioned schema if needed
- Clear verification points

**Cons:**
- 3 separate changes to commit

### Option B: Complete Rewrite

Create `ntt-copier-unpartitioned.py` from scratch:
- Start with extractor as template (already uses Redis)
- Adapt claim → hash → dedupe flow
- Preserve diagnostics system (already paths-compatible)
- Side-by-side testing

**Pros:**
- Clean slate
- Can run old copier during migration
- Less risk of breaking changes

**Cons:**
- More code duplication
- Harder to compare before/after

---

## Testing Plan

### Prerequisites

1. **Redis running:** `systemctl status redis` or `docker run -d redis`
2. **VXA Tape 1 loaded:** 348,739 paths from ntt-loader test
3. **Queue stats show unclaimed work:** 315,572 files ready

### Phase 1: Queue Functionality

```bash
# Test queue initialization
sudo -E ntt-copier.py --medium-hash <VXA_TAPE1_HASH> --worker-id test-w1 --limit 10 --dry-run

# Verify Redis keys created
redis-cli KEYS "ntt:copy:*"
redis-cli SCARD ntt:copy:unclaimed:<medium_hash>
```

**Expected:** Queue populated with unclaimed (medium_hash, dev, ino) tuples

### Phase 2: Claim and Process

```bash
# Run single batch
sudo -E ntt-copier.py --medium-hash <VXA_TAPE1_HASH> --worker-id test-w1 --limit 100

# Check results
psql copyjob -c "SELECT COUNT(*) FROM paths WHERE medium_hash = '<hash>' AND copied = true"
redis-cli HLEN ntt:copy:in_progress:<medium_hash>
redis-cli SCARD ntt:copy:unclaimed:<medium_hash>
```

**Expected:**
- 100 files processed
- `paths.copied = true` for processed files
- `paths.blobid` set to BLAKE3 hash
- Redis queue decremented

### Phase 3: Multi-Worker

```bash
# Launch 3 workers
sudo -E ntt-copier.py --medium-hash <hash> --worker-id w1 &
sudo -E ntt-copier.py --medium-hash <hash> --worker-id w2 &
sudo -E ntt-copier.py --medium-hash <hash> --worker-id w3 &

# Monitor progress
watch -n 1 'redis-cli SCARD ntt:copy:unclaimed:<hash>'
```

**Expected:** No conflicts, no duplicate work, clean completion

### Phase 4: Edge Cases

- **Hardlinks:** Verify all paths for (medium_hash, dev, ino) get `blobid` set
- **Broken files:** Test file read failures (diagnostics system)
- **Missing media:** Test mount failures
- **Redis restart:** Verify IN_PROGRESS recovery

---

## Migration Checklist

- [ ] Create `ntt_copier_queue.py` module (based on extractor queue)
- [ ] Add Redis dependency to script metadata
- [ ] Replace `fetch_and_claim_batch()` with Redis version
- [ ] Update `__init__` to initialize queue
- [ ] Change all `inode` → `paths` in queries
- [ ] Add `dev` column to all WHERE clauses
- [ ] Remove `claimed_by`, `claimed_at` column references
- [ ] Update success handlers (remove `claimed_by` updates)
- [ ] Update failure handlers (use Redis queue)
- [ ] Remove partition-pruning comments and code
- [ ] Remove `max_id` calculation
- [ ] Test with VXA Tape 1 (small scale)
- [ ] Test multi-worker scenario
- [ ] Update documentation

---

## Success Criteria

1. **Functional:** Can process VXA Tape 1 files (315K files)
2. **Performance:** Throughput similar to old copier (~50-100 files/sec)
3. **Multi-worker:** 3+ workers process without conflicts
4. **Correctness:** All hardlink paths get blobid set
5. **Resilient:** Handles broken files via diagnostics system
6. **Clean:** No references to dropped `inode` or `path` tables

---

## Open Questions

1. **Queue initialization:** Seed from database once, or re-initialize on every worker start?
2. **Redis persistence:** AOF or RDB for work queue?
3. **Cleanup:** Who removes completed items from Redis? (periodic cleanup job?)
4. **Statistics:** Keep `queue_stats` table or move to Redis?
5. **Diagnostics:** Does `DiagnosticService` need updates for paths schema?

---

## References

**Related Migrations:**
- **Phase 4 Cutover:** `migrations/phase4-cutover.sql` - Dropped inode/path tables
- **Phase 1 Schema:** `migrations/eliminate-partitions-phase1-schema.sql` - Created paths table
- **Loader Refactor:** `docs/completed/ntt-loader-refactor-problem-statement.md` - Similar migration

**Working Code:**
- **Extractor Queue:** `bin/ntt_extractor_queue.py` - Redis queue reference implementation
- **Current Copier:** `bin/ntt-copier.py` (1790 lines, BROKEN)

**Database:**
- **Current Schema:** `psql copyjob -c "\d paths"`
- **Queue Stats:** `SELECT * FROM queue_stats WHERE medium_hash = '<VXA_TAPE1_HASH>'`

---

## Glossary

- **inode** - OLD: Separate table with one row per unique filesystem inode
- **path** - OLD: Separate table with one row per path (multiple paths → same inode for hardlinks)
- **paths** - NEW: Single table with denormalized inode data (inode metadata duplicated per path)
- **partition pruning** - OLD: PostgreSQL optimization using medium_hash to select correct partition
- **claimed_by** - OLD: Database column tracking which worker owns an inode (removed in new schema)
- **Redis queue** - NEW: External work queue (like extractor uses) replacing database columns
- **(medium_hash, dev, ino)** - Unique identifier for filesystem inode in new schema
- **hardlink** - Multiple paths pointing to same inode (same dev + ino)
- **denormalized** - Inode metadata duplicated across multiple path rows (simpler queries, more storage)
