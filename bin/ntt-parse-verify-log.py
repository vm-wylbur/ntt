#!/usr/bin/env -S /home/pball/.local/bin/uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = [
#     "psycopg[binary]",
# ]
# ///
"""
Parse ntt-verify JSONL log to extract missing paths and errors.

Usage:
    # Show summary of issues
    ./ntt-parse-verify-log.py
    
    # Output blob IDs with missing paths for re-hardlinking
    ./ntt-parse-verify-log.py --blobs-only > /tmp/missing_blobs.txt
    sudo ntt-re-hardlink.py --from-file /tmp/missing_blobs.txt
    
    # Or pipe directly
    ./ntt-parse-verify-log.py --blobs-only | sudo ntt-re-hardlink.py --from-file -
"""

import json
import os
import sys
import argparse
from pathlib import Path
from collections import defaultdict

# Import database connection utility
from ntt_db import get_db_connection

def parse_verify_log(log_file):
    """Parse the verify JSONL log and extract relevant information."""
    
    stats = defaultdict(int)
    missing_paths = []
    failed_blobs = []
    errors = []
    
    with open(log_file, 'r') as f:
        for line in f:
            try:
                entry = json.loads(line)
                text = entry.get('text', '')
                record = entry.get('record', {})
                extra = record.get('extra', {})
                
                # Look for summary statistics
                if 'Verification Complete' in text:
                    print(f"Found summary: {text}")
                
                # Look for missing paths
                if 'missing path' in text:
                    missing_paths.append(text)
                
                # Look for error summaries
                if 'archived paths missing' in text:
                    print(f"Summary: {text}")
                
                # Look for blob failures
                if 'Failed:' in text or 'ERROR' in record.get('level', {}).get('name', ''):
                    errors.append(text)
                
                # Check extra fields for type markers
                if extra.get('type') == 'missing_path':
                    blob = extra.get('blob', 'unknown')
                    path = text.replace('missing path: ', '')
                    missing_paths.append({'blob': blob, 'path': path})
                
                if extra.get('type') == 'blob_failed':
                    failed_blobs.append(extra)
                
            except json.JSONDecodeError:
                continue
            except Exception as e:
                print(f"Error parsing line: {e}")
    
    return {
        'missing_paths': missing_paths,
        'failed_blobs': failed_blobs,
        'errors': errors
    }

def main():
    parser = argparse.ArgumentParser(description='Parse ntt-verify log for issues')
    parser.add_argument('--blobs-only', action='store_true',
                       help='Output only blob IDs with missing paths (for piping to ntt-re-hardlink)')
    parser.add_argument('--full-hashes', action='store_true',
                       help='Try to resolve full blob hashes from database (requires DB access)')
    parser.add_argument('--log-file', type=str, default='/var/log/ntt/verify.jsonl',
                       help='Path to verify JSONL log file')
    
    args = parser.parse_args()
    log_file = Path(args.log_file)
    
    if not log_file.exists():
        print(f"Log file not found: {log_file}", file=sys.stderr)
        sys.exit(1)
    
    if not os.access(log_file, os.R_OK):
        print(f"Permission denied: {log_file}", file=sys.stderr)
        print(f"Try running with: sudo -E {' '.join(sys.argv)}", file=sys.stderr)
        sys.exit(1)
    
    if args.blobs_only:
        # Extract unique blob IDs with missing paths (short hashes first)
        blobs_with_missing = set()
        
        with open(log_file, 'r') as f:
            for line in f:
                try:
                    entry = json.loads(line)
                    text = entry.get('text', '')
                    extra = entry.get('record', {}).get('extra', {})
                    
                    if extra.get('type') == 'missing_path' and extra.get('blob'):
                        blob = extra['blob']
                        blobs_with_missing.add(blob)
                        
                except json.JSONDecodeError:
                    continue
        
        print(f"# Found {len(blobs_with_missing)} unique blobs with missing paths", file=sys.stderr)
        
        # Resolve to full hashes if requested (batch query)
        if args.full_hashes:
            try:
                from psycopg.rows import dict_row

                db_conn = get_db_connection(row_factory=dict_row)
                
                print(f"# Resolving {len(blobs_with_missing)} short hashes to full hashes...", file=sys.stderr)
                
                # Batch query all blobs at once
                if blobs_with_missing:
                    with db_conn.cursor() as cur:
                        # Build LIKE conditions for all short hashes
                        placeholders = ' OR '.join(['convert_from(blobid, \'UTF8\') LIKE %s'] * len(blobs_with_missing))
                        patterns = [blob + '%' for blob in blobs_with_missing]
                        
                        cur.execute(f"""
                            SELECT convert_from(blobid, 'UTF8') as hex_hash
                            FROM blobs 
                            WHERE {placeholders}
                        """, patterns)
                        
                        results = cur.fetchall()
                        full_hashes = {row['hex_hash'] for row in results}
                        
                        print(f"# Resolved {len(full_hashes)} full hashes", file=sys.stderr)
                        blobs_with_missing = full_hashes
                else:
                    print(f"# No blobs to resolve", file=sys.stderr)
                
                db_conn.close()
                
            except Exception as e:
                print(f"# Warning: Could not resolve full hashes: {e}", file=sys.stderr)
                print(f"# Falling back to short hashes", file=sys.stderr)
        
        # Output blob IDs, one per line
        for blob in sorted(blobs_with_missing):
            print(blob)
        
        if not blobs_with_missing:
            print("# No blobs with missing paths found", file=sys.stderr)
    
    else:
        # Original summary mode
        results = parse_verify_log(log_file)
        
        print(f"Parsing {log_file}...")
        print(f"\n=== Parse Results ===")
        print(f"Missing paths found: {len(results['missing_paths'])}")
        print(f"Failed blobs: {len(results['failed_blobs'])}")
        print(f"Errors: {len(results['errors'])}")
        
        if results['missing_paths']:
            print(f"\n=== Sample Missing Paths ===")
            for item in results['missing_paths'][:10]:
                if isinstance(item, dict):
                    print(f"  Blob {item['blob']}: {item['path']}")
                else:
                    print(f"  {item}")
        
        if results['errors']:
            print(f"\n=== Sample Errors ===")
            for error in results['errors'][:10]:
                print(f"  {error}")
        
        # Show unique blobs with missing paths
        unique_blobs = set()
        for item in results['missing_paths']:
            if isinstance(item, dict) and 'blob' in item:
                unique_blobs.add(item['blob'])
        
        if unique_blobs:
            print(f"\n=== Unique Blobs with Missing Paths ===")
            print(f"Total: {len(unique_blobs)} blobs")
            print("\nTo fix these missing hardlinks, run:")
            print("  ./ntt-parse-verify-log.py --blobs-only > /tmp/missing_blobs.txt")
            print("  sudo ntt-re-hardlink.py --from-file /tmp/missing_blobs.txt")

if __name__ == "__main__":
    main()