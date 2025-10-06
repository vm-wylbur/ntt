<!--
Author: PB and Claude
Date: Sun 05 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/partition-migration-postmortem-2025-10-05.md
-->

# Partition Migration Postmortem - 2025-10-05

## What We Accomplished

**✓ Completed:**
1. Successfully migrated 123.6M paths and 36.3M inodes to partitioned tables
2. Created 17 partitions (one per medium)
3. Executed atomic cutover - partitioned tables now active
4. Verified all data copied correctly

**Migration timeline:**
- Steps 1-2: <5 minutes (create tables and partitions)
- Step 3: ~90 minutes (batched data copy)
- Step 4: <1 second (add triggers)
- Step 5: ~5 seconds (atomic cutover)

## Critical Issue Discovered

### Problem: ON CONFLICT doesn't benefit from partition pruning

**What we expected:**
- INSERT into bb22 partition with ON CONFLICT checks only bb22 partition (empty)
- Fast bulk insert with zero conflict overhead

**What actually happened:**
- ON CONFLICT checks ALL 17 partitions (36M inodes, 123M paths)
- bb22 load hung for 6+ minutes on inode INSERT (same as before partitioning)
- Zero performance improvement

### Root Cause

PostgreSQL has a known limitation: **ON CONFLICT on partitioned tables scans all partitions**, not just the target partition. This is documented behavior.

From testing:
```sql
-- Single row insert with ON CONFLICT into bb22 partition
INSERT INTO inode (...) VALUES (...) ON CONFLICT DO NOTHING;
-- Timed out after 2 minutes (scanning all 36M inodes across all partitions)
```

### Why This Wasn't Caught Earlier

1. **Profiling focused on SELECT queries** - investigation doc only measured SELECT performance, not INSERT with ON CONFLICT
2. **Assumed partition pruning applied to all operations** - it doesn't for ON CONFLICT
3. **Test would have caught this** - but we skipped the pre-cutover test

## Solutions to Explore Tomorrow

### Option 1: Remove ON CONFLICT for New Media (Recommended)

Modify loader to detect if medium is new and skip ON CONFLICT:

```sql
-- Check if partition is empty
SELECT count(*) FROM inode WHERE medium_hash = '$MEDIUM_HASH';

-- If count = 0, use simple INSERT (no ON CONFLICT)
INSERT INTO inode (medium_hash, dev, ino, nlink, size, mtime)
SELECT DISTINCT ON (medium_hash, ino) ...;

-- If count > 0, use ON CONFLICT (for re-loads/corrections)
INSERT INTO inode (...) ON CONFLICT DO NOTHING;
```

**Pros:**
- Zero overhead for new media (the common case)
- Partitioning still helps: isolated data, easier maintenance
- Handles re-loads correctly (uses ON CONFLICT when needed)

**Cons:**
- Adds conditional logic to loader
- Two code paths to maintain

### Option 2: Use COPY Instead of INSERT

PostgreSQL COPY is faster than INSERT and doesn't have ON CONFLICT overhead:

```sql
-- Pre-dedupe in temp table, then COPY directly to partition
COPY inode_p_bb226d2a FROM STDIN;
```

**Pros:**
- Fastest possible bulk load
- No ON CONFLICT overhead

**Cons:**
- Can't handle duplicates (must pre-dedupe perfectly)
- More complex error handling

### Option 3: Rollback Partitioning (Not Recommended)

Revert to non-partitioned tables with simpler PRIMARY KEY:

```sql
-- Change path PK from (medium_hash, ino, path) to (medium_hash, path)
-- Reduces index size, might help ON CONFLICT performance
```

**Pros:**
- Simpler architecture
- Proven to work (already in production)

**Cons:**
- Still has 123M path ON CONFLICT problem
- Loses partition benefits (isolation, maintenance)

## Recommended Next Steps

1. **Test Option 1 tomorrow** - Modify loader to skip ON CONFLICT for empty partitions
2. **Keep partitioned tables** - Don't rollback, data migration already done
3. **Document the ON CONFLICT limitation** - Update loader comments

## Current State

**Production schema:**
- `inode` and `path` are partitioned tables (17 partitions)
- `inode_old` and `path_old` available for rollback
- Loader is partition-aware but still uses ON CONFLICT (slow)

**bb22 status:**
- Medium record exists
- 1,000 inodes loaded (from previous attempt)
- 0 paths loaded
- Partition `inode_p_bb226d2a` and `path_p_bb226d2a` exist

**No damage done:**
- Can safely retry bb22 load tomorrow
- All other media data intact
- Rollback still possible

## Lessons Learned

1. **Always test with production workload** - Synthetic tests miss real bottlenecks
2. **Profile the full operation** - Not just SELECT queries, but INSERT with all clauses
3. **Research known limitations** - PostgreSQL docs mention ON CONFLICT + partitioning issues
4. **Pre-cutover testing has value** - Would have caught this before migration

## References

- PostgreSQL docs: Partitioning and constraints don't use partition pruning for ON CONFLICT
- Investigation: `docs/loader-optimization-investigation-2025-10-05.md`
- Migration plan: `docs/partition-migration-plan-2025-10-05.md`
