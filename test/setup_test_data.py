#!/usr/bin/env -S /home/pball/.local/bin/uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = [
#     "psycopg[binary]",
# ]
# ///
"""
setup_test_data.py - Generate test data for ntt-copier testing

Creates diverse test files and database records in isolated test environment.
"""

import argparse
import os
import sys
from pathlib import Path
import psycopg
from psycopg.rows import dict_row

def create_test_files(source_dir: Path) -> list[dict]:
    """Create diverse test files and return their metadata."""
    source_dir.mkdir(parents=True, exist_ok=True)
    
    files = []
    
    # 1. Empty files (5 files)
    for i in range(5):
        path = source_dir / f"empty_{i}.txt"
        path.touch()
        files.append({
            'path': str(path),
            'size': 0,
            'fs_type': 'f',
            'description': 'empty file'
        })
    
    # 2. Small text files with identical content (10 files - tests deduplication)
    identical_content = b"This is identical content for deduplication testing\n"
    for i in range(10):
        path = source_dir / f"duplicate_{i}.txt"
        path.write_bytes(identical_content)
        files.append({
            'path': str(path),
            'size': len(identical_content),
            'fs_type': 'f',
            'description': 'duplicate content'
        })
    
    # 3. Small unique text files (20 files)
    for i in range(20):
        path = source_dir / f"unique_{i}.txt"
        content = f"Unique content for file {i}\n" * (i + 1)
        path.write_bytes(content.encode())
        files.append({
            'path': str(path),
            'size': len(content),
            'fs_type': 'f',
            'description': 'unique text file'
        })
    
    # 4. Small binary files (10 files)
    for i in range(10):
        path = source_dir / f"binary_{i}.dat"
        content = bytes(range(256)) * (i + 1)
        path.write_bytes(content)
        files.append({
            'path': str(path),
            'size': len(content),
            'fs_type': 'f',
            'description': 'binary file'
        })
    
    # 5. Directories (10 directories)
    for i in range(10):
        path = source_dir / f"dir_{i}"
        path.mkdir(exist_ok=True)
        files.append({
            'path': str(path),
            'size': 4096,  # Typical directory size
            'fs_type': 'd',
            'description': 'directory'
        })
    
    # 6. Nested directories with files
    nested = source_dir / "nested" / "deep" / "structure"
    nested.mkdir(parents=True, exist_ok=True)
    files.append({
        'path': str(source_dir / "nested"),
        'size': 4096,
        'fs_type': 'd',
        'description': 'nested directory'
    })
    files.append({
        'path': str(source_dir / "nested" / "deep"),
        'size': 4096,
        'fs_type': 'd',
        'description': 'nested directory'
    })
    files.append({
        'path': str(nested),
        'size': 4096,
        'fs_type': 'd',
        'description': 'nested directory'
    })
    
    nested_file = nested / "file.txt"
    nested_file.write_text("Nested file content\n")
    files.append({
        'path': str(nested_file),
        'size': nested_file.stat().st_size,
        'fs_type': 'f',
        'description': 'nested file'
    })
    
    # 7. Symlinks (5 valid, 2 broken)
    for i in range(5):
        target = source_dir / f"unique_{i}.txt"
        link = source_dir / f"symlink_{i}.lnk"
        link.symlink_to(target)
        files.append({
            'path': str(link),
            'size': len(str(target)),
            'fs_type': 'l',
            'description': 'valid symlink'
        })
    
    # Broken symlinks
    for i in range(2):
        link = source_dir / f"broken_symlink_{i}.lnk"
        link.symlink_to("/nonexistent/path")
        files.append({
            'path': str(link),
            'size': len("/nonexistent/path"),
            'fs_type': 'l',
            'description': 'broken symlink'
        })
    
    # 8. Files with multiple hardlinks (same inode, different paths)
    hardlink_source = source_dir / "hardlink_source.txt"
    hardlink_source.write_text("Content with multiple paths\n")
    files.append({
        'path': str(hardlink_source),
        'size': hardlink_source.stat().st_size,
        'fs_type': 'f',
        'description': 'hardlink source'
    })
    
    for i in range(3):
        link = source_dir / f"hardlink_{i}.txt"
        link.hardlink_to(hardlink_source)
        files.append({
            'path': str(link),
            'size': link.stat().st_size,
            'fs_type': 'f',
            'description': 'hardlink to source'
        })
    
    return files

