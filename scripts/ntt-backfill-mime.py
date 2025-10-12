#!/usr/bin/env -S /home/pball/.local/bin/uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = [
#     "psycopg[binary]",
#     "python-magic",
#     "typer",
# ]
# ///
#
# Author: PB and Claude
# Date: 2025-10-10
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/scripts/ntt-backfill-mime.py
#
# Backfill mime_type for inodes with blobid but NULL mime_type
#
# Strategy:
#   1. Query distinct blobids WHERE blobid IS NOT NULL AND mime_type IS NULL
#   2. For each blobid: detect MIME type from by-hash file
#   3. Update ALL inodes with that blobid in single UPDATE statement
#   4. Process in batches with tunable batch_size
#
# Performance: ~2.8M unique blobids to process (vs 13.3M inodes)

import cProfile
import json
import multiprocessing
import os
import pstats
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Optional

import magic
import psycopg
import typer
from psycopg.rows import dict_row

app = typer.Typer()

# Empty file hash constant (SHA256 of zero bytes)
EMPTY_FILE_HASH = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

# Logging
LOG_FILE = Path("/var/log/ntt/mime-backfill.jsonl")


def log_event(stage: str, **kwargs):
    """Write event to JSONL log file."""
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        event = {"ts": datetime.now().isoformat(), "stage": stage, **kwargs}
        with open(LOG_FILE, "a") as f:
            f.write(json.dumps(event) + "\n")
    except Exception as e:
        typer.echo(f"Warning: Failed to write log: {e}", err=True)


def construct_byhash_path(blobid: str, by_hash_root: Path) -> Path:
    """
    Construct by-hash path from blobid.

    Structure: /data/cold/by-hash/XX/YY/FULLHASH

    Args:
        blobid: 64-char hex hash
        by_hash_root: Root of by-hash directory

    Returns:
        Full path to by-hash file
    """
    return by_hash_root / blobid[:2] / blobid[2:4] / blobid


def detect_mime_type(blobid: str, by_hash_root: Path, magic_detector: magic.Magic) -> Optional[str]:
    """
    Detect MIME type for a blobid.

    Uses from_buffer() to read only first 2KB for performance.

    Special cases:
    - Empty file hash → application/x-empty
    - Missing file → None (warning logged)
    - Detection failure → None (error logged)

    Args:
        blobid: Hash to detect
        by_hash_root: Root of by-hash directory
        magic_detector: Initialized magic.Magic instance

    Returns:
        MIME type string or None on failure
    """
    # Special case: empty file
    if blobid == EMPTY_FILE_HASH:
        return "application/x-empty"

    # Construct path
    file_path = construct_byhash_path(blobid, by_hash_root)

    # Check if file exists
    if not file_path.exists():
        typer.echo(f"Warning: Missing by-hash file: {blobid}", err=True)
        log_event("missing_file", blobid=blobid, path=str(file_path))
        return None

    # Detect MIME type from first 2KB (much faster than reading whole file)
    try:
        with open(file_path, 'rb') as f:
            buffer = f.read(2048)
        mime_type = magic_detector.from_buffer(buffer)
        return mime_type
    except Exception as e:
        typer.echo(f"Error detecting MIME for {blobid}: {e}", err=True)
        log_event("detection_error", blobid=blobid, error=str(e))
        return None


@app.command()
def main(
    batch_size: int = typer.Option(10000, "--batch-size", "-b", help="Number of blobids to process per batch"),
    limit: int = typer.Option(0, "--limit", "-l", help="Limit total blobids to process (0 = unlimited)"),
    dry_run: bool = typer.Option(False, "--dry-run", help="Detect MIME types but don't update database"),
    by_hash_root: str = typer.Option("/data/cold/by-hash", "--by-hash-root", help="Root of by-hash directory"),
    db_url: str = typer.Option("postgresql:///copyjob", "--db-url", help="Database connection URL"),
    workers: int = typer.Option(8, "--workers", "-w", help="Number of parallel workers for MIME detection"),
    profile: bool = typer.Option(False, "--profile", help="Enable cProfile profiling to /tmp/mime-backfill.prof"),
):
    """
    Backfill mime_type for inodes with blobid but NULL mime_type.

    Processes by unique blobid (not by inode) for efficiency.
    Logs progress to /var/log/ntt/mime-backfill.jsonl.
    """

    # If profiling requested, wrap execution
    if profile:
        profiler = cProfile.Profile()
        profiler.enable()
        try:
            _run_backfill(batch_size, limit, dry_run, by_hash_root, db_url, workers)
        finally:
            profiler.disable()
            profiler.dump_stats("/tmp/mime-backfill.prof")
            typer.echo("\nProfile saved to /tmp/mime-backfill.prof", err=True)
            typer.echo("Analyze with: python -m pstats /tmp/mime-backfill.prof", err=True)
    else:
        _run_backfill(batch_size, limit, dry_run, by_hash_root, db_url, workers)


