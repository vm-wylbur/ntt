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


def create_hardlinks_idempotent(hash_path: Path, paths_to_link: list[str], 
                                archive_root: Path) -> int:
    """
    Idempotently create hardlinks for a list of paths.
    
    This function is designed to be safely re-runnable. It will:
    - Create parent directories as needed (mode 0o755)
    - Create hardlinks for paths that don't exist
    - Replace paths that exist but aren't hardlinked to the correct by-hash inode
    - Ignore FileExistsError from concurrent workers
    
    Args:
        hash_path: Path to by-hash file (link source)
        paths_to_link: List of absolute paths to create links for
        archive_root: Archive root directory
        
    Returns:
        Number of new hardlinks actually created
        
    Raises:
        OSError: On filesystem errors other than FileExistsError
    """
    created_count = 0
    hash_path_stat = hash_path.stat()
    
    for path in paths_to_link:
        # Handle both str and bytes from database
        if isinstance(path, bytes):
            # Decode bytea using surrogateescape to preserve invalid UTF-8
            path_str = path.decode('utf-8', errors='surrogateescape')
        else:
            path_str = path

        # Sanitize path to handle HFS+ escape sequences
        sanitized_path = path_str.replace('\\r', '\r').replace('\\n', '\n')
        archive_path = archive_root / sanitized_path.lstrip('/')
        
        # Check if archive path exists
        if archive_path.exists():
            # Verify it's the same inode (proper hardlink)
            if archive_path.stat().st_ino == hash_path_stat.st_ino:
                # Already correctly hardlinked - skip
                continue
            else:
                # Orphaned hardlink to old by-hash inode - replace it
                archive_path.unlink()
        
        try:
            # Create parent directory with proper permissions
            archive_path.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
            
            # Create hardlink
            os.link(hash_path, archive_path)
            created_count += 1
            
        except FileExistsError:
            # Another worker/process created it concurrently - safe to ignore
            pass
    
    return created_count


def ensure_directory_ownership(archive_path: Path, archive_root: Path) -> None:
    """
    Ensure proper ownership and permissions for archive directories.
    
    Sets ownership to SUDO_USER:SUDO_GID and mode to 0o755.
    Only modifies directories owned by root.
    
    Args:
        archive_path: Path to directory being created
        archive_root: Archive root (don't modify above this)
    """
    uid = int(os.environ.get('SUDO_UID', -1))
    gid = int(os.environ.get('SUDO_GID', -1))
    
    if uid == -1 or gid == -1:
        # Not running under sudo, leave as-is
        return
    
    # Walk from archive_path up to (but not including) archive_root
    for part in reversed(list(archive_path.parents)):
        if part == archive_root or not part.is_relative_to(archive_root):
            break
            
        try:
            if part.exists() and part.owner() == "root":
                os.chown(part, uid, gid)
                os.chmod(part, 0o755)
        except (FileNotFoundError, PermissionError):
            # Race condition or permission issue - safe to ignore
            pass
