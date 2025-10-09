#!/usr/bin/env python3
"""
Verify /mnt/sdc1-test paths in database

Author: PB and Claude
Date: 2025-10-08
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/verify_sdc1_paths.py
"""

import subprocess
import psycopg2
from collections import Counter

# Configuration
MEDIUM_HASH = 'bb226d2ae226b3e048f486e38c55b3bd'
SAMPLE_SIZE = 300
MOUNT_POINT = '/mnt/sdc1-test'

def get_random_file_paths(n=300):
    """Get n random file paths from filesystem."""
    cmd = f'find {MOUNT_POINT} -type f 2>/dev/null'
    find_proc = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE)
    shuf_proc = subprocess.Popen(['shuf', '-n', str(n)],
                                  stdin=find_proc.stdout,
                                  stdout=subprocess.PIPE,
                                  text=True)
    find_proc.stdout.close()
    paths = shuf_proc.communicate()[0].strip().split('\n')
    return [p for p in paths if p]

def check_paths_in_db(paths):
    """Check if paths exist in database and have blobids."""
    conn = psycopg2.connect(database="copyjob")
    cur = conn.cursor()

    results = {
        'in_db_with_blobid': 0,
        'in_db_no_blobid': 0,
        'in_db_excluded': 0,
        'not_in_db': 0,
    }

    details = []

    for path in paths:
        cur.execute("""
            SELECT blobid IS NOT NULL as has_blobid, exclude_reason
            FROM path
            WHERE medium_hash = %s
              AND path = %s
        """, (MEDIUM_HASH, path.encode('utf-8')))

        row = cur.fetchone()
        if row is None:
            results['not_in_db'] += 1
            details.append(('MISSING', path, None, None))
        else:
            has_blobid, exclude_reason = row
            if exclude_reason:
                results['in_db_excluded'] += 1
                details.append(('EXCLUDED', path, has_blobid, exclude_reason))
            elif has_blobid:
                results['in_db_with_blobid'] += 1
                details.append(('OK', path, True, None))
            else:
                results['in_db_no_blobid'] += 1
                details.append(('NO_BLOBID', path, False, exclude_reason))

    conn.close()
    return results, details

def main():
    print(f"=== Phase 1: Deep Sample Verification ===\n")
    print(f"Sampling {SAMPLE_SIZE} random files from {MOUNT_POINT}...")

    paths = get_random_file_paths(SAMPLE_SIZE)
    print(f"Got {len(paths)} file paths\n")

    print("Checking paths in database...")
    results, details = check_paths_in_db(paths)

    print(f"\n=== Results ===")
    print(f"Total sampled:        {len(paths)}")
    print(f"In DB with blobid:    {results['in_db_with_blobid']} ({100*results['in_db_with_blobid']/len(paths):.2f}%)")
    print(f"In DB, excluded:      {results['in_db_excluded']} ({100*results['in_db_excluded']/len(paths):.2f}%)")
    print(f"In DB, no blobid:     {results['in_db_no_blobid']} ({100*results['in_db_no_blobid']/len(paths):.2f}%)")
    print(f"Not in DB:            {results['not_in_db']} ({100*results['not_in_db']/len(paths):.2f}%)")

    # Show problematic cases
    if results['not_in_db'] > 0:
        print(f"\n=== Files NOT in database ({results['not_in_db']}) ===")
        for status, path, _, _ in details:
            if status == 'MISSING':
                print(f"  {path}")

    if results['in_db_no_blobid'] > 0:
        print(f"\n=== Files in DB without blobid ({results['in_db_no_blobid']}) ===")
        for status, path, _, _ in details:
            if status == 'NO_BLOBID':
                print(f"  {path}")

if __name__ == '__main__':
    main()
