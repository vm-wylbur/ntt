# NTT bin/ Scripts Reference

This directory contains the core NTT (No Two Things) toolchain for disk image processing, deduplication, and archival.

**Generated:** 2025-10-11
**Total scripts:** 27
**Total lines:** ~13,800

---

## Pipeline Overview

The NTT pipeline processes disk images through these stages:

1. **Imaging** → Create disk image from physical media
2. **Mounting** → Mount disk image for filesystem access
3. **Enumeration** → Walk filesystem and extract metadata
4. **Loading** → Import metadata into PostgreSQL
5. **Copying** → Deduplicate files to by-hash storage
6. **Archiving** → Compress and move to cold storage
7. **Verification** → Validate archive integrity

---

## Core Pipeline Scripts

### ntt-orchestrator (1550 lines)
**Purpose:** Main entry point for the entire NTT pipeline
**Usage:**
```bash
sudo ntt-orchestrator /dev/sdX              # Device mode (imaging)
sudo ntt-orchestrator /path/to/directory    # Directory mode
sudo ntt-orchestrator --image file.img      # Disk image mode
sudo ntt-orchestrator --load-only file.raw  # Load existing .raw
```

**Options:**
- `--enum-only` - Stop after enumeration
- `--force` - Bypass duplicate checking
- `--message "text"` - Add custom message to medium record

**What it does:**
- Orchestrates entire pipeline from imaging to archiving
- Handles device identification and hash generation
- Calls ntt-mount-helper, ntt-enum, ntt-loader, ntt-copier, ntt-archiver
- Manages cleanup on errors

**Dependencies:** ntt-mount-helper, ntt-enum, ntt-loader, ntt-copier/ntt-copy-workers, ntt-archiver

---

### ntt-imager (324 lines)
**Purpose:** Progressive 7-phase ddrescue imaging
**Usage:**
```bash
sudo ntt-imager /dev/sdX /output/path.img
```

**What it does:**
- 7-phase ddrescue strategy (fast → slow → scraping)
- Never gives up until 100% or exhausted all phases
- Phase progression: 16→8→4→2→1→0.5→scrape sectors
- Handles read errors progressively

**Called by:** ntt-orchestrator (device mode)

---

### ntt-mount-helper (386 lines)
**Purpose:** Safe sudo wrapper for mounting/unmounting disk images
**Usage:**
```bash
sudo ntt-mount-helper mount <hash> <image_path>
sudo ntt-mount-helper unmount <hash>
sudo ntt-mount-helper status <hash>
```

**What it does:**
- Validates medium_hash format (hex only)
- Only mounts to `/mnt/ntt/<hash>` (security)
- Read-only mounts with nosuid,nodev,noatime
- Handles multi-partition disks
- Handles Zip disk offset (16384 bytes)
- ISO9660/UDF bridge-format fallback for optical media
- Cleans up stale loop devices

**Called by:** ntt-orchestrator, ntt-copier.py

---

### ntt-enum (97 lines)
**Purpose:** Filesystem enumeration to .raw format
**Usage:**
```bash
sudo ntt-enum /mnt/ntt/<hash> <hash> output.raw
```

**What it does:**
- Walks mounted filesystem using find
- Outputs binary .raw format (034/NUL delimited)
- Respects ignore patterns from `.ntt-ignore`
- Makes directories world-readable (chmod 755)
- Records: dev, ino, nlink, size, mtime, fs_type, path

**Called by:** ntt-orchestrator

---

### ntt-loader (326 lines)
**Purpose:** Stream .raw files into PostgreSQL partitioned tables
**Usage:**
```bash
ntt-loader /path/to/file.raw <medium_hash>
```

**What it does:**
- Creates partition for medium_hash
- Streams .raw → temp table → inode partition
- Deduplicates within medium (same size+mtime+ino)
- Sets up foreign keys to medium table
- ~6min for 11M paths (bb22 benchmark)

**Called by:** ntt-orchestrator

