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
DB_URL = os.environ.get('NTT_DB_URL', 'postgresql:///copyjob')
BY_HASH_ROOT = Path(os.environ.get('NTT_BY_HASH_ROOT', '/data/cold/by-hash'))
ARCHIVE_ROOT = Path(os.environ.get('NTT_ARCHIVE_ROOT', '/data/cold/archived'))
LOG_JSON = Path(os.environ.get('NTT_LOG_JSON', '/var/log/ntt/verify.jsonl'))

# Default settings
DEFAULT_SAMPLE_SIZE = 1000  # For TABLESAMPLE
BATCH_LOG_SIZE = 100  # Log success batch every N blobs

# Set PostgreSQL user
if 'SUDO_USER' in os.environ:
    os.environ['PGUSER'] = os.environ['SUDO_USER']
elif os.geteuid() == 0 and 'USER' in os.environ:
    os.environ['PGUSER'] = 'postgres'

# Fix DB_URL for sudo
if os.geteuid() == 0 and 'SUDO_USER' in os.environ:
    if '://' in DB_URL and '@' not in DB_URL:
        DB_URL = DB_URL.replace(':///', f"://{os.environ['SUDO_USER']}@localhost/")

# CLI app
app = typer.Typer()


class VerifyMode(str, Enum):
    """Blob selection modes."""
    oldest = "oldest"
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
        """Check if verification was completely successful."""
        return (self.by_hash_exists and 
                self.total_paths == self.verified_paths and
                not self.error)


