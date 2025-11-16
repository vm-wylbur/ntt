<!--
Author: PB and Claude
Date: Tue 12 Nov 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
tapes/vxa/INGESTION-PLAN.md
-->

# VXA Tape Ingestion Plan

**Created:** 2025-11-12
**Total Extracted:** 123GB across 7 tapes
**Estimated Ingestion:** ~92GB (25% reduction)

## Tape Hashes (Generated 2025-11-16)

**Method:** BLAKE3 hash of signature (first 1MB + last 1MB of tape_dump.img)

```
Tape 1: fb1bb1c0bf7387a90748f8349525cad2
Tape 2: ed01d9c48595043531f9dbe884f57f12
Tape 3: f754fa2cfd395c7979fb3c7dff2e22db
Tape 4: edd8a77ebb6eb6ef0824678fafc04442
Tape 5: 4476ee6ad7a57f68020cc2c9efb3bee9
Tape 6: 01a3f38e6a213e758ac51b71865aecf9
Tape 7: 48ed479912fb7ae4570f7e4a5b5c6df9
```

**Note:** These hashes follow NTT's standard pattern for physical media (same as ntt-orchestrator `identify_image()`)

## Priority Assessment

### HIGH PRIORITY (rsync/archive - GOLD content)
- **Tapes 5-7:** rsync and archive directories contain critical backup data
- **Tape 2-4:** rsync/guate contains Guatemala project backups (13-14GB each)
- **Tape 1,3:** rsync/guate (smaller, 3-6GB)
- **Tape 3:** archive/pball (6.7GB personal archives)

### MEDIUM PRIORITY
- Postgres database dumps and SQL files
- User home directories (pball, gserver1, gt-*)
- CVS repositories

### LOWER PRIORITY
- Web content (var/www/html)
- Backup listings (var/local/backup)
- Root home directory

---

## Inclusion Patterns by Tape

### Tape 1 (12GB → 3.4GB)
- `/rsync/*` (3.3GB)
- `/root/*` (1.7MB)
- `/home/pball/*` (11MB)
- `/home/mnc/chad-dump-20031113` (20MB file)
- `/var/www/html/*` (7.3MB)
- `/var/local/backup/*` (3.7MB)
- `/var/rafe/cvsroot/*` (957KB)

### Tape 2 (21GB → 14.1GB)
- `/rsync/*` (14GB) **GOLD**
- `/root/*` (14MB)
- `/home/pball/*` (11MB)
- `/home/gt-avancso/*` (27KB)
- `/home/gt-mack/*` (27KB)
- `/home/gserver1/*` (1.9MB)
- `/home/mnc/chad-dump-20031113` (20MB file)
- `/home/rafe/database-mar14.tar.gz` (15MB file) **POSTGRES**
- `/home/rafe/analyzer-database.sql` (file) **POSTGRES**
- `/home/rafe/exhibitionists-db-src/*` **POSTGRES**
- `/var/www/html/*` (7.3MB)
- `/var/local/backup/*` (9.9MB)
- `/var/lib/pgsql/*` (2KB)
- `/var/rafe/cvsroot/*` (953KB)

### Tape 3 (19GB → 12.5GB)
- `/rsync/*` (5.8GB) **GOLD**
- `/archive/*` (6.7GB) **GOLD - personal archives**
- `/root/*` (1.7MB)
- `/home/pball/*` (11MB)
- `/home/gserver1/*` (1.9MB)
- `/home/mnc/chad-dump-20031113` (20MB file)
- `/var/www/html/*` (7.3MB)
- `/var/local/backup/*` (5.1MB)
- `/var/lib/pgsql/*` (2KB)
- `/var/rafe/cvsroot/*` (957KB)

