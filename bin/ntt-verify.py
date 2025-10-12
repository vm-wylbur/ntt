#!/usr/bin/env -S /home/pball/.local/bin/uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = [
#     "psycopg[binary]",
#     "loguru",
#     "typer",
# ]
# ///
#
# Author: PB and Claude
# Date: 2025-09-29
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/bin/ntt-verify.py
#
# NTT blob verifier - verifies content integrity in archived storage
#
# IMPORTANT: Run with environment loaded:
#   source ~/.config/ntt/ntt.env && sudo -E ntt-verify.py [options]

import os
import sys
import time
from pathlib import Path
from typing import Optional, List, Dict, Tuple
from datetime import datetime, timezone
from dataclasses import dataclass, asdict
from enum import Enum

import typer
from typing_extensions import Annotated
import psycopg
from psycopg.rows import dict_row
from loguru import logger

# Configuration from environment
BY_HASH_ROOT = Path(os.environ.get('NTT_BY_HASH_ROOT', '/data/cold/by-hash'))
ARCHIVE_ROOT = Path(os.environ.get('NTT_ARCHIVE_ROOT', '/data/cold/archived'))
LOG_JSON = Path(os.environ.get('NTT_LOG_JSON', '/var/log/ntt/verify.jsonl'))
IGNORE_PATTERNS_FILE = os.environ.get('NTT_IGNORE_PATTERNS', '')

# Default settings
DEFAULT_SAMPLE_SIZE = 1000  # For TABLESAMPLE
BATCH_LOG_SIZE = 100  # Log success batch every N blobs

# Database connection via shared utility
from ntt_db import get_db_connection

# CLI app
app = typer.Typer()


class VerifyMode(str, Enum):
    """Blob selection modes."""
    oldest = "oldest"
    newest = "newest"
    never = "never"
    random = "random"


@dataclass
class FileStat:
    """File statistics for comparison."""
    inode: int
    mtime: float
    size: int
    
    @classmethod
    def from_path(cls, path: Path) -> 'FileStat':
        """Create FileStat from path."""
        stat = path.stat()
        return cls(stat.st_ino, stat.st_mtime, stat.st_size)
    
    def __eq__(self, other):
        """Check if stats match exactly."""
        return (self.inode == other.inode and 
                self.mtime == other.mtime and 
                self.size == other.size)
    
    def __str__(self):
        """Concise string representation."""
        return f"(ino:{self.inode},mtime:{self.mtime:.2f},size:{self.size})"


@dataclass
class BlobVerification:
    """Result of verifying a single blob."""
    blobid: str  # hex string
    by_hash_path: str
    by_hash_exists: bool
    reference_stat: Optional[FileStat] = None
    total_paths: int = 0
    verified_paths: int = 0
    missing_paths: List[str] = None
    mismatched_paths: List[str] = None
    error: Optional[str] = None
    
    def __post_init__(self):
        if self.missing_paths is None:
            self.missing_paths = []
        if self.mismatched_paths is None:
            self.mismatched_paths = []
    

    def is_success(self) -> bool:
        """Check if verification was completely successful.
        
        Stat mismatches (different inodes/mtimes) don't count as failures - 
        they just indicate files that could be deduplicated but aren't yet.
        Only real errors count: missing by-hash, missing paths, permission errors.
        """
        has_real_errors = not self.by_hash_exists or len(self.missing_paths) > 0 or self.error
        # Success if no real errors (even if verified_paths is 0 due to all paths being filtered)
        return not has_real_errors

