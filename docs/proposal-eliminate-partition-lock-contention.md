<!--
Author: PB and Claude
Date: Fri 15 Nov 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/proposal-eliminate-partition-lock-contention.md
-->

# Proposal: Eliminate Partition Lock Contention via Architectural Simplification

**Status**: Proposal
**Date**: 2025-11-15
**Problem**: PostgreSQL partition lock contention causing 62% throughput loss (2.0 archives/sec observed vs 5.3 expected)

---

## Executive Summary

Eliminate the inode table and per-medium partitioning. Replace with:
1. **blob table** - content-addressed storage (hash → size, mime_type, blobid)
2. **unpartitioned path table** - all paths, references blob via hash
3. **Redis work queue** - replaces PostgreSQL `FOR UPDATE SKIP LOCKED` complexity

**Result**: Zero partition lock contention, simpler schema, faster worker coordination.

---

## Problem Statement

### Current Bottleneck

With 16 parallel workers processing archives, we observe 2.0 archives/sec (vs 5.3 expected = 62% throughput loss).

**Root cause**: PostgreSQL partition lock serialization

```
Worker 1: CREATE PARTITION inode_p_abc123  ← holds AccessExclusiveLock on inode parent
Worker 2: CREATE PARTITION inode_p_def456  ← BLOCKED waiting for Worker 1
Worker 3: COPY inode ...                   ← BLOCKED waiting for Worker 1
Worker 4: COPY inode ...                   ← BLOCKED waiting for Worker 1
...
Worker 16: COPY inode ...                  ← BLOCKED waiting for Worker 1
```

**Current state**:
- 123,993 existing partitions (one per medium)
- Every new medium requires `CREATE TABLE ... PARTITION OF inode` (AccessExclusiveLock)
- Lock blocks ALL operations on parent table until transaction commits
- Workers serialize instead of running in parallel

### Compounding Issues

1. **FOR UPDATE SKIP LOCKED complexity** - months of lock contention issues
2. **Partition-to-partition FK architecture** - difficult to maintain
3. **inode table as work queue** - PostgreSQL is a data store, not a queue
4. **Per-medium partitioning overhead** - 123,993+ partition planning overhead

---

## Current Architecture Analysis

### Tables

```sql
CREATE TABLE medium (
    medium_hash text PRIMARY KEY,
    ...
);

CREATE TABLE inode (
    medium_hash text,
    dev bigint,
    ino bigint,
    size bigint,
    mtime bigint,
    hash bytea,           -- computed at copy time
    copied boolean,
    claimed_by text,      -- work queue coordination
    ...
    PRIMARY KEY (medium_hash, dev, ino)
) PARTITION BY LIST (medium_hash);  -- 123,993 partitions!

CREATE TABLE path (
    medium_hash text,
    dev bigint,
    ino bigint,
    path bytea,
    ...
    FOREIGN KEY (medium_hash, dev, ino) REFERENCES inode
) PARTITION BY LIST (medium_hash);  -- 123,993 partitions!
```

### What inode table does:

1. **Hardlink deduplication** - N paths → 1 inode row → hash once
2. **Work queue** - `copied=false`, `claimed_by`, `FOR UPDATE SKIP LOCKED`
3. **Metadata storage** - size, mtime, fs_type

### Why partitioning was added:

- `TRUNCATE` partition for fast reload
- `DETACH/ATTACH` for maintenance
- Per-medium isolation

### Problems:

- **Lock contention** - CREATE PARTITION serializes all workers
- **Complexity** - work queue in PostgreSQL requires careful locking
- **Metadata misplacement** - size/mime_type are deterministic from hash, shouldn't be per-inode
- **Can't reload easily anyway** - TRUNCATE cascade issues, DETACH fails with FK constraints

---

## Proposed Architecture

### Core Insight

**PostgreSQL should store data. Redis should manage work queues.**

Content-addressed storage means: **identical hash → identical size/mime_type**.
Therefore: metadata belongs with the blob, not the path or inode.

### Schema

```sql
-- Content-addressed blob storage
CREATE TABLE blob (
    blobid      text PRIMARY KEY,     -- blake3 hash (hex string, unique content identifier)
    size        bigint NOT NULL,      -- deterministic from blobid
    mime_type   text,                 -- deterministic from blobid
    first_seen  timestamptz DEFAULT now()
);

-- Note: storage_path is deterministic from blobid, computed as:
-- {storage_root}/{blobid[0:2]}/{blobid[2:4]}/{blobid}

-- All paths (no partitioning)
CREATE TABLE path (
    medium_hash text REFERENCES medium(medium_hash),
    dev         bigint,
    ino         bigint,
    path        bytea,

    -- Per-instance metadata (varies across media):
    mtime       bigint,
    size        bigint,               -- needed before hash computed
    fs_type     char(1),              -- 'f', 'd', 'l'
    nlink       int,

    -- Link to deduplicated content (NULL until copied):
    blobid      text REFERENCES blob(blobid),

    -- Status (not work queue):
    copied      boolean DEFAULT false,

    exclude_reason text,
    PRIMARY KEY (medium_hash, dev, ino, path)
);

-- Indexes will be added later based on actual query patterns
```

