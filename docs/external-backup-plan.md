<!--
Author: PB and Claude
Date: Sun 13 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer
-->

# NTT External Backup Plan

**Status:** Partially Implemented - In Production
**Created:** 2025-10-13
**Last Updated:** 2025-10-14
**Hardware:** External USB drive at `/dev/sdc`

## Implementation Status

**✅ Completed:**
- [x] Phase 1: External drive setup and mounted at `/mnt/ntt-backup`
- [x] Phase 2: Directory structure created (65,536 blob directories + pgdump/)
- [x] Phase 3: Blob count discrepancy investigated and resolved (backfill completed)
- [x] Phase 4: Schema changes applied (`external_copied`, `external_last_checked` columns added)
- [x] Tools built: `ntt-backup`, `ntt-backup-worker`, `ntt-backup-wrapper.sh`, `ntt-create-backup-dirs.sh`
- [x] Backup system actively running (worker currently copying blobs)

**⏸️ In Progress:**
- [ ] Phase 5: Initial backup run (currently in progress, ~152K files copied as of 2025-10-14)
- [ ] Database dumps running periodically via wrapper

**📋 Outstanding:**
- [ ] Phase 6: Schedule periodic backups via cron
- [ ] Production validation and monitoring setup
- [ ] Document actual performance metrics from initial backup

---

## Overview

Backup system to mirror NTT's deduplicated blob storage and database to an external USB drive for disaster recovery.

**Backup scope:**
1. PostgreSQL database (pg_dump)
2. Deduplicated file blobs (`/data/cold/by-hash/`)

**Key requirements:**
- Iterative, resumable backup process
- Progress tracking (files, bytes, rate, ETA)
- Integrity verification during copy
- Simple, maintainable implementation

---

## Current State

**Database:**
- Name: `copyjob`
- Size: 329 GB (after cleanup on 2025-10-13)
- Tables: Partitioned `path` and `inode` tables, plus `blobs`, `medium`, `queue_stats`

**Blob storage:**
- Location: `/data/cold/by-hash/`
- Structure: `{prefix1}/{prefix2}/{blobid}` where prefix1=chars 0-1, prefix2=chars 2-3
- Count: ~5.2M blobs in `blobs` table, ~6.1M in `inode` table (DISCREPANCY - under investigation)
- Size: ~4 TB estimated

---

## Architecture

### 1. Directory Structure

**Pre-created on external drive:**
```
/mnt/ntt-backup/
├── by-hash/
│   ├── 00/
│   │   ├── 00/
│   │   ├── 01/
│   │   └── ... (256 directories)
│   ├── 01/
│   └── ... (256 directories)
└── pgdump/
    └── copyjob-*.pgdump (timestamped dumps)
```

**Directory creation:**
- All 65,536 directories (`{00..ff}/{00..ff}`) created upfront
- One-time setup cost, eliminates mkdir overhead during backup
- Trivial disk space (~few MB for directory entries)

### 2. Database Schema Changes

**Add tracking columns to `blobs` table:**

```sql
ALTER TABLE blobs
  ADD COLUMN IF NOT EXISTS external_copied BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS external_last_checked TIMESTAMP WITH TIME ZONE;

-- Sparse index for finding uncompleted backups
CREATE INDEX IF NOT EXISTS idx_blobs_external_pending
  ON blobs(blobid)
  WHERE external_copied IS FALSE OR external_copied IS NULL;
```

**Column semantics:**
- `external_copied`: Boolean flag - has this blob been backed up?
- `external_last_checked`: Timestamp of last successful backup verification
- Separate from existing `last_checked` (used for internal integrity checks)

### 3. Backup Worker Design

**Tool:** `ntt-backup-worker` (Python script)

