#!/usr/bin/env -S /home/pball/.local/bin/uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = [
#     "psycopg[binary]",
#     "loguru",
#     "pyyaml",
#     "blake3",
#     "python-magic",
#     "typer",
# ]
# ///
#
# Author: PB and Claude
# Date: 2025-10-01
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/bin/ntt-copier.py
#
# NTT copy worker - deduplicates and archives filesystem content
#
# Architecture: Claim-Analyze-Execute pattern
# - Phase 0: Claim work using TABLESAMPLE + UPDATE (0.5ms, atomic)
# - Phase 1: Analyze (read-only, copy to temp, hash)
# - Phase 2: Execute (filesystem first, then DB transaction)
#
# Requirements:
#   - Python 3.13+
#   - Must run as root/sudo for filesystem access
#   - Run with: sudo -E ntt-copier.py [options]

import os
import shutil
import signal
import sys
import time
from pathlib import Path
from typing import Optional
import psycopg
from psycopg.rows import dict_row
import yaml
from loguru import logger
import typer
import magic

# Import strategy functions
import ntt_copier_strategies as strategies

app = typer.Typer()


class AnalysisError(Exception):
    """Raised when analysis phase fails."""
    pass


class ExecutionError(Exception):
    """Raised when execution phase fails."""
    pass