**No inode table. No partitioning. No work queue columns.**

### Redis Work Queue

```
Queue: work:{medium_hash}
Items: JSON { medium_hash, dev, ino, path, size, mtime, fs_type }
```

---

## Workflows

### 1. Loading (ntt-loader)

```bash
#!/usr/bin/env bash
# ntt-loader (simplified)

MEDIUM_HASH=${1:?}
RAW_FILE=${2:?}

# Step 1: Load paths into PostgreSQL (pure data, no DDL)
psql "$DB_URL" -c "
    CREATE TEMP TABLE tmp_load (
        dev bigint, ino bigint, path bytea,
        mtime bigint, size bigint, fs_type char(1), nlink int
    );

    COPY tmp_load FROM STDIN;
" < "$RAW_FILE"

psql "$DB_URL" -c "
    INSERT INTO path (medium_hash, dev, ino, path, mtime, size, fs_type, nlink)
    SELECT '$MEDIUM_HASH', dev, ino, path, mtime, size, fs_type, nlink
    FROM tmp_load
    WHERE exclude_reason IS NULL;  -- apply filters
"

# Step 2: Enumerate unclaimed work → Redis queue
psql "$DB_URL" -t -A -F'|' -c "
    SELECT json_build_object(
        'medium_hash', medium_hash,
        'dev', dev,
        'ino', ino,
        'path', encode(path, 'base64'),
        'size', size,
        'mtime', mtime,
        'fs_type', fs_type
    )
    FROM path
    WHERE medium_hash = '$MEDIUM_HASH'
      AND copied = false
      AND exclude_reason IS NULL
      AND fs_type = 'f'  -- only regular files
" | while IFS= read -r json; do
    redis-cli RPUSH "work:$MEDIUM_HASH" "$json"
done

echo "Queued $(redis-cli LLEN work:$MEDIUM_HASH) items for $MEDIUM_HASH"
```

**No CREATE PARTITION. Just INSERT.**

### 2. Copying (ntt-copier)

```python
#!/usr/bin/env python3
import redis
import psycopg
import json
import hashlib

r = redis.Redis()
conn = psycopg.connect(DB_URL)

def worker(medium_hash, worker_id):
    while True:
        # Atomic pop from Redis queue
        work_json = r.lpop(f'work:{medium_hash}')
        if not work_json:
            break

        work = json.loads(work_json)

        # Check if this inode already hashed (hardlink handling)
        with conn.cursor() as cur:
            cur.execute("""
                SELECT hash FROM path
                WHERE medium_hash = %s AND ino = %s AND hash IS NOT NULL
                LIMIT 1
            """, (work['medium_hash'], work['ino']))

            existing = cur.fetchone()

            if existing:
                # Hardlink - reuse existing hash
                hash_val = existing['hash']
                logger.info(f"Hardlink reuse: ino={work['ino']}")
            else:
                # First path for this inode - compute hash
                hash_val = compute_hash_from_disk(work)

                # Store blob (idempotent - ON CONFLICT DO NOTHING)
                mime_type = detect_mime(work['path'])
                cur.execute("""
                    INSERT INTO blob (hash, size, mime_type)
                    VALUES (%s, %s, %s)
                    ON CONFLICT (hash) DO NOTHING
                """, (hash_val, work['size'], mime_type))

            # Copy to byhash storage if needed
            cur.execute("SELECT blobid FROM blob WHERE hash = %s", (hash_val,))
            blob = cur.fetchone()

            if not blob['blobid']:
                blobid = copy_to_byhash(work, hash_val)
                cur.execute("""
                    UPDATE blob SET blobid = %s WHERE hash = %s
                """, (blobid, hash_val))

            # Mark ALL paths for this inode as copied (handles hardlinks)
            cur.execute("""
                UPDATE path SET hash = %s, copied = true
                WHERE medium_hash = %s AND ino = %s
            """, (hash_val, work['medium_hash'], work['ino']))

            conn.commit()

if __name__ == '__main__':
    worker(sys.argv[1], sys.argv[2])
```

**No FOR UPDATE SKIP LOCKED. No claimed_by. No lock contention.**

### 3. Orchestration (ntt-copy-workers)

```bash
#!/usr/bin/env bash
# Launch 16 workers in parallel

MEDIUM_HASH=${1:?}
WORKERS=16

for i in $(seq 1 $WORKERS); do
    ntt-copier.py "$MEDIUM_HASH" "worker-$i" &
done

wait
echo "All workers complete"
```

