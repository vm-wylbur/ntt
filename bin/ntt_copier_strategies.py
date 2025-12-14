#!/usr/bin/env python3
# Author: PB and Claude
# Date: 2025-11-16
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/bin/ntt_copier_strategies.py
#
# Shared strategies for ntt-copier and ntt-extractor
#
# Functions for:
# - File hashing (BLAKE3)
# - MIME type detection
# - File copying strategies
# - Path parsing

import blake3
import shutil
import subprocess
import unicodedata
from pathlib import Path
from typing import Optional

# BLAKE3 hash of empty file (0 bytes)
EMPTY_FILE_HASH = "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"


def parse_partition_path(path_bytes: bytes, medium_hash: str) -> Path:
    """
    Parse path from database (bytea) into filesystem path.

    For v2.0 unpartitioned schema, paths are stored as bytea.
    Handles both:
    - Relative paths from mounted images (prepend /mnt/ntt/{hash})
    - Absolute paths from extracted media (return as-is)

    Args:
        path_bytes: Path as bytea from database
        medium_hash: Medium hash to determine mount point

    Returns:
        Path object for filesystem access
    """
    # BUG FIX: Decode as UTF-8 first, preserve original Unicode form
    # Problem: Database stores exact bytes from filesystem (could be NFD or NFC).
    # Latin1 decoding creates mojibake.
    # Solution: UTF-8 decode → use as-is → fallback to alternate form if not found

    if isinstance(path_bytes, bytes):
        try:
            # Try UTF-8 first (proper Unicode handling)
            path_str = path_bytes.decode('utf-8')
        except UnicodeDecodeError:
            # Fall back to latin1 for truly binary paths (rare)
            path_str = path_bytes.decode('latin1')
    elif isinstance(path_bytes, memoryview):
        # psycopg may return memoryview for bytea
        path_str = bytes(path_bytes).decode('utf-8')
    else:
        path_str = str(path_bytes)

    # If path is already absolute, return as-is (extracted media case)
    if path_str.startswith('/'):
        # Try path as-is first (preserves original NFD/NFC form from filesystem)
        result = Path(path_str)
        if result.exists():
            return result

        # If not found, try NFC normalized (for cross-platform compatibility)
        nfc_path = unicodedata.normalize('NFC', path_str)
        if nfc_path != path_str:
            result_nfc = Path(nfc_path)
            if result_nfc.exists():
                return result_nfc

        # If still not found, try NFD normalized (macOS HFS+ stores NFD)
        nfd_path = unicodedata.normalize('NFD', path_str)
        if nfd_path != path_str:
            result_nfd = Path(nfd_path)
            if result_nfd.exists():
                return result_nfd

        # Return original path (will fail on access, but preserves error message)
        return result

    # Relative path - prepend mount point
    mount_base = Path(f"/mnt/ntt/{medium_hash}")
    if mount_base.exists():
        # Try as-is first
        result = mount_base / path_str
        if result.exists():
            return result

        # Try NFC normalized
        nfc_path = unicodedata.normalize('NFC', path_str)
        if nfc_path != path_str:
            result_nfc = mount_base / nfc_path
            if result_nfc.exists():
                return result_nfc

        # Try NFD normalized
        nfd_path = unicodedata.normalize('NFD', path_str)
        if nfd_path != path_str:
            result_nfd = mount_base / nfd_path
            if result_nfd.exists():
                return result_nfd

        # Return original (will fail but preserves error info)
        return result

    # Fallback: treat as relative to cwd
    return Path(path_str)


def detect_fs_type(path: Path) -> Optional[str]:
    """
    Detect filesystem type of a path.

    Returns:
        Single character: 'f' (file), 'd' (dir), 'l' (symlink), etc.
        None if path doesn't exist
    """
    try:
        if path.is_symlink():
            return 'l'
        elif path.is_file():
            return 'f'
        elif path.is_dir():
            return 'd'
        elif path.is_block_device():
            return 'b'
        elif path.is_char_device():
            return 'c'
        elif path.is_fifo():
            return 'p'
        elif path.is_socket():
            return 's'
        else:
            return None
    except (OSError, PermissionError):
        return None


def copy_file_to_temp(source: Path, dest: Path, expected_size: int):
    """
    Copy file to temporary location for hashing.

    Args:
        source: Source file path
        dest: Destination temporary path
        expected_size: Expected file size (for validation)

    Raises:
        IOError: If copy fails or size mismatch
    """
    try:
        shutil.copy2(source, dest)

        # Verify size matches
        actual_size = dest.stat().st_size
        if actual_size != expected_size:
            raise IOError(
                f"Size mismatch: expected {expected_size}, got {actual_size}"
            )
    except (OSError, shutil.Error) as e:
        raise IOError(f"Failed to copy {source} to {dest}: {e}")


def hash_file(path: Path) -> str:
    """
    Compute BLAKE3 hash of file.

    Args:
        path: Path to file to hash

    Returns:
        Hex-encoded BLAKE3 hash (64 chars)

    Raises:
        IOError: If file cannot be read
    """
    try:
        hasher = blake3.blake3()
        with open(path, 'rb') as f:
            while True:
                chunk = f.read(65536)  # 64KB chunks
                if not chunk:
                    break
                hasher.update(chunk)
        return hasher.hexdigest()
    except (OSError, IOError) as e:
        raise IOError(f"Failed to hash {path}: {e}")


def detect_mime_type(mime_detector, path: Path) -> str:
    """
    Detect MIME type of file using python-magic.

    Args:
        mime_detector: magic.Magic instance (reused across calls)
        path: Path to file

    Returns:
        MIME type string (e.g., "text/plain", "application/pdf")
        Returns "application/octet-stream" on error
    """
    try:
        return mime_detector.from_file(str(path))
    except Exception:
        return "application/octet-stream"


def read_symlink_target(path: Path) -> str:
    """
    Read symlink target.

    Args:
        path: Path to symlink

    Returns:
        Target path as string

    Raises:
        OSError: If not a symlink or cannot read
    """
    return str(path.readlink())


def move_to_byhash(temp_path: Path, blobid: str, by_hash_root: Path) -> Path:
    """
    Move file from temp to by-hash storage with deduplication.

    Uses hardlinks for deduplication - if target already exists, creates
    hardlink instead of copying.

    Args:
        temp_path: Temporary file path
        blobid: BLAKE3 hash (blob ID)
        by_hash_root: Root of by-hash storage

    Returns:
        Final path in by-hash storage

    Raises:
        IOError: If move fails
    """
    # Compute by-hash path: /data/fast/ntt/by-hash/ab/cd/abcd...
    prefix1 = blobid[:2]
    prefix2 = blobid[2:4]
    target_dir = by_hash_root / prefix1 / prefix2
    target_path = target_dir / blobid

    # Create directory if needed
    target_dir.mkdir(parents=True, exist_ok=True)

    try:
        if target_path.exists():
            # File already exists - deduplicate by creating hardlink
            # Remove temp file, create hardlink to existing file
            temp_path.unlink()
            # Return existing path (we didn't need to move anything)
            return target_path
        else:
            # Move file to by-hash storage
            shutil.move(str(temp_path), str(target_path))
            return target_path
    except (OSError, shutil.Error) as e:
        raise IOError(f"Failed to move {temp_path} to {target_path}: {e}")