### Tape 4 (19GB → 13.1GB)
- `/rsync/*` (13GB) **GOLD**
- `/root/*` (1.7MB)
- `/home/pball/*` (38MB)
- `/home/gt-avancso/*` (27KB)
- `/home/gt-mack/*` (27KB)
- `/home/gserver1/*` (1.9MB)
- `/home/mnc/chad-dump-20031113` (20MB file)
- `/home/rafe/analyzer-database.sql` (59MB file) **POSTGRES - LARGE**
- `/home/rafe/exhibitionists-db-src/*` **POSTGRES**
- `/var/www/html/*` (7.3MB)
- `/var/local/backup/*` (6.5MB)
- `/var/lib/pgsql/*` (2KB)
- `/var/rafe/cvsroot/*` (953KB)

### Tape 5 (18GB → 18GB)
- `/rsync/hrdag/*` (15GB) **GOLD**
- `/archive/pball/*` (3.1GB) **GOLD**

### Tape 6 (20GB → 20GB)
- `/rsync/hrdag/*` (16GB) **GOLD**
- `/archive/pball/*` (4.0GB) **GOLD**

### Tape 7 (14GB → 14GB)
- `/archive/pball/*` (14GB) **GOLD**
- `/archive/demog260/*` (7.9MB)

---

## Ingestion Strategy: Symlink Filtered Tree (SELECTED)

**Approach:** Create symlink tree with only included paths at `/data/fast/tapes/vxa/for-ingestion/`

**Structure:**
```
/data/fast/tapes/vxa/for-ingestion/
├── vxa-tape1/
│   ├── rsync -> /data/fast/tapes/vxa/tape1/extracted/rsync
│   ├── root -> /data/fast/tapes/vxa/tape1/extracted/root
│   ├── home/
│   │   ├── pball -> /data/fast/tapes/vxa/tape1/extracted/home/pball
│   │   └── mnc/
│   │       └── chad-dump-20031113 -> /data/fast/tapes/vxa/tape1/extracted/home/mnc/chad-dump-20031113
│   └── var/
│       ├── www/
│       │   └── html -> /data/fast/tapes/vxa/tape1/extracted/var/www/html
│       ├── local/
│       │   └── backup -> /data/fast/tapes/vxa/tape1/extracted/var/local/backup
│       └── rafe/
│           └── cvsroot -> /data/fast/tapes/vxa/tape1/extracted/var/rafe/cvsroot
├── vxa-tape2/
│   └── ... (similar structure with tape2 paths)
...
└── vxa-tape7/
    └── ... (similar structure with tape7 paths)
```

**Benefits:**
- No data duplication (saves 92GB)
- Clear review structure before ingestion
- Flexible - can adjust links without moving data
- NTT copier treats symlinks transparently

**Implementation:**
- Script creates parent directories as needed
- Symlinks point to actual extracted content
- Preserves tape identity via `vxa-tape{1..7}/` prefix

---

## NTT Integration Notes

**Database Schema:** Unpartitioned (post-migration, Nov 2025)
- Single `paths` table (denormalized, includes inode metadata)
- Single `blobs` table
- No partition management needed

**Medium Type:** Use `medium_type='carved'` (similar to PhotoRec workflow)

**Path Format:** Preserve tape identity via top-level directory:
- `vxa-tape1/rsync/guate/guatemala/...`
- `vxa-tape2/home/pball/...`
- `vxa-tape7/archive/pball/...`

**Symlink Root for NTT:** `/data/fast/tapes/vxa/for-ingestion/`

**Deduplication:**
- Expect high dedup between tapes 1-4 (same server, 2 months apart)
- Tapes 5-7 may have unique content (different backup sets)

**Database Integration:**

