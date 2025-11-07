#!/usr/bin/env -S /home/pball/.local/bin/uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = [
#     "psycopg[binary]",
#     "loguru",
#     "typer",
#     "redis",
#     "blake3",
#     "python-magic",
# ]
# ///
#
# Author: PB and Claude
# Date: 2025-11-05
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/bin/ntt-extractor.py
#
# Archive/compression extraction tool with Redis queue and multi-worker support

import json
import os
import signal
import sys
from pathlib import Path
from typing import Optional

import typer
from loguru import logger

# Import NTT modules
sys.path.insert(0, os.path.dirname(__file__))
from ntt_db import get_db_connection
from ntt_extractor_queue import RedisExtractionQueue
from ntt_extractor_medium import ExtractionMediumManager
from ntt_extractor_handlers import MIME_HANDLERS, get_supported_mime_types

app = typer.Typer(help="NTT Archive Extraction Tool")

# Global state for graceful shutdown
shutdown_requested = False


def setup_logging(log_file: str = "/var/log/ntt/extractor.jsonl"):
    """Configure JSON logging."""
    logger.remove()  # Remove default handler

    # JSON logs to file
    logger.add(
        log_file,
        format="{message}",
        level="INFO",
        serialize=True,  # JSON format
        rotation="100 MB",
        compression="gz"
    )

    # Human-readable to stderr
    logger.add(
        sys.stderr,
        format="<green>{time:HH:mm:ss}</green> | <level>{level: <8}</level> | {message}",
        level="INFO"
    )


def signal_handler(signum, frame):
    """Handle SIGINT/SIGTERM for graceful shutdown."""
    global shutdown_requested
    logger.warning(f"Received signal {signum}, requesting graceful shutdown...")
    shutdown_requested = True


@app.command()
def init(
    redis_url: str = typer.Option("redis://localhost:6379/0", help="Redis connection URL"),
    format_filter: Optional[str] = typer.Option(None, help="Filter to specific MIME type"),
    limit: Optional[int] = typer.Option(None, help="Limit number of blobs to queue"),
    reset: bool = typer.Option(True, help="Clear existing queue first (default: True)"),
    from_file: Optional[str] = typer.Option(None, help="Load from file (format: blobid|mime_type|size)")
):
    """
    Initialize extraction queue from database or file.

    Queries PostgreSQL for extractable blobs and pushes to Redis queue,
    or loads from file with format: blobid|mime_type|size (one per line).

    By default, clears existing queue data before loading. Use --no-reset to append.
    """
    setup_logging()

    logger.info("Initializing extraction queue")

    # Connect to Redis
    queue = RedisExtractionQueue(redis_url)

    if reset:
        logger.warning("Clearing existing queue data")
        queue.clear_all()

    if from_file:
        # Load from file instead of database
        file_path = Path(from_file)
        if not file_path.exists():
            typer.echo(f"✗ File not found: {from_file}", err=True)
            raise typer.Exit(1)

        logger.info(f"Loading blobs from file: {from_file}")
        count = 0

        # Batch insert with pipeline
        pipe = queue.redis.pipeline()

        with open(file_path, 'r') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue

                parts = line.split('|')
                if len(parts) != 3:
                    logger.warning(f"Skipping malformed line: {line}")
                    continue

                blobid, mime_type, size_str = parts
                try:
                    size = int(size_str)
                except ValueError:
                    logger.warning(f"Skipping invalid size: {line}")
                    continue

                # Add to queue (same format as initialize_from_db)
                item = json.dumps({'blobid': blobid, 'mime_type': mime_type})
                pipe.zadd(queue.PRIORITY, {item: size})
                count += 1

        pipe.execute()
        queue.redis.hincrby(queue.STATS, 'queued', count)

        logger.info(f"Queue initialized with {count:,} blobs from file")
        typer.echo(f"✓ Queued {count:,} blobs for extraction")
    else:
        # Load from database (original behavior)
        db = get_db_connection()

        # Get supported MIME types from handler registry
        mime_types = get_supported_mime_types()
        logger.info(f"Supporting {len(mime_types)} archive/compression formats")

        # Seed queue from database
        count = queue.initialize_from_db(
            db=db,
            mime_types=mime_types,
            format_filter=format_filter,
            limit=limit
        )

        db.close()

        logger.info(f"Queue initialized with {count:,} blobs")
        typer.echo(f"✓ Queued {count:,} blobs for extraction")


