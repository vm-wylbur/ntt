#!/usr/bin/env -S /home/pball/.local/bin/uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = [
#     "psycopg[binary]",
#     "loguru",
#     "blake3",
# ]
# ///
#
# Author: PB and Claude
# Date: 2025-09-29
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/bin/ntt-re-hardlink.py
#
# NTT re-hardlink tool - repairs missing hardlinks between by-hash and archive
#
# Performance learnings:
# - Batch size 50 is optimal (127 blobs/sec vs 106 with batch 100)
# - 32 workers is optimal (127 blobs/sec vs 106 with 64 workers)
# - Batching DB queries is critical (40->127 blobs/sec improvement)
# - Directory cache prevents redundant mkdir calls
# - Parallel batch processing achieves 226 blobs/sec (2.27x improvement)
#
# Requirements:
#   - Python 3.13+
#   - Must run as root/sudo
#   - Environment: sudo -E PATH="$PATH" or: sudo env PATH="$PATH" $(cat /etc/hrdag/ntt.env | xargs) ntt-re-hardlink.py

import argparse
import os
import sys
import time
import threading
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

import psycopg
from psycopg.rows import dict_row
from loguru import logger

# Database connection
DB_URL = os.environ.get('NTT_DB_URL', 'postgresql:///copyjob')

# Storage paths
BY_HASH_ROOT = Path('/data/cold/by-hash')
ARCHIVE_ROOT = Path('/data/cold/archived')

# Fix DB URL if running as sudo
if 'SUDO_USER' in os.environ:
    # When running with sudo, we need to connect as the sudo user
    # Change the implicit connection to explicit user@localhost
    if DB_URL.startswith('postgresql:///'):
        DB_URL = DB_URL.replace(':///', f"://{os.environ['SUDO_USER']}@localhost/")


