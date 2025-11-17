<!--
Author: PB and Claude
Date: 2025-11-16
License: (c) HRDAG, 2025, GPL-2 or newer

---
ntt/migrations/archive/README.md
-->

# Archived Migration Scripts

These migration scripts represent **completed historical migrations** and are kept for reference only.

## DO NOT EXECUTE

These scripts reference database states that no longer exist and **will fail** if run against the current database.

---

## Migration Timeline

### Phase 1: Partition-to-Partition FK Migration (Oct 2025)
**Commit:** 30153f1
**Purpose:** Migrated from parent-level FK to partition-level FK
**Status:** ✅ Completed, then superseded by Phase 2

**Files:**
- `migrate-to-p2p-fk-*.sql` (5 files) - P2P FK setup and validation
- `partition-migration-*.sql` (7 files) - Partition creation and data migration

**Result:** Created partitioned `inode` and `path` tables with 244,181 partitions each.

---

### Phase 2: Partition Elimination (Nov 2025)
**Commits:** See `migrations/eliminate-partitions-*.sql`
**Purpose:** Eliminated 488,362 partition tables, migrated to unpartitioned schema
**Status:** ✅ Completed

**Active migration files** (still in `migrations/`):
- `eliminate-partitions-phase1-schema.sql`
- `eliminate-partitions-phase2-migrate-data.sql`
- `eliminate-partitions-phase3-add-indexes.sql`
- `eliminate-partitions-phase3-verification.sql`
- `eliminate-partitions-rollback.sql`
- `phase4-cutover.sql`
- `phase4-cleanup.sql`

**Result:** Current schema with unpartitioned `paths` and `blobs` tables.

---

## Current Schema

See: `sql/00-schema.sql` (v2.0, Nov 2025)

**Tables:**
- `medium` - Disk/archive metadata
- `paths` - Unpartitioned, denormalized file metadata
- `blobs` - Content-addressed storage

**No partitions** - All partition tables dropped successfully.

---

## References

- **Schema evolution:** `docs/schema-evolution.md`
- **Partition drop lessons:** `docs/lessons/lessons-learned-partition-drop-migration-2025-11-16.md`
- **P2P FK postmortem:** `docs/lessons/partition-migration-postmortem-2025-10-05.md`
- **Original proposal:** `docs/proposal-eliminate-partition-lock-contention.md`
