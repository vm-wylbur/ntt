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

# Import diagnostic service
from ntt_copier_diagnostics import DiagnosticService

app = typer.Typer()


class AnalysisError(Exception):
    """Raised when analysis phase fails."""
    pass


class ExecutionError(Exception):
    """Raised when execution phase fails."""
    pass


# SHA-256 hash validation
HEX_CHARS = set('0123456789abcdef')

def is_sha256_hash_lowercase(s):
    """Validate SHA-256 hash string (64 lowercase hex chars)"""
    try:
        is_valid = len(s) == 64 and all(c in HEX_CHARS for c in s)
        if not is_valid and isinstance(s, str):
            logger.error(f"MALFORMED BLOB_ID: {s[:40]}...")
        return is_valid
    except (TypeError, AttributeError):
        return False


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

    def __init__(self, worker_id: str, db_url: str, medium_hash: str, limit: int = 0,
                 dry_run: bool = False, batch_size: int = 100):
        self.worker_id = worker_id
        self.db_url = db_url
        self.medium_hash = medium_hash
        self.limit = limit
        self.dry_run = dry_run
        self.batch_size = batch_size
        self.shutdown = False
        self.processed_count = 0

        # Validate medium_hash is provided
        if not medium_hash:
            raise ValueError("medium_hash is required")

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

        # Calculate max_id for this medium (used for random probe strategy)
        with self.conn.cursor() as cur:
            cur.execute("""
                SELECT MAX(id) FROM inode WHERE medium_hash = %s
            """, (self.medium_hash,))
            result = cur.fetchone()
            self.max_id = result['max'] if result and result['max'] else 0

        logger.info(f"Worker {self.worker_id} max_id for medium {self.medium_hash}: {self.max_id}")

        # Setup signal handlers
        signal.signal(signal.SIGINT, self._signal_handler)
        signal.signal(signal.SIGTERM, self._signal_handler)

        logger.info(f"Worker {self.worker_id} initialized",
                   limit=self.limit, dry_run=self.dry_run, batch_size=self.batch_size)

        # Track which media we've already ensured are mounted (cache to avoid repeated checks)
        self._mounted_media = set()

        # Setup diagnostic service for intelligent retry/error handling
        self.diagnostics = DiagnosticService(
            db_conn=self.conn,
            medium_hash=self.medium_hash,
            worker_id=self.worker_id
        )

    def _signal_handler(self, signum, frame):
        """Handle shutdown signals gracefully."""
        logger.info(f"Received signal {signum}, shutting down...")
        self.shutdown = True

    def run(self):
        """Main worker loop - batch processing mode."""
        logger.info(f"Worker {self.worker_id} starting (batch mode, batch_size={self.batch_size})")

        # Ensure medium is mounted before starting
        try:
            self.ensure_medium_mounted(self.medium_hash)
        except Exception as e:
            logger.error(f"Failed to ensure mount for {self.medium_hash}: {e}")
            raise

        # One-time startup check for inodes that exceeded max retries
        self.mark_max_retries_exceeded()

        consecutive_no_work = 0
        max_no_work_attempts = 3  # Exit after 3 consecutive empty batches

        while not self.shutdown:
            # Process one batch
            batch_processed = self.process_batch()

            if not batch_processed:
                consecutive_no_work += 1

                if consecutive_no_work >= max_no_work_attempts:
                    logger.info(f"No work found after {max_no_work_attempts} attempts, exiting")
                    break

                logger.debug("No work available, waiting...")
                time.sleep(0.1)  # 100ms between batch attempts
                continue

            consecutive_no_work = 0  # Reset on successful batch

            # Check limit (limit is in inodes processed, not batches)
            if self.limit > 0 and self.processed_count >= self.limit:
                logger.info(f"Limit reached: {self.limit}")
                break

        logger.info(f"Worker {self.worker_id} finished", stats=self.stats)
        self.conn.close()

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
        # First try the direct path
        result = subprocess.run(['findmnt', mount_point],
                              capture_output=True, text=True)

        if result.returncode == 0:
            # Already mounted
            self._mounted_media.add(medium_hash)
            logger.info(f"Medium {medium_hash} already mounted at {mount_point}")
            return mount_point

        # If mount_point is a symlink, check if the target is mounted
        if Path(mount_point).is_symlink():
            real_path = str(Path(mount_point).resolve())
            result = subprocess.run(['findmnt', real_path],
                                  capture_output=True, text=True)

            if result.returncode == 0:
                # Target is mounted
                self._mounted_media.add(medium_hash)
                logger.info(f"Medium {medium_hash} symlink target already mounted at {real_path}")
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
            subprocess.run(['sudo', '/home/pball/projects/ntt/bin/ntt-mount-helper', 'mount',
                          medium_hash, image_path],
                         check=True, capture_output=True, text=True)

            self._mounted_media.add(medium_hash)
            logger.info(f"Successfully mounted {medium_hash} at {mount_point}")
            return mount_point

        except subprocess.CalledProcessError as e:
            logger.error(f"Failed to mount {medium_hash}: {e.stderr}")
            raise Exception(f"Mount failed for {medium_hash}: {e.stderr}")

    def mark_max_retries_exceeded(self):
        """
        One-time startup check: mark inodes with >= 5 errors as permanently failed.

        This prevents them from being claimed by workers. Runs once at startup,
        not on every batch (that would scan millions of rows constantly).
        """
        logger.info(f"Checking for inodes with max retries exceeded...")

        with self.conn.cursor() as cur:
            cur.execute("""
                UPDATE inode
                SET copied = true, claimed_by = 'MAX_RETRIES_EXCEEDED'
                WHERE medium_hash = %s
                  AND copied = false
                  AND claimed_by IS NULL
                  AND array_length(errors, 1) >= 5
                RETURNING id, ino, errors
            """, (self.medium_hash,))

            exceeded = cur.fetchall()
            if exceeded:
                for row in exceeded:
                    last_error = row['errors'][-1] if row['errors'] else 'unknown'
                    logger.error(f"PERMANENTLY FAILED ino={row['ino']} after {len(row['errors'])} errors: {last_error}")
                logger.info(f"Marked {len(exceeded)} inodes as MAX_RETRIES_EXCEEDED")
            else:
                logger.info(f"No inodes exceeded max retries")

            self.conn.commit()

    def fetch_and_claim_batch(self) -> Optional[list[dict]]:
        """
        Atomically claim a batch of inodes using random ID probe strategy.

        Tries 3 random probes (id >= random_start), then falls back to sequential scan.
        This avoids partition sampling issues with TABLESAMPLE on partitioned tables.

        Returns:
            List of claimed inode dicts, or None if no work available
        """
        import random

        # CRITICAL: UPDATE WHERE clause uses composite PK (medium_hash, ino) for partition pruning
        # Using WHERE i.id = c.id would scan ALL partitions (~7000ms)
        # Using WHERE (i.medium_hash, i.ino) = (c.medium_hash, c.ino) enables runtime partition
        # pruning - PostgreSQL can determine target partition from CTE rows (~13ms)
        # Performance: 500x faster (verified 2025-10-07 via EXPLAIN ANALYZE)
        claim_query_with_probe = """
            WITH candidate AS (
                SELECT medium_hash, ino, dev, size, mtime, nlink, id
                FROM inode
                WHERE medium_hash = %s
                  AND copied = false
                  AND claimed_by IS NULL
                  AND id >= %s
                ORDER BY id
                LIMIT %s
                FOR UPDATE SKIP LOCKED
            )
            UPDATE inode i
            SET claimed_by = %s, claimed_at = NOW()
            FROM candidate c
            WHERE (i.medium_hash, i.ino) = (c.medium_hash, c.ino)
            RETURNING i.*;
        """

        # Same partition pruning optimization as above (composite PK for runtime pruning)
        claim_query_sequential = """
            WITH candidate AS (
                SELECT medium_hash, ino, dev, size, mtime, nlink, id
                FROM inode
                WHERE medium_hash = %s
                  AND copied = false
                  AND claimed_by IS NULL
                ORDER BY id
                LIMIT %s
                FOR UPDATE SKIP LOCKED
            )
            UPDATE inode i
            SET claimed_by = %s, claimed_at = NOW()
            FROM candidate c
            WHERE (i.medium_hash, i.ino) = (c.medium_hash, c.ino)
            RETURNING i.*;
        """

        claimed_inodes = None

        t0 = time.time()

        # Try 3 random probes
        for attempt in range(3):
            start_id = random.randint(0, self.max_id) if self.max_id > 0 else 0

            with self.conn.cursor() as cur:
                cur.execute(claim_query_with_probe,
                           (self.medium_hash, start_id, self.batch_size, self.worker_id))
                claimed_inodes = cur.fetchall()

            if claimed_inodes:
                logger.debug(f"Claimed {len(claimed_inodes)} inodes on probe attempt {attempt + 1}")
                break

        # Fallback: sequential scan (cleanup phase)
        if not claimed_inodes:
            with self.conn.cursor() as cur:
                cur.execute(claim_query_sequential,
                           (self.medium_hash, self.batch_size, self.worker_id))
                claimed_inodes = cur.fetchall()

            if claimed_inodes:
                logger.debug(f"Claimed {len(claimed_inodes)} inodes via sequential fallback")

        # NOTE: Do NOT commit here - locks must be held until entire batch is processed
        # Commit happens at end of process_batch() after all updates

        t1 = time.time()
        if claimed_inodes and (t1 - t0) > 0.05:  # Log if > 50ms
            logger.warning(f"Slow batch claim: {((t1-t0)*1000):.1f}ms for {len(claimed_inodes)} inodes")

        if not claimed_inodes:
            logger.debug("No work claimed")
            return None

        return claimed_inodes

    def process_inode_for_batch(self, work_unit: dict) -> Optional[str]:
        """
        Process one inode for batch mode - does filesystem operations, returns blob_id.
        Does NOT update database (that's done in batch).

        Returns blob_id on success, None on failure.
        """
        inode_row = work_unit['inode_row']
        temp_file_path = None

        try:
            # PHASE 1: ANALYSIS
            plan = self.analyze_inode(work_unit)
            temp_file_path = plan.get('temp_file_path')

            if plan['action'] == 'skip':
                logger.debug(f"Skipping inode ino={inode_row['ino']}, reason={plan['reason']}")
                return None

            if self.dry_run:
                logger.debug(f"[DRY-RUN] Would process ino={inode_row['ino']}, action={plan['action']}")
                return None

            # PHASE 2: FILESYSTEM OPERATIONS ONLY (no DB update)
            if plan['action'] == 'copy_new_file':
                self.execute_copy_new_file_fs(plan)
            elif plan['action'] == 'link_existing_file':
                self.execute_link_existing_file_fs(plan)
            elif plan['action'] == 'handle_empty_file':
                self.execute_empty_file_fs(plan)
            elif plan['action'] == 'create_directory':
                self.execute_directory_fs(plan)
            elif plan['action'] == 'create_symlink':
                self.execute_symlink_fs(plan)
            elif plan['action'] == 'record_special':
                pass  # No filesystem work, no blob_id needed

            # Return blob_id (if applicable)
            blob_id = plan.get('blobid')
            if blob_id:
                self.stats['bytes'] += inode_row.get('size', 0)

            return blob_id

        except Exception as e:
            logger.warning(f"Failed to process inode ino={inode_row['ino']}: {e}")
            return None

        finally:
            # Cleanup temp file
            if temp_file_path and temp_file_path.exists():
                temp_file_path.unlink(missing_ok=True)

    def process_batch(self) -> bool:
        """
        Process one batch of inodes with timeout protection.

        Returns True if work was processed, False if no work available.
        """
        import time
        t_batch_start = time.time()

        try:
            with self.conn.cursor() as cur:
                # Set timeout for this transaction (auto-resets after commit/rollback)
                cur.execute("SET LOCAL statement_timeout = '5min'")

                # 1. Claim batch
                claimed_inodes = self.fetch_and_claim_batch()
                if not claimed_inodes:
                    return False  # No work

                logger.info(f"Claimed batch of {len(claimed_inodes)} inodes")

                # Calculate size distribution for this batch
                size_dist = {
                    '<1KB': sum(1 for r in claimed_inodes if r['size'] < 1024),
                    '1-10KB': sum(1 for r in claimed_inodes if 1024 <= r['size'] < 10240),
                    '10-100KB': sum(1 for r in claimed_inodes if 10240 <= r['size'] < 102400),
                    '100KB-1MB': sum(1 for r in claimed_inodes if 102400 <= r['size'] < 1048576),
                    '1-10MB': sum(1 for r in claimed_inodes if 1048576 <= r['size'] < 10485760),
                    '>10MB': sum(1 for r in claimed_inodes if r['size'] >= 10485760),
                }
                total_size_mb = sum(r['size'] for r in claimed_inodes) / 1024 / 1024
                logger.info(f"BATCH SIZE_DIST: {size_dist} total_mb={total_size_mb:.1f}")

                # 2. Get paths for all inodes in batch
                t_fetch_start = time.time()
                inos = [row['ino'] for row in claimed_inodes]
                cur.execute("""
                    SELECT medium_hash, ino, path
                    FROM path
                    WHERE medium_hash = %s AND ino = ANY(%s)
                      AND exclude_reason IS NULL
                """, (self.medium_hash, inos))
                paths_rows = cur.fetchall()
                t_fetch_end = time.time()

                # Group paths by (medium_hash, ino)
                paths_by_inode = {}
                for path_row in paths_rows:
                    key = (path_row['medium_hash'], path_row['ino'])
                    if key not in paths_by_inode:
                        paths_by_inode[key] = []
                    paths_by_inode[key].append(path_row['path'])

                logger.debug(f"Retrieved {len(paths_rows)} paths for {len(paths_by_inode)} inodes")

                # 3. Process each inode (file I/O - if >5min, transaction aborts)
                t_process_start = time.time()
                results_by_inode = {}  # {(medium_hash, ino): blob_id or None}
                action_counts = {}  # Track action types
                size_by_action = {}  # Track bytes per action

                for inode_row in claimed_inodes:
                    key = (inode_row['medium_hash'], inode_row['ino'])
                    paths = paths_by_inode.get(key, [])

                    if not paths:
                        logger.warning(f"No paths found for inode {key}, skipping")
                        results_by_inode[key] = None
                        continue

                    # Create work_unit in old format for process_work_unit
                    work_unit = {
                        'inode_row': dict(inode_row),
                        'paths': paths
                    }

                    try:
                        # Process this inode (copy file, dedupe, etc.) WITHOUT db update
                        # Also get the plan to track action type
                        plan = self.analyze_inode(work_unit)
                        action = plan.get('action', 'unknown')

                        # Track action and size
                        action_counts[action] = action_counts.get(action, 0) + 1
                        size_by_action[action] = size_by_action.get(action, 0) + inode_row.get('size', 0)

                        blob_id = self.process_inode_for_batch(work_unit)
                        results_by_inode[key] = blob_id
                    except Exception as e:
                        error_type = type(e).__name__
                        error_msg = str(e)[:200]  # Truncate long messages
                        logger.error(f"Error processing inode {key}: {error_type}: {error_msg}")

                        # DIAGNOSTIC SERVICE: Track failure and run diagnostics
                        retry_count = self.diagnostics.track_failure(
                            inode_row['medium_hash'],
                            inode_row['ino']
                        )

                        # At checkpoint (retry #10), run full diagnostic analysis
                        if retry_count == 10:
                            findings = self.diagnostics.diagnose_at_checkpoint(
                                inode_row['medium_hash'],
                                inode_row['ino'],
                                e
                            )
                            logger.warning(
                                f"🔍 DIAGNOSTIC CHECKPOINT "
                                f"ino={inode_row['ino']} "
                                f"retry={retry_count} "
                                f"findings={findings}"
                            )

                        # Log when max retries approached (Phase 2 will skip here)
                        if retry_count >= 50:
                            logger.error(
                                f"⚠️  MAX RETRIES REACHED "
                                f"ino={inode_row['ino']} "
                                f"retry={retry_count} "
                                f"(WOULD SKIP IN FUTURE PHASE)"
                            )

                        results_by_inode[key] = {
                            'error_type': error_type,
                            'error_msg': error_msg
                        }
                        action_counts['error'] = action_counts.get('error', 0) + 1

                t_process_end = time.time()

                # 4. Build update arrays
                t_build_start = time.time()
                # For paths table
                medium_hashes, inos_for_paths, blob_ids = [], [], []
                for (mh, ino), result in results_by_inode.items():
                    if is_sha256_hash_lowercase(result):
                        medium_hashes.append(mh)
                        inos_for_paths.append(ino)
                        blob_ids.append(result)

                # For inode table - separate success and failures
                success_ids, success_blob_ids = [], []
                failed_inodes = []  # List of {id, ino, error_type, error_msg}

                for inode_row in claimed_inodes:
                    key = (inode_row['medium_hash'], inode_row['ino'])
                    result = results_by_inode.get(key)

                    if result and isinstance(result, str):
                        # Success: result is blob_id string
                        success_ids.append(inode_row['id'])
                        success_blob_ids.append(result)
                    elif result and isinstance(result, dict):
                        # Failure: result is error info dict
                        failed_inodes.append({
                            'id': inode_row['id'],
                            'ino': inode_row['ino'],
                            'error_type': result['error_type'],
                            'error_msg': result['error_msg']
                        })
                    else:
                        # No result (shouldn't happen, but handle gracefully)
                        failed_inodes.append({
                            'id': inode_row['id'],
                            'ino': inode_row['ino'],
                            'error_type': 'UnknownError',
                            'error_msg': 'No result returned'
                        })

                t_build_end = time.time()

                # 5. Batch update both tables
                t_db_start = time.time()

                if medium_hashes:
                    t0 = time.time()
                    cur.execute("""
                        UPDATE path SET blobid = updates.blob_id
                        FROM unnest(%s::bigint[], %s::text[])
                             AS updates(ino, blob_id)
                        WHERE path.medium_hash = %s
                          AND path.ino = updates.ino
                          AND path.exclude_reason IS NULL
                    """, (inos_for_paths, blob_ids, self.medium_hash))
                    t1 = time.time()
                    logger.info(f"TIMING: UPDATE path: {t1-t0:.3f}s for {len(medium_hashes)} paths")

                if success_ids:
                    t2 = time.time()
                    cur.execute("""
                        UPDATE inode SET copied = true, blobid = updates.blob_id
                        FROM unnest(%s::bigint[], %s::text[]) AS updates(id, blob_id)
                        WHERE inode.id = updates.id
                          AND inode.medium_hash = %s
                    """, (success_ids, success_blob_ids, self.medium_hash))
                    t3 = time.time()
                    logger.info(f"TIMING: UPDATE inode (success): {t3-t2:.3f}s for {len(success_ids)} inodes")

                if failed_inodes:
                    t4 = time.time()
                    # Update each failed inode with error tracking
                    for f in failed_inodes:
                        error_entry = f"{f['error_type']}: {f['error_msg']}"
                        cur.execute("""
                            UPDATE inode
                            SET claimed_by = NULL,
                                claimed_at = NULL,
                                errors = array_append(errors, %s::text)
                            WHERE id = %s
                        """, (error_entry, f['id']))

                        # Log each error clearly
                        logger.warning(f"Failed inode id={f['id']} ino={f['ino']}: {f['error_type']}: {f['error_msg']}")

                    t5 = time.time()
                    logger.info(f"TIMING: UPDATE inode (failed): {t5-t4:.3f}s for {len(failed_inodes)} inodes")

                # 6. Commit
                t6 = time.time()
                self.conn.commit()
                t7 = time.time()
                t_db_total = t7 - t_db_start
                logger.info(f"TIMING: commit: {t7-t6:.3f}s, total_db_ops: {t_db_total:.3f}s")

                t_batch_end = time.time()
                t_batch_total = t_batch_end - t_batch_start

                # Comprehensive batch summary
                logger.info(f"TIMING_BATCH: "
                           f"total={t_batch_total:.3f}s "
                           f"fetch_paths={t_fetch_end-t_fetch_start:.3f}s "
                           f"process_files={t_process_end-t_process_start:.3f}s "
                           f"build_arrays={t_build_end-t_build_start:.3f}s "
                           f"db_ops={t_db_total:.3f}s")

                logger.info(f"BATCH_ACTIONS: {action_counts}")

                # Log size per action in MB
                size_by_action_mb = {k: v/1024/1024 for k, v in size_by_action.items()}
                logger.info(f"BATCH_SIZE_BY_ACTION_MB: {size_by_action_mb}")

                logger.info(f"Completed batch: {len(success_ids)} copied, {len(failed_inodes)} failed")

                # Update stats
                self.stats['copied'] += len(success_ids)
                self.stats['errors'] += len(failed_inodes)
                self.processed_count += len(success_ids)

                return True

        except psycopg.errors.QueryCanceled:
            logger.warning("Batch processing exceeded 5min timeout, transaction aborted")
            self.conn.rollback()
            return False
        except Exception as e:
            logger.error(f"Batch processing error: {e}")
            self.conn.rollback()
            return False

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
        import time
        t0 = time.time()

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
            t1 = time.time()
            strategies.copy_file_to_temp(source_path, temp_path, size)
            t2 = time.time()
            hash_value = strategies.hash_file(temp_path)
            t3 = time.time()
            logger.info(f"TIMING: copy={t2-t1:.3f}s hash={t3-t2:.3f}s size={size}")
        except Exception as e:
            if temp_path.exists():
                temp_path.unlink()
            raise AnalysisError(f"Failed to copy/hash: {e}")

        # Detect MIME type
        t4 = time.time()
        mime_type = strategies.detect_mime_type(self.mime_detector, source_path)
        t5 = time.time()
        logger.info(f"TIMING: mime={t5-t4:.3f}s")

        # Check if blob already exists (deduplication)
        t6 = time.time()
        blob_exists = self.check_blob_exists(hash_value)
        t7 = time.time()
        logger.info(f"TIMING: blob_check={t7-t6:.3f}s total={t7-t0:.3f}s")

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
        import time
        t0 = time.time()

        hash_val = plan['blobid']
        hash_path = self.BY_HASH_ROOT / hash_val[:2] / hash_val[2:4] / hash_val

        strategies.create_hardlinks_idempotent(
            hash_path,
            plan['paths_to_link'],
            self.ARCHIVE_ROOT
        )

        t1 = time.time()
        logger.info(f"TIMING: create_hardlinks n_paths={len(plan['paths_to_link'])} time={t1-t0:.3f}s")

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
    medium_hash: str = typer.Option(..., "--medium-hash", "-m", help="Medium hash to process (required)"),
    limit: int = typer.Option(0, "--limit", "-l", help="Process at most N inodes (0 = unlimited)"),
    dry_run: bool = typer.Option(False, "--dry-run", help="Log actions without making changes"),
    batch_size: int = typer.Option(100, "--batch-size", "-b", help="Number of inodes to claim per batch"),
    worker_id: str = typer.Option(None, "--worker-id", help="Worker ID (defaults to w{pid})"),
):
    """
    NTT Copy Worker - Deduplicates and archives filesystem content (batch mode).

    Must run as root/sudo: sudo -E ntt-copier.py --medium-hash=<hash> [options]
    """

    # Setup logging
    logger.remove()  # Remove default handler
    logger.add(sys.stderr, level="INFO")

    # CRITICAL: Must run as root to read all files from mounted images
    if os.geteuid() != 0:
        logger.error("ERROR: ntt-copier must run as root/sudo")
        logger.error("Run with: sudo bin/ntt-copier.py --medium-hash=<hash> [options]")
        sys.exit(1)

    # Set PostgreSQL user to original user when running under sudo
    if 'SUDO_USER' in os.environ:
        os.environ['PGUSER'] = os.environ['SUDO_USER']

    # Get database URL
    db_url = os.environ.get('NTT_DB_URL', 'postgresql:///copyjob')
    if os.geteuid() == 0 and 'SUDO_USER' in os.environ:
        if '://' in db_url and '@' not in db_url:
            db_url = db_url.replace(':///', f"://{os.environ['SUDO_USER']}@localhost/")

    logger.info("NTT Copier starting (batch mode)",
                medium_hash=medium_hash,
                limit=limit,
                dry_run=dry_run,
                batch_size=batch_size)

    # Single worker mode (this process is one worker)
    # Use provided worker_id or default to w{pid}
    if worker_id is None:
        worker_id = f'w{os.getpid()}'

    worker = CopyWorker(
        worker_id=worker_id,
        db_url=db_url,
        medium_hash=medium_hash,
        limit=limit,
        dry_run=dry_run,
        batch_size=batch_size
    )
    worker.run()


if __name__ == "__main__":
    app()