def process_batch(batch_data, created_dirs, dir_lock, output_blobs, dry_run, verbose):
    """Process a single batch of blobs using its own DB connection.
    
    Args:
        batch_data: Tuple of (batch_idx, batch, db_conn)
        created_dirs: Shared set of already-created directories
        dir_lock: Threading lock for created_dirs access
        output_blobs: Whether to track blob IDs for output
        dry_run: Whether this is a dry run
        verbose: Whether to output verbose logging
    
    Returns:
        Tuple of (batch_idx, batch_stats, batch_timings)
    """
    batch_idx, batch, db_conn = batch_data
    batch_stats = {
        'blobs_processed': 0,
        'by_hash_missing': 0,
        'hardlinks_created': 0,
        'hardlinks_existed': 0,
        'errors': 0,
        'processed_blobs': []
    }
    batch_timings = {
        'query_paths': 0,
        'create_dirs': 0,
        'create_links': 0,
        'update_db': 0
    }
    
    with db_conn.cursor() as batch_cur:
        # Query all paths for this batch
        # psycopg automatically prepares repeated queries
        t1 = time.time()
        blob_ids = [b['blobid'] for b in batch]
        batch_cur.execute("""
            SELECT 
                i.hash as hex_hash,
                p.path
            FROM path p
            JOIN inode i ON p.dev = i.dev AND p.ino = i.ino
            WHERE i.hash = ANY(%s)
            ORDER BY i.hash, p.path
        """, (blob_ids,))
        all_paths = batch_cur.fetchall()
        batch_timings['query_paths'] = time.time() - t1
        
        # Group paths by blob
        paths_by_blob = {}
        for row in all_paths:
            hex_hash = row['hex_hash']
            if hex_hash not in paths_by_blob:
                paths_by_blob[hex_hash] = []
            paths_by_blob[hex_hash].append(row['path'])
        
        # Track which blobs to update
        blobs_to_update = []
        blobs_to_reset = []  # Track blobs with missing by-hash files
        
        # Process each blob in the batch
        for blob in batch:
            hex_hash = blob['hex_hash']
            by_hash_path = BY_HASH_ROOT / hex_hash[:2] / hex_hash[2:4] / hex_hash
            
            # Check if by-hash exists
            if not by_hash_path.exists():
                batch_stats['by_hash_missing'] += 1
                if verbose:
                    logger.warning(f"By-hash missing: {hex_hash[:12]}... - resetting DB counters")
                # Track for DB reset (set n_hardlinks = 0)
                if not dry_run:
                    blobs_to_reset.append(blob['blobid'])
                continue
            
            # Get paths for this blob
            paths = paths_by_blob.get(hex_hash, [])
            hardlinks_created_for_blob = 0
            hardlinks_existed_for_blob = 0
            
            if not dry_run:
                # Collect directories to create
                dirs_to_create = set()
                paths_to_link = []
                
                for path in paths:
                    archive_path = ARCHIVE_ROOT / path.lstrip('/')
                    paths_to_link.append((path, archive_path))
                    parent = archive_path.parent
                    while parent != ARCHIVE_ROOT and parent not in created_dirs:
                        dirs_to_create.add(parent)
                        parent = parent.parent
                
                # Create directories  
                t2 = time.time()
                for dir_path in sorted(dirs_to_create):
                    # Thread-safe check and add to created_dirs
                    with dir_lock:
                        if dir_path not in created_dirs:
                            try:
                                dir_path.mkdir(parents=True, exist_ok=True, mode=0o755)
                                created_dirs.add(dir_path)
                            except Exception as e:
                                logger.error(f"Failed to create directory {dir_path}: {e}")
                batch_timings['create_dirs'] += time.time() - t2
                
                # Create hardlinks
                def create_single_hardlink(args):
                    path, archive_path = args
                    try:
                        os.link(by_hash_path, archive_path)
                        return ('created', path)
                    except FileExistsError:
                        return ('existed', path)
                    except Exception as e:
                        return ('error', path, str(e))
                
                t3 = time.time()
                # IMPORTANT: 32 workers is optimal based on testing
                # - 32 workers: 127 blobs/sec
                # - 64 workers: 106 blobs/sec (worse due to contention)
                with ThreadPoolExecutor(max_workers=32) as executor:
                    futures = [executor.submit(create_single_hardlink, args) 
                             for args in paths_to_link]
                    
                    for future in as_completed(futures):
                        result = future.result()
                        if result[0] == 'created':
                            hardlinks_created_for_blob += 1
                        elif result[0] == 'existed':
                            hardlinks_existed_for_blob += 1
                        elif result[0] == 'error':
                            batch_stats['errors'] += 1
                            if verbose:
                                logger.error(f"Failed hardlink for {result[1]}: {result[2]}")
                batch_timings['create_links'] += time.time() - t3
            else:
                # Dry run
                hardlinks_created_for_blob = len(paths)
            
            batch_stats['hardlinks_created'] += hardlinks_created_for_blob
            batch_stats['hardlinks_existed'] += hardlinks_existed_for_blob
            batch_stats['blobs_processed'] += 1
            
            if output_blobs:
                batch_stats['processed_blobs'].append(hex_hash)
            
            # Track for database update
            total_hardlinks = hardlinks_created_for_blob + hardlinks_existed_for_blob
            if not dry_run and total_hardlinks > 0:
                blobs_to_update.append((total_hardlinks, blob['blobid']))
        
        # Batch update database
        if not dry_run:
            t4 = time.time()
            
            # Update successful hardlinks
            if blobs_to_update:
                batch_cur.executemany("""
                    UPDATE blobs SET n_hardlinks = %s WHERE blobid = %s
                """, blobs_to_update)
            
            # Reset blobs with missing by-hash files
            if blobs_to_reset:
                batch_cur.executemany("""
                    UPDATE blobs SET n_hardlinks = 0 WHERE blobid = %s
                """, [(bid,) for bid in blobs_to_reset])
            
            db_conn.commit()
            batch_timings['update_db'] = time.time() - t4
    
    return batch_idx, batch_stats, batch_timings


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(description='Re-create missing hardlinks for NTT blobs')
    parser.add_argument('--limit', type=int, default=0,
                       help='Limit number of blobs to process (0 = unlimited)')
    parser.add_argument('--dry-run', action='store_true',
                       help='Show what would be done without making changes')
    parser.add_argument('--verbose', action='store_true',
                       help='Enable verbose debug logging')
    parser.add_argument('--output-blobs', action='store_true',
                       help='Write processed blob IDs to /tmp/rehardlinked_blobs.txt')
    parser.add_argument('--from-file', type=str,
                       help='Process specific blobs from a file (one hex hash per line)')
    
    args = parser.parse_args()
    
    # Configure logging
    logger.remove()
    # Add date to timestamp and set appropriate log level
    if args.verbose:
        logger.add(sys.stderr, format="{time:YYYY-MM-DD HH:mm:ss} | {level:<8} | {message}", level="DEBUG")
    else:
        logger.add(sys.stderr, format="{time:YYYY-MM-DD HH:mm:ss} | {level:<8} | {message}", level="INFO")
    
    # Check if running as root (needed for accessing all files)
    if os.geteuid() != 0:
        logger.error("Error: ntt-re-hardlink must be run as root/sudo")
        sys.exit(1)
    
    start_time = time.time()
    processed_blobs = []
    
    logger.info("=" * 60)
    logger.info("NTT RE-HARDLINK TOOL")
    if args.dry_run:
        logger.info("DRY-RUN - no changes will be made")
    logger.info("Re-creating missing hardlinks for existing by-hash files")
    logger.info("=" * 60)
    
    # Create connection pool for parallel batch processing
    # Using 4 connections: 1 main + 3 for parallel batch workers
    conn_pool = []
    try:
        for i in range(4):
            conn_pool.append(psycopg.connect(DB_URL, row_factory=dict_row))
    except Exception as e:
        logger.error(f"Failed to connect to database: {e}")
        return 1
    
    # Main connection for queries
    conn = conn_pool[0]
    
    stats = {
        'blobs_processed': 0,
        'by_hash_missing': 0,
        'hardlinks_created': 0,
        'hardlinks_existed': 0,
        'errors': 0
    }
    
    try:
        with conn.cursor() as cur:
            if args.from_file:
                # Process specific blobs from file or stdin
                if args.from_file == '-':
                    logger.info("Reading blob IDs from stdin")
                    hex_hashes = [line.strip() for line in sys.stdin if line.strip()]
                else:
                    logger.info(f"Reading blob IDs from {args.from_file}")
                    with open(args.from_file) as f:
                        hex_hashes = [line.strip() for line in f if line.strip()]
                
                # Convert hex hashes to blob records
                blobs = []
                for hex_hash in hex_hashes:
                    # Query to get blob info
                    cur.execute("""
                        SELECT 
                            blobid,
                            %s as hex_hash,
                            COALESCE(n_hardlinks, 0) as actual,
                            COALESCE(expected_hardlinks, 0) as expected
                        FROM blobs 
                        WHERE blobid = %s
                    """, (hex_hash, hex_hash))
                    
                    result = cur.fetchone()
                    if result:
                        blobs.append(result)
                    else:
                        logger.warning(f"Blob not found: {hex_hash[:12]}...")
                
                total = len(blobs)
                logger.info(f"Found {total} blobs to process from file")
            else:
                # Get incomplete blobs
                # Check if expected_hardlinks column exists (for backward compatibility)
                cur.execute("""
                    SELECT column_name 
                    FROM information_schema.columns 
                    WHERE table_name = 'blobs' 
                    AND column_name = 'expected_hardlinks'
                """)
                has_expected_column = cur.fetchone() is not None
                
                if has_expected_column:
                    # Fast query using pre-calculated expected_hardlinks
                    logger.info("Using optimized query with expected_hardlinks column")
                    query = """
                        SELECT 
                            blobid,
                            blobid as hex_hash,
                            COALESCE(n_hardlinks, 0) as actual,
                            expected_hardlinks as expected
                        FROM blobs 
                        WHERE n_hardlinks < expected_hardlinks
                        ORDER BY expected_hardlinks - n_hardlinks DESC
                    """
                else:
                    # Fallback to original query with joins
                    logger.info("Using original query (run add_expected_hardlinks.sql for 10x speedup)")
                    query = """
                        WITH blob_status AS (
                            SELECT 
                                b.blobid,
                                b.blobid as hex_hash,
                                COALESCE(b.n_hardlinks, 0) as actual,
                                COUNT(DISTINCT p.path) as expected
                            FROM blobs b
                            JOIN inode i ON i.hash = b.blobid
                            JOIN path p ON p.dev = i.dev AND p.ino = i.ino
                            GROUP BY b.blobid, b.n_hardlinks
                        )
                        SELECT blobid, hex_hash, actual, expected
                        FROM blob_status 
                        WHERE actual < expected
                        ORDER BY expected - actual DESC
                    """
                if args.limit > 0:
                    query += f" LIMIT {args.limit}"
                
                cur.execute(query)
                blobs = cur.fetchall()
                total = len(blobs)
                
                if total == 0:
                    logger.success("No incomplete blobs found - all hardlinks are complete!")
                    return 0
                
                logger.info(f"Found {total} incomplete blobs to process...")
                
                if args.limit > 0 and total == args.limit:
                    # There might be more incomplete blobs
                    if has_expected_column:
                        # Fast count using expected_hardlinks
                        cur.execute("""
                            SELECT COUNT(*) as total_incomplete 
                            FROM blobs 
                            WHERE n_hardlinks < expected_hardlinks
                        """)
                    else:
                        # Original slow count query
                        cur.execute("""
                            SELECT COUNT(*) as total_incomplete FROM (
                                WITH blob_status AS (
                                    SELECT 
                                        b.blobid,
                                        COALESCE(b.n_hardlinks, 0) as actual,
                                        COUNT(DISTINCT p.path) as expected
                                    FROM blobs b
                                    JOIN inode i ON i.hash = b.blobid
                                    JOIN path p ON p.dev = i.dev AND p.ino = i.ino
                                    GROUP BY b.blobid, b.n_hardlinks
                                )
                                SELECT 1 FROM blob_status WHERE actual < expected
                            ) t
                        """)
                    result = cur.fetchone()
                    if result:
                        logger.info(f"Total incomplete blobs in database: {result['total_incomplete']}")
            
            # Add timing instrumentation
            blob_timings = {
                'query_paths': 0,
                'create_dirs': 0,
                'create_links': 0,
                'update_db': 0
            }
            
            # Cache for already-created directories to avoid redundant mkdir calls
            # Note: Using threading.Lock for thread-safe access
            created_dirs = set()
            dir_lock = threading.Lock()
            
            # Process blobs in batches for efficiency
            # IMPORTANT: Batch size 50 is optimal based on testing
            # - 50 blobs: 127 blobs/sec
            # - 100 blobs: 106 blobs/sec (worse due to larger transactions)
            BATCH_SIZE = 50
            
            # Process batches in parallel using multiple DB connections
            # Use 3 parallel workers for batch processing (1 main + 3 workers = 4 total connections)
            with ThreadPoolExecutor(max_workers=3) as batch_executor:
                futures = []
                batch_idx = 0
                
                # Submit initial batches
                for batch_start in range(0, min(total, BATCH_SIZE * 3), BATCH_SIZE):
                    batch_end = min(batch_start + BATCH_SIZE, total)
                    batch = blobs[batch_start:batch_end]
                    # Use connection from pool (1-3 for workers, 0 is main)
                    conn_idx = (batch_idx % 3) + 1
                    futures.append(batch_executor.submit(
                        process_batch, 
                        (batch_idx, batch, conn_pool[conn_idx]),
                        created_dirs, dir_lock, args.output_blobs, args.dry_run, args.verbose
                    ))
                    batch_idx += 1
                
                # Process completed batches and submit new ones
                next_batch_start = BATCH_SIZE * 3
                completed_count = 0
                
                while futures:
                    # Wait for any batch to complete
                    for future in as_completed(futures):
                        idx, batch_stats, batch_timings = future.result()
                        
                        # Update global stats
                        stats['blobs_processed'] += batch_stats['blobs_processed']
                        stats['by_hash_missing'] += batch_stats['by_hash_missing']
                        stats['hardlinks_created'] += batch_stats['hardlinks_created']
                        stats['hardlinks_existed'] += batch_stats['hardlinks_existed']
                        stats['errors'] += batch_stats['errors']
                        
                        # Update global timings
                        for key in blob_timings:
                            blob_timings[key] += batch_timings[key]
                        
                        # Add processed blobs to list
                        if args.output_blobs:
                            processed_blobs.extend(batch_stats['processed_blobs'])
                        
                        completed_count += batch_stats['blobs_processed']
                        
                        # Log progress
                        if completed_count > 0 and completed_count % 100 == 0:
                            logger.info(f"Progress: {completed_count}/{total} ({completed_count*100/total:.1f}%) - "
                                      f"{stats['hardlinks_created']} created, {stats['hardlinks_existed']} existed")
                            if args.verbose:
                                logger.debug(f"Avg times per blob: query_paths={blob_timings['query_paths']/completed_count:.3f}s, "
                                           f"dirs={blob_timings['create_dirs']/completed_count:.3f}s, "
                                           f"links={blob_timings['create_links']/completed_count:.3f}s, "
                                           f"db={blob_timings['update_db']/completed_count:.3f}s")
                        
                        # Remove completed future
                        futures.remove(future)
                        
                        # Submit next batch if available
                        if next_batch_start < total:
                            batch_end = min(next_batch_start + BATCH_SIZE, total)
                            batch = blobs[next_batch_start:batch_end]
                            conn_idx = (batch_idx % 3) + 1
                            futures.append(batch_executor.submit(
                                process_batch,
                                (batch_idx, batch, conn_pool[conn_idx]),
                                created_dirs, dir_lock, args.output_blobs, args.dry_run, args.verbose
                            ))
                            batch_idx += 1
                            next_batch_start += BATCH_SIZE
                        
                        # Only process one completed future at a time
                        break
        
        if not args.dry_run:
            conn.commit()  # Final commit for any remaining updates
            logger.info("Database updated")
        
    except Exception as e:
        logger.error(f"Fatal error: {e}")
        for conn in conn_pool:
            try:
                conn.rollback()
            except:
                pass
        return 1
    finally:
        # Close all connections in the pool
        for conn in conn_pool:
            try:
                conn.close()
            except:
                pass
    
    # Print summary
    logger.success("=" * 60)
    logger.success("Re-hardlink Complete")
    logger.success(f"Blobs processed: {stats['blobs_processed']}")
    logger.success(f"By-hash missing: {stats['by_hash_missing']}")
    logger.success(f"Hardlinks created: {stats['hardlinks_created']}")
    logger.success(f"Hardlinks existed: {stats['hardlinks_existed']}")
    if stats['errors'] > 0:
        logger.error(f"Errors: {stats['errors']}")
    
    # Check if there might be more work
    if args.limit > 0 and stats['blobs_processed'] == args.limit:
        logger.info("Limit reached - there may be more incomplete blobs")
        logger.info("Run again to continue processing remaining incomplete blobs")
    
    # Show total elapsed time and rates
    elapsed = time.time() - start_time
    if elapsed > 0:
        blobs_per_sec = stats['blobs_processed'] / elapsed if stats['blobs_processed'] > 0 else 0
        links_per_sec = stats['hardlinks_created'] / elapsed if stats['hardlinks_created'] > 0 else 0
        logger.info(f"Total elapsed time: {elapsed:.1f} seconds ({elapsed/60:.1f} minutes)")
        if stats['blobs_processed'] > 0:
            logger.info(f"Processing rate: {blobs_per_sec:.1f} blobs/sec, {links_per_sec:.0f} hardlinks/sec")
            
            # Show timing breakdown if we have it
            if blob_timings and stats['blobs_processed'] > 0:
                n = stats['blobs_processed']
                logger.info(f"Per-blob timing: query_paths={blob_timings['query_paths']/n:.3f}s, "
                           f"dirs={blob_timings['create_dirs']/n:.3f}s, "
                           f"links={blob_timings['create_links']/n:.3f}s, "
                           f"db_update={blob_timings['update_db']/n:.3f}s")
                total_per_blob = sum(blob_timings.values()) / n
                logger.info(f"Total per blob: {total_per_blob:.3f}s ({1/total_per_blob:.1f} blobs/sec theoretical)")
    else:
        logger.info(f"Total elapsed time: {elapsed:.1f} seconds")
    
    logger.success("=" * 60)
    
    # Output processed blobs if requested
    if args.output_blobs and processed_blobs:
        output_file = Path('/tmp/rehardlinked_blobs.txt')
        with open(output_file, 'w') as f:
            for blob in processed_blobs:
                f.write(f"{blob}\n")
        logger.info(f"Wrote {len(processed_blobs)} blob IDs to {output_file}")
        logger.info("To verify these blobs, run:")
        logger.info(f"  sudo /home/pball/projects/ntt/bin/ntt-verify.py --from-file {output_file}")
    
    return 0 if stats['errors'] == 0 else 1


if __name__ == '__main__':
    sys.exit(main())