class CopyWorker:
    """NTT copy worker using Claim-Analyze-Execute pattern."""
    
    def __init__(self, worker_id: str, db_url: str, limit: int = 0, 
                 dry_run: bool = False, sample_size: int = 1000,
                 medium_hashes: Optional[list[str]] = None):
        self.worker_id = worker_id
        self.db_url = db_url
        self.limit = limit
        self.dry_run = dry_run
        self.sample_size = sample_size
        self.medium_hashes = medium_hashes
        self.shutdown = False
        self.processed_count = 0
        
        # Environment configuration
        self.RAMDISK = Path(os.environ.get('NTT_RAMDISK', '/tmp/ram'))
        self.NVME_TMP = Path(os.environ.get('NTT_NVME_TMP', '/data/fast/tmp'))
        self.BY_HASH_ROOT = Path(os.environ.get('NTT_BY_HASH_ROOT', '/data/cold/by-hash'))
        self.ARCHIVE_ROOT = Path(os.environ.get('NTT_ARCHIVE_ROOT', '/data/cold/archived'))
        
        logger.info(f"Worker {self.worker_id} paths: by-hash={self.BY_HASH_ROOT}, archive={self.ARCHIVE_ROOT}")
        
        # Stats
        self.stats = {
            'copied': 0,
            'deduped': 0,
            'errors': 0,
            'bytes': 0,
        }
        
        # Database connection
        self.conn = psycopg.connect(self.db_url, row_factory=dict_row, autocommit=False)
        
        # Set search_path if NTT_SEARCH_PATH is provided, adding 'public' for extensions
        if 'NTT_SEARCH_PATH' in os.environ:
            search_path = os.environ['NTT_SEARCH_PATH']
            with self.conn.cursor() as cur:
                # Include 'public' so extensions like tsm_system_rows are accessible
                cur.execute(f"SET search_path = {search_path}, public")
            self.conn.commit()
        
        # MIME type detector (reused across files)
        self.mime_detector = magic.Magic(mime=True)
        
        # Setup signal handlers
        signal.signal(signal.SIGINT, self._signal_handler)
        signal.signal(signal.SIGTERM, self._signal_handler)
        
        logger.info(f"Worker {self.worker_id} initialized", 
                   limit=self.limit, dry_run=self.dry_run, sample_size=self.sample_size)
    
    def _signal_handler(self, signum, frame):
        """Handle shutdown signals gracefully."""
        logger.info(f"Received signal {signum}, shutting down...")
        self.shutdown = True
    
    def run(self):
        """Main worker loop."""
        logger.info(f"Worker {self.worker_id} starting")
        
        consecutive_no_work = 0
        max_no_work_attempts = 10  # Check for exhaustion after 10 failed claims
        
        while not self.shutdown:
            work_unit = self.fetch_and_claim_work_unit()
            if not work_unit:
                consecutive_no_work += 1
                
                # If we have medium_hashes filter and consistently finding no work,
                # check if work is truly exhausted for our media
                if self.medium_hashes and consecutive_no_work >= max_no_work_attempts:
                    if self.check_media_exhausted():
                        logger.info(f"No remaining work for assigned media, exiting")
                        break
                    consecutive_no_work = 0  # Reset counter, work exists but claim race
                
                logger.debug("No work available, waiting...")
                time.sleep(0.01)  # 10ms - fast retry on claim race
                continue
            
            consecutive_no_work = 0  # Reset on successful claim
            
            logger.info(f"Processing work unit ino={work_unit['inode_row']['ino']}")
            self.process_work_unit(work_unit)
            self.processed_count += 1
            logger.info(f"Completed work unit, processed_count={self.processed_count}")
            
            if self.limit > 0 and self.processed_count >= self.limit:
                logger.info(f"Limit reached: {self.limit}")
                break
        
        logger.info(f"Worker {self.worker_id} finished", stats=self.stats)
        self.conn.close()
    
    def check_media_exhausted(self) -> bool:
        """
        Check if there are any unclaimed inodes left for our assigned media.
        (Health checked at startup via ntt-copy-workers)

        Returns:
            True if no work remains, False if work still exists
        """
        with self.conn.cursor() as cur:
            cur.execute("""
                SELECT EXISTS(
                    SELECT 1 FROM inode
                    WHERE copied = false
                      AND claimed_by IS NULL
                      AND medium_hash = ANY(%s)
                    LIMIT 1
                )
            """, (self.medium_hashes,))
            result = cur.fetchone()
            work_exists = result['exists'] if result else False
            return not work_exists
    
    def get_queue_depth(self) -> int:
        """Get current queue depth for adaptive sampling (respects medium_hashes filter).
        Health checked at startup via ntt-copy-workers."""
        with self.conn.cursor() as cur:
            if self.medium_hashes:
                cur.execute("""
                    SELECT COUNT(*) as count
                    FROM inode
                    WHERE copied = false
                      AND claimed_by IS NULL
                      AND medium_hash = ANY(%s)
                """, (self.medium_hashes,))
            else:
                cur.execute("""
                    SELECT COUNT(*) as count
                    FROM inode
                    WHERE copied = false
                      AND claimed_by IS NULL
                """)
            return cur.fetchone()['count']

    def fetch_and_claim_work_unit(self) -> Optional[dict]:
        """
        Atomically claim one inode with all its paths.

        Uses adaptive sampling:
        - TABLESAMPLE for large queues (>50K) - fast random sampling
        - Direct query for small queues (<=50K) - handles sparse long-tail

        Returns:
            {'inode_row': {...}, 'paths': ['/path1', ...]} or None
        """
        # Build WHERE clause for medium_hash filter
        medium_filter = ""
        if self.medium_hashes:
            medium_filter = "AND medium_hash = ANY(%(medium_hashes)s)"

        # Check queue depth every 100 claims to decide sampling strategy
        if not hasattr(self, '_queue_depth_cache'):
            self._queue_depth_cache = None
            self._queue_depth_check_counter = 0

        self._queue_depth_check_counter += 1
        if self._queue_depth_check_counter >= 100 or self._queue_depth_cache is None:
            self._queue_depth_cache = self.get_queue_depth()
            self._queue_depth_check_counter = 0
            logger.debug(f"Queue depth: {self._queue_depth_cache}")

        # Adaptive sampling: use TABLESAMPLE for large queues, direct query for long-tail
        LONG_TAIL_THRESHOLD = 50000

        if self._queue_depth_cache > LONG_TAIL_THRESHOLD:
            # Large queue: SELECT with SKIP LOCKED to avoid worker contention
            claim_query = f"""
                WITH locked_row AS (
                    SELECT medium_hash, ino
                    FROM inode
                    WHERE copied = false
                      AND claimed_by IS NULL
                      {medium_filter}
                    LIMIT 1
                    FOR UPDATE SKIP LOCKED
                ),
                claimed AS (
                    UPDATE inode i
                    SET claimed_by = %(worker_id)s, claimed_at = NOW()
                    FROM locked_row lr
                    WHERE (i.medium_hash, i.ino) = (lr.medium_hash, lr.ino)
                    RETURNING i.*
                )
                SELECT c.*,
                       (SELECT array_agg(p.path)
                        FROM path p
                        WHERE (p.medium_hash, p.ino) = (c.medium_hash, c.ino)) as paths
                FROM claimed c;
            """
        else:
            # Long-tail: SELECT with SKIP LOCKED (same as large queue for consistency)
            claim_query = f"""
                WITH locked_row AS (
                    SELECT medium_hash, ino
                    FROM inode
                    WHERE copied = false
                      AND claimed_by IS NULL
                      {medium_filter}
                    LIMIT 1
                    FOR UPDATE SKIP LOCKED
                ),
                claimed AS (
                    UPDATE inode i
                    SET claimed_by = %(worker_id)s, claimed_at = NOW()
                    FROM locked_row lr
                    WHERE (i.medium_hash, i.ino) = (lr.medium_hash, lr.ino)
                    RETURNING i.*
                )
                SELECT c.*,
                       (SELECT array_agg(p.path)
                        FROM path p
                        WHERE (p.medium_hash, p.ino) = (c.medium_hash, c.ino)) as paths
                FROM claimed c;
            """

        params = {
            'worker_id': self.worker_id
        }
        if self.medium_hashes:
            params['medium_hashes'] = self.medium_hashes

        with self.conn.cursor() as cur:
            cur.execute(claim_query, params)
            row = cur.fetchone()

        self.conn.commit()  # Auto-commit the claim

        if not row:
            logger.debug("No work claimed (either no candidates or claim race lost)")
            return None

        logger.debug(f"Claimed inode ino={row['ino']}, paths={len(row.get('paths', []))}")

        inode_row = dict(row)
        paths = inode_row.pop('paths', [])

        return {'inode_row': inode_row, 'paths': paths}
    
    def release_claim(self, inode_row: dict):
        """Release claim on an inode after error."""
        with self.conn.cursor() as cur:
            cur.execute("""
                UPDATE inode 
                SET claimed_by = NULL, claimed_at = NULL
                WHERE medium_hash = %s AND ino = %s
                  AND claimed_by = %s
            """, (inode_row['medium_hash'], inode_row['ino'],
                  self.worker_id))
        self.conn.commit()
    
    def process_work_unit(self, work_unit: dict):
        """Process one work unit through Claim-Analyze-Execute."""
        plan = None
        temp_file_path = None
        inode_row = work_unit['inode_row']
        
        try:
            # PHASE 1: ANALYSIS (read-only, no locks)
            plan = self.analyze_inode(work_unit)
            temp_file_path = plan.get('temp_file_path')
            
            logger.info(f"Analysis complete: action={plan['action']}, ino={inode_row['ino']}")
            
            if plan['action'] == 'skip':
                logger.warning(f"Skipping inode ino={inode_row['ino']}, reason={plan['reason']}")
                self.release_claim(inode_row)
                return
            
            if self.dry_run:
                logger.info("[DRY-RUN] Would execute", 
                           action=plan['action'],
                           ino=inode_row['ino'],
                           paths=len(work_unit['paths']))
                self.release_claim(inode_row)
                return
            
            # PHASE 2: EXECUTION (filesystem first, then DB)
            logger.info(f"Starting execution: action={plan['action']}, ino={inode_row['ino']}")
            self.execute_plan(plan)
            
            logger.info(f"Work unit completed: action={plan['action']}, ino={inode_row['ino']}")
            logger.debug("Work unit completed", 
                        ino=inode_row['ino'],
                        action=plan['action'])
        
        except AnalysisError as e:
            logger.error(f"Analysis failed ino={inode_row['ino']}, error={e}", exc_info=True)
            self.release_claim(inode_row)
            self.stats['errors'] += 1
        
        except ExecutionError as e:
            logger.error(f"Execution failed ino={inode_row['ino']}, error={e}", exc_info=True)
            # Don't release claim - timeout will trigger retry
            self.stats['errors'] += 1
        
        except Exception as e:
            logger.error(f"Unexpected error ino={inode_row['ino']}, error={e}", exc_info=True)
            self.release_claim(inode_row)
            self.stats['errors'] += 1
        
        finally:
            # Cleanup temp file
            if temp_file_path and temp_file_path.exists():
                temp_file_path.unlink(missing_ok=True)
    
    # ========================================
    # PHASE 1: ANALYSIS FUNCTIONS
    # ========================================
    
    def analyze_inode(self, work_unit: dict) -> dict:
        """Analyze an inode and create execution plan."""
        inode_row = work_unit['inode_row']
        paths = work_unit['paths']
        source_path = Path(paths[0])  # Use first path for analysis
        
        fs_type = inode_row.get('fs_type')
        if not fs_type:
            fs_type = strategies.detect_fs_type(source_path)
            if not fs_type:
                return {'action': 'skip', 'reason': 'Cannot detect fs_type'}
        
        # Strategy dispatch
        if fs_type == 'f':
            return self.analyze_file(work_unit, source_path)
        elif fs_type == 'd':
            return self.analyze_directory(work_unit)
        elif fs_type == 'l':
            return self.analyze_symlink(work_unit, source_path)
        elif fs_type in ['b', 'c', 'p', 's']:
            return self.analyze_special(work_unit, fs_type)
        else:
            return {'action': 'skip', 'reason': f'Unknown fs_type: {fs_type}'}
    
    def analyze_file(self, work_unit: dict, source_path: Path) -> dict:
        """Analyze regular file - copy to temp and hash."""
        inode_row = work_unit['inode_row']
        size = inode_row['size']
        
        # Empty file special case
        if size == 0:
            return {
                'action': 'handle_empty_file',
                'blobid': strategies.EMPTY_FILE_HASH,
                'paths_to_link': work_unit['paths'],
                'inode_row': inode_row,
                'mime_type': 'application/x-empty'
            }
        
        # Copy to temp and hash
        temp_path = self.get_temp_path(inode_row)
        try:
            strategies.copy_file_to_temp(source_path, temp_path, size)
            hash_value = strategies.hash_file(temp_path)
        except Exception as e:
            if temp_path.exists():
                temp_path.unlink()
            raise AnalysisError(f"Failed to copy/hash: {e}")
        
        # Detect MIME type
        mime_type = strategies.detect_mime_type(self.mime_detector, source_path)
        
        # Check if blob already exists (deduplication)
        blob_exists = self.check_blob_exists(hash_value)
        
        if blob_exists:
            temp_path.unlink()  # No longer needed
            return {
                'action': 'link_existing_file',
                'blobid': hash_value,
                'paths_to_link': work_unit['paths'],
                'inode_row': inode_row,
                'mime_type': mime_type
            }
        else:
            return {
                'action': 'copy_new_file',
                'blobid': hash_value,
                'paths_to_link': work_unit['paths'],
                'temp_file_path': temp_path,
                'inode_row': inode_row,
                'mime_type': mime_type
            }
    
    def analyze_directory(self, work_unit: dict) -> dict:
        """Analyze directory."""
        return {
            'action': 'create_directory',
            'paths': work_unit['paths'],
            'inode_row': work_unit['inode_row']
        }
    
    def analyze_symlink(self, work_unit: dict, source_path: Path) -> dict:
        """Analyze symlink."""
        try:
            target = strategies.read_symlink_target(source_path)
        except Exception as e:
            raise AnalysisError(f"Failed to read symlink: {e}")
        
        return {
            'action': 'create_symlink',
            'target': target,
            'paths': work_unit['paths'],
            'inode_row': work_unit['inode_row']
        }
    
    def analyze_special(self, work_unit: dict, fs_type: str) -> dict:
        """Analyze special file (block/char device, pipe, socket)."""
        return {
            'action': 'record_special',
            'fs_type': fs_type,
            'inode_row': work_unit['inode_row']
        }
    
    def get_temp_path(self, inode_row: dict) -> Path:
        """Get temporary file path for an inode."""
        size = inode_row['size']
        ino = inode_row['ino']
        
        if size < 100 * 1024 * 1024:  # < 100MB: use per-worker tmpfs
            base = self.RAMDISK / self.worker_id
        else:  # >= 100MB: use NVME
            base = self.NVME_TMP
        
        base.mkdir(parents=True, exist_ok=True)
        return base / f"{ino}.tmp"
    
    def check_blob_exists(self, hash_value: str) -> bool:
        """Check if a blob already exists."""
        with self.conn.cursor() as cur:
            cur.execute("SELECT 1 FROM blobs WHERE blobid = %s", (hash_value,))
            return cur.fetchone() is not None
    
    # ========================================
    # PHASE 2: EXECUTION FUNCTIONS
    # ========================================
    
    def execute_plan(self, plan: dict):
        """Execute plan - filesystem first, then database transaction."""
        
        by_hash_created_by_this_worker = False
        
        # ========================================
        # STEP 1: FILESYSTEM (outside transaction)
        # ========================================
        try:
            if plan['action'] == 'copy_new_file':
                logger.info(f"Calling execute_copy_new_file_fs for ino={plan['inode_row']['ino']}")
                by_hash_created_by_this_worker = self.execute_copy_new_file_fs(plan)
                logger.info(f"execute_copy_new_file_fs returned: {by_hash_created_by_this_worker}")
            
            elif plan['action'] == 'link_existing_file':
                self.execute_link_existing_file_fs(plan)
            
            elif plan['action'] == 'handle_empty_file':
                self.execute_empty_file_fs(plan)
            
            elif plan['action'] == 'create_directory':
                self.execute_directory_fs(plan)
            
            elif plan['action'] == 'create_symlink':
                self.execute_symlink_fs(plan)
            
            elif plan['action'] == 'record_special':
                pass  # No filesystem work
        
        except (OSError, PermissionError) as e:
            # Filesystem failure - release claim for retry
            self.release_claim(plan['inode_row'])
            raise ExecutionError(f"Filesystem failed: {e}")
        
        # ========================================
        # STEP 2: DATABASE (atomic transaction)
        # ========================================
        try:
            logger.info(f"Starting DB transaction for action={plan['action']}, ino={plan['inode_row']['ino']}")
            with self.conn.transaction():
                if plan['action'] in ['copy_new_file', 'link_existing_file', 'handle_empty_file']:
                    self.update_db_for_file(
                        plan['inode_row'],
                        plan['blobid'],
                        by_hash_created_by_this_worker,
                        len(plan['paths_to_link']),
                        plan.get('mime_type')
                    )
                
                elif plan['action'] == 'create_directory':
                    self.update_db_for_directory(plan['inode_row'])
                
                elif plan['action'] == 'create_symlink':
                    self.update_db_for_symlink(plan['inode_row'])
                
                elif plan['action'] == 'record_special':
                    self.update_db_for_special(plan['inode_row'], plan['fs_type'])
            
            # Explicit commit (transaction context should auto-commit, but being explicit)
            self.conn.commit()
            logger.info(f"DB transaction committed for ino={plan['inode_row']['ino']}")
        
        except Exception as e:
            # DB failure - filesystem is correct, claim stays set
            # Next run will fix DB state
            logger.error(f"DB transaction failed: {e}", exc_info=True)
            raise ExecutionError(f"Database failed: {e}")
        
        # Update stats
        self.update_stats(plan, by_hash_created_by_this_worker)
    
    def execute_copy_new_file_fs(self, plan: dict) -> bool:
        """Filesystem operations for new file. Returns True if we created by-hash."""
        hash_val = plan['blobid']
        hash_path = self.BY_HASH_ROOT / hash_val[:2] / hash_val[2:4] / hash_val
        temp_file = plan['temp_file_path']
        
        logger.info(f"execute_copy_new_file_fs: temp={temp_file}, exists={temp_file.exists()}, hash_path={hash_path}")
        
        try:
            hash_path.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
            logger.info(f"Created parent dir: {hash_path.parent}")
        except Exception as e:
            logger.error(f"Failed to create parent dir {hash_path.parent}: {e}")
            raise
        
        try:
            # Atomic move
            shutil.move(str(temp_file), str(hash_path))
            by_hash_created = True
            logger.info(f"Created by-hash file: {hash_path}")
        except FileExistsError:
            # RACE: Another worker created it between analysis and now
            temp_file.unlink()
            by_hash_created = False
            logger.info(f"By-hash already exists: {hash_path}")
        except Exception as e:
            logger.error(f"Failed to move {temp_file} to {hash_path}: {e}")
            raise
        
        # Create hardlinks (idempotent)
        strategies.create_hardlinks_idempotent(
            hash_path, 
            plan['paths_to_link'],
            self.ARCHIVE_ROOT
        )
        
        return by_hash_created
    
    def execute_link_existing_file_fs(self, plan: dict):
        """Filesystem operations for deduplicated file."""
        hash_val = plan['blobid']
        hash_path = self.BY_HASH_ROOT / hash_val[:2] / hash_val[2:4] / hash_val
        
        strategies.create_hardlinks_idempotent(
            hash_path,
            plan['paths_to_link'],
            self.ARCHIVE_ROOT
        )
    
    def execute_empty_file_fs(self, plan: dict):
        """Filesystem operations for empty file."""
        hash_path = self.BY_HASH_ROOT / plan['blobid'][:2] / plan['blobid'][2:4] / plan['blobid']
        hash_path.parent.mkdir(parents=True, exist_ok=True)
        hash_path.touch(exist_ok=True)
        
        strategies.create_hardlinks_idempotent(
            hash_path,
            plan['paths_to_link'],
            self.ARCHIVE_ROOT
        )
    
    def execute_directory_fs(self, plan: dict):
        """Filesystem operations for directory."""
        for path_str in plan['paths']:
            archive_path = self.ARCHIVE_ROOT / path_str.lstrip('/')
            if not archive_path.exists():
                archive_path.mkdir(parents=True, exist_ok=True, mode=0o755)
                strategies.ensure_directory_ownership(archive_path, self.ARCHIVE_ROOT)
    
    def execute_symlink_fs(self, plan: dict):
        """Filesystem operations for symlink."""
        target = plan['target']
        for path_str in plan['paths']:
            archive_path = self.ARCHIVE_ROOT / path_str.lstrip('/')
            if not archive_path.exists() and not archive_path.is_symlink():
                archive_path.parent.mkdir(parents=True, exist_ok=True)
                try:
                    archive_path.symlink_to(target)
                except FileExistsError:
                    pass  # Race with another worker
    
    # ========================================
    # DATABASE UPDATE FUNCTIONS
    # ========================================
    
    def update_db_for_file(self, inode_row, hash_val, by_hash_created, num_links, mime_type):
        """Single atomic DB transaction for file."""
        with self.conn.cursor() as cur:
            # Update inode
            cur.execute("""
                UPDATE inode
                SET blobid = %s,
                    copied = true,
                    by_hash_created = %s,
                    mime_type = COALESCE(%s, mime_type),
                    processed_at = NOW(),
                    claimed_by = NULL,
                    claimed_at = NULL
                WHERE medium_hash = %s AND ino = %s
            """, (hash_val, by_hash_created, mime_type,
                  inode_row['medium_hash'], inode_row['ino']))
            
            # Update path.blobid for all paths of this inode
            cur.execute("""
                UPDATE path
                SET blobid = %s
                WHERE medium_hash = %s AND ino = %s
            """, (hash_val, inode_row['medium_hash'], inode_row['ino']))
            
            # Upsert blob (atomic increment)
            cur.execute("""
                INSERT INTO blobs (blobid, n_hardlinks)
                VALUES (%s, %s)
                ON CONFLICT (blobid) DO UPDATE
                SET n_hardlinks = blobs.n_hardlinks + EXCLUDED.n_hardlinks
            """, (hash_val, num_links))
    
    def update_db_for_directory(self, inode_row):
        """Update DB for directory."""
        with self.conn.cursor() as cur:
            cur.execute("""
                UPDATE inode
                SET copied = true,
                    by_hash_created = true,
                    mime_type = 'inode/directory',
                    processed_at = NOW(),
                    claimed_by = NULL,
                    claimed_at = NULL
                WHERE medium_hash = %s AND ino = %s
            """, (inode_row['medium_hash'], inode_row['ino']))
    
    def update_db_for_symlink(self, inode_row):
        """Update DB for symlink."""
        with self.conn.cursor() as cur:
            cur.execute("""
                UPDATE inode
                SET copied = true,
                    by_hash_created = true,
                    mime_type = 'inode/symlink',
                    processed_at = NOW(),
                    claimed_by = NULL,
                    claimed_at = NULL
                WHERE medium_hash = %s AND ino = %s
            """, (inode_row['medium_hash'], inode_row['ino']))
    
    def update_db_for_special(self, inode_row, fs_type):
        """Update DB for special file."""
        mime_type = {
            'b': 'inode/blockdevice',
            'c': 'inode/chardevice',
            'p': 'inode/fifo',
            's': 'inode/socket'
        }.get(fs_type, 'inode/special')
        
        with self.conn.cursor() as cur:
            cur.execute("""
                UPDATE inode
                SET copied = true,
                    by_hash_created = true,
                    mime_type = %s,
                    processed_at = NOW(),
                    claimed_by = NULL,
                    claimed_at = NULL
                WHERE medium_hash = %s AND ino = %s
            """, (mime_type,
                  inode_row['medium_hash'], inode_row['ino']))
    
    def update_stats(self, plan: dict, by_hash_created: bool):
        """Update worker statistics."""
        if plan['action'] in ['copy_new_file', 'link_existing_file', 'handle_empty_file']:
            if by_hash_created:
                self.stats['copied'] += 1
            else:
                self.stats['deduped'] += 1
            self.stats['bytes'] += plan['inode_row'].get('size', 0)


