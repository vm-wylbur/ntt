#!/usr/bin/env -S /home/pball/.local/bin/uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = [
#     "psycopg[binary]",
#     "loguru",
#     "pyyaml",
#     "blake3",
#     "python-magic"
# ]
# ///
#
# Author: PB and Claude
# Date: 2025-09-28
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/bin/ntt-copier.py
#
# NTT copy worker - deduplicates and archives filesystem content
#
# Requirements:
#   - Python 3.13+
#   - Must run as root/sudo
#   - Environment: sudo -E PATH="$PATH" or: sudo env PATH="$PATH" $(cat /etc/hrdag/ntt.env | xargs) ntt-copier.py

import os
import shutil
import signal
import sys
import time
from pathlib import Path
from typing import Optional
from concurrent.futures import ThreadPoolExecutor, as_completed

import blake3
import psycopg

# Import processor chain components
# Load the processors module (handles dash in filename)
processors_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ntt-copier-processors.py")
processors_globals = {}
with open(processors_path) as f:
    exec(f.read(), processors_globals)

# Extract the classes we need
InodeContext = processors_globals['InodeContext']
FileTypeDetector = processors_globals['FileTypeDetector']
DirectoryHandler = processors_globals['DirectoryHandler']
SymlinkHandler = processors_globals['SymlinkHandler']
NonFileHandler = processors_globals['NonFileHandler']
MimeTypeDetector = processors_globals['MimeTypeDetector']
FileProcessor = processors_globals['FileProcessor']
from psycopg.rows import dict_row
import yaml
from loguru import logger

# Set PostgreSQL user to original user when running under sudo
# This allows root to connect to PostgreSQL as the invoking user
if 'SUDO_USER' in os.environ:
    os.environ['PGUSER'] = os.environ['SUDO_USER']
elif os.geteuid() == 0 and 'USER' in os.environ:
    # Running as root but no SUDO_USER (e.g., direct root login)
    # Default to 'postgres' user for safety
    os.environ['PGUSER'] = 'postgres'

# Configuration from environment with defaults
# Note: Run with sudo -E to preserve environment, or:
#       sudo env $(cat /etc/hrdag/ntt.env | xargs) ntt-copier.py
DB_URL = os.environ.get('NTT_DB_URL', 'postgresql:///copyjob')

# If running as root and DB_URL doesn't specify a user, add the original user
if os.geteuid() == 0 and 'SUDO_USER' in os.environ:
    if '://' in DB_URL and '@' not in DB_URL:
        # Insert the original user into the connection string
        # postgresql:///copyjob -> postgresql://pball@/copyjob
        DB_URL = DB_URL.replace(':///', f"://{os.environ['SUDO_USER']}@localhost/")
RAMDISK = Path(os.environ.get('NTT_RAMDISK', '/tmp/ram'))
NVME_TMP = Path(os.environ.get('NTT_NVME_TMP', '/data/fast/tmp'))
BY_HASH_ROOT = Path(os.environ.get('NTT_BY_HASH_ROOT', '/data/cold/by-hash'))
ARCHIVE_ROOT = Path(os.environ.get('NTT_ARCHIVE_ROOT', '/data/cold/archived'))
LOG_JSON = Path(os.environ.get('NTT_LOG_JSON', '/var/log/ntt/copier.jsonl'))
MOUNT_MAP_FILE = Path(os.environ.get('NTT_MOUNT_MAP', '/etc/hrdag/ntt/mounts.yaml'))
IGNORE_PATTERNS_FILE = os.environ.get('NTT_IGNORE_PATTERNS', '')

# Size thresholds
RAM_THRESHOLD = 1 * 1024 * 1024 * 1024  # 1GB
CHUNK_SIZE = 64 * 1024  # 64KB for streaming

# Worker configuration
WORKER_ID = os.environ.get('NTT_WORKER_ID', f'w{os.getpid()}')
HEARTBEAT_INTERVAL = 30  # seconds
SAMPLE_SIZE = int(os.environ.get('NTT_SAMPLE_SIZE', '1000'))  # TABLESAMPLE rows

# Processing mode and limit
DRY_RUN = False
LIMIT = 0  # Unified limit for both dry-run and live modes