@app.command()
def run(
    redis_url: str = typer.Option("redis://localhost:6379/0", help="Redis connection URL"),
    worker_id: Optional[int] = typer.Option(None, help="Worker ID (for multi-worker)"),
    batch_size: int = typer.Option(1000, help="Bulk insert batch size"),
    max_jobs: Optional[int] = typer.Option(None, help="Max jobs to process (for testing)")
):
    """
    Run extraction worker.

    Processes items from Redis queue until empty or interrupted.
    """
    setup_logging()

    # Register signal handlers for graceful shutdown
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    logger.info("Starting extraction worker", worker_id=worker_id)

    # Connect to Redis
    queue = RedisExtractionQueue(redis_url, worker_id=worker_id)

    # Connect to database
    db = get_db_connection()

    medium_manager = ExtractionMediumManager(db)

    jobs_processed = 0

    try:
        while not shutdown_requested:
            # Check if we've hit max_jobs limit (for testing)
            if max_jobs and jobs_processed >= max_jobs:
                logger.info(f"Reached max_jobs limit ({max_jobs})")
                break

            # Get next blob from queue
            item = queue.pop()
            if not item:
                logger.info("Queue empty, exiting")
                break

            blobid, mime_type = item

            logger.info("Processing blob", blobid=blobid, mime_type=mime_type)

            # Check if already extracted (defense in depth)
            cursor = db.cursor()
            cursor.execute("""
                SELECT medium_hash, extracted_at
                FROM medium
                WHERE source_blobid = %s AND medium_type = 'extracted'
            """, [blobid])

            existing = cursor.fetchone()
            if existing:
                logger.info(
                    f"Blob {blobid[:8]}... already extracted to {existing['medium_hash']} "
                    f"at {existing['extracted_at']}, skipping"
                )
                queue.mark_complete(blobid)
                jobs_processed += 1
                continue

            try:
                logger.debug(f"Starting extraction for {blobid[:8]}...")

                # Get handler function name from registry
                handler_name = MIME_HANDLERS.get(mime_type)
                logger.debug(f"Registry lookup result: {handler_name}")

                if not handler_name:
                    raise ValueError(f"No handler for MIME type: {mime_type}")

                logger.debug(f"Selected handler: {handler_name} for {mime_type}")
                logger.debug("Attempting to import handlers...")

                # Import handler function (Phase 3 will implement these)
                from ntt_extractor_handlers import (
                    decompress_gzip, decompress_bzip2, decompress_xz,
                    decompress_compress, decompress_lzip,
                    extract_tar, extract_zip, extract_ar,
                    extract_rar, extract_cab, extract_7z,
                    extract_tar_gz, extract_tar_bz2, extract_tar_xz
                )
                logger.debug("Import successful")

                handlers = {
                    'decompress_gzip': decompress_gzip,
                    'decompress_bzip2': decompress_bzip2,
                    'decompress_xz': decompress_xz,
                    'decompress_compress': decompress_compress,
                    'decompress_lzip': decompress_lzip,
                    'extract_tar': extract_tar,
                    'extract_zip': extract_zip,
                    'extract_ar': extract_ar,
                    'extract_rar': extract_rar,
                    'extract_cab': extract_cab,
                    'extract_7z': extract_7z,
                    'extract_tar_gz': extract_tar_gz,
                    'extract_tar_bz2': extract_tar_bz2,
                    'extract_tar_xz': extract_tar_xz,
                }

                handler_func = handlers[handler_name]
                logger.debug(f"Calling handler function: {handler_func.__name__}")

                # Execute extraction (will fail in Phase 2 - handlers are stubs)
                result = handler_func(db, blobid)
                logger.debug(f"Handler returned: files={result.files_extracted}, nested={len(result.nested_archives)}")

                # Mark complete
                medium_manager.mark_extraction_complete(
                    blobid=blobid,
                    files_extracted=result.files_extracted,
                    medium_hash=result.medium_hash
                )

                queue.mark_complete(blobid)

                # Queue nested archives (depth-first)
                for nested_blobid, nested_mime in result.nested_archives:
                    queue.push_nested(nested_blobid, nested_mime)

                jobs_processed += 1

                logger.info(
                    "Extraction complete",
                    blobid=blobid,
                    files=result.files_extracted,
                    nested=len(result.nested_archives)
                )

            except Exception as e:
                import traceback
                logger.error(
                    f"Extraction failed: {e}",
                    blobid=blobid,
                    error=str(e),
                    error_type=type(e).__name__,
                    traceback=traceback.format_exc()
                )

                # CRITICAL: Rollback aborted transaction FIRST
                try:
                    db.rollback()
                    logger.debug("Rolled back failed transaction")
                except Exception as rollback_error:
                    logger.error(f"Rollback failed: {rollback_error}")

                # NOW we can mark as failed (in new transaction)
                try:
                    medium_manager.mark_extraction_failed(blobid, str(e))
                    queue.mark_failed(blobid, str(e))
                except Exception as cleanup_error:
                    logger.error(f"Failed to mark extraction as failed: {cleanup_error}")

    finally:
        db.close()
        logger.info("Worker shutdown complete", jobs_processed=jobs_processed)


