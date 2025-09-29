#!/usr/bin/env -S /home/pball/.local/bin/uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = [
#     "psycopg[binary]",
#     "loguru",
#     "typer",
# ]
# ///
"""
Count existing hardlinks for each blob and update database.

This script examines the current state of the filesystem and updates
the n_hardlinks count in the blobs table to reflect reality.
"""

import os
import sys
from pathlib import Path
from typing import Optional
from dataclasses import dataclass
from datetime import datetime

import psycopg
from psycopg.rows import dict_row
import typer
from loguru import logger

app = typer.Typer()

# Configure logging
logger.remove()
logger.add(sys.stderr, format="{time:HH:mm:ss} | {level:<8} | {message}")

@dataclass
class HardlinkStats:
    """Statistics for hardlink counting."""
    blobs_processed: int = 0
    by_hash_missing: int = 0
    correct_hardlinks: int = 0
    wrong_hardlinks: int = 0
    missing_hardlinks: int = 0
    blobs_complete: int = 0
    blobs_partial: int = 0
    blobs_none: int = 0


class HardlinkCounter:
    """Count and verify hardlinks for blobs."""
    
    def __init__(self, db_url: str, by_hash_root: Path, archive_root: Path):
        self.db_url = db_url
        self.by_hash_root = by_hash_root
        self.archive_root = archive_root
        self.stats = HardlinkStats()
        
    def connect_db(self) -> psycopg.Connection:
        """Connect to database."""
        return psycopg.connect(self.db_url, row_factory=dict_row)
    
    def process_blob(self, conn: psycopg.Connection, blob: dict) -> int:
        """Count hardlinks for a single blob."""
        blobid = blob['blobid']
        hex_hash = blobid.decode('utf-8') if isinstance(blobid, bytes) else blobid
        
        # Construct by-hash path
        by_hash_path = self.by_hash_root / hex_hash[:2] / hex_hash[2:4] / hex_hash
        
        # Check if by-hash exists
        if not by_hash_path.exists():
            logger.warning(f"By-hash missing: {hex_hash[:12]}...")
            self.stats.by_hash_missing += 1
            return 0
        
        try:
            by_hash_stat = by_hash_path.stat()
        except OSError as e:
            logger.error(f"Cannot stat by-hash {hex_hash[:12]}...: {e}")
            return 0
        
        # Get all expected paths for this blob
        with conn.cursor() as cur:
            cur.execute("""
                SELECT DISTINCT p.path
                FROM path p
                JOIN inode i ON p.dev = i.dev AND p.ino = i.ino
                WHERE i.hash = %s
                ORDER BY p.path
            """, (blobid,))
            paths = cur.fetchall()
        
        correct_hardlinks = 0
        
        for path_row in paths:
            path = path_row['path']
            # Remove leading slash and join with archive root
            archived_path = self.archive_root / path.lstrip('/')
            
            if archived_path.exists():
                try:
                    archived_stat = archived_path.stat()
                    # Check if it's the same inode (correct hardlink)
                    if (archived_stat.st_ino == by_hash_stat.st_ino and 
                        archived_stat.st_dev == by_hash_stat.st_dev):
                        correct_hardlinks += 1
                        self.stats.correct_hardlinks += 1
                    else:
                        logger.error(f"WRONG HARDLINK: {archived_path}")
                        logger.error(f"  Expected inode: {by_hash_stat.st_ino}")
                        logger.error(f"  Actual inode: {archived_stat.st_ino}")
                        self.stats.wrong_hardlinks += 1
                except OSError as e:
                    logger.error(f"Cannot stat {archived_path}: {e}")
            else:
                self.stats.missing_hardlinks += 1
        
        # Update statistics
        if correct_hardlinks == len(paths):
            self.stats.blobs_complete += 1
        elif correct_hardlinks > 0:
            self.stats.blobs_partial += 1
        else:
            self.stats.blobs_none += 1
        
        return correct_hardlinks
    
    def run(self, dry_run: bool = False, limit: Optional[int] = None):
        """Count all hardlinks and update database."""
        start_time = datetime.now()
        
        with self.connect_db() as conn:
            # Get all blobs
            query = "SELECT blobid FROM blobs"
            if limit:
                query += f" LIMIT {limit}"
            
            with conn.cursor() as cur:
                cur.execute(query)
                blobs = cur.fetchall()
            
            total = len(blobs)
            logger.info(f"Processing {total} blobs...")
            
            # Process each blob
            for i, blob in enumerate(blobs):
                if i > 0 and i % 1000 == 0:
                    elapsed = (datetime.now() - start_time).total_seconds()
                    rate = i / elapsed
                    remaining = (total - i) / rate
                    logger.info(
                        f"Progress: {i}/{total} ({i*100/total:.1f}%) "
                        f"Rate: {rate:.1f}/s "
                        f"ETA: {remaining/60:.1f}m"
                    )
                
                # Count hardlinks for this blob
                count = self.process_blob(conn, blob)
                
                # Update database
                if not dry_run:
                    with conn.cursor() as cur:
                        cur.execute("""
                            UPDATE blobs 
                            SET n_hardlinks = %s 
                            WHERE blobid = %s
                        """, (count, blob['blobid']))
                
                self.stats.blobs_processed += 1
            
            if not dry_run:
                conn.commit()
                logger.success("Database updated")
            else:
                logger.warning("DRY RUN - no database updates")
        
        # Print summary
        elapsed = (datetime.now() - start_time).total_seconds()
        logger.success(f"\n{'='*60}")
        logger.success(f"Hardlink Count Complete in {elapsed:.1f}s")
        logger.success(f"Blobs processed: {self.stats.blobs_processed}")
        logger.success(f"By-hash missing: {self.stats.by_hash_missing}")
        logger.success(f"Correct hardlinks: {self.stats.correct_hardlinks}")
        logger.success(f"Missing hardlinks: {self.stats.missing_hardlinks}")
        logger.success(f"Wrong hardlinks: {self.stats.wrong_hardlinks}")
        logger.success(f"Complete blobs: {self.stats.blobs_complete}")
        logger.success(f"Partial blobs: {self.stats.blobs_partial}")
        logger.success(f"No hardlinks: {self.stats.blobs_none}")


@app.command()
def main(
    dry_run: bool = typer.Option(False, "--dry-run", help="Don't update database"),
    limit: Optional[int] = typer.Option(None, "--limit", help="Limit number of blobs to process"),
    by_hash_root: Path = typer.Option("/data/cold/by-hash", "--by-hash", help="By-hash root directory"),
    archive_root: Path = typer.Option("/data/cold/archived", "--archive", help="Archive root directory"),
    database: str = typer.Option("copyjob", "--database", help="Database name"),
    host: str = typer.Option("localhost", "--host", help="Database host"),
    user: str = typer.Option("postgres", "--user", help="Database user"),
):
    """Count existing hardlinks for all blobs and update n_hardlinks in database."""
    
    # Build database URL
    db_url = f"postgresql://{user}@{host}/{database}"
    
    logger.info(f"Database: {database}")
    logger.info(f"By-hash root: {by_hash_root}")
    logger.info(f"Archive root: {archive_root}")
    
    if dry_run:
        logger.warning("DRY RUN MODE - no database updates")
    
    # Create counter and run
    counter = HardlinkCounter(db_url, by_hash_root, archive_root)
    counter.run(dry_run, limit)


if __name__ == "__main__":
    app()