**Workers coordinate via Redis LPOP (atomic, microseconds). No PostgreSQL locks.**

---

## Benefits

### Performance

✅ **Zero partition lock contention** - no CREATE PARTITION DDL
✅ **Fast worker coordination** - Redis LPOP vs PostgreSQL SELECT FOR UPDATE
✅ **16 workers truly parallel** - no serialization bottleneck
✅ **Simpler queries** - no partition pruning complexity

**Expected**: 5.3 archives/sec (62% improvement over current 2.0)

### Simplicity

✅ **No inode table** - one less table to understand
✅ **No partitioning** - 123,993 partitions → 0 partitions
✅ **No work queue in PostgreSQL** - claimed_by, claimed_at, FOR UPDATE SKIP LOCKED eliminated
✅ **Correct data modeling** - blob metadata stored once per hash (not per inode/path)

### Observability

✅ **Queue depth visible** - `redis-cli LLEN work:{medium}` shows remaining work
✅ **Worker progress** - count paths with `copied=true`
✅ **Cross-medium deduplication** - `SELECT COUNT(*) FROM path WHERE hash = ?` shows instances
✅ **Storage efficiency** - `SELECT SUM(size) FROM blob` = actual storage used

### Reliability

✅ **Simpler failure recovery** - re-enumerate `copied=false` paths to Redis
✅ **No deadlocks** - Redis queue is FIFO, no lock ordering issues
✅ **Idempotent operations** - blob INSERT ON CONFLICT, path UPDATE are safe to retry

---

## Migration Considerations

### Backward Compatibility

**This is a breaking schema change.** Requires:
1. Dump existing data
2. Create new schema
3. Migrate data
4. Update all scripts

### Migration Steps

```sql
-- 1. Create new tables
CREATE TABLE blob (...);
CREATE TABLE path_new (...);

-- 2. Migrate data
INSERT INTO blob (hash, size, mime_type, blobid)
SELECT DISTINCT hash, size, mime_type, copied_to
FROM inode
WHERE hash IS NOT NULL;

INSERT INTO path_new (medium_hash, dev, ino, path, mtime, size, fs_type, nlink, hash, copied)
SELECT p.medium_hash, p.dev, p.ino, p.path,
       i.mtime, i.size, i.fs_type, i.nlink,
       i.hash, i.copied
FROM path p
JOIN inode i ON (p.medium_hash, p.dev, p.ino) = (i.medium_hash, i.dev, i.ino);

-- 3. Rename
DROP TABLE path;
ALTER TABLE path_new RENAME TO path;

-- 4. Drop old table
DROP TABLE inode;
```

### Script Updates

- `ntt-loader` - remove partition creation, add Redis queueing
- `ntt-copier.py` - replace FOR UPDATE SKIP LOCKED with Redis LPOP
- `ntt-orchestrator` - simplified (no partition checks)

### Testing Plan

1. Test on small dataset first
2. Verify hardlink deduplication works
3. Verify cross-medium deduplication visible
4. Performance benchmark: compare 16 workers before/after
5. Test failure recovery (kill worker mid-batch)

---

## Open Questions

1. **Redis persistence**: Use RDB snapshots or AOF?
   - Lost queue items can be re-enumerated from `copied=false` paths

2. **Queue per-medium or global?**
   - Current proposal: `work:{medium_hash}` per medium
   - Alternative: single global queue (simpler but loses medium isolation)

3. **Hardlink edge case**: What if two workers process hardlinks concurrently?
   - Both compute hash, both INSERT blob (ON CONFLICT → one wins)
   - Both UPDATE paths (idempotent)
   - Wasteful but correct

4. **Should blob table track blobid per storage tier?**
   - Currently: single `blobid` column
   - Future: `blobid_fast`, `blobid_cold` for tiered storage?

---

## Next Steps

1. **Validate assumptions**:
   - Check actual partition lock wait times in production
   - Measure FOR UPDATE SKIP LOCKED overhead

2. **Prototype**:
   - Create test schema on small dataset
   - Benchmark Redis work queue vs FOR UPDATE SKIP LOCKED

3. **Document migration**:
   - Detailed migration script
   - Rollback plan

4. **Implement**:
   - Update ntt-loader
   - Rewrite ntt-copier.py
   - Update ntt-orchestrator

5. **Deploy**:
   - Test environment first
   - Measure throughput improvement
   - Production migration

---

## References

- PostgreSQL partitioning locks: https://www.postgresql.org/docs/current/ddl-partitioning.html
- Redis as work queue: https://redis.io/docs/data-types/lists/
- Content-addressed storage: https://en.wikipedia.org/wiki/Content-addressable_storage
- `docs/lessons/partition-migration-postmortem-2025-10-05.md` - Previous partition issues