def populate_database(db_url: str, schema: str, files: list[dict]):
    """Populate test database with inode and path records."""
    conn = psycopg.connect(db_url, row_factory=dict_row)
    
    # Set search path to test schema
    with conn.cursor() as cur:
        cur.execute(f"SET search_path = {schema}")
    
    # Create a test medium
    medium_hash = "test_medium_001"
    with conn.cursor() as cur:
        cur.execute(f"""
            INSERT INTO {schema}.medium (medium_hash, medium_human, added_at)
            VALUES (%s, %s, NOW())
            ON CONFLICT (medium_hash) DO NOTHING
        """, (medium_hash, "Test Medium"))
    conn.commit()
    
    # Group files by inode (for hardlinks)
    inode_map = {}
    for file_info in files:
        path = Path(file_info['path'])
        if path.exists() or path.is_symlink():
            stat = path.lstat()  # lstat doesn't follow symlinks
            inode_key = (stat.st_dev, stat.st_ino)
            
            if inode_key not in inode_map:
                inode_map[inode_key] = {
                    'dev': stat.st_dev,
                    'ino': stat.st_ino,
                    'size': file_info['size'],
                    'fs_type': file_info['fs_type'],
                    'paths': []
                }
            inode_map[inode_key]['paths'].append(file_info['path'])
    
    # Insert inodes and paths
    inode_count = 0
    path_count = 0
    
    with conn.cursor() as cur:
        for inode_key, inode_data in inode_map.items():
            # Insert inode
            cur.execute(f"""
                INSERT INTO {schema}.inode (
                    medium_hash, dev, ino, size, fs_type,
                    copied, by_hash_created, processed_at
                )
                VALUES (%s, %s, %s, %s, %s, false, false, NULL)
                ON CONFLICT (medium_hash, dev, ino) DO NOTHING
            """, (
                medium_hash,
                inode_data['dev'],
                inode_data['ino'],
                inode_data['size'],
                inode_data['fs_type']
            ))
            inode_count += 1
            
            # Insert all paths for this inode
            for path in inode_data['paths']:
                cur.execute(f"""
                    INSERT INTO {schema}.path (medium_hash, dev, ino, path)
                    VALUES (%s, %s, %s, %s)
                    ON CONFLICT (medium_hash, dev, ino, path) DO NOTHING
                """, (
                    medium_hash,
                    inode_data['dev'],
                    inode_data['ino'],
                    path
                ))
                path_count += 1
    
    conn.commit()
    conn.close()
    
    return inode_count, path_count

def main():
    parser = argparse.ArgumentParser(description='Generate test data for ntt-copier')
    parser.add_argument('--db-url', required=True, help='Database URL')
    parser.add_argument('--schema', required=True, help='Schema name')
    parser.add_argument('--source', required=True, help='Source directory path')
    
    args = parser.parse_args()
    
    source_dir = Path(args.source)
    
    print(f"Creating test files in {source_dir}...")
    files = create_test_files(source_dir)
    print(f"✓ Created {len(files)} test files")
    
    print(f"Populating database schema {args.schema}...")
    inode_count, path_count = populate_database(args.db_url, args.schema, files)
    print(f"✓ Inserted {inode_count} inodes and {path_count} paths")
    
    print("\nTest data summary:")
    print(f"  Total files created: {len(files)}")
    print(f"  Inodes in database: {inode_count}")
    print(f"  Paths in database: {path_count}")
    print(f"  Source directory: {source_dir}")

if __name__ == '__main__':
    main()
