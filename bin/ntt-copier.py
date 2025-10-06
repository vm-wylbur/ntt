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
#     "bitmath",
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
import bitmath
import shutil
import signal
import subprocess
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


def validate_destination_filesystem():
    """
    Validate /data/cold filesystem before starting worker.

    Requirements:
    1. Filesystem must be 'coldpool'
    2. Available space must be > 5TB
    3. Mount point must be /data/cold

    Raises typer.Exit(1) if validation fails.
    """
    try:
        # Run df -h and parse output
        result = subprocess.run(
            ['df', '-h', '/data/cold'],
            capture_output=True,
            text=True,
            check=True
        )

        # Parse df output (skip header line)
        lines = result.stdout.strip().split('\n')
        if len(lines) < 2:
            logger.error("df command returned unexpected output")
            raise typer.Exit(code=1)

        # Parse the data line
        # Format: Filesystem Size Used Avail Use% Mounted on
        parts = lines[1].split()
        if len(parts) < 6:
            logger.error(f"df output malformed: {lines[1]}")
            raise typer.Exit(code=1)

        filesystem = parts[0]
        avail_str = parts[3]
        mounted_on = parts[5]

        # Validation 1: Filesystem must be 'coldpool'
        if filesystem != 'coldpool':
            logger.error(f"Wrong filesystem: expected 'coldpool', got '{filesystem}'")
            raise typer.Exit(code=1)

        # Validation 2: Available space > 5TB
        try:
            # df -h uses shorthand: K, M, G, T, P (need to convert to bitmath format)
            # bitmath expects: KiB, MiB, GiB, TiB, PiB
            size_normalized = avail_str
            if avail_str[-1] in 'KMGTP' and not avail_str.endswith('iB'):
                size_normalized = avail_str[:-1] + avail_str[-1] + 'iB'

            avail_size = bitmath.parse_string(size_normalized)
            avail_tb = float(avail_size.TB)  # Convert to TB

            if avail_tb <= 5.0:
                logger.error(f"Insufficient space: {avail_str} available (need > 5T)")
                raise typer.Exit(code=1)
        except (ValueError, AttributeError) as e:
            logger.error(f"Could not parse available space '{avail_str}': {e}")
            raise typer.Exit(code=1)

        # Validation 3: Mount point must be /data/cold
        if mounted_on != '/data/cold':
            logger.error(f"Wrong mount point: expected '/data/cold', got '{mounted_on}'")
            raise typer.Exit(code=1)

        logger.info(f"Filesystem validation passed: {filesystem} with {avail_str} available at {mounted_on}")

    except subprocess.CalledProcessError as e:
        logger.error(f"df command failed: {e}")
        raise typer.Exit(code=1)
    except typer.Exit:
        raise  # Re-raise typer.Exit as-is
    except Exception as e:
        logger.error(f"Filesystem validation failed: {e}")
        raise typer.Exit(code=1)


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

        # Validate destination filesystem before doing anything
        validate_destination_filesystem()

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

        # Force index usage for all queries - PostgreSQL planner chooses seqscan incorrectly
        with self.conn.cursor() as cur:
            cur.execute("SET enable_seqscan = off;")
        self.conn.commit()

        # Verify setting applied
        with self.conn.cursor() as cur:
            cur.execute("SHOW enable_seqscan;")
            result = cur.fetchone()
            logger.info(f"Worker {self.worker_id} enable_seqscan setting: {result}")

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

        # Track which media we've already ensured are mounted (cache to avoid repeated checks)
        self._mounted_media = set()

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

            # Ensure medium is mounted before processing
            medium_hash = work_unit['inode_row']['medium_hash']
            try:
                self.ensure_medium_mounted(medium_hash)
            except Exception as e:
                logger.error(f"Failed to ensure mount for {medium_hash}: {e}")
                self.release_claim(work_unit['inode_row'], error_msg=f"Mount failed: {str(e)[:100]}")
                self.stats['errors'] += 1
                continue

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
                    SELECT 1 FROM inode i
                    WHERE i.copied = false
                      AND i.claimed_by IS NULL
                      AND i.medium_hash = ANY(%s)
                      AND EXISTS (
                        SELECT 1 FROM path p
                        WHERE (p.medium_hash, p.ino) = (i.medium_hash, i.ino)
                          AND p.exclude_reason IS NULL
                      )
                    LIMIT 1
                )
            """, (self.medium_hashes,))
            result = cur.fetchone()
            work_exists = result['exists'] if result else False
            return not work_exists
    
    def get_queue_depth(self) -> int:
        """Get fast queue depth from materialized counter (respects medium_hashes filter).
        Reads from queue_stats table maintained by triggers - instant lookup."""
        with self.conn.cursor() as cur:
            if self.medium_hashes:
                cur.execute("""
                    SELECT COALESCE(SUM(unclaimed_count), 0)::int as count
                    FROM queue_stats
                    WHERE medium_hash = ANY(%s)
                """, (self.medium_hashes,))
            else:
                cur.execute("""
                    SELECT COALESCE(SUM(unclaimed_count), 0)::int as count
                    FROM queue_stats qs
                    JOIN medium m ON qs.medium_hash = m.medium_hash
                    WHERE m.health = 'ok'
                """)
            return cur.fetchone()['count']

    def get_image_path(self, medium_hash: str) -> Optional[str]:
        """Get image path for a medium from database."""
        with self.conn.cursor() as cur:
            cur.execute("""
                SELECT image_path
                FROM medium
                WHERE medium_hash = %s
            """, (medium_hash,))
            result = cur.fetchone()
            return result['image_path'] if result else None

    def ensure_medium_mounted(self, medium_hash: str) -> str:
        """Ensure medium is mounted, mount if needed.

        Returns mount path or raises exception if cannot mount.
        Uses cache to avoid repeated filesystem checks for same medium.
        """
        # Check cache first
        if medium_hash in self._mounted_media:
            return f"/mnt/ntt/{medium_hash}"

        mount_point = f"/mnt/ntt/{medium_hash}"

        # Check if already mounted using findmnt
        result = subprocess.run(['findmnt', mount_point],
                              capture_output=True, text=True)

        if result.returncode == 0:
            # Already mounted
            self._mounted_media.add(medium_hash)
            logger.info(f"Medium {medium_hash} already mounted at {mount_point}")
            return mount_point

        # Not mounted - need to mount it
        logger.info(f"Medium {medium_hash} not mounted, attempting to mount...")

        # Get image path from database
        image_path = self.get_image_path(medium_hash)
        if not image_path:
            raise Exception(f"No image_path in database for medium {medium_hash}")

        if not Path(image_path).exists():
            raise Exception(f"Image file not found: {image_path}")

        # Mount via helper (requires sudo)
        try:
            subprocess.run(['sudo', 'ntt-mount-helper', 'mount',
                          medium_hash, image_path],
                         check=True, capture_output=True, text=True)

            self._mounted_media.add(medium_hash)
            logger.info(f"Successfully mounted {medium_hash} at {mount_point}")
            return mount_point

        except subprocess.CalledProcessError as e:
            logger.error(f"Failed to mount {medium_hash}: {e.stderr}")
            raise Exception(f"Mount failed for {medium_hash}: {e.stderr}")

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
        if self._queue_depth_check_counter >= 1000 or self._queue_depth_cache is None:
            self._queue_depth_cache = self.get_queue_depth()
            self._queue_depth_check_counter = 0
            logger.debug(f"Queue depth: {self._queue_depth_cache}")

        # Adaptive query selection based on queue depth
        if self._queue_depth_cache <= 5000:
            # Small queue: use direct query with ORDER BY RANDOM()
            # Fast for small tables (~1-2ms), reliable hit rate
            claim_query = f"""
                WITH candidate AS (
                    SELECT i.medium_hash, i.ino
                    FROM inode i
                    WHERE i.copied = false
                      AND i.claimed_by IS NULL
                      {medium_filter}
                      AND EXISTS (
                        SELECT 1 FROM path p
                        WHERE (p.medium_hash, p.ino) = (i.medium_hash, i.ino)
                          AND p.exclude_reason IS NULL
                      )
                    ORDER BY RANDOM()
                    LIMIT 1
                    FOR UPDATE OF i SKIP LOCKED
                ),
                claimed AS (
                    UPDATE inode i
                    SET claimed_by = %(worker_id)s, claimed_at = NOW()
                    FROM candidate c
                    WHERE (i.medium_hash, i.ino) = (c.medium_hash, c.ino)
                    RETURNING i.*
                )
                SELECT c.*,
                       (SELECT array_agg(p.path)
                        FROM path p
                        WHERE (p.medium_hash, p.ino) = (c.medium_hash, c.ino)
                          AND p.exclude_reason IS NULL) as paths
                FROM claimed c;
            """
        else:
            # Large queue: use TABLESAMPLE for performance
            # TABLESAMPLE hybrid: sample from entire table FIRST, then filter
            # This is fast because TABLESAMPLE operates at block level before any filtering
            claim_query = f"""
                WITH sampled AS (
                    SELECT i.medium_hash, i.ino
                    FROM inode i
                    TABLESAMPLE SYSTEM_ROWS(%(sample_size)s)
                    WHERE i.copied = false
                      AND i.claimed_by IS NULL
                      AND EXISTS (
                        SELECT 1 FROM path p
                        WHERE (p.medium_hash, p.ino) = (i.medium_hash, i.ino)
                          AND p.exclude_reason IS NULL
                      )
                    ORDER BY RANDOM()
                    LIMIT 100
                ),
                filtered AS (
                    SELECT medium_hash, ino
                    FROM sampled
                    {medium_filter.replace('AND', 'WHERE') if medium_filter else ''}
                    LIMIT 1
                ),
                locked_row AS (
                    SELECT f.medium_hash, f.ino
                    FROM filtered f
                    JOIN inode i ON (i.medium_hash, i.ino) = (f.medium_hash, f.ino)
                    FOR UPDATE OF i SKIP LOCKED
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
                        WHERE (p.medium_hash, p.ino) = (c.medium_hash, c.ino)
                          AND p.exclude_reason IS NULL) as paths
                FROM claimed c;
            """

        params = {
            'worker_id': self.worker_id,
            'sample_size': self.sample_size
        }
        if self.medium_hashes:
            params['medium_hashes'] = self.medium_hashes

        import time
        t0 = time.time()

        with self.conn.cursor() as cur:
            t1 = time.time()
            cur.execute(claim_query, params)
            t2 = time.time()
            row = cur.fetchone()
            t3 = time.time()

        self.conn.commit()  # Auto-commit the claim
        t4 = time.time()

        if (t4 - t0) > 0.05:  # Log if > 50ms
            logger.warning(f"Slow claim: total={((t4-t0)*1000):.1f}ms execute={((t2-t1)*1000):.1f}ms fetch={((t3-t2)*1000):.1f}ms commit={((t4-t3)*1000):.1f}ms")

        if not row:
            logger.debug("No work claimed (either no candidates or claim race lost)")
            return None

        logger.debug(f"Claimed inode ino={row['ino']}, paths={len(row.get('paths', []))}")

        inode_row = dict(row)
        paths = inode_row.pop('paths', [])

        return {'inode_row': inode_row, 'paths': paths}
    
    def release_claim(self, inode_row: dict, error_msg: str = None):
        """Release claim on an inode after error.

        If error_msg is provided, tracks failure in errors array.
        After 3 consecutive failures with same error, marks inode as EXCLUDED.
        """
        medium_hash = inode_row['medium_hash']
        ino = inode_row['ino']

        if error_msg:
            # Track this error in the errors array
            with self.conn.cursor() as cur:
                cur.execute("""
                    UPDATE inode
                    SET errors = array_append(errors, %s)
                    WHERE medium_hash = %s AND ino = %s
                    RETURNING array_length(errors, 1) as error_count, errors
                """, (error_msg, medium_hash, ino))
                result = cur.fetchone()
                self.conn.commit()

                if result:
                    error_count = result['error_count']
                    errors = result['errors']

                    # Check if last 3 errors are identical (persistent failure)
                    if error_count >= 3 and len(set(errors[-3:])) == 1:
                        logger.warning(f"Persistent failure detected for ino={ino}: {error_msg}")
                        logger.warning(f"Marking as EXCLUDED after {error_count} failures")
                        self.mark_inode_excluded(inode_row, reason=f"persistent_failure: {error_msg}")
                        return

                    logger.info(f"Released claim on ino={ino} after error (attempt {error_count}): {error_msg}")

        # Normal release - clear claim
        with self.conn.cursor() as cur:
            cur.execute("""
                UPDATE inode
                SET claimed_by = NULL, claimed_at = NULL
                WHERE medium_hash = %s AND ino = %s
                  AND claimed_by = %s
            """, (medium_hash, ino, self.worker_id))
        self.conn.commit()

        if not error_msg:
            logger.debug(f"Released claim on ino={ino}")

    def mark_path_excluded(self, path: str, medium_hash: str, ino: int, reason: str):
        """Mark a specific path as excluded."""
        with self.conn.cursor() as cur:
            cur.execute("""
                UPDATE path
                SET exclude_reason = %s
                WHERE medium_hash = %s AND ino = %s AND path = %s
            """, (reason, medium_hash, ino, path))
        self.conn.commit()
        logger.debug(f"Marked path as excluded: {path}, reason={reason}")

    def check_all_paths_excluded(self, medium_hash: str, ino: int) -> bool:
        """Check if all paths for an inode are excluded."""
        with self.conn.cursor() as cur:
            cur.execute("""
                SELECT NOT EXISTS (
                    SELECT 1 FROM path
                    WHERE medium_hash = %s AND ino = %s
                      AND exclude_reason IS NULL
                ) as all_excluded
            """, (medium_hash, ino))
            return cur.fetchone()['all_excluded']

    def mark_inode_excluded(self, inode_row: dict, reason: str = None):
        """Mark inode as copied with EXCLUDED flag when all paths are excluded."""
        claimed_by = f'EXCLUDED: {reason}' if reason else 'EXCLUDED'
        with self.conn.cursor() as cur:
            cur.execute("""
                UPDATE inode
                SET copied = true, claimed_by = %s, claimed_at = NOW()
                WHERE medium_hash = %s AND ino = %s
            """, (claimed_by, inode_row['medium_hash'], inode_row['ino']))
        self.conn.commit()
        logger.info(f"Marked inode as EXCLUDED: ino={inode_row['ino']}, reason={reason or 'all_paths_excluded'}")
    
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

            # Check if it's a file-not-found error
            error_str = str(e)
            if 'No such file or directory' in error_str or '[Errno 2]' in error_str:
                # Extract the path from the first available path
                if work_unit['paths']:
                    failed_path = work_unit['paths'][0]
                    self.mark_path_excluded(failed_path, inode_row['medium_hash'],
                                          inode_row['ino'], 'file_not_found')

                    # Check if all paths are now excluded
                    if self.check_all_paths_excluded(inode_row['medium_hash'], inode_row['ino']):
                        self.mark_inode_excluded(inode_row)
                        logger.info(f"All paths excluded for ino={inode_row['ino']}, marked as EXCLUDED")
                        return

            # Release with error tracking
            self.release_claim(inode_row, error_msg=f"AnalysisError: {str(e)[:100]}")
            self.stats['errors'] += 1

        except ExecutionError as e:
            logger.error(f"Execution failed ino={inode_row['ino']}, error={e}", exc_info=True)

            # Check if it's a file-not-found error (e.g., missing by-hash file)
            error_str = str(e)
            if 'No such file or directory' in error_str or '[Errno 2]' in error_str:
                # This is likely a missing by-hash file, which means data integrity issue
                # Release with error tracking for persistent failures
                self.release_claim(inode_row, error_msg=f"ExecutionError: missing by-hash file")
            else:
                # Other execution errors - release with tracking
                self.release_claim(inode_row, error_msg=f"ExecutionError: {str(e)[:100]}")

            self.stats['errors'] += 1

        except Exception as e:
            logger.error(f"Unexpected error ino={inode_row['ino']}, error={e}", exc_info=True)
            # Release with error tracking
            error_type = type(e).__name__
            self.release_claim(inode_row, error_msg=f"{error_type}: {str(e)[:100]}")
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
        source_path = strategies.sanitize_path(paths[0])  # Use first path for analysis
        
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
        for path_bytes in plan['paths']:
            # Decode bytes to str (paths are stored as bytea in database)
            path_str = path_bytes.decode('utf-8', errors='replace') if isinstance(path_bytes, bytes) else path_bytes
            archive_path = self.ARCHIVE_ROOT / path_str.lstrip('/')
            if not archive_path.exists():
                archive_path.mkdir(parents=True, exist_ok=True, mode=0o755)
                strategies.ensure_directory_ownership(archive_path, self.ARCHIVE_ROOT)
    
    def execute_symlink_fs(self, plan: dict):
        """Filesystem operations for symlink."""
        target = plan['target']
        for path_bytes in plan['paths']:
            # Decode bytes to str (paths are stored as bytea in database)
            path_str = path_bytes.decode('utf-8', errors='replace') if isinstance(path_bytes, bytes) else path_bytes
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