# Parse command line arguments
has_dry_run = False
has_limit = False
VERBOSE = False

for arg in sys.argv:
    if arg == '--re-hardlink':
        print("Note: --re-hardlink mode has been moved to a separate tool.")
        print("Please use: sudo /home/pball/projects/ntt/bin/ntt-re-hardlink.py")
        sys.exit(1)
    elif arg == '--verbose':
        VERBOSE = True
    elif arg.startswith('--dry-run'):
        has_dry_run = True
        if '=' in arg:
            # --dry-run=100 format
            try:
                LIMIT = int(arg.split('=')[1])
                DRY_RUN = True
            except ValueError:
                print(f"Error: Invalid dry-run limit: {arg}", file=sys.stderr)
                sys.exit(1)
        else:
            # Just --dry-run (unlimited)
            DRY_RUN = True
            LIMIT = 0
    elif arg.startswith('--limit'):
        has_limit = True
        if '=' in arg:
            # --limit=100 format
            try:
                LIMIT = int(arg.split('=')[1])
            except ValueError:
                print(f"Error: Invalid limit: {arg}", file=sys.stderr)
                sys.exit(1)
        else:
            print("Error: --limit requires a value (e.g., --limit=100)", file=sys.stderr)
            sys.exit(1)

# Check mutual exclusivity
if has_dry_run and has_limit:
    print("Error: --dry-run and --limit are mutually exclusive", file=sys.stderr)
    sys.exit(1)

# Also check environment variable
if not DRY_RUN and not has_limit and os.environ.get('NTT_DRY_RUN', '').lower() == 'true':
    DRY_RUN = True
    LIMIT = int(os.environ.get('NTT_DRY_RUN_LIMIT', '10'))  # Default to 10 for env var

# Constants
EMPTY_FILE_HASH = 'af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262'  # BLAKE3 of empty


