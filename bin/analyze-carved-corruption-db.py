#!/usr/bin/env python3
"""
Analyze corruption patterns in carved GRAID recovery files - direct to PostgreSQL.

Runs `cmp` on pairs of (dd4918_carved, original) files and saves directly to database.
Supports resume from interruption by skipping already-analyzed pairs.

Author: PB and Claude
Date: 2025-11-22
License: (c) HRDAG, 2025, GPL-2 or newer
"""

import subprocess
import sys
from pathlib import Path
import psycopg2
from collections import Counter

def get_blob_path(blobid):
    """Convert blobid to by-hash filesystem path."""
    return f"/data/fast/ntt/by-hash/{blobid[:2]}/{blobid[2:4]}/{blobid}"

def analyze_pair(dd_blobid, other_blobid, max_diffs=1000):
    """
    Compare two files and return corruption analysis.

    Returns tuple: (dd_blobid, other_blobid, status, dd_size, other_size,
                    diff_count, first_diff_byte, extra_bytes, extra_all_zeros,
                    extra_pct_zeros, extra_pct_printable, extra_entropy, unusable)
    """
    # Get file paths
    dd_path = Path(get_blob_path(dd_blobid))
    other_path = Path(get_blob_path(other_blobid))

    # Get file sizes
    try:
        dd_size = dd_path.stat().st_size
        other_size = other_path.stat().st_size
    except FileNotFoundError as e:
        print(f"ERROR: File not found: {e.filename}", file=sys.stderr)
        return None

    # Run cmp -l to get byte-level differences
    proc = subprocess.run(
        ['cmp', '-l', str(dd_path), str(other_path)],
        capture_output=True,
        text=True
    )

    if proc.returncode == 0:
        # Identical
        return (dd_blobid, other_blobid, 'identical', dd_size, other_size,
                0, None, None, None, None, None, None, False)

    elif proc.returncode == 1:
        # Files differ
        lines = proc.stdout.strip().split('\n')
        diff_count = len(lines) if lines[0] else 0

        # Get first diff position
        first_diff_byte = None
        if lines and lines[0]:
            parts = lines[0].split()
            if len(parts) == 3:
                first_diff_byte = int(parts[0]) - 1

        # Classify corruption type
        if diff_count == 0 and dd_size < other_size:
            # DD is shorter but overlapping bytes match
            status = 'truncated'
        elif diff_count == 0 and dd_size > other_size:
            # DD is larger but overlapping bytes match - analyze padding
            status = 'extra_padding'
        elif diff_count > 0 and dd_size < other_size * 0.05:
            # DD is tiny compared to other - likely wrong match from chunk overlap
            status = 'wrong_match'
        else:
            # Actual byte-level corruption
            status = 'byte_corruption'

        # Analyze extra bytes if DD file is larger with 0 byte diffs
        extra_bytes = None
        extra_all_zeros = None
        extra_pct_zeros = None
        extra_pct_printable = None
        extra_entropy = None

        if status == 'extra_padding':
            extra_bytes = dd_size - other_size

            # Read extra bytes
            try:
                with dd_path.open('rb') as f:
                    f.seek(other_size)
                    extra_data = f.read()

                # Analyze content
                byte_counts = Counter(extra_data)
                extra_all_zeros = all(b == 0 for b in extra_data)
                extra_pct_zeros = 100.0 * byte_counts.get(0, 0) / len(extra_data)

                printable_count = sum(1 for b in extra_data
                                     if 32 <= b < 127 or b in (9, 10, 13))
                extra_pct_printable = 100.0 * printable_count / len(extra_data)

                extra_entropy = len(byte_counts) / 256.0
            except Exception as e:
                print(f"ERROR analyzing extra bytes: {e}", file=sys.stderr)

        # Determine if file is unusable
        unusable = status in ('wrong_match', 'byte_corruption')

        return (dd_blobid, other_blobid, status, dd_size, other_size,
                diff_count, first_diff_byte, extra_bytes, extra_all_zeros,
                extra_pct_zeros, extra_pct_printable, extra_entropy, unusable)

    else:
        # Error running cmp
        print(f"ERROR running cmp: {proc.stderr.strip()}", file=sys.stderr)
        return None

