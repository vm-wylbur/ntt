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

import os
import signal
import sys
import time
from typing import Optional

import psycopg
import redis
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
    reset: bool = typer.Option(False, help="Clear existing queue first")
):
    """
    Initialize extraction queue from database.

    Queries PostgreSQL for extractable blobs and pushes to Redis queue.
    """
    setup_logging()

    logger.info("Initializing extraction queue")

    # Connect to Redis
    queue = RedisExtractionQueue(redis_url)

    if reset:
        logger.warning("Clearing existing queue data")
        queue.clear_all()

    # Connect to database
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

            logger.info(f"Processing blob", blobid=blobid, mime_type=mime_type)

            try:
                logger.debug(f"Starting extraction for {blobid[:8]}...")

                # Get handler function name from registry
                handler_name = MIME_HANDLERS.get(mime_type)
                logger.debug(f"Registry lookup result: {handler_name}")

                if not handler_name:
                    raise ValueError(f"No handler for MIME type: {mime_type}")

                logger.debug(f"Selected handler: {handler_name} for {mime_type}")
                logger.debug(f"Attempting to import handlers...")

                # Import handler function (Phase 3 will implement these)
                from ntt_extractor_handlers import (
                    decompress_gzip, decompress_bzip2, decompress_xz,
                    decompress_compress, decompress_lzip,
                    extract_tar, extract_zip, extract_ar,
                    extract_rar, extract_cab, extract_7z,
                    extract_tar_gz, extract_tar_bz2, extract_tar_xz
                )
                logger.debug(f"Import successful")

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
                medium_manager.mark_extraction_failed(blobid, str(e))
                queue.mark_failed(blobid, str(e))

    finally:
        db.close()
        logger.info(f"Worker shutdown complete", jobs_processed=jobs_processed)


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