class BlobVerifier:
    """Verifies blob integrity in content-addressable storage."""
    
    def __init__(self, db_url: str, by_hash_root: Path, archive_root: Path, 
                 log_json: Path, dry_run: bool = False, sample_size: int = DEFAULT_SAMPLE_SIZE):
        self.db_url = db_url
        self.by_hash_root = by_hash_root
        self.archive_root = archive_root
        self.log_json = log_json
        self.dry_run = dry_run
        self.sample_size = sample_size
        
        # Statistics
        self.stats = {
            'blobs_checked': 0,
            'blobs_success': 0,
            'blobs_failed': 0,
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
        
        # Setup logging
        self.setup_logging()
    
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
        return psycopg.connect(self.db_url, row_factory=dict_row)
    
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
            logger.warning("No blob IDs found in file")
            return []
        
        logger.info(f"Loaded {len(blob_ids)} blob IDs from file")
        
        # Convert hex strings to bytea format for query
        blobs = []
        with conn.cursor() as cur:
            for blob_id in blob_ids:
                cur.execute("""
                    SELECT blobid 
                    FROM blobs
                    WHERE blobid = %s::text::bytea
                """, (blob_id,))
                result = cur.fetchone()
                if result:
                    blobs.append(result)
                else:
                    logger.warning(f"Blob not found in database: {blob_id[:12]}...")
        
        return blobs
    
    def get_blobs_to_verify(self, conn: psycopg.Connection, count: int, 
                           mode: VerifyMode) -> List[Dict]:
        """Select blobs for verification using efficient TABLESAMPLE."""
        with conn.cursor() as cur:
            if mode == VerifyMode.random:
                # Use TABLESAMPLE hybrid approach for true randomness
                cur.execute("""
                    SELECT blobid FROM (
                        SELECT * FROM blobs
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
        """Get all paths associated with a blob."""
        with conn.cursor() as cur:
            cur.execute("""
                SELECT DISTINCT p.path
                FROM path p
                JOIN inode i ON i.dev = p.dev AND i.ino = p.ino
                WHERE i.hash = %s
                ORDER BY p.path
            """, (blobid,))
            
            return [row['path'] for row in cur.fetchall()]
    
    def construct_paths(self, blobid: bytes, paths: List[str]) -> Tuple[Path, List[Path]]:
        """Construct by-hash and archived paths."""
        # blobid is bytea but contains the hex string, decode it
        hex_hash = blobid.decode('utf-8') if isinstance(blobid, bytes) else blobid
        by_hash_path = self.by_hash_root / hex_hash[:2] / hex_hash[2:4] / hex_hash
        
        # Remove leading slash from paths and join with archive root
        archived_paths = [
            self.archive_root / path.lstrip('/')
            for path in paths
        ]
        
        return by_hash_path, archived_paths
    
    def verify_blob(self, blobid: bytes, paths: List[str]) -> BlobVerification:
        """Verify a single blob and all its paths."""
        # blobid is bytea but contains the hex string, decode it
        hex_hash = blobid.decode('utf-8') if isinstance(blobid, bytes) else blobid
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
            
            if not archived_path.exists():
                result.missing_paths.append(str(archived_path))
                self.stats['paths_missing'] += 1
                logger.warning(
                    f"missing path: {archived_path}",
                    blob=hex_hash[:12],
                    type="missing_path",
                    path=str(archived_path)
                )
                continue
            
            try:
                path_stat = FileStat.from_path(archived_path)
                
                # Check if stats match
                if path_stat != result.reference_stat:
                    result.mismatched_paths.append(str(archived_path))
                    self.stats['paths_mismatched'] += 1
                    logger.warning(
                        f"stat mismatch: ref={result.reference_stat} path={archived_path} stat={path_stat}",
                        blob=hex_hash[:12],
                        type="stat_mismatch",
                        details={
                            "path": str(archived_path),
                            "expected": asdict(result.reference_stat),
                            "actual": asdict(path_stat)
                        }
                    )
                else:
                    result.verified_paths += 1
                    self.stats['paths_verified'] += 1
                    
            except Exception as e:
                result.mismatched_paths.append(str(archived_path))
                self.stats['paths_mismatched'] += 1
                logger.error(
                    f"stat error: {archived_path}: {e}",
                    blob=hex_hash[:12],
                    type="stat_error",
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
            
            # Console log
            logger.info(
                f"✓ {result.total_paths} paths verified",
                blob=blob_short,
                stats={"paths": result.total_paths, "size": result.reference_stat.size if result.reference_stat else 0}
            )
            
            # Update database (only on success, not in dry-run)
            if not self.dry_run:
                with conn.cursor() as cur:
                    cur.execute("""
                        UPDATE blobs 
                        SET last_checked = NOW()
                        WHERE blobid = %s
                    """, (bytes.fromhex(result.blobid),))
                conn.commit()
            
            # Log batch of successes every 100
            if len(self.success_buffer) >= BATCH_LOG_SIZE:
                self.log_success_batch()
                
        else:
            # Error case - no database update
            self.stats['blobs_failed'] += 1
            
            # Console log
            if not result.by_hash_exists:
                logger.critical(
                    f"✗ BY-HASH MISSING! {result.total_paths} paths orphaned",
                    blob=blob_short,
                    type="critical_error",
                    details={
                        "blobid": result.blobid,
                        "by_hash_path": result.by_hash_path,
                        "affected_paths": result.total_paths
                    }
                )
            else:
                missing = len(result.missing_paths)
                mismatched = len(result.mismatched_paths)
                logger.error(
                    f"✗ {missing} missing, {mismatched} mismatched of {result.total_paths} paths",
                    blob=blob_short,
                    type="verification_failure",
                    details={
                        "missing": missing,
                        "mismatched": mismatched,
                        "total": result.total_paths
                    }
                )
    
    def log_success_batch(self):
        """Log batch of successful verifications."""
        if not self.success_buffer:
            return
            
        # Calculate totals
        total_size = sum(b['size'] for b in self.success_buffer)
        total_paths = sum(b['paths'] for b in self.success_buffer)
        
        # Console summary
        logger.success(
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
        logger.success("=" * 60)
        logger.success(f"Verification Complete in {elapsed:.1f}s")
        logger.success(f"Blobs: {self.stats['blobs_checked']} checked, "
                      f"{self.stats['blobs_success']} ok, "
                      f"{self.stats['blobs_failed']} failed")
        logger.success(f"Paths: {self.stats['paths_checked']} checked, "
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
            logger.warning("DRY RUN - no database updates")
        
        with self.connect_db() as conn:
            # Get blobs to verify
            if from_file:
                blobs = self.get_blobs_from_file(conn, from_file)
            else:
                blobs = self.get_blobs_to_verify(conn, count, mode)
            
            if not blobs:
                logger.warning("No blobs found to verify")
                return
            
            logger.info(f"Selected {len(blobs)} blobs for verification")
            
            # Process each blob
            for i, blob_row in enumerate(blobs, 1):
                blobid = blob_row['blobid']
                self.stats['blobs_checked'] += 1
                
                # Get paths for this blob
                paths = self.get_blob_paths(conn, blobid)
                
                if not paths:
                    logger.warning(
                        f"No paths found",
                        blob=blobid.hex()[:12],
                        type="no_paths"
                    )
                    continue
                
                # Verify the blob
                result = self.verify_blob(blobid, paths)
                
                # Process result
                self.process_verification_result(conn, result)
                
                # Progress report every 10 blobs
                if i % 10 == 0:
                    self.report_progress(i, len(blobs))
            
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
        db_url=DB_URL,
        by_hash_root=by_hash_root,
        archive_root=archive_root,
        log_json=log_json,
        dry_run=dry_run,
        sample_size=sample_size
    )
    
    try:
        verifier.run(count, mode, from_file)
    except KeyboardInterrupt:
        logger.warning("Verification interrupted by user")
        verifier.report_summary()
        sys.exit(1)
    except Exception as e:
        logger.exception(f"Fatal error: {e}")
        sys.exit(1)


if __name__ == '__main__':
    app()