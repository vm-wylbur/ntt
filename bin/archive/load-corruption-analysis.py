#!/usr/bin/env python3
"""
Load corruption analysis results from JSONL into PostgreSQL.

Reads results from analyze-carved-corruption.py and analyze-extra-bytes.py
and loads them into the dd4918_corruption_analysis table.

Author: PB and Claude
Date: 2025-11-22
License: (c) HRDAG, 2025, GPL-2 or newer
"""

import json
import sys
from pathlib import Path
import psycopg2
from psycopg2.extras import execute_batch

def load_corruption_data(corruption_file, extra_bytes_file, db_conn):
    """
    Load corruption analysis data into PostgreSQL.

    Args:
        corruption_file: Path to corruption_analysis.jsonl
        extra_bytes_file: Path to extra_bytes_analysis.jsonl (optional)
        db_conn: PostgreSQL connection
    """
    # First, load extra bytes data into a dict for lookup
    extra_bytes_data = {}
    if extra_bytes_file and extra_bytes_file.exists():
        print(f"Loading extra bytes data from {extra_bytes_file}...", file=sys.stderr)
        with extra_bytes_file.open() as f:
            for line in f:
                if not line.strip():
                    continue
                rec = json.loads(line)
                key = (rec['dd_blobid'], rec['other_blobid'])
                extra_bytes_data[key] = rec
        print(f"Loaded {len(extra_bytes_data)} extra bytes records", file=sys.stderr)

    # Now load corruption data and merge with extra bytes
    print(f"Loading corruption data from {corruption_file}...", file=sys.stderr)

    batch = []
    batch_size = 1000
    total_loaded = 0

    cursor = db_conn.cursor()

    with corruption_file.open() as f:
        for line in f:
            if not line.strip():
                continue

            rec = json.loads(line)

            # Get extra bytes data if available
            key = (rec['dd_blobid'], rec['other_blobid'])
            extra = extra_bytes_data.get(key, {})

            # Prepare row for insertion
            row = (
                rec['dd_blobid'],
                rec['other_blobid'],
                rec['status'],
                rec['dd_size'],
                rec['other_size'],
                rec['diff_count'],
                rec.get('first_diff_byte'),  # May be None
                # Extra bytes columns (all may be None)
                extra.get('extra_bytes'),
                extra.get('all_zeros'),
                extra.get('pct_zeros'),
                extra.get('pct_printable'),
                extra.get('entropy_estimate'),
            )

            batch.append(row)

            if len(batch) >= batch_size:
                execute_batch(cursor, """
                    INSERT INTO dd4918_corruption_analysis (
                        dd_blobid, other_blobid, status,
                        dd_size, other_size,
                        diff_count, first_diff_byte,
                        extra_bytes, extra_all_zeros,
                        extra_pct_zeros, extra_pct_printable,
                        extra_entropy
                    ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                    ON CONFLICT (dd_blobid, other_blobid) DO UPDATE SET
                        status = EXCLUDED.status,
                        dd_size = EXCLUDED.dd_size,
                        other_size = EXCLUDED.other_size,
                        diff_count = EXCLUDED.diff_count,
                        first_diff_byte = EXCLUDED.first_diff_byte,
                        extra_bytes = EXCLUDED.extra_bytes,
                        extra_all_zeros = EXCLUDED.extra_all_zeros,
                        extra_pct_zeros = EXCLUDED.extra_pct_zeros,
                        extra_pct_printable = EXCLUDED.extra_pct_printable,
                        extra_entropy = EXCLUDED.extra_entropy
                """, batch)

                db_conn.commit()
                total_loaded += len(batch)
                print(f"Loaded {total_loaded} records...", file=sys.stderr)
                batch = []

    # Insert remaining batch
    if batch:
        execute_batch(cursor, """
            INSERT INTO dd4918_corruption_analysis (
                dd_blobid, other_blobid, status,
                dd_size, other_size,
                diff_count, first_diff_byte,
                extra_bytes, extra_all_zeros,
                extra_pct_zeros, extra_pct_printable,
                extra_entropy
            ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (dd_blobid, other_blobid) DO UPDATE SET
                status = EXCLUDED.status,
                dd_size = EXCLUDED.dd_size,
                other_size = EXCLUDED.other_size,
                diff_count = EXCLUDED.diff_count,
                first_diff_byte = EXCLUDED.first_diff_byte,
                extra_bytes = EXCLUDED.extra_bytes,
                extra_all_zeros = EXCLUDED.extra_all_zeros,
                extra_pct_zeros = EXCLUDED.extra_pct_zeros,
                extra_pct_printable = EXCLUDED.extra_pct_printable,
                extra_entropy = EXCLUDED.extra_entropy
        """, batch)

        db_conn.commit()
        total_loaded += len(batch)

    cursor.close()
    print(f"Total loaded: {total_loaded} records", file=sys.stderr)

    return total_loaded

def main():
    if len(sys.argv) < 2 or len(sys.argv) > 3:
        print(f"Usage: {sys.argv[0]} <corruption_analysis.jsonl> [extra_bytes_analysis.jsonl]", file=sys.stderr)
        sys.exit(1)

    corruption_file = Path(sys.argv[1])
    extra_bytes_file = Path(sys.argv[2]) if len(sys.argv) == 3 else None

    if not corruption_file.exists():
        print(f"Error: {corruption_file} not found", file=sys.stderr)
        sys.exit(1)

    if extra_bytes_file and not extra_bytes_file.exists():
        print(f"Warning: {extra_bytes_file} not found, skipping extra bytes data", file=sys.stderr)
        extra_bytes_file = None

    # Connect to database
    print("Connecting to database...", file=sys.stderr)
    conn = psycopg2.connect(dbname='copyjob')

    try:
        # Load data
        total = load_corruption_data(corruption_file, extra_bytes_file, conn)

        # Show statistics
        print("\n=== Database Statistics ===", file=sys.stderr)
        cursor = conn.cursor()

        cursor.execute("""
            SELECT status, COUNT(*) as count
            FROM dd4918_corruption_analysis
            GROUP BY status
            ORDER BY status
        """)

        print("\nRecords by status:", file=sys.stderr)
        for status, count in cursor.fetchall():
            print(f"  {status:20s}: {count:,}", file=sys.stderr)

        cursor.execute("SELECT COUNT(*) FROM dd4918_corruption_analysis")
        total_in_db = cursor.fetchone()[0]
        print(f"\nTotal in database: {total_in_db:,}", file=sys.stderr)

        cursor.close()

    finally:
        conn.close()

if __name__ == '__main__':
    main()