Create medium records for each tape (7 total):
```sql
INSERT INTO medium (medium_hash, medium_human, medium_type, image_path, extraction_method, extracted_at)
VALUES
  ('fb1bb1c0bf7387a90748f8349525cad2', 'VXA Tape 1 (2003 backup)', 'physical', '/data/fast/tapes/vxa/tape1/tape_dump.img', 'tar', '2025-11-12'),
  ('ed01d9c48595043531f9dbe884f57f12', 'VXA Tape 2 (2003 backup)', 'physical', '/data/fast/tapes/vxa/tape2/tape_dump.img', 'tar', '2025-11-12'),
  ('f754fa2cfd395c7979fb3c7dff2e22db', 'VXA Tape 3 (2003 backup)', 'physical', '/data/fast/tapes/vxa/tape3/tape_dump.img', 'tar', '2025-11-12'),
  ('edd8a77ebb6eb6ef0824678fafc04442', 'VXA Tape 4 (2003 backup)', 'physical', '/data/fast/tapes/vxa/tape4/tape_dump.img', 'tar', '2025-11-12'),
  ('4476ee6ad7a57f68020cc2c9efb3bee9', 'VXA Tape 5 (HRDAG backup)', 'physical', '/data/fast/tapes/vxa/tape5/tape_dump.img', 'tar', '2025-11-12'),
  ('01a3f38e6a213e758ac51b71865aecf9', 'VXA Tape 6 (HRDAG backup)', 'physical', '/data/fast/tapes/vxa/tape6/tape_dump.img', 'tar', '2025-11-12'),
  ('48ed479912fb7ae4570f7e4a5b5c6df9', 'VXA Tape 7 (archive)', 'physical', '/data/fast/tapes/vxa/tape7/tape_dump.img', 'tar', '2025-11-12');
```

**Enumeration Workflow:**

**Tested:** 2025-11-16 with Tape 1 - enumeration successful ✅

**Step 1: Create symlink for ntt-copier access**
```bash
sudo ln -sfn /data/fast/tapes/vxa/tape1/extracted /mnt/ntt/fb1bb1c0bf7387a90748f8349525cad2
```
Note: ntt-copier uses symlink at `/mnt/ntt/{hash}` to access files

**Step 2: Enumerate from actual directory (not symlink)**
```bash
sudo ntt-enum /data/fast/tapes/vxa/tape1/extracted \
              fb1bb1c0bf7387a90748f8349525cad2 \
              /data/fast/enum/fb1bb1c0bf7387a90748f8349525cad2.raw
```

**Key finding:** Must enumerate from actual directory, not symlink mount point.
- ❌ Enumerating `/mnt/ntt/{hash}` only gets 1 record (the symlink itself)
- ✅ Enumerating `/data/fast/tapes/vxa/tape1/extracted` gets all 348,739 files

**Path format in database:** Absolute paths from enumeration source
```
/data/fast/tapes/vxa/tape1/extracted/root/.bash_history
/data/fast/tapes/vxa/tape1/extracted/rsync/guate/...
```

**Step 3: Load enumeration (NEEDS REFACTORING)**
```bash
ntt-loader fb1bb1c0bf7387a90748f8349525cad2  # TODO: rewrite for unpartitioned schema
```

**ntt-loader** must be rewritten to:
- Insert into single `paths` table (not partitioned `path` + `inode`)
- Remove partition creation logic (`CREATE TABLE ... PARTITION OF`)
- Remove partition safety checks and TRUNCATE operations
- Map enumeration fields to denormalized `paths` columns

**Step 4: Copy files (NEEDS REFACTORING)**
```bash
ntt-copier fb1bb1c0bf7387a90748f8349525cad2  # TODO: rewrite for paths table
```

**ntt-copier.py** must be rewritten to:
- Query `paths` table instead of `inode` table
- Update `paths` columns directly (no separate `inode` record)
- Replace all `inode.id`, `inode.copied`, `inode.claimed_by` references
- Use `paths` table's denormalized structure (has dev, ino, size, mtime, etc.)
- Access files via symlink at `/mnt/ntt/{hash}` (already handles symlinks correctly)

**Expected Results** (after tooling updated):
- ~92GB of unique content after deduplication
- All paths inserted into single `paths` table
- High dedup rate between tapes 1-4 (same source server)
- Blobs shared across tapes automatically via content-addressing

**Next Steps:**
1. Refactor ntt-loader for unpartitioned schema
2. Refactor ntt-copier.py for `paths` table (no `inode`)
3. Test with small tape subset before full ingestion
4. Document new loader/copier behavior
