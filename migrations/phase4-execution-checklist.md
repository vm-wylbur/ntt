<!--
Author: PB and Claude
Date: Sat 16 Nov 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/migrations/phase4-execution-checklist.md
-->

# Phase 4 Cutover Execution Checklist

## Pre-Cutover Preparation

### 1. Verify Prerequisites
```bash
# Check data counts
psql -d copyjob -c "SELECT 'paths_provisional', COUNT(*) FROM paths_provisional;"
# Expected: 231,628,765

psql -d copyjob -c "SELECT 'blobs_provisional', COUNT(*) FROM blobs_provisional;"
# Expected: 9,310,725

# Verify provisional tables have correct structure
psql -d copyjob -c "\d paths_provisional"
psql -d copyjob -c "\d blobs_provisional"
```

### 2. Create Backup
```bash
# Full database backup (recommended)
pg_dump -d copyjob -Fc -f /backup/copyjob-pre-cutover-$(date +%Y%m%d-%H%M%S).pgdump

# Or at minimum, backup just the tables being renamed
pg_dump -d copyjob -Fc -t path -t inode -t paths_provisional -t blobs_provisional \
    -f /backup/copyjob-cutover-tables-$(date +%Y%m%d-%H%M%S).pgdump
```

### 3. Stop All Workers
```bash
# Stop ntt-copier workers
# (command depends on how workers are managed - systemd, supervisor, etc.)

# Stop ntt-orchestrator
# (command depends on deployment)

# Stop ntt-loader
# (command depends on deployment)

# Verify no workers are running
ps aux | grep ntt-copier
ps aux | grep ntt-orchestrator
ps aux | grep ntt-loader

# Verify no active connections to old tables
psql -d copyjob -c "SELECT pid, usename, application_name, state, query
FROM pg_stat_activity
WHERE query LIKE '%path%' OR query LIKE '%inode%'
  AND state = 'active'
  AND pid != pg_backend_pid();"
```

---

## Cutover Execution

### 4. Run Cutover Script
```bash
# Run the fast cutover (5-10 seconds)
psql -d copyjob -f migrations/phase4-cutover.sql
```

**Expected output:**
```
PHASE 4: FAST CUTOVER TO UNPARTITIONED SCHEMA
...
✓ path → path_old_to_drop
✓ inode → inode_old_to_drop
✓ paths_provisional → paths
✓ blobs_provisional → blobs
CUTOVER COMPLETE
```

**If errors occur:**
See "Rollback Procedure" below.

---

## Post-Cutover Verification

### 5. Verify Cutover Success
```bash
# Check new tables exist
psql -d copyjob -c "\dt paths"
psql -d copyjob -c "\dt blobs"

# Verify row counts
psql -d copyjob -c "SELECT 'paths', COUNT(*) FROM paths;"
# Expected: 231,628,765

psql -d copyjob -c "SELECT 'blobs', COUNT(*) FROM blobs;"
# Expected: 9,310,725

# Verify no partitions on new tables
psql -d copyjob -c "SELECT COUNT(*) FROM pg_inherits WHERE inhparent IN (
    SELECT oid FROM pg_class WHERE relname IN ('paths', 'blobs')
);"
# Expected: 0

# Check old tables exist for cleanup
psql -d copyjob -c "\dt path_old_to_drop"
psql -d copyjob -c "\dt inode_old_to_drop"
```

### 6. Update Application Code
**Before restarting workers, update code to reference new table names:**

Old references:
- `path` table → update to `paths`
- `inode` table → update to `inode` (still exists in denormalized `paths` table)

Specifically check:
- SQL queries in ntt-copier.py
- ntt-loader SQL statements
- ntt-orchestrator database interactions
- Any ad-hoc scripts or queries

### 7. Restart Workers
```bash
# Start workers one at a time, verify each starts correctly

# Start ntt-loader (if used)
# (command depends on deployment)

# Start one ntt-copier worker
# (command depends on deployment)

# Verify it's working correctly
# Check logs, verify it's processing data

# Start remaining ntt-copier workers
# (scale up gradually)

# Start ntt-orchestrator
# (command depends on deployment)
```