class CopyWorker:
    """Single worker that processes inodes from the queue."""

    def __init__(self, worker_id: str):
        self.worker_id = worker_id
        self.conn: Optional[psycopg.Connection] = None
        self.shutdown = False
        self.stats = {
            'copied': 0,
            'bytes': 0,
            'errors': 0,
            'skipped': 0,
            'deduped': 0,
            'start_time': time.time()
        }
        self.processed_count = 0  # Track files processed (for both dry-run and limit modes)

        # Export config for processors
        self.dry_run = DRY_RUN
        self.EMPTY_FILE_HASH = EMPTY_FILE_HASH
        self.CHUNK_SIZE = CHUNK_SIZE
        self.BY_HASH_ROOT = BY_HASH_ROOT
        self.ARCHIVE_ROOT = ARCHIVE_ROOT

        # Configure loguru for both console and JSON file
        logger.remove()  # Remove default handler

        # Use different log file for dry-run mode
        log_file = LOG_JSON if not DRY_RUN else Path('/var/log/ntt/copier-dryrun.jsonl')

        logger.add(
            log_file,
            format="{time:UNIX} {message}",
            serialize=True,
            rotation="1 GB",
            retention="30 days" if not DRY_RUN else "7 days",  # Shorter retention for dry-run
            level="DEBUG"
        )

        # Make log files readable by dashboard user
        try:
            log_file.chmod(0o644)
        except (OSError, PermissionError):
            pass  # Ignore permission errors, dashboard will handle gracefully
        logger.add(sys.stderr, format="{time:HH:mm:ss} [{level}] {message}", level="INFO")

        # Bind context without reassigning
        self.logger = logger.bind(worker_id=worker_id)
        if DRY_RUN:
            self.logger = self.logger.bind(dry_run=True)  # Mark all logs as dry-run

        self.mount_map = self.load_mount_map()
        
        # Load ignore patterns
        self.ignore_patterns = []
        if IGNORE_PATTERNS_FILE and Path(IGNORE_PATTERNS_FILE).exists():
            with open(IGNORE_PATTERNS_FILE) as f:
                self.ignore_patterns = [
                    line.strip() for line in f
                    if line.strip() and not line.strip().startswith('#')
                ]
            if self.ignore_patterns:
                self.logger.info(f"Loaded {len(self.ignore_patterns)} ignore patterns")

        # Build the processor pipeline
        self.pipeline = FileTypeDetector(
            DirectoryHandler(
                SymlinkHandler(
                    NonFileHandler(
                        MimeTypeDetector(
                            FileProcessor()
                        )
                    )
                )
            )
        )

        # Set up per-worker temp directories
        self.ramdisk_dir = RAMDISK / self.worker_id
        self.nvme_dir = NVME_TMP / self.worker_id

        # Clean up any leftover temps on startup
        for temp_dir in [self.ramdisk_dir, self.nvme_dir]:
            if temp_dir.exists():
                self.logger.info("Cleaning up old temp dir", path=str(temp_dir))
                shutil.rmtree(temp_dir, ignore_errors=True)
            # Create fresh directory
            temp_dir.mkdir(parents=True, exist_ok=True)
            # Fix permissions if running as root
            if os.geteuid() == 0:
                os.chown(temp_dir, 1000, 1000)
                os.chmod(temp_dir, 0o755)

    def load_mount_map(self) -> dict[str, Path]:
        """Load mount mapping from YAML file."""
        if not MOUNT_MAP_FILE.exists():
            self.logger.warning(f"Mount map not found: {MOUNT_MAP_FILE}")
            return {}

        try:
            with open(MOUNT_MAP_FILE) as f:
                config = yaml.safe_load(f)
                return {k: Path(v) for k, v in config.get('mounts', {}).items()}
        except Exception as e:
            self.logger.error(f"Failed to load mount map: {e}")
            return {}

    def connect_db(self):
        """Establish database connection."""
        self.conn = psycopg.connect(DB_URL, row_factory=dict_row)
        self.conn.autocommit = False

    def fetch_work(self) -> Optional[dict]:
        """Fetch random uncoped inode with row-level lock using TABLESAMPLE.

        Uses TABLESAMPLE SYSTEM_ROWS for fast random selection from large tables.
        CTE filters uncoped rows first, then JOINs for better performance.
        Falls back to simple query if sample returns no results (edge case).
        """
        with self.conn.cursor() as cur:
            # Primary strategy: CTE with TABLESAMPLE for random selection
            # Filter first in CTE, then JOIN only the filtered subset
            
            # Build path filter condition if ignore patterns exist
            path_filter = ""
            if self.ignore_patterns:
                # Use PostgreSQL's ~ operator for regex matching (case-sensitive)
                # NOT matching any of the patterns
                pattern_conditions = " AND ".join(
                    f"p.path !~ '{pattern}'" for pattern in self.ignore_patterns
                )
                path_filter = f"AND {pattern_conditions}"
            
            query = f"""
                SELECT i.*, p.path
                FROM (
                    SELECT * FROM inode
                    TABLESAMPLE SYSTEM_ROWS(%(sample_size)s)
                    WHERE copied = false
                    ORDER BY RANDOM()
                    LIMIT 100
                ) i
                JOIN path p ON (i.medium_hash = p.medium_hash
                            AND i.dev = p.dev
                            AND i.ino = p.ino)
                WHERE 1=1 {path_filter}
                ORDER BY RANDOM()
                LIMIT 1
                FOR UPDATE OF i SKIP LOCKED
            """
            cur.execute(query, {'sample_size': SAMPLE_SIZE})

            row = cur.fetchone()
            if row:
                return row

            # Fallback: if TABLESAMPLE missed all uncoped files
            # This can happen when very few uncoped files remain
            self.logger.debug("TABLESAMPLE returned no results, using fallback")
            cur.execute("""
                SELECT i.*, p.path
                FROM inode i
                JOIN path p ON (i.medium_hash = p.medium_hash
                            AND i.dev = p.dev
                            AND i.ino = p.ino)
                WHERE i.copied = false
                LIMIT 1
                FOR UPDATE OF i SKIP LOCKED
            """)
            return cur.fetchone()

    def get_source_path(self, row: dict) -> Path:
        """Get actual source path with mount mapping."""
        if row['medium_hash'] in self.mount_map:
            mount_point = self.mount_map[row['medium_hash']]
            return mount_point / row['path'].lstrip('/')
        else:
            # Assume path is already absolute
            return Path(row['path'])

    def get_temp_path(self, row: dict) -> Path:
        """Get temp path for this inode, includes medium_hash for uniqueness."""
        size = row['size']
        if size < RAM_THRESHOLD:
            temp_dir = self.ramdisk_dir
        else:
            temp_dir = self.nvme_dir

        temp_dir.mkdir(parents=True, exist_ok=True)
        # Fix permissions if running as root
        if os.geteuid() == 0:
            os.chown(temp_dir, 1000, 1000)
            os.chmod(temp_dir, 0o755)
        temp_name = f"{row['medium_hash']}_{row['dev']}_{row['ino']}.tmp"
        return temp_dir / temp_name

    def hash_file(self, path: Path) -> str:
        """Calculate BLAKE3 hash of existing file."""
        hasher = blake3.blake3()

        with open(path, 'rb') as f:
            while chunk := f.read(CHUNK_SIZE):
                hasher.update(chunk)

        return hasher.hexdigest()

    def hash_and_copy(self, source: Path, dest: Path) -> str:
        """Stream copy to dest while calculating BLAKE3 hash."""
        hasher = blake3.blake3()

        with open(source, 'rb') as src, open(dest, 'wb') as dst:
            while chunk := src.read(CHUNK_SIZE):
                hasher.update(chunk)
                dst.write(chunk)

            # Ensure data is on disk
            dst.flush()
            os.fsync(dst.fileno())

        return hasher.hexdigest()

    def handle_existing_temp(self, temp_path: Path, source_path: Path, size: int) -> Optional[str]:
        """Handle existing temp file from previous run."""
        if not temp_path.exists():
            return None

        if size < RAM_THRESHOLD:
            # Small file in ramdisk - just redo it
            self.logger.info("Restarting small file from ramdisk", path=str(temp_path))
            temp_path.unlink()
            return None
        else:
            # Large file on NVMe - verify before discarding
            temp_size = temp_path.stat().st_size
            if temp_size == size:
                # Might be complete, hash to verify
                self.logger.info("Verifying large file", path=str(temp_path))
                temp_hash = self.hash_file(temp_path)
                # For now, trust it if size matches
                # Could verify against source if paranoid
                return temp_hash
            else:
                # Definitely incomplete
                self.logger.info("Restarting incomplete file",
                               path=str(temp_path), temp_size=temp_size, expected_size=size)
                temp_path.unlink()
                return None

    def process_inode(self, row: dict):
        """Process single inode through the processor chain."""
        # Create context and run through pipeline
        context = InodeContext(
            row=row,
            source_path=self.get_source_path(row),
            fs_type=row.get('fs_type'),
            mime_type=row.get('mime_type')
        )

        try:
            result = self.pipeline.process(context, self)

            if not result.should_process:
                self.logger.debug(f"Skipped: {result.skip_reason}",
                                path=str(result.source_path),
                                ino=row['ino'])

        except Exception as e:
            self.logger.error(f"Processing failed: {e}",
                            ino=row['ino'],
                            path=str(context.source_path))
            self.stats['errors'] += 1

            # Record error in database
            with self.conn.cursor() as cur:
                cur.execute("""
                    UPDATE inode
                    SET errors = array_append(errors, %s)
                    WHERE medium_hash = %s AND dev = %s AND ino = %s
                """, (str(e), row['medium_hash'], row['dev'], row['ino']))
            self.conn.commit()

        return


    def emit_heartbeat(self):
        """Emit JSON heartbeat with worker stats."""
        elapsed = time.time() - self.stats['start_time']
        rate = self.stats['bytes'] / elapsed if elapsed > 0 else 0

        heartbeat = {
            'worker_id': self.worker_id,
            'copied': self.stats['copied'],
            'deduped': self.stats['deduped'],
            'skipped': self.stats['skipped'],
            'mb': self.stats['bytes'] / (1024 * 1024),
            'rate_mb_s': rate / (1024 * 1024),
            'errors': self.stats['errors'],
            'ts': time.time()
        }
        # Log to both console and JSON file
        self.logger.info("Heartbeat: {copied} files, {mb:.1f} MB, {rate_mb_s:.1f} MB/s, {errors} errors",
                        copied=heartbeat['copied'],
                        mb=heartbeat['mb'],
                        rate_mb_s=heartbeat['rate_mb_s'],
                        errors=heartbeat['errors'])

    def handle_shutdown(self, signum, frame):
        """Graceful shutdown on SIGTERM."""
        self.logger.info("Shutdown signal received", signal=signum)
        self.shutdown = True

    def cleanup(self):
        """Clean up worker resources."""
        # Clean up temp directories
        if hasattr(self, 'ramdisk_dir') and hasattr(self, 'nvme_dir'):
            for temp_dir in [self.ramdisk_dir, self.nvme_dir]:
                if temp_dir.exists():
                    self.logger.info("Cleaning up temp dir", path=str(temp_dir))
                    try:
                        shutil.rmtree(temp_dir)
                    except Exception as e:
                        self.logger.warning(f"Failed to clean up {temp_dir}: {e}")

        # Close database connection
        if self.conn:
            self.conn.close()

    def run(self):
        """Main worker loop."""
        signal.signal(signal.SIGTERM, self.handle_shutdown)
        signal.signal(signal.SIGINT, self.handle_shutdown)

        self.connect_db()
        last_heartbeat = time.time()

        self.logger.info("Worker starting", worker_id=self.worker_id)

        while not self.shutdown:
            # Check processing limit
            if LIMIT > 0 and self.processed_count >= LIMIT:
                mode = "Dry-run" if DRY_RUN else "Processing"
                self.logger.info(f"{mode} limit reached", limit=LIMIT, processed=self.processed_count)
                break

            if time.time() - last_heartbeat > HEARTBEAT_INTERVAL:
                self.emit_heartbeat()
                last_heartbeat = time.time()

            row = self.fetch_work()
            if row:
                self.process_inode(row)
            else:
                time.sleep(1)

        self.emit_heartbeat()
        self.cleanup()

        self.logger.info("Worker complete", stats=self.stats)
        return 0 if self.stats['errors'] == 0 else 1