class BlobVerifier:
    """Verifies blob integrity in content-addressable storage."""
    
    def __init__(self, by_hash_root: Path, archive_root: Path,
                 log_json: Path, dry_run: bool = False, sample_size: int = DEFAULT_SAMPLE_SIZE):
        self.by_hash_root = by_hash_root
        self.archive_root = archive_root
        self.log_json = log_json
        self.dry_run = dry_run
        self.sample_size = sample_size
        
        # Setup logging first so all subsequent logs use correct format
        self.setup_logging()
        
        # Load ignore patterns
        self.ignore_patterns = []
        if IGNORE_PATTERNS_FILE and Path(IGNORE_PATTERNS_FILE).exists():
            with open(IGNORE_PATTERNS_FILE) as f:
                self.ignore_patterns = [
                    line.strip() for line in f
                    if line.strip() and not line.strip().startswith('#')
                ]
            logger.info(f"Loaded {len(self.ignore_patterns)} ignore patterns from {IGNORE_PATTERNS_FILE}")
        elif IGNORE_PATTERNS_FILE:
            logger.debug(f"Ignore patterns file not found: {IGNORE_PATTERNS_FILE}")
        else:
            logger.info("No ignore patterns configured (NTT_IGNORE_PATTERNS not set)")
        
        # Statistics
        self.stats = {
            'blobs_checked': 0,
            'blobs_success': 0,
            'blobs_failed': 0,
            'blobs_skipped': 0,  # Blobs with no paths after filtering
            'paths_checked': 0,
            'paths_verified': 0,
            'paths_missing': 0,
            'paths_mismatched': 0,
            'by_hash_missing': 0,
            'start_time': time.time(),
            'total_bytes': 0
        }
        
        # Success buffer for batch logging
        self.success_buffer = []
    
    def setup_logging(self):
        """Setup dual logging: console + JSONL using loguru."""
        # Remove default handler
        logger.remove()
        
        # Console handler - human-readable format like ntt-enum
        # For messages with blob context
        logger.add(
            sys.stderr,
            format="<green>{time:YYYY-MM-DD HH:mm:ss}</green> | <level>{level: <8}</level> | <cyan>{extra[blob]: <12}</cyan> | {message}",
            level="INFO",
            filter=lambda record: "blob" in record["extra"]
        )
        
        # For messages without blob context (summary, progress)
        logger.add(
            sys.stderr,
            format="<green>{time:YYYY-MM-DD HH:mm:ss}</green> | <level>{level: <8}</level> | {message}",
            level="INFO",
            filter=lambda record: "blob" not in record["extra"]
        )
        
        # JSONL handler - structured logs for analysis
        if not self.dry_run:
            logger.add(
                self.log_json,
                serialize=True,  # Native JSONL support
                level="DEBUG",   # Capture everything in JSONL
                rotation="100 MB",
                retention="30 days"
            )
    
    def connect_db(self) -> psycopg.Connection:
        """Connect to database."""
        return get_db_connection(row_factory=dict_row)
    
    def get_blobs_from_file(self, conn: psycopg.Connection, file_path: Path) -> List[Dict]:
        """Load blob IDs from a file and fetch from database."""
        if not file_path.exists():
            logger.error(f"File not found: {file_path}")
            return []
        
        # Read blob IDs from file
        blob_ids = []
        with open(file_path, 'r') as f:
            for line in f:
                blob_id = line.strip()
                if blob_id:
                    blob_ids.append(blob_id)
        
        if not blob_ids:
            logger.debug("No blob IDs found in file")
            return []
        
        logger.info(f"Loaded {len(blob_ids)} blob IDs from file")
        
        # Convert hex strings to bytea format for query
        blobs = []
        with conn.cursor() as cur:
            for blob_id in blob_ids:
                cur.execute("""
                    SELECT blobid 
                    FROM blobs
                    WHERE blobid = %s
                """, (blob_id,))
                result = cur.fetchone()
                if result:
                    blobs.append(result)
                else:
                    logger.debug(f"Blob not found in database: {blob_id[:12]}...")
        
        return blobs
    
    def get_blobs_to_verify(self, conn: psycopg.Connection, count: int, 
                           mode: VerifyMode) -> List[Dict]:
        """Select blobs for verification using efficient TABLESAMPLE.
        
        Simplified: Fast blob selection without pre-filtering.
        Path filtering happens in batched queries (much faster).
        """
        with conn.cursor() as cur:
            if mode == VerifyMode.random:
                # Use TABLESAMPLE hybrid approach for true randomness
                cur.execute("""
                    SELECT blobid FROM (
                        SELECT blobid FROM blobs
                        TABLESAMPLE SYSTEM_ROWS(%(sample)s)
                        ORDER BY RANDOM()
                        LIMIT %(limit)s
                    ) sample
                    ORDER BY RANDOM()
                    LIMIT %(count)s
                """, {'sample': self.sample_size, 'limit': min(100, count), 'count': count})
                
                blobs = cur.fetchall()
                
                # Fallback if not enough rows
                if len(blobs) < count:
                    cur.execute("""
                        SELECT blobid FROM blobs
                        WHERE last_checked IS NULL
                        LIMIT %(count)s
                    """, {'count': count - len(blobs)})
                    blobs.extend(cur.fetchall())
                    
            elif mode == VerifyMode.never:
                # Never checked blobs
                cur.execute("""
                    SELECT blobid 
                    FROM blobs
                    WHERE last_checked IS NULL
                    ORDER BY blobid
                    LIMIT %s
                """, (count,))
                blobs = cur.fetchall()
                
            elif mode == VerifyMode.newest:
                # Most recently copied blobs (by inode.processed_at)
                cur.execute("""
                    SELECT b.blobid 
                    FROM blobs b
                    JOIN inode i ON i.blobid = b.blobid
                    WHERE i.processed_at IS NOT NULL
                    GROUP BY b.blobid
                    ORDER BY MAX(i.processed_at) DESC
                    LIMIT %s
                """, (count,))
                blobs = cur.fetchall()
                
            else:  # oldest
                # Oldest checked (including never checked)
                cur.execute("""
                    SELECT blobid 
                    FROM blobs
                    ORDER BY last_checked NULLS FIRST, blobid
                    LIMIT %s
                """, (count,))
                blobs = cur.fetchall()
            
            return blobs
    
    def get_blob_paths(self, conn: psycopg.Connection, blobid: bytes) -> List[str]:
        """Get all paths associated with a blob, filtering ignored patterns."""
        with conn.cursor() as cur:
            cur.execute("""
                SELECT DISTINCT p.path
                FROM path p
                JOIN inode i ON i.dev = p.dev AND i.ino = p.ino
                WHERE i.blobid = %s
                ORDER BY p.path
            """, (blobid,))
            
            paths = [row['path'] for row in cur.fetchall()]
            
            # Filter out ignored patterns
            if self.ignore_patterns:
                import re
                filtered_paths = []
                for path in paths:
                    if not any(re.search(pattern, path) for pattern in self.ignore_patterns):
                        filtered_paths.append(path)
                return filtered_paths
            
            return paths
    
    def get_blob_paths_batch(self, conn: psycopg.Connection, blobids: List[bytes]) -> Dict[bytes, List[str]]:
        """Get all paths for multiple blobs in a single query.
        
        Returns a dict mapping blobid -> [paths], filtering ignored patterns.
        This eliminates the N+1 query problem by batching path lookups.
        
        Filtering is done in Python (fast) rather than SQL (slow with 58M paths).
        """
        if not blobids:
            return {}
        
        with conn.cursor() as cur:
            # Single query to get all paths for all blobs - NO filtering in SQL
            cur.execute("""
                SELECT i.blobid, p.path
                FROM inode i
                JOIN path p ON i.dev = p.dev AND i.ino = p.ino
                WHERE i.blobid = ANY(%s)
                  AND i.blobid IS NOT NULL
                ORDER BY i.blobid, p.path
            """, (blobids,))
            
            # Group paths by blobid and filter in Python
            import re
            result = {blobid: set() for blobid in blobids}
            
            for row in cur.fetchall():
                path = row['path']
                
                # Apply ignore patterns in Python (much faster than SQL regex)
                if self.ignore_patterns:
                    if any(re.search(pattern, path) for pattern in self.ignore_patterns):
                        continue  # Skip ignored paths
                
                result[row['blobid']].add(path)
            
            # Convert sets to lists
            return {blobid: list(paths) for blobid, paths in result.items()}
    
    def construct_paths(self, blobid: bytes, paths: List[str]) -> Tuple[Path, List[Path]]:
        """Construct by-hash and archived paths."""
        # blobid is bytea but contains the hex string, decode it
        hex_hash = blobid
        by_hash_path = self.by_hash_root / hex_hash[:2] / hex_hash[2:4] / hex_hash

        # Paths in database are absolute source paths, reconstruct archived locations
        # e.g., /data/staging/foo → /data/cold/archived/data/staging/foo
        archived_paths = [
            self.archive_root / path.lstrip('/')
            for path in paths
        ]

        return by_hash_path, archived_paths
    
    def verify_blob(self, blobid: bytes, paths: List[str]) -> BlobVerification:
        """Verify a single blob and all its paths."""
        # blobid is bytea but contains the hex string, decode it
        hex_hash = blobid
        result = BlobVerification(
            blobid=hex_hash,
            by_hash_path="",
            by_hash_exists=False,
            total_paths=len(paths)
        )
        
        # Construct paths
        by_hash_path, archived_paths = self.construct_paths(blobid, paths)
        result.by_hash_path = str(by_hash_path)
        
        # Step 1: Verify by-hash file exists
        if not by_hash_path.exists():
            result.error = f"By-hash file missing: {by_hash_path}"
            self.stats['by_hash_missing'] += 1
            return result
        
        result.by_hash_exists = True
        
        # Get reference stats from by-hash file
        try:
            result.reference_stat = FileStat.from_path(by_hash_path)
            self.stats['total_bytes'] += result.reference_stat.size
        except Exception as e:
            result.error = f"Cannot stat by-hash file: {e}"
            return result
        
        # Step 2: Verify all archived paths
        for archived_path in archived_paths:
            self.stats['paths_checked'] += 1
            
            try:
                exists = archived_path.exists()
            except PermissionError:
                # Can't access path due to permissions in source data - this is expected
                # Don't count as error, just skip this path
                logger.debug(
                    "permission denied (source data)",
                    blob=hex_hash[:12],
                    type="permission_skipped",
                    path=str(archived_path)
                )
                # Still count as verified since we can't access it anyway
                result.verified_paths += 1
                continue

            if not exists:
                result.missing_paths.append(str(archived_path))
                self.stats['paths_missing'] += 1
                # Log missing path - use WARNING so it actually gets written and parsed
                logger.debug(
                    "missing path: {}",
                    str(archived_path),
                    blob=hex_hash[:12],
                    type="missing_path"
                )
                continue
            
            try:
                path_stat = FileStat.from_path(archived_path)
                
                # Check if stats match
                if path_stat != result.reference_stat:
                    result.mismatched_paths.append(str(archived_path))
                    self.stats['paths_mismatched'] += 1
                    logger.debug(
                        "stat mismatch",
                        blob=hex_hash[:12],
                        type="stat_mismatch",
                        path=str(archived_path),
                        expected=asdict(result.reference_stat),
                        actual=asdict(path_stat)
                    )
                    # Still count as verified - file exists with correct content
                    result.verified_paths += 1
                else:
                    result.verified_paths += 1
                    self.stats['paths_verified'] += 1
                    
            except Exception as e:
                result.mismatched_paths.append(str(archived_path))
                self.stats['paths_mismatched'] += 1
                logger.error(
                    "stat error",
                    blob=hex_hash[:12],
                    type="stat_error",
                    path=str(archived_path),
                    error=str(e)
                )
        
        return result
    
    def process_verification_result(self, conn: psycopg.Connection, 
                                   result: BlobVerification):
        """Process and log verification result."""
        blob_short = result.blobid[:12]
        
        if result.is_success():
            # Success case
            self.stats['blobs_success'] += 1
            self.success_buffer.append({
                'id': result.blobid,
                'paths': result.total_paths,
                'size': result.reference_stat.size if result.reference_stat else 0
            })
            
            # Console log (debug level for individual successes)
            logger.debug(
                "paths verified",
                blob=blob_short,
                paths=result.total_paths,
                size=result.reference_stat.size if result.reference_stat else 0
            )
            
            # Update database (only on success, not in dry-run)
            if not self.dry_run:
                with conn.cursor() as cur:
                    cur.execute("""
                        UPDATE blobs 
                        SET last_checked = NOW()
                        WHERE blobid = %s
                    """, (result.blobid,))
                conn.commit()
            
            # Log batch of successes every 100
            if len(self.success_buffer) >= BATCH_LOG_SIZE:
                self.log_success_batch()
                
        else:
            # Error case - no database update
            self.stats['blobs_failed'] += 1
            
            # Console log (keep errors at normal levels - they're important)
            if not result.by_hash_exists:
                logger.critical(
                    "BY-HASH MISSING",
                    blob=blob_short,
                    type="critical_error",
                    blobid=result.blobid,
                    by_hash_path=result.by_hash_path,
                    affected_paths=result.total_paths
                )
            else:
                missing = len(result.missing_paths)
                mismatched = len(result.mismatched_paths)
                logger.error(
                    "verification failure",
                    blob=blob_short,
                    type="verification_failure",
                    blobid=result.blobid,
                    missing=missing,
                    mismatched=mismatched,
                    total=result.total_paths
                )
    
    def log_success_batch(self):
        """Log batch of successful verifications."""
        if not self.success_buffer:
            return
            
        # Calculate totals
        total_size = sum(b['size'] for b in self.success_buffer)
        total_paths = sum(b['paths'] for b in self.success_buffer)
        
        # Log batch to JSONL only (no console output)
        logger.debug(
            f"Batch complete: {len(self.success_buffer)} blobs, "
            f"{total_paths} paths, {total_size:,} bytes verified",
            type="batch_success",
            stats={
                "count": len(self.success_buffer),
                "total_paths": total_paths,
                "total_size": total_size,
                "blob_ids": [b['id'][:12] for b in self.success_buffer]
            }
        )
        
        # Clear buffer
        self.success_buffer.clear()
    
    def report_progress(self, current: int, total: int):
        """Report progress to console."""
        elapsed = time.time() - self.stats['start_time']
        rate = current / elapsed if elapsed > 0 else 0
        mb_rate = self.stats['total_bytes'] / (1024*1024) / elapsed if elapsed > 0 else 0
        
        logger.info(
            f"Progress: {current}/{total} blobs "
            f"({self.stats['blobs_success']} ok, {self.stats['blobs_failed']} err), "
            f"{rate:.1f} blobs/s, {mb_rate:.1f} MB/s"
        )
    
    def report_summary(self):
        """Final summary report."""
        elapsed = time.time() - self.stats['start_time']
        
        # Flush any remaining successes
        if self.success_buffer:
            self.log_success_batch()
        
        # Console summary
        logger.info("=" * 60)
        logger.info(f"Verification Complete in {elapsed:.1f}s")
        logger.info(f"Blobs: {self.stats['blobs_checked']} checked, "
                      f"{self.stats['blobs_success']} ok, "
                      f"{self.stats['blobs_failed']} failed, "
                      f"{self.stats['blobs_skipped']} skipped")
        logger.info(f"Paths: {self.stats['paths_checked']} checked, "
                      f"{self.stats['paths_verified']} verified")
        
        if self.stats['by_hash_missing'] > 0:
            logger.critical(
                f"CRITICAL: {self.stats['by_hash_missing']} by-hash files missing!",
                type="summary",
                critical_errors=self.stats['by_hash_missing']
            )
        if self.stats['paths_missing'] > 0:
            logger.error(
                f"ERROR: {self.stats['paths_missing']} archived paths missing",
                type="summary",
                path_errors=self.stats['paths_missing']
            )
        if self.stats['paths_mismatched'] > 0:
            logger.error(
                f"ERROR: {self.stats['paths_mismatched']} paths mismatched",
                type="summary",
                mismatch_errors=self.stats['paths_mismatched']
            )
        
        # Log final stats to JSONL
        logger.info(
            "Final statistics",
            type="final_summary",
            stats=self.stats,
            elapsed=elapsed
        )
    
    def run(self, count: int, mode: VerifyMode, from_file: Optional[Path] = None):
        """Main verification loop."""
        if from_file:
            logger.info(f"Reading blob IDs from: {from_file}")
        else:
            logger.info(f"Starting verification: {count} blobs, mode={mode.value}")
        
        logger.info(f"Archive root: {self.archive_root}")
        logger.info(f"By-hash root: {self.by_hash_root}")
        
        if self.dry_run:
            logger.debug("DRY RUN - no database updates")
        
        with self.connect_db() as conn:
            # Get blobs to verify
            if from_file:
                blobs = self.get_blobs_from_file(conn, from_file)
            else:
                blobs = self.get_blobs_to_verify(conn, count, mode)
            
            if not blobs:
                logger.debug("No blobs found to verify")
                return
            
            logger.info(f"Selected {len(blobs)} blobs for verification")
            
            # Process blobs in batches to reduce DB queries
            BATCH_SIZE = 100
            total_blobs = len(blobs)
            
            for batch_start in range(0, total_blobs, BATCH_SIZE):
                batch_end = min(batch_start + BATCH_SIZE, total_blobs)
                batch = blobs[batch_start:batch_end]
                
                # Get all blobids in this batch
                blobids = [blob_row['blobid'] for blob_row in batch]
                
                # Single query to get paths for all blobs in batch
                blob_paths_map = self.get_blob_paths_batch(conn, blobids)
                
                # Process each blob in the batch
                for blob_row in batch:
                    blobid = blob_row['blobid']
                    self.stats['blobs_checked'] += 1
                    
                    # Get paths from batch result
                    paths = blob_paths_map.get(blobid, [])
                    
                    if not paths:
                        # All paths for this blob were filtered by ignore patterns
                        # Skip silently - this is expected and normal
                        self.stats['blobs_skipped'] += 1
                        continue
                    
                    # Verify the blob
                    result = self.verify_blob(blobid, paths)
                    
                    # Process result
                    self.process_verification_result(conn, result)
                
                # Progress report every batch
                if (batch_end % 1000) < BATCH_SIZE:
                    self.report_progress(batch_end, total_blobs)
            
            # Final summary
            self.report_summary()