@app.command()
def main(
    limit: int = typer.Option(0, "--limit", "-l", help="Process at most N inodes (0 = unlimited)"),
    dry_run: bool = typer.Option(False, "--dry-run", help="Log actions without making changes"),
    sample_size: int = typer.Option(1000, "--sample-size", help="TABLESAMPLE size for work selection"),
    worker_id: str = typer.Option(None, "--worker-id", help="Worker ID (defaults to w{pid})"),
    medium_hashes: str = typer.Option(None, "--medium-hashes", help="Comma-separated medium_hashes to restrict worker to"),
):
    """
    NTT Copy Worker - Deduplicates and archives filesystem content.
    
    Must run as root/sudo: sudo -E ntt-copier.py [options]
    """
    
    # Setup logging
    logger.remove()  # Remove default handler
    logger.add(sys.stderr, level="INFO")
    
    # Set PostgreSQL user to original user when running under sudo
    if 'SUDO_USER' in os.environ:
        os.environ['PGUSER'] = os.environ['SUDO_USER']
    
    # Get database URL
    db_url = os.environ.get('NTT_DB_URL', 'postgresql:///copyjob')
    if os.geteuid() == 0 and 'SUDO_USER' in os.environ:
        if '://' in db_url and '@' not in db_url:
            db_url = db_url.replace(':///', f"://{os.environ['SUDO_USER']}@localhost/")
    
    logger.info("NTT Copier starting", 
                limit=limit, 
                dry_run=dry_run,
                sample_size=sample_size)
    
    # Single worker mode (this process is one worker)
    # Use provided worker_id or default to w{pid}
    if worker_id is None:
        worker_id = f'w{os.getpid()}'
    
    # Parse medium_hashes if provided
    medium_hash_list = None
    if medium_hashes:
        medium_hash_list = [h.strip() for h in medium_hashes.split(',')]
        logger.info(f"Restricting to {len(medium_hash_list)} media")
    
    worker = CopyWorker(
        worker_id=worker_id,
        db_url=db_url,
        limit=limit,
        dry_run=dry_run,
        sample_size=sample_size,
        medium_hashes=medium_hash_list
    )
    worker.run()


if __name__ == "__main__":
    app()