**Note:** Current active loader. See "Loader Variants" below for alternatives.

---

### ntt-copier.py (1771 lines) + ntt_copier_strategies.py (364 lines) + ntt_copier_diagnostics.py (348 lines)
**Purpose:** Deduplicate files to by-hash storage with hardlinks
**Usage:**
```bash
sudo -E ntt-copier.py --medium-hash <hash> [--limit N] [--batch-size N]
```

**Options:**
- `-m, --medium-hash` - Medium to process (required)
- `--limit N` - Process max N inodes then exit
- `--batch-size N` - Claim N inodes per batch (default: 50)
- `--max-errors N` - Stop after N errors (default: 10)

**Architecture:**
- **Claim-Analyze-Execute** pattern
- Phase 0: Claim work (TABLESAMPLE + UPDATE, atomic)
- Phase 1: Analyze (read files, compute BLAKE3 hash)
- Phase 2: Execute (filesystem first, then DB transaction)

**What it does:**
- Claims unclaimed inodes from database
- Copies to temp, computes BLAKE3 hash
- Deduplicates: hardlink if exists, else create new
- Updates database: `copied=true`, `blobid=hash`, `status='success'`
- Error classification: path_error, io_error, hash_error, permission_error
- Retry logic: max 50 attempts with exponential backoff
- DiagnosticService: tracks failures by error type

**Called by:** ntt-copy-workers, ntt-orchestrator

---

### ntt-copy-workers (302 lines)
**Purpose:** Launch parallel ntt-copier.py workers with signal handling
**Usage:**
```bash
sudo ntt-copy-workers -m <hash> [-w N] [--limit N] [--wait]
```

**Options:**
- `-m, --medium-hash` - Medium to process (required)
- `-w, --workers N` - Number of parallel workers (default: 4)
- `-l, --limit N` - Process limit per worker
- `--wait` - Wait for all workers to complete
- `--dry-run N` - Dry-run mode

**What it does:**
- Launches N parallel ntt-copier.py instances
- Handles ^C (SIGINT) for clean shutdown
- Saves PIDs to `/tmp/ntt-workers.pids`
- Two-phase shutdown: SIGTERM → wait → SIGKILL

**Called by:** ntt-orchestrator

---

### ntt-archiver (274 lines)
**Purpose:** Archive disk images to cold storage after copying completes
**Usage:**
```bash
sudo ntt-archiver <medium_hash> [--force] [--verbose]
```

**What it does:**
- Safety checks: all inodes copied, archive doesn't exist
- Creates tar.zst archive of image + raw + logs
- Source: `/data/fast/img/<hash>*`
- Destination: `/data/cold/archives/<hash>.tar.zst`
- Updates database: `medium.copy_done = NOW()`
- --force: skip safety checks

**Exit codes:**
- 0 = success
- 1 = error
- 2 = already archived (skipped)

**Called by:** ntt-orchestrator

---

## Management & Monitoring Scripts

### ntt-dashboard (1391 lines)
**Purpose:** Real-time monitoring TUI for NTT system
**Usage:**
```bash
ntt-dashboard
```

**Features:**
- Live worker status (PID, medium, progress)
- Batch processing metrics
- Recent errors and diagnostics
- Queue depth and processing rates
- Textual TUI with auto-refresh

---

### ntt-pipeline-status (93 lines)
**Purpose:** Check complete pipeline status for a medium
**Usage:**
```bash
ntt-pipeline-status <medium_hash>
```

**What it checks:**
- Image file exists
- Raw file exists
- Database records exist
- Enumeration complete
- Copying complete
- Archive exists

---

### ntt-list-media (151 lines)
**Purpose:** List medium_hashes for media containing specific path prefix
**Usage:**
```bash
ntt-list-media --path-prefix /data/staging [--format list|comma|quoted] [--stats]
```

**Output formats:**
- `list` - One per line (default)
- `comma` - CSV format
- `quoted` - SQL-ready quoted list

---

