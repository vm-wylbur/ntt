<!--
Author: PB and Claude
Date: 2025-11-16
License: (c) HRDAG, 2025, GPL-2 or newer

---
ntt/docs/schema-evolution.md
-->

# NTT Schema Evolution History

This document tracks the major schema changes in the NTT project.

---

## Current Schema (v2.0 - Nov 2025)

**Status:** ✅ Active in production
**Commit:** fa93b4c (loader refactor)
**Migration:** migrations/phase4-cutover.sql

### Tables

#### `medium` - Disk/archive metadata
- Primary key: `medium_hash`
- Tracks physical disks, extracted archives, carved images
- Health tracking: ok/incomplete/corrupt/failed

#### `paths` - Unpartitioned, denormalized file metadata
- **231M rows** in single table
- No foreign keys to other tables (denormalized)
- Columns: medium_hash, dev, ino, path, mtime, size, fs_type, nlink, blobid, copied, processed_at, broken, exclude_reason
- Indexes: medium_hash, (medium_hash, copied), (medium_hash, ino), (medium_hash, ino, path)

#### `blobs` - Content-addressed storage
- Primary key: `blobid` (BLAKE3 hash)
- ~9.3M unique content blobs
- Extraction tracking: status, mime_type, extracted_at

### Key Characteristics
- ✅ **No partitions** - Single `paths` table
- ✅ **No inode table** - Metadata denormalized into `paths`
- ✅ **No work queue in database** - Moved to Redis
- ✅ **Fast writes** - No partition lock contention

---

## Schema v1.5 (Oct 2025 - Partitioned with P2P FK)

**Status:** ❌ Deprecated (superseded by v2.0)
**Commit:** 30153f1
**Migration:** sql/partition-migration-*.sql (now in migrations/archive/)

### Tables
- `inode` - Partitioned by `medium_hash` (244,181 partitions)
- `path` - Partitioned by `medium_hash` (244,181 partitions)
- **Partition-to-partition FK:** `path_p_xxx` → `inode_p_xxx`

### Problems
- ❌ Lock contention on partition creation (AccessExclusiveLock on parent)
- ❌ Slow loader performance (DETACH/ATTACH cycles)
- ❌ 488,362 partition tables (catalog overhead)
- ❌ Poor query performance without partition pruning

### Why Eliminated
See: `docs/proposal-eliminate-partition-lock-contention.md`

**Key insight:** Partitioning existed solely to optimize loader TRUNCATE operations. The complexity cost outweighed benefits.

---

## Schema v1.0 (Original - Pre-Oct 2025)

**Status:** ❌ Deprecated
**Reference:** git history (pre-30153f1)

### Tables
- `inode` - Non-partitioned
- `path` - Non-partitioned
- **Parent-level FK:** `path` → `inode`

### Problems
- ❌ ON CONFLICT overhead during loader deduplication
- ❌ Full table scans for FK validation during partition ATTACH

### Migration to v1.5
**Reason:** Partitioning introduced to enable TRUNCATE-based reload without ON CONFLICT overhead.

**Result:** Created 488,362 partitions (Oct 2025).

---

## Migration Path

```
v1.0 (Non-partitioned)
  ↓
  │ Oct 2025: partition-migration-*.sql
  ↓
v1.5 (Partitioned with P2P FK) - 488,362 partitions
  ↓
  │ Nov 2025: eliminate-partitions-*.sql
  ↓
v2.0 (Unpartitioned, denormalized) - Current
```

---

## Lessons Learned

### From v1.0 → v1.5 Migration
**See:** `docs/lessons/partition-migration-postmortem-2025-10-05.md`

- ❌ DETACH/ATTACH fails with parent-level FK
- ❌ TRUNCATE CASCADE is dangerous with parent FK
- ✅ Partition-to-partition FK required for safe DETACH
- ⚠️  But this created new lock contention problems...

### From v1.5 → v2.0 Migration
**See:** `docs/lessons/lessons-learned-partition-drop-migration-2025-11-16.md`

- ✅ Rename strategy minimizes downtime (5-10 seconds)
- ✅ Background DROP avoids blocking operations
- ⚠️  Don't optimize prematurely - measure first
- **Key insight:** Solving the wrong problem (partitioning for performance) created worse problems (lock contention)

---

## Schema Files

### Active
- `sql/00-schema.sql` - **Current schema (v2.0)**
- `migrations/eliminate-partitions-*.sql` - v1.5 → v2.0 migration
- `migrations/phase4-cutover.sql` - Fast cutover script
- `migrations/phase4-cleanup.sql` - Partition cleanup

### Archived
- `migrations/archive/partition-migration-*.sql` - v1.0 → v1.5 migration
- `migrations/archive/migrate-to-p2p-fk-*.sql` - P2P FK setup

---

## Future Considerations

### What We Kept from Partitioning Era
- ✅ Loader DELETE-based reload (replaced TRUNCATE)
- ✅ Partition suffix concept (first 8 chars of medium_hash)
- ✅ Denormalized schema learnings

### What We Abandoned
- ❌ Per-medium partition creation
- ❌ DETACH/ATTACH pattern
- ❌ Partition-level FK constraints
- ❌ Work queue in PostgreSQL

### Current Trade-offs
- **Win:** No lock contention, simpler schema, faster queries
- **Cost:** DELETE-based reload slower than TRUNCATE (acceptable)
- **Monitoring:** Track paths table size growth (~231M rows currently)

---

## References

**Migration documentation:**
- `migrations/archive/README.md` - Archived migration guide
- `docs/db-migration-plan-eliminate-partitions.md` - v2.0 migration plan

**Lessons learned:**
- `docs/lessons/partition-migration-postmortem-2025-10-05.md` - v1.5 FK issues
- `docs/lessons/lessons-learned-partition-drop-migration-2025-11-16.md` - v2.0 migration

**Original proposals:**
- `docs/proposal-eliminate-partition-lock-contention.md` - Why we eliminated partitions
- `docs/completed/partition-migration-plan-2025-10-05.md` - v1.5 plan (archive reference)

**Current schema:**
- `sql/00-schema.sql` - Authoritative v2.0 schema definition
