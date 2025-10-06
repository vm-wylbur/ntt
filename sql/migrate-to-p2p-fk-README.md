<!--
Author: PB and Claude
Date: Mon 06 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/sql/migrate-to-p2p-fk-README.md
-->

# Partition-to-Partition FK Migration Guide

## Overview

This directory contains SQL scripts to migrate from parent-level FK architecture to partition-to-partition FK architecture.

**Why this migration is necessary:**
- DELETE operations hang for 4+ minutes with current parent-level FK
- TRUNCATE CASCADE wipes all 18 partitions (data loss risk)
- DETACH/ATTACH workflow is impossible with parent-level FK
- Cross-partition FK scanning causes CPU-bound hangs

**Benefits after migration:**
- DELETE performance: 4min 41s → <1 second (100-1000x faster)
- TRUNCATE CASCADE: Safe (only affects partition pair)
- DETACH/ATTACH: Works correctly
- No cross-partition scanning

## Migration Steps

### Prerequisites

**Before starting:**
1. ✅ Database backup completed and tested
2. ✅ Path data restored from `path_old` (123.6M rows)
3. ✅ Maintenance window scheduled (10-15 minutes)

### Step 1: Add Partition-Level FKs (Instant)

```bash
sudo -u pball psql postgres:///copyjob -f sql/migrate-to-p2p-fk-step1-add-partition-fks.sql
```

**What it does:**
- Adds FK constraint to each path partition → matching inode partition
- Uses `NOT VALID` flag (instant, no data scan)
- Expected time: <5 seconds

**Output:**
```
[1/17] ✓ Added NOT VALID FK for partition: path_p_bb226d2a → inode_p_bb226d2a
[2/17] ✓ Added NOT VALID FK for partition: path_p_1d7c9dc8 → inode_p_1d7c9dc8
...
Successfully added 17 partition-level FK constraints
```

### Step 2: Validate FK Constraints (Background)

```bash
sudo -u pball psql postgres:///copyjob -f sql/migrate-to-p2p-fk-step2-validate.sql
```

**What it does:**
- Validates existing data satisfies FK constraints
- Scans data but does NOT block queries
- Expected time: ~8-15 minutes for all 17 partitions

**Output:**
```
[1/17] ✓ Validated FK for path_p_bb226d2a (11267245 rows) in 00:00:42
[2/17] ✓ Validated FK for path_p_1d7c9dc8 (8234567 rows) in 00:00:35
...
Successfully validated 17 partition-level FK constraints
✓ No FK violations found - all data is valid
```

**If validation fails:**
- Script will report orphaned rows
- Check data integrity before proceeding
- Consider rollback if major issues found

### Step 3: Drop Parent-Level FK (Instant)

```bash
sudo -u pball psql postgres:///copyjob -f sql/migrate-to-p2p-fk-step3-drop-parent-fk.sql
```

**What it does:**
- Removes old parent-level FK constraint
- Runs preflight check (ensures Step 2 completed)
- Expected time: <1 second

**Output:**
```
✓ Preflight check passed: All 17 partition-level FKs are VALID
Found parent-level FK constraint: path_medium_hash_ino_fkey
✓ Successfully dropped parent-level FK constraint
```

### Step 4: Verify Migration (Validation)

```bash
sudo -u pball psql postgres:///copyjob -f sql/migrate-to-p2p-fk-step4-verify.sql
```

**What it does:**
- Runs comprehensive checks on new architecture
- Tests DELETE performance
- Verifies data integrity
- Expected time: ~1 minute

**Output:**
```
[1/6] Checking partition-level FK constraints...
  total_partition_fks: 17
  validated_fks: 17
  not_validated_fks: 0
[2/6] Checking for parent-level FK...
  ✓ PASS: No parent-level FK found
[3/6] Verifying FK targets...
  ✓ PASS: All FK constraints reference matching partition pairs
[4/6] Testing DELETE performance...
  ✓ Deleted 10 rows in 00:00:00.023
  ✓ PASS: DELETE performance is fast
[5/6] Verifying data integrity...
  ✓ PASS: No orphaned rows found in 3 partitions checked
[6/6] Listing all partition-to-partition FK constraints...

✓✓✓ MIGRATION SUCCESSFUL ✓✓✓
```

## Emergency Rollback

**If migration fails, rollback to parent-level FK:**

```bash
sudo -u pball psql postgres:///copyjob -f sql/migrate-to-p2p-fk-rollback.sql
```

**What it does:**
- Drops all partition-level FK constraints
- Recreates parent-level FK constraint
- Expected time: ~2 minutes