**Algorithm:**
```
1. Query database for blobs where external_copied IS FALSE/NULL
2. Process in batches (1000 blobs per transaction)
3. For each blob:
   a. Use rsync with --checksum for copy + verification
   b. Mark as copied in database on success
4. Log progress every 60 seconds:
   - Files copied (current session + total)
   - Bytes copied (GB)
   - Rate (files/min, MB/min)
   - Remaining blobs
   - ETA
5. Repeat until all blobs backed up
```

**Copy method: rsync vs cp**

Analysis:
- **cp --reflink=never**: Fast but no built-in verification, no resume on interruption
- **rsync -a --checksum**: Checksums during transfer, partial resume, idempotent ✓

**Decision: Use rsync per-file**
- Reliability: Built-in integrity verification with `--checksum`
- Resumable: Handles interruptions gracefully
- Idempotent: Safe to re-run (skips already-copied files if unchanged)
- Trade-off: Slight overhead for very small files, but worth it for 4TB of data

### 4. Progress Tracking

**Console output format:**
```
[2025-10-13T14:23:45-07:00] Progress: 125,432 files, 87.32 GB copied |
  Rate: 1,247 files/min, 142.3 MB/min | Remaining: 5,074,568 | ETA: 2.8d
```

**Metrics tracked:**
- Total blobs in database
- Blobs already backed up (from previous sessions)
- Blobs copied this session
- Total bytes transferred this session
- Files per minute rate
- MB per minute rate
- Estimated time to completion

### 5. Database Backup

**Command:**
```bash
pg_dump -d copyjob -F c -f /mnt/ntt-backup/pgdump/copyjob-$(date -Iseconds).pgdump
```

**Format:** Custom format (`-F c`) - compressed, allows selective restore

**Rotation:**
```bash
# Keep last 7 days of dumps
find /mnt/ntt-backup/pgdump -name "copyjob-*.pgdump" -mtime +7 -delete
```

---

## Implementation Plan

### Phase 1: Setup External Drive

```bash
# Mount external drive
EXTERNAL_DEV="/dev/sdc"
EXTERNAL_MOUNT="/mnt/ntt-backup"
mkdir -p "$EXTERNAL_MOUNT"
mount -o noatime,nodiratime "$EXTERNAL_DEV" "$EXTERNAL_MOUNT"

# Add to /etc/fstab for persistence (optional)
```

### Phase 2: Create Directory Structure

```bash
# Run once: bin/ntt-create-backup-dirs.sh
#!/bin/bash
BACKUP_ROOT="/mnt/ntt-backup/by-hash"
mkdir -p "$BACKUP_ROOT"

for prefix1 in {00..ff}; do
  for prefix2 in {00..ff}; do
    mkdir -p "$BACKUP_ROOT/$prefix1/$prefix2"
  done
done

mkdir -p /mnt/ntt-backup/pgdump
echo "Directory structure created: 65,536 blob directories + pgdump/"
```

### Phase 3: Backfill Missing Blobs

**Critical:** 1,053,484 blobs exist in by-hash but are missing from `blobs` table.

```bash
psql copyjob -f sql/backfill-missing-blobs.sql
```

**SQL:**
```sql
-- sql/backfill-missing-blobs.sql
INSERT INTO blobs (blobid, n_hardlinks)
SELECT DISTINCT i.blobid, 0 as n_hardlinks
FROM inode i
LEFT JOIN blobs b ON i.blobid = b.blobid
WHERE i.blobid IS NOT NULL
  AND b.blobid IS NULL
ON CONFLICT (blobid) DO NOTHING;
```

**Expected result:** 1,053,484 rows inserted

### Phase 4: Apply Schema Changes

```bash
psql copyjob -f sql/add-external-backup-columns.sql
```

### Phase 5: Run Initial Backup

```bash
# Start backup (includes pg_dump + blob backup)
bin/ntt-backup

# Can be interrupted with Ctrl+C - will resume on next run

# For testing without pg_dump
bin/ntt-backup --skip-pgdump

# Custom batch size
bin/ntt-backup --batch-size 5000
```