### 8. Monitor Application
```bash
# Watch for errors in logs
tail -f /path/to/ntt-copier.log
tail -f /path/to/ntt-orchestrator.log

# Monitor database activity
psql -d copyjob -c "SELECT COUNT(*) FROM paths WHERE copied = false;"

# Check for errors
psql -d copyjob -c "SELECT error_type, COUNT(*) FROM paths
WHERE error_type IS NOT NULL GROUP BY error_type;"
```

---

## Background Cleanup (After Verification)

### 9. Schedule Cleanup (1-2 hours, run separately)

**Only proceed after:**
- [x] Cutover completed successfully
- [x] Application running on new tables
- [x] Application verified working correctly
- [x] At least 24 hours of successful operation (recommended)

```bash
# Run in screen or tmux (will take 1-2 hours)
screen -S partition-cleanup

# Inside screen session:
psql -d copyjob -f migrations/phase4-cleanup.sql

# Detach from screen: Ctrl+A, D
# Reattach later: screen -r partition-cleanup
```

**Expected cleanup time:**
- path_old_to_drop: ~1 hour (244,182 partitions)
- inode_old_to_drop: ~30-60 minutes (244,182 partitions)

---

## Rollback Procedure

**If cutover fails or problems discovered:**

### Immediate Rollback (within minutes of cutover)
```sql
BEGIN;

-- Rename new tables back to provisional
ALTER TABLE paths RENAME TO paths_provisional;
ALTER TABLE blobs RENAME TO blobs_provisional;

-- Rename old tables back to production
ALTER TABLE path_old_to_drop RENAME TO path;
ALTER TABLE inode_old_to_drop RENAME TO inode;

COMMIT;

-- Update statistics
ANALYZE path;
ANALYZE inode;
```

### Rollback After Cleanup Started
If cleanup script has already started dropping partitions:
1. **DO NOT CANCEL** the DROP operations (will leave database inconsistent)
2. Let cleanup complete
3. Restore from backup:
   ```bash
   # Stop all workers first
   pg_restore -d copyjob /backup/copyjob-pre-cutover-TIMESTAMP.pgdump
   ```

---

## Success Criteria

Cutover is successful when:
- [x] New tables exist: `paths`, `blobs`
- [x] Row counts match: 231,628,765 paths, 9,310,725 blobs
- [x] No partitions on new tables
- [x] Application code updated
- [x] Workers restarted and processing data
- [x] No errors in application logs
- [x] Data integrity checks pass

---

## Timeline

**Cutover window:** 5-10 seconds
- Stop workers: ~1 minute
- Run cutover script: 5-10 seconds
- Verify: ~2 minutes
- Update code & restart: ~5-10 minutes
- **Total downtime: ~10-15 minutes**

**Background cleanup:** 1-2 hours (no downtime, run separately)

---

## Contacts & Escalation

If issues occur:
1. Check error messages in script output
2. Check PostgreSQL logs: `/var/log/postgresql/`
3. Consult lessons-learned: `docs/lessons/lessons-learned-partition-drop-migration-2025-11-16.md`
4. If needed, execute rollback procedure immediately

---

## Post-Migration Tasks

After successful cleanup:
- [ ] Update documentation to reflect new schema (paths, blobs)
- [ ] Remove old migration scripts if no longer needed
- [ ] Update database diagram/schema docs
- [ ] Document new table structures
- [ ] Archive backup files after retention period
- [ ] Update monitoring/alerting for new table names

---

## Notes

- New schema uses **plural table names** (`paths`, `blobs`) vs old singular (`path`, `inode`)
- `paths` table is **denormalized** - combines data from old `path` and `inode` tables
- No separate `inode` table in new schema - data merged into `paths`
- Old tables remain as `*_old_to_drop` until cleanup completes
- Cleanup can be run anytime - no rush, no user impact
