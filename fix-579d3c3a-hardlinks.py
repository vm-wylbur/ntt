#!/usr/bin/env python3
"""
Recreate hardlinks for 579d3c3a archived directory.

This medium had all files copied to by-hash, but hardlinks weren't created
in /data/cold/archived. This script recreates them using database state.
"""

import os
import psycopg
from pathlib import Path

HASH = '579d3c3a476185f524b77b286c5319f5'
BY_HASH_ROOT = Path('/data/cold/by-hash')
ARCHIVE_ROOT = Path('/data/cold/archived')

def main():
    # Build connection string (same as ntt-copier when running under sudo)
    db_url = 'postgresql:///copyjob'
    if os.geteuid() == 0 and 'SUDO_USER' in os.environ:
        user = os.environ['SUDO_USER']
        db_url = f'postgresql://{user}@localhost/copyjob'

    # Connect to database
    conn = psycopg.connect(db_url)
    cur = conn.cursor()

    # Get all paths with blobids
    cur.execute("""
        SELECT path, blobid
        FROM path
        WHERE medium_hash = %s AND blobid IS NOT NULL
        ORDER BY path
    """, (HASH,))

    rows = cur.fetchall()
    print(f"Found {len(rows)} paths to process")

    created = 0
    existed = 0
    errors = 0

    for path_bytes, blobid in rows:
        # Decode path
        path_str = path_bytes.decode('utf-8', errors='replace')

        # Create archive path (strip leading /)
        archive_path = ARCHIVE_ROOT / path_str.lstrip('/')

        # Create by-hash path
        by_hash_path = BY_HASH_ROOT / blobid[:2] / blobid[2:4] / blobid

        # Check if by-hash exists
        if not by_hash_path.exists():
            print(f"ERROR: by-hash missing: {blobid[:16]}...")
            errors += 1
            continue

        # Create parent directory
        archive_path.parent.mkdir(parents=True, exist_ok=True, mode=0o755)

        # Check if hardlink already exists
        if archive_path.exists():
            existed += 1
            continue

        # Create hardlink
        try:
            os.link(by_hash_path, archive_path)
            created += 1
            if created % 1000 == 0:
                print(f"Progress: {created} created, {existed} existed, {errors} errors")
        except FileExistsError:
            existed += 1
        except Exception as e:
            print(f"ERROR creating {archive_path}: {e}")
            errors += 1

    print(f"\nDone!")
    print(f"  Created: {created}")
    print(f"  Existed: {existed}")
    print(f"  Errors: {errors}")

    conn.close()

if __name__ == '__main__':
    main()