def main():
    """Entry point."""
    # Ensure temp directories exist with proper permissions
    for temp_dir in [RAMDISK, NVME_TMP]:
        try:
            temp_dir.mkdir(parents=True, exist_ok=True)
            # Set permissions to match /tmp (sticky bit + world writable)
            os.chmod(temp_dir, 0o1777)
        except PermissionError:
            # Try with sudo if we're running as root
            if os.geteuid() == 0:
                os.makedirs(temp_dir, exist_ok=True)
                os.chmod(temp_dir, 0o1777)
            else:
                print(f"Warning: Cannot create temp directory {temp_dir}", file=sys.stderr)

    # Show mode and limit status prominently
    print("=" * 60, file=sys.stderr)
    if DRY_RUN:
        print("RUNNING IN DRY-RUN MODE", file=sys.stderr)
        if LIMIT > 0:
            print(f"Will process up to {LIMIT} files", file=sys.stderr)
        else:
            print("No limit set (use --dry-run=N to limit)", file=sys.stderr)
        print("No files will be modified or copied", file=sys.stderr)
        print("No database updates will be committed", file=sys.stderr)
        print(f"Dry-run logs: /var/log/ntt/copier-dryrun.jsonl", file=sys.stderr)
    else:
        if LIMIT > 0:
            print(f"RUNNING IN LIMITED MODE", file=sys.stderr)
            print(f"Will process up to {LIMIT} files", file=sys.stderr)
            print("Files WILL be copied and database WILL be updated", file=sys.stderr)
        else:
            print("RUNNING IN FULL PRODUCTION MODE", file=sys.stderr)
            print("Processing all files until complete", file=sys.stderr)
    print("=" * 60, file=sys.stderr)

    # Check if running as root (needed for accessing all files)
    if os.geteuid() != 0:
        print("Error: ntt-copier must be run as root/sudo", file=sys.stderr)
        sys.exit(1)

    worker = CopyWorker(WORKER_ID)
    sys.exit(worker.run())


if __name__ == '__main__':
    main()

# done.  <-- always leave this string at the end of the file.
