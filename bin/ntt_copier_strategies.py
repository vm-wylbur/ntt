#!/usr/bin/env python3
"""
ntt_copier_strategies.py - Strategy functions for ntt-copier

Extracted and refactored logic from the deprecated processor chain.
These functions implement the Claim-Analyze-Execute pattern.
"""

import os
import shutil
from pathlib import Path
from typing import Optional
import blake3
import magic

# Empty file hash constant (SHA256 of zero bytes)
EMPTY_FILE_HASH = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"


def sanitize_path(path: str | bytes) -> Path:
    """
    Convert database path (text or bytea) to filesystem path.

    Handles both text and bytea from database:
    - bytea: Decoded using surrogateescape to preserve invalid UTF-8 bytes
    - text: Used directly

    Also handles escape sequences like \\r (stored as literal text) by converting
    them to actual control characters for HFS+ metadata directories.

    Args:
        path: Path from database (str or bytes, may contain literal \\r, \\n, etc.)

    Returns:
        Path object with escape sequences converted to actual characters
    """
    # Handle bytea from PostgreSQL
    if isinstance(path, bytes):
        # Use surrogateescape to preserve invalid UTF-8 bytes
        # This allows round-tripping through Python back to filesystem
        path_str = path.decode('utf-8', errors='surrogateescape')
    else:
        path_str = path

    # Replace literal escape sequences with actual control characters
    # This handles HFS+ Private Directory Data\r paths
    sanitized = path_str.replace('\\r', '\r').replace('\\n', '\n')
    return Path(sanitized)


def parse_partition_path(path: str | bytes, medium_hash: str) -> Path:
    """
    Parse path and construct correct source path.

    Paths may be stored as:
    - Full absolute path: /mnt/ntt/{hash}/p5/file (new format, includes partition)
    - Full absolute path: /mnt/ntt/{hash}/file (single partition)
    - Relative path: /file (construct with mount base)
    - Legacy with p{N}: prefix: p5:/mnt/ntt/{hash}/p5/file (old format, to be cleaned)

    Args:
        path: Path from database (may be absolute or relative)
        medium_hash: Medium hash for constructing mount path

    Returns:
        Full source path for filesystem access

    Examples:
        parse_partition_path("/mnt/ntt/abc123/p5/etc/passwd", "abc123")
        -> Path("/mnt/ntt/abc123/p5/etc/passwd")

        parse_partition_path("/etc/passwd", "abc123")
        -> Path("/mnt/ntt/abc123/etc/passwd")
    """
    # Handle bytea from PostgreSQL
    if isinstance(path, bytes):
        path_str = path.decode('utf-8', errors='surrogateescape')
    else:
        path_str = path

    # Legacy cleanup: strip p{N}: prefix if present
    if path_str.startswith('p') and ':' in path_str[:4]:
        # Strip prefix (e.g., "p5:/mnt/..." -> "/mnt/...")
        path_str = path_str.split(':', 1)[1]

    # Check if path is already absolute (starts with /mnt/ntt/{hash})
    expected_mount_prefix = f"/mnt/ntt/{medium_hash}"

    if path_str.startswith(expected_mount_prefix):
        # Already full path - use directly
        sanitized_path = path_str.replace('\\r', '\r').replace('\\n', '\n')
        source_path = Path(sanitized_path)
    else:
        # Relative path - construct with mount base
        sanitized_path = path_str.replace('\\r', '\r').replace('\\n', '\n')
        # Strip medium_hash prefix if present (carved files case)
        if sanitized_path.startswith(f"{medium_hash}/"):
            sanitized_path = sanitized_path[len(medium_hash)+1:]
        source_path = Path(expected_mount_prefix) / sanitized_path.lstrip('/')

    return source_path


def detect_fs_type(source_path: Path) -> Optional[str]:
    """
    Detect filesystem type for a path.
    
    Returns:
        'f': regular file
        'd': directory
        'l': symlink
        'b': block device
        'c': character device
        'p': named pipe (FIFO)
        's': socket
        None: if path doesn't exist or unknown type
    
    Note: Checks symlinks BEFORE exists() because broken symlinks
    return False for exists() but we still want to process them.
    """
    if source_path.is_symlink():
        return 'l'
    elif not source_path.exists():
        return None
    elif source_path.is_dir():
        return 'd'
    elif source_path.is_file():
        return 'f'
    elif source_path.is_block_device():
        return 'b'
    elif source_path.is_char_device():
        return 'c'
    elif source_path.is_fifo():
        return 'p'
    elif source_path.is_socket():
        return 's'
    else:
        return None


def detect_mime_type(magic_instance: magic.Magic, file_path: Path) -> Optional[str]:
    """
    Detect MIME type of a file using python-magic.
    
    Args:
        magic_instance: Initialized magic.Magic(mime=True) instance
        file_path: Path to file
        
    Returns:
        MIME type string or None if detection fails
    """
    try:
        return magic_instance.from_file(str(file_path))
    except Exception:
        return None


def hash_file(file_path: Path, chunk_size: int = 64 * 1024 * 1024) -> str:
    """
    Calculate BLAKE3 hash of a file.
    
    Args:
        file_path: Path to file
        chunk_size: Read chunk size (default 64MB)
        
    Returns:
        Hexadecimal hash string
    """
    hasher = blake3.blake3()
    with open(file_path, 'rb') as f:
        while chunk := f.read(chunk_size):
            hasher.update(chunk)
    return hasher.hexdigest()


def copy_file_to_temp(source_path: Path, temp_path: Path, size: int) -> None:
    """
    Copy file to temporary location for processing.
    
    Uses streaming copy for large files (>100MB).
    Preserves metadata with shutil.copystat().
    
    Args:
        source_path: Source file path
        temp_path: Destination temp path
        size: File size in bytes
        
    Raises:
        OSError: If copy fails
    """
    # Parent dir (tmpfs mount) is pre-created by wrapper script, no need to mkdir
    
    if size < 100 * 1024 * 1024:  # 100MB threshold
        shutil.copy2(source_path, temp_path)
    else:
        # Stream large files in chunks
        with open(source_path, 'rb') as src:
            with open(temp_path, 'wb') as dst:
                while chunk := src.read(64 * 1024 * 1024):  # 64MB chunks
                    dst.write(chunk)
        # Preserve metadata
        shutil.copystat(source_path, temp_path)


def read_symlink_target(symlink_path: Path) -> str:
    """
    Read symlink target.
    
    Args:
        symlink_path: Path to symlink
        
    Returns:
        Target path as string
        
    Raises:
        OSError: If readlink fails
    """
    return os.readlink(symlink_path)


def filter_longest_paths(paths: list[str]) -> set[str]:
    """
    Filter to keep only the longest (leaf) paths, removing ancestor directories.

    Since mkdir(parents=True) creates all ancestors automatically, we only need
    to create the deepest directories. This reduces redundant syscalls.

    Args:
        paths: List of directory path strings

    Returns:
        Set of leaf directory paths (those with no children in the input set)
    """
    sorted_paths = sorted(paths)
    result = []

    for i, path in enumerate(sorted_paths):
        # Check if any subsequent path has this as a directory prefix
        is_prefix = False
        for j in range(i + 1, len(sorted_paths)):
            # Lexicographic sorting means once we don't match prefix, we're done
            if not sorted_paths[j].startswith(path):
                break
            # Check if it's a proper directory prefix (not just string prefix)
            if sorted_paths[j].startswith(path + '/'):
                is_prefix = True
                break

        if not is_prefix:
            result.append(path)

    return set(result)


# Hardlink functions removed - archive tree reconstruction abandoned
# See commit message for rationale