@app.command()
def status(
    redis_url: str = typer.Option("redis://localhost:6379/0", help="Redis connection URL")
):
    """
    Show queue status and statistics.
    """
    setup_logging()

    queue = RedisExtractionQueue(redis_url)

    # Get stats
    stats = queue.get_stats()
    queue_size = queue.queue_size()
    in_progress = queue.in_progress_count()
    workers = queue.get_in_progress_workers()

    typer.echo("\n=== NTT Extraction Queue Status ===\n")

    typer.echo(f"Queue size:     {queue_size:,}")
    typer.echo(f"In progress:    {in_progress:,}")
    typer.echo(f"Completed:      {stats.get('processed', 0):,}")
    typer.echo(f"Failed:         {stats.get('failed', 0):,}")
    typer.echo(f"Total queued:   {stats.get('queued', 0):,}")

    if workers:
        typer.echo(f"\nActive workers: {len(workers)}")
        for worker_id, pid in workers.items():
            typer.echo(f"  - {worker_id} (PID: {pid})")


@app.command()
def report(
    hours: int = typer.Option(24, help="Look back this many hours"),
    by_method: bool = typer.Option(True, help="Group by extraction method")
):
    """
    Show extraction statistics from database.

    Reports on archives extracted, files produced, and sizes by extraction method.
    """
    setup_logging()

    db = get_db_connection()

    typer.echo(f"\n=== NTT Extraction Report (last {hours} hours) ===\n")

    # Get extraction summary by method
    query = """
        SELECT
            m.extraction_method,
            COUNT(DISTINCT m.medium_hash) as archives_extracted,
            COUNT(DISTINCT i.blobid) as files_extracted,
            pg_size_pretty(SUM(i.size)::bigint) as total_size,
            MIN(m.extracted_at) as first_extraction,
            MAX(m.extracted_at) as last_extraction
        FROM medium m
        LEFT JOIN inode i ON i.medium_hash = m.medium_hash
        WHERE m.medium_type = 'extracted'
          AND m.extracted_at > NOW() - INTERVAL '%s hours'
        GROUP BY m.extraction_method
        ORDER BY m.extraction_method
    """

    cursor = db.execute(query, [hours])
    results = cursor.fetchall()

    if not results:
        typer.echo(f"No extractions found in the last {hours} hours.")
        db.close()
        return

    # Print header
    typer.echo(f"{'Method':<15} {'Archives':<10} {'Files':<10} {'Size':<12} {'First':<20} {'Last':<20}")
    typer.echo("-" * 95)

    total_archives = 0
    total_files = 0

    for row in results:
        method = row['extraction_method']
        archives = row['archives_extracted']
        files = row['files_extracted'] or 0
        size = row['total_size']
        first = row['first_extraction'].strftime('%Y-%m-%d %H:%M:%S') if row['first_extraction'] else 'N/A'
        last = row['last_extraction'].strftime('%Y-%m-%d %H:%M:%S') if row['last_extraction'] else 'N/A'

        typer.echo(f"{method:<15} {archives:<10} {files:<10} {size:<12} {first:<20} {last:<20}")

        total_archives += archives
        total_files += files

    # Print totals
    typer.echo("-" * 95)
    typer.echo(f"{'TOTAL':<15} {total_archives:<10} {total_files:<10}")
    typer.echo()

    db.close()


@app.command()
def reset(
    redis_url: str = typer.Option("redis://localhost:6379/0", help="Redis connection URL"),
    confirm: bool = typer.Option(False, "--yes", help="Skip confirmation prompt")
):
    """
    Clear all queue data (DESTRUCTIVE).
    """
    setup_logging()

    if not confirm:
        typer.confirm("This will clear ALL queue data. Continue?", abort=True)

    queue = RedisExtractionQueue(redis_url)
    queue.clear_all()

    typer.echo("✓ Queue data cleared")


@app.command()
def recover(
    redis_url: str = typer.Option("redis://localhost:6379/0", help="Redis connection URL")
):
    """
    Recover stuck jobs from crashed workers.

    Clears in-progress tracking for jobs that were never completed.
    """
    setup_logging()

    queue = RedisExtractionQueue(redis_url)

    count = queue.recover_stuck_jobs()

    if count > 0:
        logger.warning(f"Recovered {count} stuck jobs")
        typer.echo(f"✓ Recovered {count} stuck jobs")
    else:
        typer.echo("✓ No stuck jobs found")


if __name__ == "__main__":
    app()