def main():
    if len(sys.argv) not in [2, 3]:
        print(f"Usage: {sys.argv[0]} <pairs_tsv> [limit]", file=sys.stderr)
        print(f"  Analyzes pairs and writes directly to dd4918_corruption_analysis table", file=sys.stderr)
        print(f"  Skips pairs already in database (supports resume)", file=sys.stderr)
        sys.exit(1)

    pairs_file = Path(sys.argv[1])
    limit = int(sys.argv[2]) if len(sys.argv) == 3 else None

    # Connect to database
    print("Connecting to database...", file=sys.stderr)
    conn = psycopg2.connect(dbname='copyjob')
    cursor = conn.cursor()

    # Get already-analyzed pairs for resume support
    print("Checking for existing results...", file=sys.stderr)
    cursor.execute("""
        SELECT dd_blobid, other_blobid
        FROM dd4918_corruption_analysis
    """)
    analyzed = set(cursor.fetchall())
    print(f"Found {len(analyzed)} already-analyzed pairs", file=sys.stderr)

    # Process pairs
    processed = 0
    skipped = 0
    commit_interval = 10

    import time
    start_time = time.time()

    try:
        with pairs_file.open() as f:
            for line in f:
                line = line.strip()
                if not line or '\t' not in line:
                    continue

                dd_blobid, other_blobid = line.split('\t')

                # Skip if already analyzed
                if (dd_blobid, other_blobid) in analyzed:
                    skipped += 1
                    continue

                # Check limit
                if limit and processed >= limit:
                    break

                processed += 1
                if processed % 10 == 1:  # Log every 10th
                    elapsed = time.time() - start_time
                    rate = processed / elapsed if elapsed > 0 else 0
                    print(f"Analyzing pair {processed} ({rate:.1f}/sec, {skipped} skipped): {dd_blobid[:8]}...",
                          file=sys.stderr)

                # Analyze
                result = analyze_pair(dd_blobid, other_blobid)
                if result is None:
                    continue

                # Insert into database
                cursor.execute("""
                    INSERT INTO dd4918_corruption_analysis (
                        dd_blobid, other_blobid, status,
                        dd_size, other_size, diff_count, first_diff_byte,
                        extra_bytes, extra_all_zeros,
                        extra_pct_zeros, extra_pct_printable, extra_entropy, unusable
                    ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                    ON CONFLICT (dd_blobid, other_blobid) DO NOTHING
                """, result)

                # Commit every N pairs
                if processed % commit_interval == 0:
                    conn.commit()
                    print(f"  Committed {processed} pairs", file=sys.stderr)

        # Final commit
        conn.commit()

        # Calculate throughput
        elapsed = time.time() - start_time
        pairs_per_sec = processed / elapsed if elapsed > 0 else 0

        print(f"\n=== Run Summary ===", file=sys.stderr)
        print(f"New pairs analyzed:  {processed}", file=sys.stderr)
        print(f"Already in database: {skipped}", file=sys.stderr)
        print(f"Elapsed time:        {elapsed:.1f}s ({pairs_per_sec:.1f} pairs/sec)", file=sys.stderr)

        # Show statistics with descriptions
        status_descriptions = {
            'identical': 'Perfect matches (should not occur)',
            'truncated': 'DD shorter, overlapping bytes match (usable)',
            'extra_padding': 'DD has extra bytes, overlapping bytes match (usable)',
            'wrong_match': 'Size mismatch indicates false positive (UNUSABLE)',
            'byte_corruption': 'Actual corruption throughout file (UNUSABLE)'
        }

        cursor.execute("""
            SELECT status, COUNT(*)
            FROM dd4918_corruption_analysis
            GROUP BY status
            ORDER BY status
        """)
        print("\n=== Database Statistics ===", file=sys.stderr)
        for status, count in cursor.fetchall():
            desc = status_descriptions.get(status, '')
            print(f"  {status:20s}: {count:6,}  # {desc}", file=sys.stderr)

        cursor.execute("SELECT COUNT(*) FROM dd4918_corruption_analysis")
        total = cursor.fetchone()[0]
        print(f"\nTotal in database: {total:,}", file=sys.stderr)

    finally:
        cursor.close()
        conn.close()

if __name__ == '__main__':
    main()