def _detect_mime_worker(args):
    """Worker function for multiprocessing (must be pickleable)."""
    blobid, by_hash_root_str = args
    by_hash_root = Path(by_hash_root_str)

    # Create magic detector per worker (not thread-safe to share)
    magic_detector = magic.Magic(mime=True)

    return blobid, detect_mime_type(blobid, by_hash_root, magic_detector)


def _run_backfill(batch_size: int, limit: int, dry_run: bool, by_hash_root: str, db_url: str, workers: int):
    """Core backfill logic (extracted for profiling)."""

    # Set PostgreSQL user to original user when running under sudo
    if 'SUDO_USER' in os.environ:
        os.environ['PGUSER'] = os.environ['SUDO_USER']

    # Get database URL (apply SUDO_USER if running as root)
    if os.geteuid() == 0 and 'SUDO_USER' in os.environ:
        if '://' in db_url and '@' not in db_url:
            db_url = db_url.replace(':///', f"://{os.environ['SUDO_USER']}@localhost/")

    by_hash_path = Path(by_hash_root)

    if not by_hash_path.exists():
        typer.echo(f"Error: by-hash directory not found: {by_hash_path}", err=True)
        raise typer.Exit(code=1)

    typer.echo("=" * 70)
    typer.echo("NTT MIME Type Backfill")
    typer.echo("=" * 70)
    typer.echo(f"Batch size: {batch_size}")
    typer.echo(f"Limit: {limit if limit > 0 else 'unlimited'}")
    typer.echo(f"Dry run: {dry_run}")
    typer.echo(f"Workers: {workers}")
    typer.echo(f"By-hash root: {by_hash_path}")
    typer.echo(f"Database: {db_url}")
    typer.echo("=" * 70)

    log_event("script_start", batch_size=batch_size, limit=limit, dry_run=dry_run)

    # Connect to database
    try:
        conn = psycopg.connect(db_url, row_factory=dict_row, autocommit=True)
    except Exception as e:
        typer.echo(f"Error connecting to database: {e}", err=True)
        log_event("db_connection_error", error=str(e))
        raise typer.Exit(code=1)

    # Initialize MIME detector (reused across all detections)
    magic_detector = magic.Magic(mime=True)

    # Get total count for progress tracking
    with conn.cursor() as cur:
        cur.execute("""
            SELECT COUNT(DISTINCT blobid) as total
            FROM inode
            WHERE blobid IS NOT NULL AND mime_type IS NULL
        """)
        result = cur.fetchone()
        total_blobids = result['total'] if result else 0

    if total_blobids == 0:
        typer.echo("No blobids need mime_type backfill!")
        log_event("script_complete", total_processed=0, message="no_work")
        return

    # Apply limit if specified
    effective_total = min(total_blobids, limit) if limit > 0 else total_blobids

    typer.echo(f"\nTotal blobids to process: {effective_total:,} (of {total_blobids:,})")
    typer.echo()

    # Processing loop
    processed_count = 0
    batch_num = 0
    start_time = time.time()

    stats = {
        'detected': 0,
        'empty_files': 0,
        'missing_files': 0,
        'detection_errors': 0,
        'db_updates': 0,
        'inodes_updated': 0,
    }

    while True:
        # Check limit
        if limit > 0 and processed_count >= limit:
            typer.echo(f"\nReached limit of {limit} blobids")
            break

        batch_num += 1
        batch_start = time.time()

        # Fetch batch of blobids
        with conn.cursor() as cur:
            fetch_limit = min(batch_size, limit - processed_count) if limit > 0 else batch_size

            cur.execute("""
                SELECT DISTINCT blobid
                FROM inode
                WHERE blobid IS NOT NULL AND mime_type IS NULL
                LIMIT %s
            """, (fetch_limit,))

            blobids = [row['blobid'] for row in cur.fetchall()]

        if not blobids:
            # No more work
            break

        # Process this batch (with multiprocessing if workers > 1)
        batch_results = {}  # {blobid: mime_type or None}

        if workers > 1:
            # Parallel processing with multiprocessing pool
            with multiprocessing.Pool(workers) as pool:
                worker_args = [(blobid, by_hash_root) for blobid in blobids]
                results = pool.map(_detect_mime_worker, worker_args)

                for blobid, mime_type in results:
                    batch_results[blobid] = mime_type
        else:
            # Sequential processing (single worker)
            for blobid in blobids:
                mime_type = detect_mime_type(blobid, by_hash_path, magic_detector)
                batch_results[blobid] = mime_type

        # Update stats
        for blobid, mime_type in batch_results.items():
            if mime_type:
                stats['detected'] += 1
                if blobid == EMPTY_FILE_HASH:
                    stats['empty_files'] += 1
            elif mime_type is None:
                # Check if it was missing file or detection error (logged in detect_mime_type)
                file_path = construct_byhash_path(blobid, by_hash_path)
                if not file_path.exists():
                    stats['missing_files'] += 1
                else:
                    stats['detection_errors'] += 1

        # Update database (skip if dry-run)
        if not dry_run:
            try:
                # Prepare batch update using UNNEST (single query instead of 10K queries)
                updates = [(blobid, mime_type) for blobid, mime_type in batch_results.items() if mime_type]

                if updates:
                    blobids, mime_types = zip(*updates)

                    with conn.transaction():
                        with conn.cursor() as cur:
                            cur.execute("""
                                UPDATE inode
                                SET mime_type = data.mime_type
                                FROM (SELECT UNNEST(%s::text[]) AS blobid,
                                             UNNEST(%s::text[]) AS mime_type) AS data
                                WHERE inode.blobid = data.blobid
                                  AND inode.mime_type IS NULL
                            """, (list(blobids), list(mime_types)))

                            stats['db_updates'] += len(updates)
                            stats['inodes_updated'] += cur.rowcount

                log_event("batch_complete", batch_num=batch_num, blobids=len(blobids),
                         detected=sum(1 for m in batch_results.values() if m),
                         inodes_updated=stats['inodes_updated'])

            except Exception as e:
                typer.echo(f"\nError updating database (batch {batch_num}): {e}", err=True)
                log_event("batch_error", batch_num=batch_num, error=str(e))
                conn.rollback()
                # Continue to next batch

        processed_count += len(blobids)
        batch_time = time.time() - batch_start

        # Progress report
        elapsed = time.time() - start_time
        rate = processed_count / elapsed if elapsed > 0 else 0
        eta_seconds = (effective_total - processed_count) / rate if rate > 0 else 0
        progress_pct = (processed_count / effective_total) * 100

        typer.echo(f"Batch {batch_num}: {len(blobids)} blobids in {batch_time:.1f}s | "
                  f"Progress: {processed_count:,}/{effective_total:,} ({progress_pct:.1f}%) | "
                  f"Rate: {rate:.1f} blobs/s | "
                  f"ETA: {int(eta_seconds)}s")

    # Final summary
    elapsed_total = time.time() - start_time

    typer.echo("\n" + "=" * 70)
    typer.echo("SUMMARY")
    typer.echo("=" * 70)
    typer.echo(f"Processed: {processed_count:,} blobids in {elapsed_total:.1f}s")
    typer.echo(f"Rate: {processed_count/elapsed_total:.1f} blobs/s")
    typer.echo(f"")
    typer.echo(f"Successfully detected: {stats['detected']:,}")
    typer.echo(f"  - Empty files: {stats['empty_files']:,}")
    typer.echo(f"  - Regular files: {stats['detected'] - stats['empty_files']:,}")
    typer.echo(f"")
    typer.echo(f"Failures:")
    typer.echo(f"  - Missing files: {stats['missing_files']:,}")
    typer.echo(f"  - Detection errors: {stats['detection_errors']:,}")
    typer.echo(f"")

    if not dry_run:
        typer.echo(f"Database updates: {stats['db_updates']:,} blobids")
        typer.echo(f"Inodes updated: {stats['inodes_updated']:,}")
    else:
        typer.echo("DRY RUN - No database updates performed")

    typer.echo("=" * 70)

    log_event("script_complete",
             processed=processed_count,
             detected=stats['detected'],
             missing=stats['missing_files'],
             errors=stats['detection_errors'],
             db_updates=stats['db_updates'],
             inodes_updated=stats['inodes_updated'],
             elapsed_seconds=elapsed_total,
             dry_run=dry_run)

    conn.close()


if __name__ == "__main__":
    app()
