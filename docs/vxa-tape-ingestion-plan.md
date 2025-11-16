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
- Create medium records for each tape (7 total)
- Use tape identifier as medium_hash (e.g., `vxa-tape1`, `vxa-tape2`)
- Link to tape metadata (date, label from tar header)
- Medium type: `carved`