### ntt-cleanup-mounts (116 lines)
**Purpose:** Periodic cleanup of mounted NTT disk images
**Usage:**
```bash
sudo ntt-cleanup-mounts
```

**What it does:**
- Unmounts images where all inodes are copied
- Cleans up loop devices
- Meant for cron (e.g., hourly)

---

### ntt-stop-workers (159 lines)
**Purpose:** Stop running ntt-copier workers
**Usage:**
```bash
ntt-stop-workers [--pidfile FILE] [--force]
```

**What it does:**
- Reads PIDs from `/tmp/ntt-workers.pids`
- Two-phase shutdown: SIGTERM (15s) → SIGKILL
- --force: immediate SIGKILL

---

## Recovery & Repair Scripts

### ntt-recover-failed (237 lines)
**Purpose:** Reset failed_retryable inodes for retry (BUG-007 fix)
**Usage:**
```bash
ntt-recover-failed list-failures -m <hash>
ntt-recover-failed reset-failures -m <hash> [--error-type TYPE] [--dry-run]
```

**Commands:**
- `list-failures` - Show failures by error_type
- `reset-failures` - Reset failed_retryable → pending

**Error types:**
- `path_error` - File not found (fixable)
- `io_error` - I/O errors (often permanent)
- `permission_error` - Permission denied
- `hash_error` - Hash mismatch
- `unknown` - Unclassified

**Use case:** After fixing root cause (mount issues, permissions), reset inodes for retry

---

### ntt-re-hardlink.py (577 lines)
**Purpose:** Repair missing hardlinks between by-hash and archived
**Usage:**
```bash
sudo ntt-re-hardlink.py -m <hash> [--batch-size N] [--check-only]
```

**Options:**
- `--check-only` - Report issues without fixing
- `--batch-size N` - Process N inodes per batch (default: 10000)
- `--verify-after` - Verify links after creation

**What it does:**
- Finds inodes with `blobid` but link count < 2
- Creates missing hardlinks from by-hash to archived
- Performance: 5k links/sec with batch processing

---

### ntt-verify.py (745 lines)
**Purpose:** Verify content integrity in archived storage
**Usage:**
```bash
sudo ntt-verify.py -m <hash> [--sample-rate N] [--max-verifications N]
```

**Options:**
- `--sample-rate N` - Verify 1 in N files (default: 10)
- `--max-verifications N` - Stop after N verifications
- `--from-file FILE` - Verify specific blobids from file
- `--workers N` - Parallel workers (default: 4)

**What it does:**
- Recomputes BLAKE3 hash for archived files
- Compares against database blobid
- Reports mismatches and missing files
- Can verify specific files or random sample

---

### ntt-verify-sudo (14 lines)
**Purpose:** Wrapper for ntt-verify.py that preserves environment under sudo
**Usage:**
```bash
sudo ntt-verify-sudo -m <hash>
```

**What it does:**
- Loads NTT environment variables
- Passes them explicitly to ntt-verify.py
- Ensures correct database connection under sudo

---

### ntt-mark-excluded (141 lines)
**Purpose:** Mark inodes as excluded based on ignore patterns
**Usage:**
```bash
ntt-mark-excluded <medium_hash>
```

**What it does:**
- Reads ignore patterns from docs/ignore-patterns-guide.md
- Marks matching paths as excluded in database
- Used for post-load cleanup

---

### ntt-parse-verify-log.py (215 lines)
**Purpose:** Parse and analyze ntt-verify.py output logs
**Usage:**
```bash
ntt-parse-verify-log.py verify-output.log
```

**What it does:**
- Extracts verification results from logs
- Summarizes: verified, failed, missing counts
- Generates reports for analysis

---

## Loader (Single Active Version)

### ntt-loader (326 lines)
**Status:** ✅ Active, production
**Strategy:** Partition-per-medium with parent-level FK
**Performance:** ~6min for 11M paths (bb22)
**Features:**
- Partition-to-partition FK architecture (commit 30153f1)
- Respects ignore patterns
- Atomic partition operations