**Features:**
- PID-based locking (only one instance can run)
- Validates backup drive is mounted and writable
- Runs pg_dump before blob backup
- Structured JSON logging to `/var/log/ntt/backup.jsonl`
- Human-readable console output with loguru
- Resumable on interruption

### Phase 6: Schedule Periodic Backups

```bash
# Cron job (daily at 2 AM)
# Use wrapper for mount validation and auto-recovery
0 2 * * * /home/pball/projects/ntt/bin/ntt-backup-wrapper.sh >> /var/log/ntt/backup-cron.log 2>&1
```

**Wrapper features:**
- Validates backup drive is mounted and accessible
- Auto-remounts if drive is in error state
- Retries up to 3 times on failure
- Passes through all arguments to `ntt-backup`

**Manual usage:**
```bash
# Direct (no retry/remount)
bin/ntt-backup

# With wrapper (recommended for production)
bin/ntt-backup-wrapper.sh

# Pass arguments through wrapper
bin/ntt-backup-wrapper.sh --skip-pgdump --batch-size 5000
```

---

## Safety & Recovery

### Safety Measures

1. **Idempotent operations**: Safe to re-run worker at any time
2. **Atomic updates**: Both `external_copied` and `external_last_checked` updated together
3. **Verification built-in**: rsync `--checksum` ensures copy integrity
4. **No deletions**: Worker only adds files, never removes
5. **Source is read-only**: Backup never modifies `/data/cold/by-hash/`

### Recovery Procedure

**To restore from backup:**

1. Restore database:
```bash
pg_restore -d copyjob /mnt/ntt-backup/pgdump/copyjob-YYYY-MM-DDTHH:MM:SS.pgdump
```

2. Restore blob storage:
```bash
rsync -av --checksum /mnt/ntt-backup/by-hash/ /data/cold/by-hash/
```

### Monitoring & Alerts

- Worker logs to `/var/log/ntt/backup.jsonl`
- Monitor disk space on external drive
- Alert on worker failures (missing source files, write errors)
- Periodic integrity checks (compare checksums)

---

## Performance Estimates

**Assumptions:**
- 6M blobs to backup
- 4 TB total size
- Average file size: ~700 KB
- USB 3.0 drive: ~100 MB/s write speed (real-world)

**Estimates:**
- Time to complete initial backup: ~11-12 hours
- Incremental backups: Minutes (only new blobs since last run)
- Database dump: ~5-10 minutes (329 GB compressed)

---

## Blob Count Discrepancy - RESOLVED

### Issue discovered 2025-10-13

**Initial findings:**
- `blobs` table: 5,199,107 rows
- `inode` table (unique blobids): 6,143,636 rows
- **Discrepancy: 1,053,484 blobs (17.1%)**

**Investigation results (2025-10-13):**
1. ✓ **All 1,053,484 "missing" blobs exist as files in `/data/cold/by-hash/`**
2. ✓ Files were successfully copied but `blobs` table wasn't updated
3. ✓ Root cause: `blobs` table populated by ntt-copier (bin/ntt-copier.py:1681) during copy operations
4. ✓ These files were copied but database insert failed/skipped for unknown reason

**Resolution:** Backfill `blobs` table before starting backup (see Phase 3 below)

---

## Future Enhancements

1. **Parallel copying**: Use multiple rsync workers for faster backup
2. **Incremental verification**: Periodically re-check old backups (30-day cycle)
3. **Compression**: Use zstd compression on external drive (if space-constrained)
4. **Deduplication**: Use btrfs/zfs on backup drive for additional space savings
5. **Remote backup**: Extend to support off-site backup locations
6. **Metrics dashboard**: Web UI for monitoring backup progress

---

## References

- Database cleanup: Reclaimed 227 GB on 2025-10-13 (tmp tables, old tables, analysis tables)
- Original pipeline: docs/NTT-pipeline-stages.md (if exists)
- Blob integrity: docs/lessons/lessons-learned-verifying-byhash-integrity-2025-10-04.md