**When to use:**
- Step 2 validation finds major data integrity issues
- Step 3 or 4 fail unexpectedly
- Need to abort migration and restore original state

## Timeline Summary

| Step | Time | Blocking | Can Rollback After |
|------|------|----------|-------------------|
| Step 1: Add FKs (NOT VALID) | <5s | No | ✅ Yes |
| Step 2: Validate FKs | 8-15min | No | ✅ Yes |
| Step 3: Drop parent FK | <1s | No | ✅ Yes |
| Step 4: Verify | ~1min | No | N/A (read-only) |
| **Total** | **~10-15min** | **Minimal** | - |

## Post-Migration Actions

### 1. Test DELETE Performance

```sql
-- Should complete in <1 second now
BEGIN;
DELETE FROM path_p_bb226d2a WHERE medium_hash = 'bb226d2ae226b3e048f486e38c55b3bd' LIMIT 1000;
ROLLBACK;
```

**Expected:** <1 second (vs 4+ minutes before)

### 2. Update ntt-loader

Current loader DELETE operations will now be fast:
```bash
# This should now complete in ~5.5 minutes (vs 10 minutes before)
./bin/ntt-loader /data/fast/raw/bb226d2ae226b3e048f486e38c55b3bd.raw bb226d2ae226b3e048f486e38c55b3bd
```

### 3. Document New Partition Provisioning

When creating new partitions, add P2P FK:

```sql
-- Create inode partition first
CREATE TABLE inode_p_XXXXXXXX PARTITION OF inode FOR VALUES IN ('XXXXXXXX...');

-- Create path partition
CREATE TABLE path_p_XXXXXXXX PARTITION OF path FOR VALUES IN ('XXXXXXXX...');

-- Add partition-level FK (NEW STEP)
ALTER TABLE path_p_XXXXXXXX
  ADD CONSTRAINT fk_path_to_inode_p_XXXXXXXX
  FOREIGN KEY (medium_hash, ino)
  REFERENCES inode_p_XXXXXXXX (medium_hash, ino)
  ON DELETE CASCADE;

-- Create FK index
CREATE INDEX CONCURRENTLY idx_path_p_XXXXXXXX_fk
  ON path_p_XXXXXXXX (medium_hash, ino);
```

## Monitoring

### Check Current FK Architecture

```sql
-- Should show partition-to-partition FKs
SELECT
    cl.relname as path_partition,
    c.conname as fk_constraint,
    cl2.relname as inode_partition
FROM pg_constraint c
JOIN pg_class cl ON cl.oid = c.conrelid
JOIN pg_class cl2 ON cl2.oid = c.confrelid
WHERE c.contype = 'f'
  AND cl.relname LIKE 'path_p_%'
ORDER BY cl.relname;
```

### Monitor DELETE Performance

```sql
-- Check recent DELETE operations
SELECT
    schemaname,
    relname,
    n_tup_del as total_deletes,
    n_tup_del::float / NULLIF(n_live_tup + n_dead_tup, 0) as delete_ratio,
    last_vacuum,
    last_autovacuum
FROM pg_stat_user_tables
WHERE relname LIKE '%_p_%'
  AND n_tup_del > 0
ORDER BY n_tup_del DESC;
```

## Files in This Directory

- `migrate-to-p2p-fk-step1-add-partition-fks.sql` - Add P2P FKs as NOT VALID
- `migrate-to-p2p-fk-step2-validate.sql` - Validate all P2P FKs
- `migrate-to-p2p-fk-step3-drop-parent-fk.sql` - Remove parent-level FK
- `migrate-to-p2p-fk-step4-verify.sql` - Verify new architecture
- `migrate-to-p2p-fk-rollback.sql` - Emergency rollback procedure
- `migrate-to-p2p-fk-README.md` - This file

## References

- PostgreSQL Documentation: https://www.postgresql.org/docs/current/ddl-partitioning.html
- Web-Claude Expert Analysis: `/home/pball/projects/ntt/docs/web-claude-p2p-fk-guide.md`
- Phase 2A Failure Analysis: `/home/pball/projects/ntt/docs/integrated-analysis-and-plan-2025-10-06.md`

## Support

If migration encounters issues:
1. Check Step 2 validation output for data integrity problems
2. Review Step 4 verification checks
3. Use rollback script if needed
4. Consult PostgreSQL logs: `/var/log/postgresql/`

---

**Migration Status:** Ready to execute after path restore completes

**Next Step:** Wait for path restore, then run Step 1