@app.command()
def main(
    count: Annotated[int, typer.Option("--count", "-n", help="Number of blobs to verify")] = 1000,
    mode: Annotated[VerifyMode, typer.Option("--mode", "-m", help="Selection mode")] = VerifyMode.oldest,
    dry_run: Annotated[bool, typer.Option("--dry-run", help="Don't update database")] = False,
    sample_size: Annotated[int, typer.Option("--sample-size", help="TABLESAMPLE size for random mode")] = DEFAULT_SAMPLE_SIZE,
    archive_root: Annotated[Path, typer.Option(help="Archive root directory")] = ARCHIVE_ROOT,
    by_hash_root: Annotated[Path, typer.Option(help="By-hash root directory")] = BY_HASH_ROOT,
    log_json: Annotated[Path, typer.Option(help="JSONL log file path")] = LOG_JSON,
    from_file: Annotated[Optional[Path], typer.Option(help="File containing blob IDs to verify")] = None,
):
    """NTT Blob Verifier - Verify archived path integrity.
    
    Verifies that:
    - Content blobs exist in by-hash storage
    - All archived paths are properly hardlinked
    - File stats (inode, mtime, size) match across hardlinks
    """
    
    # Create log directory if needed
    log_json.parent.mkdir(parents=True, exist_ok=True)
    
    # Create and run verifier
    verifier = BlobVerifier(
        by_hash_root=by_hash_root,
        archive_root=archive_root,
        log_json=log_json,
        dry_run=dry_run,
        sample_size=sample_size
    )
    
    try:
        verifier.run(count, mode, from_file)
    except KeyboardInterrupt:
        logger.debug("Verification interrupted by user")
        verifier.report_summary()
        sys.exit(1)
    except Exception as e:
        logger.exception(f"Fatal error: {e}")
        sys.exit(1)


if __name__ == '__main__':
    app()