**Deprecated variants:** Previous loader versions (ntt-loader-old, ntt-loader-partitioned, ntt-loader-detach) have been moved to `bin/deprecated/` as of 2025-10-11. See `bin/deprecated/README.md` for details.

---

## Utility Scripts

### ntt-raw-tail (20 lines)
**Purpose:** Display last N records from .raw file
**Usage:**
```bash
ntt-raw-tail file.raw [N]
```

**What it does:**
- Parses binary .raw format
- Shows last N records (default: 10)

---

### oneoff-count-hardlinks.py (217 lines)
**Purpose:** One-off script to count hardlinks in by-hash storage
**Usage:**
```bash
oneoff-count-hardlinks.py /data/cold/by-hash
```

**What it does:**
- Walks by-hash directory
- Counts files by link count (1, 2, 3+)
- Diagnostic tool for deduplication analysis

---

### diagnose-loader-hang.sql (194 lines)
**Purpose:** SQL queries to diagnose loader performance issues
**Usage:**
```sql
\i bin/diagnose-loader-hang.sql
```

**What it provides:**
- Active queries and their duration
- Lock contention analysis
- Partition size and statistics
- Index bloat detection
- Table and index sizes

---

## Dependencies Between Scripts

### Orchestrator Calls:
- ntt-mount-helper
- ntt-enum
- ntt-loader
- ntt-copier.py / ntt-copy-workers
- ntt-archiver

### Copier Modules:
- ntt-copier.py imports:
  - ntt_copier_strategies.py (copy strategies)
  - ntt_copier_diagnostics.py (error analysis)
- Calls: ntt-mount-helper

### Copy Workers:
- ntt-copy-workers launches: ntt-copier.py

### Verification Chain:
- ntt-verify-sudo → ntt-verify.py
- ntt-re-hardlink.py → ntt-verify.py (verification step)

---

## File Naming Conventions

### Python Scripts (uv run --script):
- `ntt-*.py` - Main executables with inline dependencies
- `ntt_*.py` - Library modules (imported by other scripts)

### Bash Scripts:
- `ntt-*` (no extension) - Executable bash scripts

### SQL Files:
- `*.sql` - SQL diagnostic/utility scripts

---

## Environment Variables

Most scripts use these environment variables:

- `NTT_DB_URL` - PostgreSQL connection (default: `postgresql:///copyjob`)
- `IMAGE_ROOT` - Disk image storage (default: `/data/fast/img`)
- `RAW_ROOT` - .raw file storage (default: `/data/fast/raw`)
- `BYHASH_ROOT` - By-hash storage (default: `/data/cold/by-hash`)
- `ARCHIVE_ROOT` - Archive storage (default: `/data/cold/archives`)
- `ARCHIVED_ROOT` - Hardlink archive storage (default: `/data/cold/archived`)
- `NTT_IGNORE_PATTERNS` - Path to ignore patterns file

---

## Script Sizes

**Largest scripts:**
- ntt-copier.py: 1771 lines
- ntt-orchestrator: 1550 lines
- ntt-dashboard: 1391 lines
- ntt-verify.py: 745 lines
- ntt-re-hardlink.py: 577 lines

**Total:** ~13,800 lines across 27 scripts

---

## Testing

No comprehensive test suite currently exists. Testing is manual:
- Integration testing via full pipeline runs
- Bug reports tracked in bugs/ directory
- Lessons learned documented in docs/lessons/

**See:** bugs/TEMPLATE.md for bug reporting format

---

## Related Documentation

- `docs/hash-format.md` - BLAKE3 v2 hybrid format
- `docs/ignore-patterns-guide.md` - Path exclusion patterns
- `docs/diagnostic-queries.md` - SQL queries for analysis
- `docs/sanity-checks.md` - Database integrity checks
- `docs/lessons/` - Critical mistakes to avoid
- `ROLES.md` - Multi-Claude workflow
